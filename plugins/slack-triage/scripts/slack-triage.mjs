#!/usr/bin/env node
/**
 * Slack -> GitHub issue triage plumbing.
 *
 * Deterministic halves of the pipeline only. Everything judgement-shaped
 * (is this real, what is the fix, how urgent) lives in the `/slack-triage:triage-slack`
 * command, because it needs the repo checked out and its conventions in
 * context — which is exactly why this is a per-repo plugin rather than a
 * hosted service.
 *
 *   init          Write a starter slack-triage.json, discovering board fields.
 *   refresh-board Re-resolve cached board field IDs into an existing config.
 *   fetch         Emit flagged-but-unprocessed Slack messages as JSON.
 *   file          Create the issue, put it on the board, mark Slack done.
 *
 * A message is a candidate when it carries the trigger reaction and does not
 * yet carry the done reaction. Slack itself is therefore the record of what has
 * been processed — no local watermark to lose — so re-running is safe.
 */

import { execFile, spawn } from "node:child_process";
import { createWriteStream } from "node:fs";
import { lstat, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const CONFIG_FILENAME = "slack-triage.json";

const DEFAULTS = {
  triggerEmoji: "ticket",
  doneEmoji: "white_check_mark",
  lookbackDays: 14,
  keychainService: "slack-triage",
  // Only states a triage run may file into. `Todo` dispatches the agent;
  // `Blocked` and `Backlog` are the escape hatches when research cannot
  // substantiate the report. The rest belong to the workflow, not to intake.
  fileableStates: ["Todo", "Blocked", "Backlog"],
  // States that hand the issue to an agent the moment it lands. Filing into
  // one is a per-draft human decision, so `file` refuses these without
  // --confirmed. The reaction alone is a nomination, not that decision — the
  // safe target for an unconfirmed draft is Backlog.
  confirmRequiredStates: ["Todo"],
  // Detent sets github_graphql_min_remaining_reserve: 1000 so no single project
  // can drain the per-user GraphQL quota the whole fleet shares. This script is
  // not Detent but draws on the same quota, so it honours the same floor rather
  // than being the thing that starves the fleet.
  graphqlMinRemainingReserve: 1000,
};

class TriageError extends Error {}

/* -------------------------------------------------------------------------- */
/* Config                                                                      */
/* -------------------------------------------------------------------------- */

/** Walks up from `startDirectory` looking for the repo's triage config. */
async function findConfigPath(startDirectory) {
  let directory = path.resolve(startDirectory);

  for (;;) {
    const candidate = path.join(directory, CONFIG_FILENAME);
    try {
      await readFile(candidate, "utf8");
      return candidate;
    } catch {
      const parent = path.dirname(directory);
      if (parent === directory) return null;
      directory = parent;
    }
  }
}

async function readJsonFile(filePath, label) {
  let raw;
  try {
    raw = await readFile(filePath, "utf8");
  } catch (error) {
    throw new TriageError(
      `Cannot read ${label} at ${filePath}: ${error.code ?? error.message}`,
    );
  }

  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new TriageError(
      `${label} at ${filePath} is not valid JSON: ${error.message}`,
    );
  }
}

async function loadConfig(explicitPath) {
  const configPath = explicitPath ?? (await findConfigPath(process.cwd()));

  if (!configPath) {
    throw new TriageError(
      `No ${CONFIG_FILENAME} found in this repo or any parent.\n` +
        "Create one with:\n" +
        "  node <plugin>/scripts/slack-triage.mjs init \\\n" +
        "    --repo owner/name --project-id PVT_… --channel '#feedback'",
    );
  }

  const config = await readJsonFile(configPath, "config");
  const slack = { ...DEFAULTS, ...(config.slack ?? {}) };

  return {
    path: configPath,
    repository: config.repository,
    slack,
    board: config.board ?? {},
    fileableStates: new Set(config.fileableStates ?? DEFAULTS.fileableStates),
    confirmRequiredStates: new Set(
      config.confirmRequiredStates ?? DEFAULTS.confirmRequiredStates,
    ),
    graphqlMinRemainingReserve:
      config.graphqlMinRemainingReserve ?? DEFAULTS.graphqlMinRemainingReserve,
  };
}

