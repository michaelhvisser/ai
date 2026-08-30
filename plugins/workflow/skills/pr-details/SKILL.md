---
name: pr-details
description: "Read-only situation report for one pull request: CI judged against the base branch's actual required checks, review decision, unresolved threads split by author class, mergeability, board state, whether the linked issue's problem still exists on base, whether its plan is the right plan, which review skill (codex-ship, antagonist-review, ui-review) is still needed at this head — and the ordered action queue to merge, each step green-lightable at a prompt or doable by hand from its local recipe. UI changes get a screenshot glance from the preview deploy; everything renders into one local report.html. It mutates nothing on GitHub itself; on your explicit go it launches the step it named. Use before spending tokens on review or fixes, when you pick up a PR cold, or as a check-in to approve what runs next. SKIP when you already know the next step and just want it done — run that skill directly."
argument-hint: "[PR-number] [--plan-model fable|codex|both|none] [--effort low|medium|high|xhigh] [--no-plan-check] [--no-dup-search] [--no-shots] [--no-page] [--no-gate] [--json] [--refresh]"
---

# PR Details — read-only situation report for one PR

Before requesting decisions or delegating work, read
`${CLAUDE_PLUGIN_ROOT}/lib/driver-interaction.md` and follow its cross-platform
capability-binding rules.

Read `${CLAUDE_PLUGIN_ROOT}/lib/decision-gates.md` before resolving any workflow choice.

