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
per-repo, in the `/slack-triage:triage-slack` command.

## How it decides what to work on

A message is a candidate when it carries the **trigger** reaction and does not
yet carry the **done** reaction. Slack is therefore the record of what has been
processed — there is no local watermark to lose or reset, and re-running is
always safe.

The reaction is a nomination, not a dispatch decision — anyone in the channel
can react. Filing into a state an agent picks up automatically (default:
`Todo`, via `confirmRequiredStates`) therefore takes a second human decision:
the script refuses those drafts unless the call carries `--confirmed`, which
the operator grants per draft after seeing it. A draft nobody confirms files
into `Backlog`, where board workflows expect a human to promote it. Unflagged
chatter is never read.

Be clear-eyed about what that flag is: a tripwire and an audit trail, not
authentication. The agent running the command executes shell as the operator,
so no check inside the script can prove a human approved — a steered or
misbehaving model *could* pass `--confirmed` itself. What the gate guarantees
is that no draft reaches a dispatching state by default, by accident, or in an
unattended run, and that a bypass is a single explicit act you can find
afterwards: the flag in the session transcript, the issue on the board. If a
dispatching-state issue appears that you never approved, treat it as an
incident — pull it back on the board and read that transcript. The enforceable
containment for adversarial Slack content remains running triage attended.

Pick a trigger emoji nobody uses conversationally. `:ticket:` is safe; `:eyes:`
and `:+1:` are not — people react with those by reflex, and every one would
queue an agent.

## One-time Slack app setup

Do this once for the whole fleet.

1. At <https://api.slack.com/apps>, **create a dedicated app** for triage.
   Resist extending an app that already posts notifications through an incoming
   webhook: adding scopes requires reinstalling, and that puts a live webhook in
   the blast radius. The bot token and a webhook URL are unrelated credentials,
   so sharing one app buys nothing.
2. **OAuth & Permissions** → **Bot Token Scopes**:

   | Scope | Why |
   | --- | --- |
   | `channels:history` | Read messages in a public channel |
   | `channels:read` | Resolve `#name` to a channel ID |
   | `reactions:read` | See the trigger reaction |
   | `reactions:write` | Add the done reaction so a message is filed once |
   | `chat:write` | Reply in-thread with the issue link |
   | `users:read` | Resolve user IDs to names for attribution |

   For **private** channels also add `groups:history` and `groups:read`. They
   are genuinely optional: without them the channel lookup narrows to public
   channels rather than failing, so a public-channel workspace never has to
   grant private-channel access.
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
  "confirmRequiredStates": ["Todo"],
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
else on the board belongs to the workflow, not to intake. `confirmRequiredStates`
is the second rail inside the first: any of these states additionally needs the
operator's per-draft `--confirmed`. List every state your orchestrator treats as
active; a state in `confirmRequiredStates` but not `fileableStates` is
unreachable anyway.

Boards without a `Priority` field work fine — filing just skips it.

## Running it

```
/slack-triage:triage-slack
/slack-triage:triage-slack --dry-run                        # research and print, create nothing
/slack-triage:triage-slack --channel #product-feedback --days 3
```

Headless, for a scheduled run:

```bash
claude -p "/slack-triage:triage-slack" --permission-mode acceptEdits
```

A headless run has no operator to grant `--confirmed`, so everything it would
have filed into a `confirmRequiredStates` state lands in `Backlog` instead —
research done, dispatch still a human's call from the board. That degradation
is the point: do not "fix" it by scripting the flag into an unattended run.

The plumbing is usable on its own:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" fetch
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" file --input draft.json [--dry-run] [--confirmed]
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
| `Filing into … hands the issue to an agent` | Draft targets a `confirmRequiredStates` state. Show the operator and re-run with `--confirmed`, or file it as `Backlog` |
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

That single token is a deliberate trade-off, not an oversight. The whole fleet
runs on one machine under one user, so per-repo tokens would live side by side
in the same keychain — anything that can read one entry can enumerate them all,
and splitting buys no isolation there. What actually bounds exposure is channel
membership: the bot reads only the channels it has been invited to, so keep it
out of anything sensitive. Revisit per-repo apps only if the fleet ever spans
hosts, where a lifted token really would be scoped to one machine's repos.