/* -------------------------------------------------------------------------- */
/* Credentials                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * The bot token, from the environment or the macOS keychain. One app and one
 * token serves the whole fleet; only the channel differs per repo.
 */
async function resolveSlackToken(service) {
  if (process.env.SLACK_BOT_TOKEN) return process.env.SLACK_BOT_TOKEN;

  try {
    const { stdout } = await execFileAsync("security", [
      "find-generic-password",
      "-s",
      service,
      "-w",
    ]);
    const token = stdout.trim();
    if (token) return token;
  } catch {
    // Fall through to the actionable error below.
  }

  throw new TriageError(
    `No Slack bot token. Set SLACK_BOT_TOKEN, or store it in the keychain:\n` +
      `  security add-generic-password -s ${service} -a "$USER" -w xoxb-your-token`,
  );
}

/* -------------------------------------------------------------------------- */
/* Slack                                                                       */
/* -------------------------------------------------------------------------- */

async function slackApi(token, method, params = {}, httpMethod = "GET") {
  const url = new URL(`https://slack.com/api/${method}`);
  const init = {
    method: httpMethod,
    headers: { Authorization: `Bearer ${token}` },
  };

  if (httpMethod === "GET") {
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }
  } else {
    init.headers["Content-Type"] = "application/json; charset=utf-8";
    init.body = JSON.stringify(params);
  }

  const response = await fetch(url, init);
  const payload = await response.json();

  if (!payload.ok) {
    // `needed` names the missing scope when that is the cause.
    const scope = payload.needed ? ` (needs scope: ${payload.needed})` : "";
    throw new TriageError(`Slack ${method} failed: ${payload.error}${scope}`);
  }

  return payload;
}

async function listChannels(token, types) {
  const channels = [];
  let cursor;

  do {
    const page = await slackApi(token, "conversations.list", {
      types,
      exclude_archived: true,
      limit: 200,
      cursor,
    });
    channels.push(...page.channels);
    cursor = page.response_metadata?.next_cursor || undefined;
  } while (cursor);

  return channels;
}

/**
 * Accepts a raw channel ID or a `#name`, returning the ID.
 *
 * Private channels are only searched when the token carries `groups:read`.
 * Asking for them unconditionally would make that scope mandatory for every
 * workspace, including those whose feedback channel is public, so a missing
 * scope narrows the search instead of failing it.
 */