Load the shared GitHub helpers before any GitHub operation:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/github-rest.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/pr-facts.sh"
```

From `github-rest.sh`: `github_pr`, `github_current_pr`, `github_pr_reviews`,
`github_check_snapshot`. From `pr-facts.sh`: `pr_facts_gh` (the retry wrapper — every `gh`
call goes through it), `pr_facts_graphql_ok`, `pr_facts_rate_gate`, `pr_facts_rules`,
`pr_facts_check_matrix`, `pr_facts_ci_state`, `pr_facts_review_threads`, `pr_facts_board`,
`pr_facts_compare`, `pr_facts_shared_files`, `pr_facts_run_dir`.

---

## What this skill is

`pr-details` answers six questions about one PR:

1. **Where is it?** CI, review decision, threads, mergeability, behind-base, board state.
2. **Why does it exist, and is that still true?** The linked issue's problem, re-checked
   against the base branch, with duplicate issues and PRs surfaced.
3. **Is the plan right?** A strong model audits the issue's plan against the problem and the
   diff, and proposes corrections.
4. **Is there UI to look at?** If so, a screenshot glance from the preview deployment shows
   it without launching the app.
5. **Is the quality ladder satisfied?** Which of codex-ship, antagonist-review, deep review,
   and E2E already ran at this head, and which the decision table still requires.
6. **What is the path?** One actual next step, then the projected steps behind it — an
   ordered queue where each entry can be green-lit at the closing prompt or done by hand from
   its `local:` recipe.

It is the front door of the review family: every sibling either mutates the PR
(`address-review`, `codex-ship`) or spends a lot of tokens (`antagonist-review`). This one
spends little, mutates nothing on GitHub, and tells you which expensive tool to reach for.
Think of it as the check-in with a project manager: current status, what needs your green
light, and what you can do yourself instead. The report lands twice — a ≤48-line terminal
summary, and `report.html` in the run dir with the queue, screenshots, and the change outline
in one place.

**Non-goals (hard).** It never pushes, commits, rebases, comments, resolves threads, edits
issues, changes labels, or moves board items. It never triggers a bot review. The plan check
*proposes* issue-body edits as text; applying them is a separate human action. It judges the
**plan**, not the **diff quality** — that is `review-deep` / `antagonist-review`. The Phase 8
gate launches a sibling skill only on the user's explicit selection; that launch is the user's
decision, and everything the sibling then does runs under the sibling's own contract, not this
one's.

## Read-only enforcement

Read-only is enforced by construction, in two layers. There is no "breach detection": diffing
comment counts produces false alarms from concurrent humans, misses reviews, labels,
reactions, edits, and pushes, and its usual recovery (`git stash push -u`) mutates the user's
tree and captures unrelated work.

1. **The skill issues only `gh` read verbs.** The complete allowed list: `gh pr view`,
   `gh pr list`, `gh pr checks`, `gh pr diff`, `gh issue view`, `gh issue list`,
   `gh search issues`, `gh search prs`, `gh repo view`, `gh auth status`, `gh api` with no
   `--method`/`-X` (or an explicit `-X GET`), and `gh api graphql` with a `query` operation
   only. Any other verb is a bug.
2. **Codex runs sandboxed.** `-s read-only` plus `-c sandbox_mode="read-only"` plus
   `-c approval_policy="never"`. `approval_policy="never"` is what denies outward-facing tool
   calls; the sandbox flag fences only the filesystem.

**Accepted residual risk:** the Codex process inherits the host's `gh` credentials, so a
read-only *filesystem* sandbox does not by itself prove no network mutation is possible; the
prompt forbids GitHub tool use explicitly and `approval_policy="never"` denies the escalation
path, and that combination is the mitigation this skill relies on.

The skill never runs `git stash`, `git checkout`, `git reset`, `git fetch --prune`, or
anything else that changes the working tree or branch state. Its only `git` writes are
object-only fetches into `refs/pr-details/*`, a namespace this skill owns (`facts.md` §0c).

**The screenshot phase browses, it never acts — and the browser enforces that.** Phase 5b
captures the PR's preview deployment only in a context where read-only is enforceable
(JavaScript disabled, or every non-GET request **and all WebSocket traffic** intercepted —
the upgrade handshake is a GET and its frames evade method filters), because a real app mutates
state on mere load; no clicks, no form input, no logging in (`page.md` §1c). A route behind
an auth wall is recorded as `auth-blocked`, and a browser that cannot enforce the controls
means no navigation at all.

## Usage

**Claude Code:** `/workflow:pr-details [PR-number] [flags]`
**Codex:** `$workflow:pr-details [PR-number] [flags]`

**Examples:** `/workflow:pr-details` · `/workflow:pr-details 161` ·
`/workflow:pr-details 161 --plan-model both` · `/workflow:pr-details 161 --json`

| Flag | Default | Why |
|---|---|---|
| `[PR-number]` | auto from the current branch via `github_current_pr`, then `gh pr list --search <HEAD sha>` | House convention. A branch name or a full PR **URL** is also accepted; a URL sets host, owner, and repo too (`facts.md` §0a). |
| `--plan-model fable\|codex\|both\|none` | `fable` if a strong subagent tier exists, else `codex` if `command -v codex`, else `none` | `both` runs a two-model quorum. Never silently downgrade — an unavailable model produces a warning line in the report. |
| `--effort low\|medium\|high\|xhigh` | `xhigh` | Passed to `codex exec -c model_reasoning_effort=`; mapped to the subagent effort hint for Fable. |
| `--no-plan-check` | off | Phase 4 is the only slow phase. Skipping it makes this a ~20-second status command. |
| `--no-dup-search` | off | Duplicate discovery costs search calls, which charge **both** the 30/min search bucket and the GraphQL bucket. |
| `--no-shots` | off | Skip Phase 5b screenshot capture. The UI verdict is unaffected — screenshots are evidence for the human, never a fact (`page.md` §1). |
| `--no-page` | off | Skip writing and opening `report.html` (`page.md` §2). |
| `--no-gate` | off | Report and stop — no green-light prompt. `--json` implies it, and also suppresses the page auto-open. |
| `--json` | off | Machine schema on stdout (`output.md` §2). |
| `--refresh` | off | Ignore the SHA-keyed immutable cache (`facts.md` §0e). |

Rejected flags: `--fix` / `--apply` (mutation without the gate's per-run selection defeats the
non-goals — the Phase 8 gate is the sanctioned route, and it never runs unprompted); `--go`
(same reason: pre-authorizing the dispatch turns a status command into a mutation command);
`--base` (a PR always has a base).

Parse with the `for arg in $ARGUMENTS … case` loop and `SKIP_NEXT` for valued flags, as in
`codex-ship`. A bare token that is not `^[0-9]+$` is a branch name or a URL.

```bash
PLAN_MODEL=""; EFFORT="xhigh"; DO_PLAN=1; DO_DUP=1; DO_SHOTS=1; DO_PAGE=1; DO_GATE=1
AS_JSON=0; REFRESH=0; PR_ARG=""
SKIP_NEXT=""
for arg in $ARGUMENTS; do
  case "$SKIP_NEXT" in
    model)  PLAN_MODEL="$arg"; SKIP_NEXT=""; continue ;;
    effort) EFFORT="$arg";     SKIP_NEXT=""; continue ;;
  esac
  case "$arg" in
    --plan-model)    SKIP_NEXT="model" ;;
    --effort)        SKIP_NEXT="effort" ;;
    --no-plan-check) DO_PLAN=0 ;;
    --no-dup-search) DO_DUP=0 ;;
    --no-shots)      DO_SHOTS=0 ;;
    --no-page)       DO_PAGE=0 ;;
    --no-gate)       DO_GATE=0 ;;
    --json)          AS_JSON=1; DO_GATE=0 ;;
    --refresh)       REFRESH=1 ;;
    --*)             echo "pr-details: unknown flag $arg" >&2; exit 2 ;;
    *)               PR_ARG="$arg" ;;
  esac
done
[ -n "$SKIP_NEXT" ] && { echo "pr-details: $SKIP_NEXT flag needs a value" >&2; exit 2; }
```

## Output contract

Stdout and stderr are strictly separated so `--json` is machine-consumable:

- With `--json`: **stdout carries JSON and nothing else** — no banners, no progress, no
  warnings. Every diagnostic goes to **stderr**, and warnings that matter to a consumer are
  *also* carried inside the JSON as `warnings[]`.
- Without `--json`: the terminal report goes to stdout; diagnostics still go to stderr.

| Exit | Meaning |
|---|---|
| `0` | A report was produced. **This includes `next_step.id == "blocked"`** — a blocked verdict is a successful report. Callers branch on `next_step.id`, never on the exit code. |
| `2` | Usage error: unparseable flag, a valued flag with no value, mutually exclusive flags. |
| `3` | Auth or rate-limit refusal: `gh` unauthenticated for the resolved host, or a quota bucket below its reserve (`facts.md` §0b). No partial report. |
| `4` | PR not found, or resolved to a repository the caller did not intend (`facts.md` §0a). |
| `1` | Reserved for unexpected internal failure. Never used deliberately. |

## Model roles

Edit this block; never hard-pin a model name in the phase logic.

| Role | Default tier | Job | Token posture |
|---|---|---|---|
| **Orchestrator** | session model | argument parsing, all `gh`/git calls, fact assembly, decision table, report. **Zero code judgment.** | cheap |
| **Still-needed researcher** | read-only researcher tier | Phase 3: trace the problem on base at the pinned SHA; name the fixing commit or the live code path | one call, small prompt |
| **Plan judge (Fable)** | strongest available subagent tier | Phase 4: plan adequacy, gaps, proposed issue edits | one call; the main spend when selected |
| **Plan judge (Codex)** | local `codex exec` CLI, a second model *family* | same prompt, independent family | one backgrounded call; wall-time cost, subscription-side tokens |
| **Quorum** | none — the orchestrator applies the `plan-check.md` §4 table | report agreement or split; never adjudicate | free |

The **reference bar** for "strong tier" is whatever the frontier-quality model is when you run
this, never a model name.

Cost: `--no-plan-check` is ~10 API calls plus one researcher call; the default `fable` adds one
strong call; `both` adds a backgrounded Codex run whose cost is wall time, not tokens.
Screenshots add one to two minutes of browser wall time only when UI is warranted and a
preview deploy exists; the page render and the queue are free — they reuse facts already
fetched.

## Phase outline

| Phase | What | Detail file |
|---|---|---|
| 0 | Preflight: **resolve identity first**, auth for that host, rate gate, git pins, contract + ruleset discovery, run dir and cache | `facts.md` §0 |
| 1 | PR record, linked issues, duplicates, diff | `facts.md` §1 |
| 2 | Status snapshot: CI, reviews, threads, mergeability, local state, board, prior-skill evidence | `facts.md` §2 |
| 3 | Still-needed validation, per linked issue | `still-needed.md` |
| 4 | Plan check by a strong model (skippable) | `plan-check.md` |
| 5 | UI-review detection (deterministic, no model) | below |
| 5b | Screenshot glance from the preview deployment (capability-bound, skippable) | `page.md` §1 |
| 6 | Next-step decision table + action-queue projection | below + `next-step.md` |
| 7 | Render | `output.md` |
| 7b | Report page, written and opened locally | `page.md` §2 |
| 8 | Green-light gate: approve the next step(s), take the local recipe, or stop | below |

**The rate gate runs twice**: once in Phase 0, and once immediately before Phase 4 dispatch.
Phase 4 is the expensive phase, and a shared fleet's quota moves underneath a long run.

## Phase 5 — UI-review detection

Deterministic; no model. Inputs: the changed-file list, `diff.patch`, the PR body.

**Path heuristics** (any match → `ui_touch=true`): App Router / pages
(`^app/.*\.(tsx|jsx|mdx)$`, `^pages/`, `^src/(app|pages|routes)/`); components
(`^(src/)?components?/`, `^ui/`, `^(src/)?features/.*\.(tsx|jsx|vue|svelte|astro)$`);
templates and styles (`\.(vue|svelte|astro|html|hbs|ejs|njk)$`,
`\.(css|scss|sass|less|pcss)$`, `tailwind\.config\.*`, `globals\.css`); Storybook and visual
tests (`\.stories\.(tsx|jsx|mdx)$`, `^\.storybook/`, `\.(spec|test)\.(ts|tsx)$` importing
`@playwright/test`); assets (`^public/`, `\.(svg|png|jpg|webp)$`); copy and i18n
(`^(locales|messages|i18n)/`).

**Negative filters:** pure test files with no sibling source change; `\.d\.ts`; hunks whose
non-`import`/non-comment changed-line count is zero.

**Severity:** `visual` when JSX/template/CSS hunks change markup or class names; `behavioural`
when only handlers, hooks, or state in a UI file change; `copy` when only string literals
change.

**Route mapping**, so the report says *where* to look: `app/<segments>/page.tsx` → route, with
`(group)` segments dropped and `[param]` kept. For a component, the `app/**/page.tsx` files
that import it, found with one shallow `git grep -l "<basename>" "$HEAD_SHA" -- app/` — pinned
to the head SHA like every other source read (`still-needed.md` §1). Cap at 5 routes.

**Evidence:** screenshots in the PR body (`!\[`, `<img`, `user-attachments`), an
`## E2E Verification Results` comment, an `e2e-verified` label.

Output → `ui {warranted, severity, files[], routes[], evidence_present, reason}`. Phase 5b
appends `preview_url`, `shots_status`, `screenshots[]`, and `visual_summary` (`page.md` §1);
none of them feed the decision table.

## Phase 6 — Next-step decision table

Evaluated **top to bottom; first match wins; exactly one step**. Every row yields exactly one
`next_step.id` from the closed vocabulary in `output.md` §2 — there is no "optional" outcome; a
weaker secondary suggestion goes in `next_step.then[]` or `next_step.notes[]`, never in the
headline. Fact names are defined in `next-step.md` §1; ordering rationale in §2; the ready
predicate's conjuncts in §3.

| # | Group | Condition (first match wins) | `next_step.id` |
|---|---|---|---|
| 1 | terminal | PR state `MERGED` | `merged` |
| 2 | terminal | PR state `CLOSED`, not merged | `closed` |
| 3 | terminal | `FACTS_INCOMPLETE` — a required fact is `unknown`: auth/quota degraded mid-run, `mergeable == UNKNOWN` after both retries, a paginated collection failed to complete, or partial GraphQL data on a load-bearing query | `facts-incomplete` |
| 4 | board | `BOARD_STATUS` ∈ terminal states (`Done`, `Cancelled`) while the PR is open | `board-terminal` |
| 5 | board | `BOARD_STATUS == Blocked` | `blocked` |
| 6 | board | `BOARD_STATUS == Backlog`, or no linked issue, or `BOARD_AMBIGUOUS` | `no-active-issue` |
| 7 | supersede | **every** linked issue is `already-fixed-by` with `confidence: high` | `close-superseded` |
| 8 | supersede | **every** linked issue is `likely-duplicate-of #M` where #M is open and further along, and this PR is not the further-along one | `close-duplicate` |
| 9 | mechanical | `mergeable == CONFLICTING` | `rebase` |
| 10 | mechanical | `BEHIND && STRICT` | `rebase` |
| 11 | mechanical | `CI_STATE == red` | `address-review` |
| 12 | feedback | `HUMAN_CR` or `UNRES_H > 0` | `address-review` |
| 13 | feedback | `CODEX_CR` or `UNRES_CODEX > 0` | `codex-ship` |
| 14 | feedback | `UNRES_B > 0` (non-Codex bots), or any `needs-resolve-only` thread | `address-review` |
| 15 | plan | `PLAN_COMBINED == no` | `fix-plan` |
| 16 | plan | `PLAN_COMBINED == partial` with a `blocker` gap, **or** `PLAN_SPLIT` | `antagonist-review` |
| 17 | waiting | `CI_STATE == pending` (includes a required check that is **absent** from the rollup) | `wait-ci` |
| 18 | review spend | `ui.warranted && !E2E_AT_HEAD` | `ui-review` |
| 19 | review spend | `!AR_AT_HEAD && !CS_AT_HEAD && DIFF_LINES >= 150` | `antagonist-review` |
| 20 | review spend | `AR_AT_HEAD && !CS_AT_HEAD` | `codex-ship` |
| 21 | review spend | `!AR_AT_HEAD && CS_AT_HEAD && DIFF_LINES >= 150` | `antagonist-review` |
| 22 | draft | `IS_DRAFT` (nothing above fired) | `finish-draft` |
| 23 | gate | any **mandatory contract conjunct is observably false** at head (`next-step.md` §3) | `complete-gate` |
| 24 | approval | approval shortfall: `APPROVALS_GIVEN < APPROVALS_REQUIRED`, or `reviewDecision == REVIEW_REQUIRED`, or an unsatisfied code-owner / last-push / unattributed-changes approval requirement | `human-approval` |
| 25 | ready | `READY_VERIFIABLE` and `BOARD_STATUS == Merging` | `hand-to-detent` |
| 26 | ready | `READY_VERIFIABLE` and `BOARD_STATUS == Human Review` and `!AUTO_PROMOTE` | `human-approval` |
| 27 | ready | `READY_VERIFIABLE` and `BOARD_STATUS == Human Review` and `AUTO_PROMOTE` and `!REQ_LABEL` | `hand-to-detent` |
| 28 | ready | `READY_VERIFIABLE` and `BOARD_STATUS == Human Review` and `AUTO_PROMOTE` and `REQ_LABEL` | `human-approval` |
| 29 | ready | `READY_VERIFIABLE` and `BOARD_STATUS` ∈ active (`Todo`, `In Progress`, `Rework`) | `move-to-human-review` |
| 30 | fallback | anything else | `needs-human` |

Rows 25–29 carry a **verdict qualifier**, not just an id. When every mandatory conjunct is
`verified` or `evidenced` at head, the verdict reads `ready`. When one or more conjuncts are
`self-report` (nothing on GitHub can prove them — a local `pnpm` gate and Convex schema
validation always fall here), the verdict reads `ready pending: <conjunct list>` and
`next_step.pending[]` names them. A conjunct that is *observably false* never reaches these
rows; it fires row 23 instead.

Four cross-cutting **annotations** print under any step and never change the headline:
`IS_DRAFT` when a row other than 22 fired ("draft — the blocker above outranks promoting it");
a partial supersession result (some but not all linked issues superseded, per
`still-needed.md` §5); a low-confidence duplicate; and local checkout state.

**The queue.** After the headline row fires, project the path behind it: assume the step
succeeded, overlay the resolution map, re-run the table, repeat — cap 5, loop-guarded,
stopping at any human-owned or terminal id (`next-step.md` §5). Entries after the first are
marked `projected` and each carries the `local:` recipe from `next-step.md` §6. `queue[0]`
is the headline restated; the projection changes no fact and no verdict.

## Phase 8 — the green-light gate

The report names the next step; the gate turns it into motion without giving up the skill's
read-only posture. Classify it per `decision-gates.md`: consent to spend tokens or mutate the
PR is **missing intent** — a status request does not imply it — so the gate asks once, through
the driver's structured-input capability, and never loops.

Skip the gate entirely when `--no-gate` or `--json`, or when `queue[0]` is a
`QUEUE_TERMINAL` id — the report already says who owns the move. A driver **without**
structured input does not skip it: per `driver-interaction.md`, ask the same one question
as concise text in the final response and stop; the user's answer resumes the gate.

**Dispatchability is checked, not assumed.** The id→skill mapping is explicit:
`codex-ship` → `/workflow:codex-ship`; `antagonist-review` → `/workflow:antagonist-review`;
`address-review` → the language plugin's `address-review`; `ui-review` → the language
plugin's **E2E verification skill** (in `ts-workflow` that is `e2e-verify` — there is no
skill literally named `ui-review`). An entry is dispatchable only when its mapped skill is
actually invocable **by the orchestrator** in this session — installed AND model-invocable.
A `disable-model-invocation: true` target (ts-workflow's `address-review` and `e2e-verify`
today) cannot be launched from here: for those entries the gate presents the exact slash
command for the user to type, never a Run option that would fail. `rebase` stays the one
mechanical entry.
Everything else (`wait-ci`, `fix-plan`, `finish-draft`, `complete-gate`,
`move-to-human-review`, …) is an action the report describes, not a skill to launch: for
those the gate offers only the local recipe and Stop. Never present a Run option that
cannot actually run.

