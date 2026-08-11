# slack-triage

React to a Slack message with :ticket:, and it becomes a researched GitHub issue
on the repo's Projects v2 board — ready for an agent to pick up.

One Slack app and one bot token serve every repo. Onboarding repo number two is
a config file.

## Why a plugin and not a service

The pipeline is **ingest → research → file**. Ingest and file are generic; the
research is not. Establishing whether a report is real needs the repo checked
out, its `AGENTS.md` in context, its issue conventions, and read access to its
own datastores. A hosted service could only enqueue work — and the board already
is the queue. So the plumbing ships as a shared plugin and the judgement stays
per-repo, in the `/triage-slack` command.

## How it decides what to work on

A message is a candidate when it carries the **trigger** reaction and does not
yet carry the **done** reaction. Slack is therefore the record of what has been
processed — there is no local watermark to lose or reset, and re-running is
always safe.

That reaction is also the human prioritization signal. Workflows that reserve a
`Backlog` state for "not yet triaged" can accept issues from this tool directly
into an active state precisely because a human already made that call. Unflagged
chatter is never read.

Pick a trigger emoji nobody uses conversationally. `:ticket:` is safe; `:eyes:`
and `:+1:` are not — people react with those by reflex, and every one would
queue an agent.

## One-time Slack app setup

Do this once for the whole fleet.

1. At <https://api.slack.com/apps>, open or create the workspace's app. If you
   already have one posting notifications via an incoming webhook, extend that
   one — a webhook cannot read a channel, so it needs a bot token regardless.
2. **OAuth & Permissions** → **Bot Token Scopes**:

   | Scope | Why |
   | --- | --- |
   | `channels:history` | Read messages in a public channel |
   | `channels:read` | Resolve `#name` to a channel ID |
   | `reactions:read` | See the trigger reaction |
   | `reactions:write` | Add the done reaction so a message is filed once |
   | `chat:write` | Reply in-thread with the issue link |
   | `users:read` | Resolve user IDs to names for attribution |

   For **private** channels also add `groups:history` and `groups:read`.
3. **Install to Workspace** — reinstall if the app already existed, since new
   scopes do not apply until you do — and copy the **Bot User OAuth Token**
   (`xoxb-…`).
4. `/invite @<app name>` in each channel. Without this, `conversations.history`
   returns `not_in_channel`.

Store the token in the keychain, shared across repos:

```bash
security add-generic-password -s slack-triage -a "$USER" -w xoxb-your-token
```

`SLACK_BOT_TOKEN` overrides it — the escape hatch for CI or a non-macOS host.

Do not put it in a `.env` file that gets copied into agent worktrees. Nothing in
any app runtime needs this credential; only this plugin does.

## Onboarding a repo

From the repo root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" init \
  --repo owner/name \
  --project-id PVT_… \
  --channel '#feedback'
```

That discovers the board's Status and Priority options and writes
`slack-triage.json`. Commit it — it holds no secrets.

Find the project ID with `gh project list --owner <org> --format json`.

```jsonc
{
  "repository": "owner/name",
  "slack": {
    "channel": "#feedback",
    "triggerEmoji": "ticket",
    "doneEmoji": "white_check_mark",
    "lookbackDays": 14,
    "keychainService": "slack-triage"
  },
  "board": {
    "projectId": "PVT_…",
    "statusFieldId": "PVTSSF_…",
    "statusOptions": { "Todo": "…", "Blocked": "…" },
    "priorityFieldId": "PVTSSF_…",
    "priorityOptions": { "High": "…" }
  },
  "fileableStates": ["Todo", "Blocked", "Backlog"],
  "graphqlMinRemainingReserve": 1000
}
```

The board IDs are **cached deliberately**. Projects v2 has no REST surface, so
rediscovering them costs GraphQL on every run. Re-resolve after renaming a
column or adding an option:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" refresh-board
```

`fileableStates` is the safety rail: triage may only file into these. Everything
else on the board belongs to the workflow, not to intake.

Boards without a `Priority` field work fine — filing just skips it.

## Running it

```
/triage-slack
/triage-slack --dry-run                        # research and print, create nothing
/triage-slack --channel #product-feedback --days 3
```

Headless, for a scheduled run:

```bash
claude -p "/triage-slack" --permission-mode acceptEdits
```

The plumbing is usable on its own:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" fetch
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" file --input draft.json [--dry-run]
```

## What filing does

1. Creates the issue over **REST** — the one step that need not touch the
   contended GraphQL quota.
2. Adds it to the board, then sets Status and Priority (three GraphQL mutations).
3. Adds the done reaction and replies in the Slack thread with the issue link.

Step 3 is best-effort and runs last. If it fails, the issue still exists and the
script says so — add the reaction by hand, or the next run files a duplicate.
The alternative ordering loses the request entirely, which is worse.

## Rate-limit guard

The GitHub GraphQL quota is **per-user and shared across every repo** on the
account. Draining it stalls everything that reads a board.

Below `graphqlMinRemainingReserve` (default 1000, matching Detent's
`github_graphql_min_remaining_reserve`), filing refuses **before** creating
anything, and the Slack flags stay unprocessed for the next run.

```bash
gh api rate_limit --jq '.resources.graphql'
```

## Requirements

- `gh`, authenticated with the `repo` and `project` scopes
- Node 18+ (uses built-in `fetch`); no npm dependencies
- macOS for keychain storage, or `SLACK_BOT_TOKEN` anywhere else

## Troubleshooting

| Error | Cause |
| --- | --- |
| `not_in_channel` | Invite the bot: `/invite @<app name>` |
| `missing_scope (needs scope: …)` | Add the scope, then **reinstall** the app |
| `channel_not_found` | Private channel, or bot not a member. Add `groups:history` and `groups:read` |
| `No Slack bot token` | Keychain entry missing, or a different `keychainService` in config |
| `No slack-triage.json found` | Run `init` from the repo root |
| `config is missing board field IDs` | Run `refresh-board` |
| `GraphQL quota at N, below the … reserve` | Wait for the reset in `gh api rate_limit` |
| Message filed twice | The done reaction failed on the first run; that run's output names the issue URL |

## Rotating the token

**OAuth & Permissions** → **Revoke All OAuth Tokens**, reinstall for a fresh
`xoxb-…`, then:

```bash
security delete-generic-password -s slack-triage
security add-generic-password -s slack-triage -a "$USER" -w xoxb-new-token
```

One token, so this is a single rotation for the whole fleet.