async function resolveChannelId(token, channel) {
  if (/^[CGD][A-Z0-9]{6,}$/.test(channel)) return channel;
  const name = channel.replace(/^#/, "");

  let channels;
  let searchedPrivate = true;

  try {
    channels = await listChannels(token, "public_channel,private_channel");
  } catch (error) {
    if (!/missing_scope/.test(error.message)) throw error;
    searchedPrivate = false;
    channels = await listChannels(token, "public_channel");
  }

  const match = channels.find((entry) => entry.name === name);
  if (match) return match.id;

  throw new TriageError(
    searchedPrivate
      ? `Channel ${channel} not found. Invite the bot to it first.`
      : `Channel ${channel} not found among public channels, and this token ` +
          "cannot see private ones. If it is private, add the groups:read and " +
          "groups:history scopes, then reinstall the app.",
  );
}

function createUserResolver(token) {
  const cache = new Map();

  return async function resolveUser(userId) {
    if (!userId) return "unknown";
    if (cache.has(userId)) return cache.get(userId);

    try {
      const { user } = await slackApi(token, "users.info", { user: userId });
      const name = user.profile?.real_name || user.name || userId;
      cache.set(userId, name);
      return name;
    } catch {
      cache.set(userId, userId);
      return userId;
    }
  };
}

function hasReaction(message, emoji) {
  return (message.reactions ?? []).some((reaction) => reaction.name === emoji);
}

/* -------------------------------------------------------------------------- */
/* Attachments                                                                 */
/* -------------------------------------------------------------------------- */

// Only kinds the researcher can actually open. Screenshots are the common case
// — "the page pictured below" is meaningless without them.
const DOWNLOADABLE_MIMETYPES = /^(image\/|application\/pdf$|text\/)/;
const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;
// Aggregate cap for one fetch run, across every message. Enough for dozens of
// screenshots; a run that hits it keeps listing files by permalink instead of
// filling a small tmpfs before any candidate is emitted.
const MAX_RUN_ATTACHMENT_BYTES = 200 * 1024 * 1024;

/**
 * Where fetch puts a channel's attachments unless --attachments-dir says
 * otherwise. Only this default location is ever deleted by the script: fetch
 * clears it at the start of a run and file removes a message's directory once
 * that message is filed, so screenshots of client-facing pages do not outlive
 * the triage that needed them. A custom directory is the operator's to manage.
 */
const SLACK_CHANNEL_ID = /^[CGD][A-Z0-9]{6,}$/;
const SLACK_TS = /^\d+\.\d+$/;

function defaultAttachmentsRoot(channelId) {
  return path.join(os.tmpdir(), "slack-triage", channelId);
}

/**
 * Deletes one message's attachment directory in the default location — and
 * only there. The channel and ts come from a draft the agent wrote, so they
 * are re-validated here and the resolved path is checked against the root
 * before anything recursive runs; a value that would escape is refused, not
 * "cleaned up".
 */
async function removeDefaultAttachments(channelId, ts) {
  if (!SLACK_CHANNEL_ID.test(channelId) || !SLACK_TS.test(ts)) {
    throw new TriageError(
      `Refusing to delete attachments for channel=${channelId} ts=${ts}: not Slack identifiers`,
    );
  }
  const root = path.resolve(os.tmpdir(), "slack-triage");
  const target = path.resolve(defaultAttachmentsRoot(channelId), ts);
  if (!target.startsWith(root + path.sep)) {
    throw new TriageError(`Refusing to delete ${target}: outside ${root}`);
  }
  await rm(target, { recursive: true, force: true });
}

/**
 * Creates `directory` owner-only, one component at a time below `base`,
 * checking each is a real directory this user owns before descending into it
 * — not a symlink or a directory somebody else planted under a predictable
 * name in a shared /tmp. `mkdir -p` would walk straight through either.
 * `base` must already exist and is not itself checked: on a shared host it is
 * /tmp, world-writable and root-owned by design. Refusing is the safe answer:
 * the fetch still emits the message text and the file's permalink.
 */
async function ensurePrivateDirectory(base, directory) {
  const relative = path.relative(base, directory);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new TriageError(`${directory} is not below ${base}`);
  }
  let current = base;
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    try {
      await mkdir(current, { mode: 0o700 });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    const stat = await lstat(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      throw new TriageError(`${current} is not a directory — refusing to write attachments there`);
    }
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      throw new TriageError(`${current} is owned by another user — refusing to write attachments there`);
    }
  }
}

/** Nearest ancestor of `directory` that exists — the point a custom --attachments-dir walk starts from. */
async function existingAncestor(directory) {
  let current = path.resolve(directory);
  for (;;) {
    const parent = path.dirname(current);
    try {
      await lstat(parent);
      return parent;
    } catch {
      if (parent === current) return parent;
      current = parent;
    }
  }
}