**Every mutating dispatch binds to the PR's checkout, never the shell's.** The skill
reports from any checkout — another branch, detached HEAD, a dirty tree — and every
dispatchable skill can reach a fixer that commits and pushes from the ambient directory
(`codex-ship` invokes `address-review`; `antagonist-review` dispatches its own fixer). So
the Run options are offered **only when Phase 2e's local facts show a clean checkout at
the PR head**; otherwise the gate names the gap — "checkout is not at the PR head; open
its worktree (`/workflow:create-worktree <n>` review mode) and run `<command>` there" —
and offers only the local recipe and Stop. For `rebase` specifically, the executed push
sends the rebased commit itself, to the remote that actually hosts the head:

```
git push --force-with-lease=refs/heads/<headRefName>:<HEAD_SHA> \
  <head-remote> HEAD:refs/heads/<headRefName>
```

The explicit lease pins the expectation to the head **this run observed** — the SHA every
fact in the report describes. A bare `--force-with-lease` trusts the remote-tracking ref,
which any background fetch refreshes into a rubber stamp; with the pin, a contributor's
push after Phase 2 rejects the force-push instead of being overwritten, and the rejection
is surfaced, never retried with a refreshed lease.

`<head-remote>` is the configured remote whose URL matches the full `HEAD_SLUG`
(owner/name, normalized — the owner login alone is ambiguous for renamed forks or several
repos under one owner; `facts.md` §0a carries both it and `IS_FORK`): `origin` for a
same-repo PR, the fork's remote otherwise. The
`HEAD:` refspec pushes what was just rebased even when the local branch is not named
`<headRefName>`. When no configured remote points at the head repository — the usual case
for a fork checked out via `refs/pull/*` — the entry is **not dispatchable**: present the
recipe instead of running it.

