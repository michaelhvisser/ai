#!/usr/bin/env node
/**
 * Slack -> GitHub issue triage plumbing.
 *
 * Deterministic halves of the pipeline only. Everything judgement-shaped
 * (is this real, what is the fix, how urgent) lives in the `/triage-slack`
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

import { execFile } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
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

/** Accepts a raw channel ID or a `#name`, returning the ID. */
async function resolveChannelId(token, channel) {
  if (/^[CGD][A-Z0-9]{6,}$/.test(channel)) return channel;
  const name = channel.replace(/^#/, "");

  let cursor;
  do {
    const page = await slackApi(token, "conversations.list", {
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
      cursor,
    });
    const match = page.channels.find((entry) => entry.name === name);
    if (match) return match.id;
    cursor = page.response_metadata?.next_cursor || undefined;
  } while (cursor);

  throw new TriageError(
    `Channel ${channel} not found. If it is private, invite the bot to it first.`,
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

async function fetchCandidates(config, overrides) {
  const settings = { ...config.slack, ...overrides };
  const token = await resolveSlackToken(settings.keychainService);
  const channelId = await resolveChannelId(token, settings.channel);
  const resolveUser = createUserResolver(token);
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

    // Feedback is usually argued out in the thread, so the replies are often
    // where the actual reproduction detail lives.
    let thread = [];
    if (message.thread_ts && (message.reply_count ?? 0) > 0) {
      const { messages: replies } = await slackApi(
        token,
        "conversations.replies",
        { channel: channelId, ts: message.thread_ts, limit: 100 },
      );
      thread = await Promise.all(
        replies
          .filter((reply) => reply.ts !== message.ts)
          .map(async (reply) => ({
            author: await resolveUser(reply.user),
            text: reply.text,
          })),
      );
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

async function gh(args, input) {
  const options = { maxBuffer: 32 * 1024 * 1024 };
  if (input !== undefined) options.input = input;

  try {
    const { stdout } = await execFileAsync("gh", args, options);
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
  if (!draft.slack?.channel || !draft.slack?.ts) {
    problems.push("slack.channel and slack.ts are required");
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

async function fileDraft(draft, config, { dryRun }) {
  validateDraft(draft, config);
  const { board } = config;

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
    } else {
      options[key] = argv[++index];
    }
  }
  return options;
}

const USAGE = `Usage:
  slack-triage.mjs init --repo owner/name --project-id PVT_… --channel '#name'
  slack-triage.mjs refresh-board [--config path]
  slack-triage.mjs fetch [--channel #name] [--emoji ticket] [--days 14]
  slack-triage.mjs file --input draft.json [--dry-run]

Reads ${CONFIG_FILENAME} from the repo root (or any parent of the cwd).`;

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
      });
      console.log(JSON.stringify(candidates, null, 2));
      break;
    }

    case "file": {
      if (!options.input) throw new TriageError("file requires --input <path>");
      const config = await loadConfig(options.config);
      const draft = await readJsonFile(options.input, "draft");
      await fileDraft(draft, config, { dryRun: Boolean(options.dryRun) });
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