function createAttachmentFetcher(token, base, directory, budget) {
  let scopeWarned = false;

  return async function fetchAttachments(message) {
    const files = message.files ?? [];
    if (files.length === 0) return [];

    // One at a time, streamed to disk: a thread can carry a hundred replies
    // and every one may hold a screenshot, so downloading them all at once and
    // buffering each whole would let one busy thread exhaust the process.
    const records = [];
    for (const file of files) {
      const record = {
        id: file.id,
        name: file.name ?? file.title ?? file.id,
        mimetype: file.mimetype ?? "unknown",
        size: file.size ?? null,
        permalink: file.permalink ?? null,
      };

      // Slack hides deleted or otherwise unavailable files behind a stub
      // (`mode: "hidden_by_limit"`, `"tombstone"`) with no URL to fetch.
      const url = file.url_private_download ?? file.url_private;
      if (!url) {
        records.push({ ...record, error: `unavailable (${file.mode ?? "no url"})` });
        continue;
      }
      if (!DOWNLOADABLE_MIMETYPES.test(record.mimetype)) {
        records.push({ ...record, error: "not downloaded (unsupported type)" });
        continue;
      }
      if (record.size && record.size > MAX_ATTACHMENT_BYTES) {
        records.push({ ...record, error: "not downloaded (over 20 MB)" });
        continue;
      }
      if ((record.size ?? MAX_ATTACHMENT_BYTES) > budget.remaining) {
        records.push({ ...record, error: "not downloaded (run attachment budget exhausted)" });
        continue;
      }

      let response;
      try {
        response = await fetch(url, {
          headers: { Authorization: `Bearer ${token}` },
        });
        const contentType = response.headers.get("content-type") ?? "";
        if (!response.ok) {
          await response.body?.cancel();
          records.push({ ...record, error: `download failed: HTTP ${response.status}` });
          continue;
        }
        // Without files:read Slack does not 403; it 302s to the workspace
        // sign-in page (`https://<team>.slack.com/?redir=/files-pri/…`) and
        // serves that as HTML with a 200. The redirect is the tell — an
        // attachment that is itself an HTML file arrives with the same
        // content type but from files.slack.com directly.
        const signInPage =
          /text\/html/.test(contentType) &&
          response.redirected &&
          /[?&]redir=/.test(response.url);
        if (signInPage) {
          // An unread body keeps the socket — and the event loop — alive
          // after main() returns, so the process never exits.
          await response.body?.cancel();
          if (!scopeWarned) {
            scopeWarned = true;
            console.error(
              "Attachments could not be downloaded — the token is missing the " +
                "files:read scope. Add it and reinstall the app; the messages " +
                "were still fetched.",
            );
          }
          records.push({ ...record, error: "missing_scope (needs scope: files:read)" });
          continue;
        }

        // Owner-only: on a shared host os.tmpdir() is /tmp, and these are
        // screenshots of client-facing pages. `wx` creates exclusively, so a
        // link planted at the path beforehand fails the open rather than
        // being followed.
        await ensurePrivateDirectory(base, directory);
        const safeName = record.name.replace(/[^\w.-]+/g, "_");
        const filePath = path.join(directory, `${file.id}-${safeName}`);
        await pipeline(
          Readable.fromWeb(response.body),
          createWriteStream(filePath, { flags: "wx", mode: 0o600 }),
        );
        budget.remaining -= (await lstat(filePath)).size;
        records.push({ ...record, path: filePath });
      } catch (error) {
        // A body left unconsumed here — say, the directory check refused —
        // holds its socket open and fetch never exits, exactly like the
        // sign-in branch above.
        await response?.body?.cancel().catch(() => {});
        records.push({ ...record, error: `download failed: ${error.message}` });
      }
    }
    return records;
  };
}