One question, at most four options:

1. **Run step 1** — offered only when step 1 is dispatchable; invokes the mapped skill (or
   the rebase recipe) against this PR.
2. **Run steps 1–k** — offered only when two or more dispatchable steps precede the first
   non-dispatchable, human-owned, or terminal entry, **where interleaved `wait-ci` entries
   are absorbed rather than batch-breaking**: every dispatchable resolution projects CI to
   pending, so `wait-ci` sits between any two dispatches by construction, and the
   orchestrator handles it itself as part of the batch — and a freshly pushed head has a
   registration window in which the checks watch reports *no checks* and exits: poll until
   the new head's checks exist, then watch them to completion, before evaluating anything.
   **Every batch command stays repo-qualified** — the ambient checkout may be a fork whose
   default remote is not the base repository, so the watch is
   `gh pr checks <n> -R <host>/<slug>` and the recheck passes the full PR URL (which pins
   host, owner, and repo per `facts.md` §0a). Between steps, re-run
   `pr-details <PR-URL> --no-plan-check --no-page --no-gate`, **carrying the original run's
   plan verdict into the recheck's table** (read `PLAN_COMBINED`/`PLAN_SPLIT` from the
   prior `facts.json` — Phase 4 is skipped for cost, not because the verdict expired, and
   without the carry a plan-keyed row can never reproduce). The carry is valid only while
   the diff is materially unchanged (a rebase); once a dispatched fixer changed the diff,
   a plan-keyed projection is stale — that is divergence. Continue only while the fresh
   headline matches the projection; a red CI landing or a stale plan projection stops the
   run with a report.
