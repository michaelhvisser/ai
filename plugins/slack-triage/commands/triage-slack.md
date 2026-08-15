---
argument-hint: "[--channel #name] [--days 14] [--dry-run]"
description: "Turn reaction-flagged Slack feedback into researched GitHub issues on the project board"
allowed-tools: ["Bash(*slack-triage.mjs*)", "Bash(git:*)", "Bash(gh:*)", "Read", "Grep", "Glob", "Write", "Agent", "AskUserQuestion"]
---

# Triage Slack feedback into GitHub issues

Pass through any `--channel` / `--days` / `--dry-run` arguments given: $ARGUMENTS

## What you are doing

A teammate reacted to a Slack message with the trigger emoji. That reaction
nominates the report: it is authorization to *investigate*, never a claim that
the report is accurate — and never, by itself, the decision that hands work to
an agent. Anyone in the channel can react; only the operator running this
command can approve a filing that dispatches (step 5). Two keys, both human.

Your job is to establish whether the report survives contact with the code, and
to file an issue good enough that a coding agent can act on it without a human
re-explaining it.

**Read the repo's own guidance first** — `AGENTS.md`, `CLAUDE.md`, and
`WORKFLOW.md` if they exist. They define the board states, the verification
gate, and any security invariants. Where this command and the repo disagree, the
repo wins.

## Step 1 — Fetch

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" fetch [--channel …] [--days …]
```

Emits a JSON array. Empty: say so and stop. Non-empty: work oldest first, and
finish each candidate completely before starting the next.

Each message and each thread reply carries a `files` array. A file with a
`path` has been downloaded — **open it with the Read tool** (screenshots are
the usual case, and "the page pictured below" means nothing without them) and
treat what it shows as part of the report. A file with an `error` could not
be fetched: `missing_scope` means the Slack app lacks `files:read` — say so in
the run report so the operator can add it, and note in the issue that a
screenshot existed but was not seen. Never guess at what an unseen image shows.
Do not attach the image to the issue: it may carry client PII, and the Slack
permalink in `## Provenance` already leads back to it.

## Step 2 — Research each candidate

Pin your reading to one commit so the issue's references stay meaningful:

```bash
git fetch origin && git rev-parse --short origin/HEAD
```

Delegate the search to an `Explore` subagent. Give it the Slack text and thread
verbatim, plus what each downloaded attachment shows (the subagent cannot see
the images, so describe them — which page, which controls, any visible values
that are not PII), and ask it to establish:

- Which files and functions the report implicates, as `file:line`.
- Whether the code actually behaves as described. Quote the lines that decide it.
- Whether it is already fixed on the integration branch, or covered by an open
  issue (`gh issue list --state open`) or PR.
- What tests cover the area today, and whether the repo's test setup can even
  verify a fix of this kind.

Check claims against live data where the repo gives you a read-only way to do so
(a database MCP, a logs tool, an analytics query). Never mutate anything while
researching.

## Step 3 — Classify

Pick exactly one:

- **Substantiated** — you can point at the code or data that makes it true. File it.
- **Feature request** — coherent and well-scoped, no defect. File it.
- **Already fixed / duplicate** — do not file. Reply in the Slack thread with the
  commit, issue, or PR that covers it, then add the done reaction so it stops
  resurfacing.
- **Cannot substantiate** — the code does not behave as described, or the report
  is too vague to scope. File with status `Blocked` and state the *exact* missing
  context. Never invent scope to make something fileable.

## Step 4 — Write the issue

Match the repo's existing conventions rather than a generic template. Read the
two or three most recent substantive issues (`gh issue list --state all --limit 5`)
and follow their structure — typically **Summary**, **Evidence**, **Impact**,
**Proposed fix**, **Verification**.

- Lead with the conclusion, not the story of your investigation.
- Every code reference is `file:line`, pinned to the commit from step 2.
- Add a `## Provenance` section with the Slack permalink and who reported it.
- **Strip PII.** Slack feedback routinely names people and quotes emails, and an
  issue outlives the request. Refer to roles ("an org admin") and use slugs or
  IDs rather than contact details. If the repo declares a no-PII invariant, this
  is that invariant.
- Quote the original report only as much as preserves intent. The issue must
  stand on your research, not on the Slack message.

**Priority** — use the board's own options (the config caches them):

| Priority | Use for |
| --- | --- |
| `Urgent` | Data exposure, cross-tenant leakage, auth bypass, or an unusable app |
| `High` | A broken user-facing workflow with no workaround |
| `Medium` | Default — real but survivable |
| `Low` | Cosmetic, copy, or internal-only |

If the repo documents per-issue agent overrides (effort, model) and the change
touches auth, authorization, tenant isolation, or a shared schema, add that
block — but consult the repo's own docs for the current syntax rather than
reproducing one from memory.

## Step 5 — File

Write the draft to a scratch file:

```jsonc
{
  "slack": { "channel": "C…", "ts": "…", "permalink": "https://…" },
  "title": "…",
  "body": "…",
  "labels": ["bug"],          // existing labels only; check `gh label list`
  "priority": "Medium",
  "status": "Todo"            // or "Blocked" / "Backlog"
}
```

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/slack-triage.mjs" file --input <draft.json>
```

Honour `--dry-run` if passed: print what would be filed and stop.

The script refuses a status in the config's `confirmRequiredStates` (default:
`Todo` — the states an agent picks up automatically) unless the call carries
`--confirmed`. That flag is the operator's per-draft approval, and it is never
yours to grant:

1. Present the draft with AskUserQuestion: title, target status, priority, one
   line of what the research established, and the Slack permalink.
2. Approved → re-run the same `file` call with `--confirmed`.
3. Declined — or nobody can answer, as in a headless or scheduled run → set the
   draft's `status` to `"Backlog"` and file that instead, so a human promotes
   it from the board. Never pass `--confirmed` unprompted, and never edit
   `confirmRequiredStates` to route around the refusal.

The script creates the issue, places it on the board, sets Status and Priority,
adds the done reaction, and replies in the Slack thread with the issue link. It
refuses to run when the shared GraphQL quota is below its reserve — if you hit
that, stop and report. The flags stay unprocessed and the next run picks them up.

## Step 6 — Report

One line per candidate: Slack author → classification → issue link, status,
priority. Call out anything filed as `Blocked` and what it needs, and anything
you deliberately did not file.

If the repo runs a single-lane agent queue, say how many issues you just put in
`Todo` and in what order they will run — that is the queue you committed.