async function fetchCandidates(config, overrides) {
  const settings = { ...config.slack, ...overrides };
  const token = await resolveSlackToken(settings.keychainService);
  const channelId = await resolveChannelId(token, settings.channel);
  const resolveUser = createUserResolver(token);
  const attachmentsRoot =
    settings.attachmentsDir ?? defaultAttachmentsRoot(channelId);
  if (!settings.attachmentsDir) {
    await rm(attachmentsRoot, { recursive: true, force: true });
  }
  // Where the owner-checked directory walk starts: the OS temp dir for the
  // default location, or whatever already exists above a custom one.
  const attachmentsBase = settings.attachmentsDir
    ? await existingAncestor(attachmentsRoot)
    : os.tmpdir();
  const attachmentBudget = { remaining: MAX_RUN_ATTACHMENT_BYTES };
  const oldest = Math.floor(Date.now() / 1000) - settings.lookbackDays * 86_400;

  const messages = [];
  let cursor;
  do {
    const page = await slackApi(token, "conversations.history", {
      channel: channelId,
      oldest,
      limit: 200,
      cursor,
    });
    messages.push(...page.messages);
    cursor = page.response_metadata?.next_cursor || undefined;
  } while (cursor);

  const flagged = messages.filter(
    (message) =>
      hasReaction(message, settings.triggerEmoji) &&
      !hasReaction(message, settings.doneEmoji),
  );

  const candidates = [];
  for (const message of flagged) {
    const { permalink } = await slackApi(token, "chat.getPermalink", {
      channel: channelId,
      message_ts: message.ts,
    });

    // One directory per flagged message, so a run's screenshots don't collide
    // and a re-run overwrites rather than accumulates.
    const fetchAttachments = createAttachmentFetcher(
      token,
      attachmentsBase,
      path.join(attachmentsRoot, message.ts),
      attachmentBudget,
    );

    // Feedback is usually argued out in the thread, so the replies are often
    // where the actual reproduction detail lives — and the screenshots are
    // usually attached to a reply, not the flagged post.
    let thread = [];
    if (message.thread_ts && (message.reply_count ?? 0) > 0) {
      const { messages: replies } = await slackApi(
        token,
        "conversations.replies",
        { channel: channelId, ts: message.thread_ts, limit: 100 },
      );
      for (const reply of replies) {
        if (reply.ts === message.ts) continue;
        thread.push({
          author: await resolveUser(reply.user),
          text: reply.text,
          files: await fetchAttachments(reply),
        });
      }
    }

    const reactors = await Promise.all(
      (message.reactions ?? [])
        .find((reaction) => reaction.name === settings.triggerEmoji)
        .users.map(resolveUser),
    );

    candidates.push({
      repository: config.repository,
      channel: channelId,
      ts: message.ts,
      permalink,
      author: await resolveUser(message.user),
      postedAt: new Date(Number(message.ts) * 1000).toISOString(),
      flaggedBy: reactors,
      text: message.text,
      files: await fetchAttachments(message),
      thread,
    });
  }

  // Oldest first, so a run that files several issues queues them in the order
  // the requests actually arrived.
  candidates.sort((a, b) => Number(a.ts) - Number(b.ts));
  return candidates;
}

/* -------------------------------------------------------------------------- */
/* GitHub                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Runs `gh`, optionally piping `input` to its stdin.
 *
 * The stdin path uses spawn rather than execFile: execFile has no `input`
 * option (that belongs to the *Sync variants), so passing one is silently
 * ignored and `gh --input -` blocks forever on a stdin nothing ever closes.
 */
function ghWithStdin(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn("gh", args);
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(stderr.trim() || `gh exited with code ${code}`));
    });

    child.stdin.end(input);
  });
}

async function gh(args, input) {
  try {
    if (input !== undefined) return await ghWithStdin(args, input);
    const { stdout } = await execFileAsync("gh", args, {
      maxBuffer: 32 * 1024 * 1024,
    });
    return stdout;
  } catch (error) {
    throw new TriageError(
      `gh ${args[0]} ${args[1] ?? ""} failed: ${error.stderr || error.message}`,
    );
  }
}

async function assertGraphqlBudget(reserve) {
  const raw = await gh([
    "api",
    "rate_limit",
    "--jq",
    ".resources.graphql.remaining",
  ]);
  const remaining = Number(raw.trim());

  if (Number.isFinite(remaining) && remaining < reserve) {
    throw new TriageError(
      `GraphQL quota at ${remaining}, below the ${reserve} reserve the fleet ` +
        "shares. Not filing — the Slack flags stay unprocessed, so re-run " +
        "after the quota resets.",
    );
  }
}

/**
 * Projects v2 has no REST surface, so board coordinates cost GraphQL to
 * discover. They are cached in the config precisely so a triage run spends its
 * quota on mutations rather than rediscovery.
 */
async function discoverBoardFields(projectId) {
  const query = `query{node(id:"${projectId}"){... on ProjectV2{title fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}}}}}`;
  const raw = await gh(["api", "graphql", "-f", `query=${query}`]);
  const project = JSON.parse(raw).data?.node;

  if (!project) {
    throw new TriageError(`Project ${projectId} not found, or the token lacks the 'project' scope.`);
  }

  const fields = (project.fields?.nodes ?? []).filter((node) => node?.name);
  const byName = (name) => fields.find((field) => field.name === name);
  const toOptionMap = (field) =>
    Object.fromEntries((field.options ?? []).map((o) => [o.name, o.id]));

  const status = byName("Status");
  if (!status) {
    throw new TriageError(
      `Project "${project.title}" has no single-select "Status" field.`,
    );
  }

  const priority = byName("Priority");

  return {
    projectId,
    projectTitle: project.title,
    statusFieldId: status.id,
    statusOptions: toOptionMap(status),
    // Not every board carries Priority; filing simply skips it when absent.
    priorityFieldId: priority?.id ?? null,
    priorityOptions: priority ? toOptionMap(priority) : {},
  };
}