3. **Handle it locally** — print step 1's `local:` recipe and stop.
4. **Stop** — the report stands as-is.

**Every sibling dispatch passes the full PR URL, never a bare number.** Siblings resolve
their repository from the ambient checkout (`codex-ship` via `gh repo view`,
`antagonist-review` via unqualified `gh pr` calls), and a fork checkout can carry a
same-numbered PR — a bare `261` there addresses the wrong pull request. The URL pins host,
owner, and repo. A sibling that cannot accept a URL is dispatchable only when the ambient
checkout's repository **is** the resolved base repository.

Dispatch means invoking the sibling skill exactly as the user would have; every gate, prompt,
and confirmation inside that skill still applies. `pr-details` itself still mutates nothing —
the mutation belongs to the skill the user selected, and the selection is recorded in the
final response.

## Output template

Read `output.md` for the full grammar. Shape (a real run, verified live):

```
=== PR #261 · fix(settings): guard admin Server Actions ===
threefold-solutions/client-portals · dev ← detent/…_258-643cc60a3ccb @ ae3b03e · 3 files +256/−13 · open, not draft

STATUS
  CI        green   Lint, typecheck, test ✓ (required, integration 15368) · Vercel ✓ (required, legacy status, no integration_id)
  Review    0/0 approvals · no CHANGES_REQUESTED · extra approval for unattributed changes: required
  Threads   0 unresolved (0 human · 0 codex · 0 other) · 1 resolved
  Merge     MERGEABLE · BLOCKED · 0 behind dev (strict up-to-date required)
  Board     #258 Human Review · auto-promote: on (opt-out label present) · PR row: Backlog (ignored)
  Local     checkout at PR head · clean

PURPOSE
  #258 Admin settings Server Actions do not assert their own caller
  Needed?   NEEDED (high) — 8 effectful exports on dev@733f9f1 still skip the caller assert; #228 fixed admin/ but never settings/

PLAN CHECK  (fable @ xhigh · 80s)
  PLAN_ADEQUATE: yes
  G1 should  cross-file sweep left optional though 10 more admin actions.ts files carry the same gap — file the follow-up issue

UI REVIEW   not warranted — no UI paths changed

QUALITY     codex-ship ✓ at head · antagonist ✗ not run · deep review stale (pre-force-push) · e2e n/a
            still required before merge: antagonist-review (row 21) · deep review at head (C9)

NEXT STEPS
  1 → /workflow:antagonist-review 261                 [row 21]
      why:   codex-ship clean at head but no second-family review, and the diff is 354 lines ≥ 150
      local: review gh pr diff 261 yourself, or run the language plugin's review-deep
  2 → complete the pre-review gate                    [row 23 · projected]
      why:   the contract's deep-review conjunct is observably false at this head
  3 → your approval                                   [row 28 · projected]  ready pending: local gate
  then:  /workflow:pr-details 261
  page:  <run dir>/report.html
  files: <run dir>
```

## Supporting files

- `facts.md` — Phases 0–2: identity, auth, rate gate, git pins, contract and ruleset
  discovery, run dir and cache, retries, PR and issue records, duplicates, CI, reviews,
  threads, mergeability, board, prior-skill evidence
- `still-needed.md` — Phase 3: pinned-read rule, claim extraction, mechanical base probe,
  researcher brief, per-issue aggregation
- `plan-check.md` — Phase 4: prompt template, Fable routing, the Codex `exec` invocation,
  quorum
- `next-step.md` — Phase 6: fact definitions, ordering rationale, ready-predicate ledger,
  action-queue projection and local recipes, fact-vector regression
- `page.md` — Phases 5b and 7b: preview-deploy screenshots and the local report page
- `output.md` — Phase 7: terminal grammar, `--json` schema v2, exit codes, scratch hygiene