async function createIssue(repository, { title, body, labels }) {
  const payload = { title, body, ...(labels?.length ? { labels } : {}) };

  // REST, deliberately: issue creation is the one part of filing that does not
  // have to touch the contended GraphQL quota.
  const raw = await gh(
    [
      "api",
      "--method",
      "POST",
      `repos/${repository}/issues`,
      "--input",
      "-",
      "--jq",
      "{number: .number, url: .html_url, nodeId: .node_id}",
    ],
    JSON.stringify(payload),
  );

  return JSON.parse(raw);
}

async function addIssueToBoard(projectId, issueNodeId) {
  const raw = await gh([
    "api",
    "graphql",
    "-f",
    `query=mutation{addProjectV2ItemById(input:{projectId:"${projectId}",contentId:"${issueNodeId}"}){item{id}}}`,
    "--jq",
    ".data.addProjectV2ItemById.item.id",
  ]);

  return raw.trim();
}

async function setSingleSelectField(projectId, itemId, fieldId, optionId) {
  await gh([
    "api",
    "graphql",
    "-f",
    `query=mutation{updateProjectV2ItemFieldValue(input:{projectId:"${projectId}",itemId:"${itemId}",fieldId:"${fieldId}",value:{singleSelectOptionId:"${optionId}"}}){projectV2Item{id}}}`,
    "--jq",
    ".data.updateProjectV2ItemFieldValue.projectV2Item.id",
  ]);
}

/* -------------------------------------------------------------------------- */
/* file                                                                        */
/* -------------------------------------------------------------------------- */

function validateDraft(draft, config) {
  const { board } = config;
  const problems = [];

  if (!config.repository) problems.push("config is missing `repository`");
  if (!board.projectId) problems.push("config is missing `board.projectId`");
  if (!board.statusFieldId) {
    problems.push("config is missing board field IDs — run `refresh-board`");
  }
  if (!draft.title?.trim()) problems.push("title is required");
  if (!draft.body?.trim()) problems.push("body is required");
  // These two also name the attachment directory that filing deletes, so
  // they must be Slack identifiers and nothing else — a draft is written by
  // the agent, and the agent reads Slack.
  if (!SLACK_CHANNEL_ID.test(draft.slack?.channel ?? "")) {
    problems.push("slack.channel must be a Slack channel ID (C…, G…, or D…)");
  }
  if (!SLACK_TS.test(draft.slack?.ts ?? "")) {
    problems.push("slack.ts must be a Slack message timestamp (seconds.fraction)");
  }

  if (!config.fileableStates.has(draft.status)) {
    problems.push(
      `status must be one of ${[...config.fileableStates].join(", ")} (got ${draft.status})`,
    );
  } else if (board.statusOptions && !(draft.status in board.statusOptions)) {
    problems.push(`board has no Status option named ${draft.status}`);
  }

  if (draft.priority && board.priorityFieldId) {
    if (!(draft.priority in board.priorityOptions)) {
      problems.push(
        `priority must be one of ${Object.keys(board.priorityOptions).join(", ")} (got ${draft.priority})`,
      );
    }
  }

  if (problems.length) {
    throw new TriageError(`Invalid draft:\n  - ${problems.join("\n  - ")}`);
  }
}

async function fileDraft(draft, config, { dryRun, confirmed }) {
  validateDraft(draft, config);
  const { board } = config;

  // Not folded into validateDraft: this is not a malformed draft, it is a
  // well-formed draft missing a human decision. Dry runs create nothing, so
  // they stay exempt.
  //
  // The flag is a tripwire, not authentication. The script cannot know who
  // set it, and an agent filing drafts already runs with the operator's own
  // authority, so no in-process check can bind approval to a human — an
  // unattended agent could pass the flag too, instructions notwithstanding.
  // What this enforces is narrower and real: no draft reaches a dispatching
  // state silently. Reaching one always requires this explicit flag, which
  // makes any bypass a single auditable act rather than a default.
  if (!dryRun && !confirmed && config.confirmRequiredStates.has(draft.status)) {
    throw new TriageError(
      `Filing into ${draft.status} hands the issue to an agent, and the ` +
        `trigger reaction alone does not authorize that.\n` +
        `Show the operator this draft and re-run with --confirmed once they ` +
        `approve it. If no operator can answer — a headless or scheduled ` +
        `run — file it as Backlog instead. Never pass --confirmed on your ` +
        `own authority.`,
    );
  }

  if (dryRun) {
    console.log("DRY RUN — nothing was created.\n");
    console.log(`Repository : ${config.repository}`);
    console.log(`Board      : ${board.projectTitle ?? board.projectId}`);
    console.log(`Title      : ${draft.title}`);
    console.log(`Labels     : ${draft.labels?.join(", ") || "(none)"}`);
    console.log(`Status     : ${draft.status}`);
    console.log(`Priority   : ${draft.priority ?? "(unset)"}`);
    console.log(`Slack      : ${draft.slack.permalink ?? draft.slack.ts}`);
    console.log(`\n--- body ---\n${draft.body}`);
    return;
  }

  await assertGraphqlBudget(config.graphqlMinRemainingReserve);

  const issue = await createIssue(config.repository, draft);
  console.log(`Created ${issue.url}`);

  const itemId = await addIssueToBoard(board.projectId, issue.nodeId);
  await setSingleSelectField(
    board.projectId,
    itemId,
    board.statusFieldId,
    board.statusOptions[draft.status],
  );

  if (draft.priority && board.priorityFieldId) {
    await setSingleSelectField(
      board.projectId,
      itemId,
      board.priorityFieldId,
      board.priorityOptions[draft.priority],
    );
  }
  console.log(
    `Board: Status=${draft.status}` +
      (draft.priority ? ` Priority=${draft.priority}` : ""),
  );

  // The issue exists, so the screenshots fetch pulled for it have done their
  // job; do not leave copies of client-facing pages sitting in tmp. A failure
  // here is reported, not thrown — aborting now would skip the Slack marker
  // below and the next run would file this message again.
  try {
    await removeDefaultAttachments(draft.slack.channel, draft.slack.ts);
  } catch (error) {
    console.error(
      `WARNING: could not remove downloaded attachments: ${error.message}\n` +
        `Delete ${path.join(defaultAttachmentsRoot(draft.slack.channel), draft.slack.ts)} by hand.`,
    );
  }

  // Slack is marked last and best-effort. A failure here re-surfaces the
  // message on the next run, which risks a duplicate issue — noisy but
  // recoverable. Failing before the issue exists would lose the request
  // entirely, which is not.
  try {
    const token = await resolveSlackToken(config.slack.keychainService);
    await slackApi(
      token,
      "reactions.add",
      {
        channel: draft.slack.channel,
        timestamp: draft.slack.ts,
        name: config.slack.doneEmoji,
      },
      "POST",
    );
    await slackApi(
      token,
      "chat.postMessage",
      {
        channel: draft.slack.channel,
        thread_ts: draft.slack.ts,
        text: `Filed as <${issue.url}|#${issue.number}> — ${draft.status}${draft.priority ? `, ${draft.priority} priority` : ""}.`,
        unfurl_links: false,
      },
      "POST",
    );
    console.log(`Slack: marked :${config.slack.doneEmoji}: and replied in thread`);
  } catch (error) {
    console.error(
      `WARNING: ${issue.url} was filed, but marking Slack failed: ${error.message}\n` +
        `Add :${config.slack.doneEmoji}: to the message manually or the next run will file it again.`,
    );
  }
}

/* -------------------------------------------------------------------------- */
/* init / refresh-board                                                        */
/* -------------------------------------------------------------------------- */

async function writeConfig(configPath, config) {
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
}

async function runInit(options) {
  const repository = options.repo;
  const projectId = options["project-id"];
  const channel = options.channel;

  if (!repository || !projectId || !channel) {
    throw new TriageError(
      "init requires --repo owner/name --project-id PVT_… --channel '#name'",
    );
  }

  const board = await discoverBoardFields(projectId);
  const configPath = path.resolve(options.output ?? CONFIG_FILENAME);

  await writeConfig(configPath, {
    repository,
    slack: {
      channel,
      triggerEmoji: DEFAULTS.triggerEmoji,
      doneEmoji: DEFAULTS.doneEmoji,
      lookbackDays: DEFAULTS.lookbackDays,
      keychainService: DEFAULTS.keychainService,
    },
    board,
    fileableStates: DEFAULTS.fileableStates,
    confirmRequiredStates: DEFAULTS.confirmRequiredStates,
    graphqlMinRemainingReserve: DEFAULTS.graphqlMinRemainingReserve,
  });

  console.log(`Wrote ${configPath}`);
  console.log(`Board  : ${board.projectTitle}`);
  console.log(`Status : ${Object.keys(board.statusOptions).join(", ")}`);
  console.log(
    `Priority: ${board.priorityFieldId ? Object.keys(board.priorityOptions).join(", ") : "(no Priority field)"}`,
  );
}

async function runRefreshBoard(configPath) {
  const resolvedPath = configPath ?? (await findConfigPath(process.cwd()));
  if (!resolvedPath) throw new TriageError(`No ${CONFIG_FILENAME} found.`);

  const config = await readJsonFile(resolvedPath, "config");
  if (!config.board?.projectId) {
    throw new TriageError("Config has no board.projectId to refresh from.");
  }

  config.board = await discoverBoardFields(config.board.projectId);
  await writeConfig(resolvedPath, config);
  console.log(`Refreshed board fields in ${resolvedPath}`);
}

/* -------------------------------------------------------------------------- */
/* CLI                                                                         */
/* -------------------------------------------------------------------------- */

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) continue;
    const key = argument.slice(2);
    if (key === "dry-run") {
      options.dryRun = true;
    } else if (key === "confirmed") {
      options.confirmed = true;
    } else {
      options[key] = argv[++index];
    }
  }
  return options;
}

const USAGE = `Usage:
  slack-triage.mjs init --repo owner/name --project-id PVT_… --channel '#name'
  slack-triage.mjs refresh-board [--config path]
  slack-triage.mjs fetch [--channel #name] [--emoji ticket] [--days 14] [--attachments-dir path]
  slack-triage.mjs file --input draft.json [--dry-run] [--confirmed]

Reads ${CONFIG_FILENAME} from the repo root (or any parent of the cwd).
fetch downloads message attachments (images, PDFs, text; needs files:read) under
--attachments-dir, default <tmpdir>/slack-triage/<channel>/<ts>/, and reports each
one's local path — or the reason it could not be fetched — on the message.`;

async function main() {
  const [subcommand, ...rest] = process.argv.slice(2);
  const options = parseArguments(rest);

  switch (subcommand) {
    case "init":
      await runInit(options);
      break;

    case "refresh-board":
      await runRefreshBoard(options.config);
      break;

    case "fetch": {
      const config = await loadConfig(options.config);
      const candidates = await fetchCandidates(config, {
        ...(options.channel ? { channel: options.channel } : {}),
        ...(options.emoji ? { triggerEmoji: options.emoji } : {}),
        ...(options["done-emoji"] ? { doneEmoji: options["done-emoji"] } : {}),
        ...(options.days ? { lookbackDays: Number(options.days) } : {}),
        ...(options["attachments-dir"]
          ? { attachmentsDir: path.resolve(options["attachments-dir"]) }
          : {}),
      });
      console.log(JSON.stringify(candidates, null, 2));
      break;
    }

    case "file": {
      if (!options.input) throw new TriageError("file requires --input <path>");
      const config = await loadConfig(options.config);
      const draft = await readJsonFile(options.input, "draft");
      await fileDraft(draft, config, {
        dryRun: Boolean(options.dryRun),
        confirmed: Boolean(options.confirmed),
      });
      break;
    }

    default:
      console.error(USAGE);
      process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error instanceof TriageError ? error.message : error);
  process.exitCode = 1;
});
