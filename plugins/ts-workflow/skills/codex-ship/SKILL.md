---
name: codex-ship
description: "Drive a PR to merge-readiness with the Codex GitHub connector: consume existing Codex feedback, judge every finding (real vs. slop) with a strong model, corroborate with a local Codex CLI second opinion, fix only the confirmed-real set, and loop until Codex runs out of genuine value. Use to harden a PR against Codex review before merging. SKIP one-off review-comment cleanup with no loop intent; use address-review."
argument-hint: "[PR-number] [--max-rounds <n>] [--second-opinion mandatory|auto|off]"
disable-model-invocation: true
---

# Codex Ship — triage-gated Codex↔fix loop

Drive a PR to merge-readiness with the Codex connector: **consume any Codex feedback already
on the PR first, then** trigger a review, **judge** each finding (real vs. slop) with a strong
model, corroborate the judgment with a **local Codex CLI second opinion**, fix only the
confirmed-real findings, and **keep looping until Codex runs out of genuine value** — then
**checkpoint with a human** and merge (or hand off to whatever merge automation the repo uses).

Before requesting decisions or delegating work, read
`${CLAUDE_PLUGIN_ROOT}/lib/driver-interaction.md` and follow its
cross-platform capability-binding rules.

Read `${CLAUDE_PLUGIN_ROOT}/lib/decision-gates.md` before resolving any workflow
choice.

Load the shared GitHub REST helpers before any GitHub operation:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/github-rest.sh"
```

**The loop's natural terminus is finding quality, not a round count.** Keep going, round after
round, as long as Codex keeps surfacing *new, real, fixable* defects. Stop when it goes **clear**
(all-clear or nothing confirmed-real — only slop remains), or when it **re-raises a finding a
prior round already dismissed** (a "repeat" — you're going in circles). The round cap
(default **10**) is a high safety backstop against oscillation, not the intended exit — most PRs
converge well before it.

The defining feature is the **anti-slop gate**: rather than fixing every Codex finding blindly,
this skill triages each one first, records *why* it dismissed anything, **dismisses the slop on
the PR itself** (resolves the review thread with the reason, so it doesn't linger or block
merging), and never silently waves slop through.

**Usage:** `/ts-workflow:codex-ship [PR-number] [--max-rounds <n>] [--second-opinion mandatory|auto|off]`

**Examples:** `/ts-workflow:codex-ship 152` · `/ts-workflow:codex-ship 152 --max-rounds 15` ·
`/ts-workflow:codex-ship --second-opinion mandatory`

---

## Model roles (edit this block; never hard-pin a model name in loop logic)

The loop assigns work to roles, not fixed models. Resolve each to whatever tier is available
the week you run this. The cost story: the orchestrator does cheap mechanical babysitting; the
judge and fixer need real reasoning; the second opinion is a different model *family* (local
Codex CLI), so it catches what the primary models miss.

| Role | Default tier | Job |
|------|--------------|-----|
| **Orchestrator** | cheapest fast tier | trigger, poll, SHA-freshness, round-count, dispatch, completion. **Zero code judgment.** |
| **Judge** | strong tier | per finding → verdict `real / wrong / redundant / out-of-scope` + one-line reason |
| **Fixer** | strong tier | one `/ts-workflow:address-review` pass on the confirmed-real set, one commit, one push |
| **Second opinion** | local `codex exec` CLI | AGREE/DISAGREE per finding against the working tree |

**Reference bar for the second-opinion policy = the current strong tier** (whatever the
frontier-quality model is when you run this). The rule below compares the judge against that
bar, never against a model name.

---

## Parse arguments

```bash
MAX_ROUNDS=10               # safety backstop against oscillation, NOT the intended exit
SECOND_OPINION_ARG="auto"   # auto | mandatory | off
PR_NUM=""
SKIP_NEXT=""
for arg in $ARGUMENTS; do
  case "$SKIP_NEXT" in
    rounds) MAX_ROUNDS="$arg"; SKIP_NEXT=""; continue ;;
    so)     SECOND_OPINION_ARG="$arg"; SKIP_NEXT=""; continue ;;
  esac
  case "$arg" in
    --max-rounds)      SKIP_NEXT="rounds" ;;
    --second-opinion)  SKIP_NEXT="so" ;;
    *)                 PR_NUM="$arg" ;;
  esac
done

[ -z "$PR_NUM" ] && PR_NUM=$(github_current_pr 2>/dev/null | jq -r '.number // empty')
if [ -z "$PR_NUM" ]; then echo "ERROR: no PR. Pass a number or run from a PR branch."; exit 1; fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
echo "PR: #$PR_NUM | repo: $REPO | max-rounds: $MAX_ROUNDS | second-opinion arg: $SECOND_OPINION_ARG"
```

Store `PR_NUM`, `REPO`, `MAX_ROUNDS`, `SECOND_OPINION_ARG`.

---

## Phase 0: Preflight

1. **Working tree clean?** `git status --porcelain` must be empty. If not, stop and ask.
2. **Linked issue** — capture for the final report and closure:
   ```bash
   gh pr view $PR_NUM --json closingIssuesReferences --jq '.closingIssuesReferences[].number'
   ```
   Store the first as `ISSUE_NUM` (may be empty — that's fine, just note it).
3. **Resolve the repo's check commands** so we don't burn Codex rounds on lint noise:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/detect-pm.sh"
   pm_detect
   ```
   Build `LOCAL_CHECKS` from what exists, in order: `$PM run lint` if `has_script lint`,
   `$PM run typecheck` if `has_script typecheck`, `$PM run test` if `has_script test`.
   If there is no `package.json`, fall back to `Makefile` targets `lint`/`test`; if neither
   exists, ask the user for the repo's check commands — never guess.
4. **Local courtesy green:** run `LOCAL_CHECKS`. Fix trivial lint locally (≤5 attempts) and
   commit+push if needed. Don't chase deep test failures here — that's what the loop is for.

Print: `=== PHASE 0 COMPLETE: preflight clean, checks: <LOCAL_CHECKS>, issue #$ISSUE_NUM ===`

---

## Kickoff: resolve the second-opinion policy

The second opinion is **mandatory when the judge is a cheaper/weaker model than the strong-tier
reference bar** — because you cannot trust a cheap model's solo triage — and **discretionary
(the judge invokes it per-finding, for the ambiguous ones) when the judge is at or above the
bar**.

Resolve it, then **confirm with the user** before the first round (use the active surface's
structured-input capability per `driver-interaction.md`):

```
JUDGE = <resolved Judge-role model>
if   SECOND_OPINION_ARG == "mandatory":   POLICY = MANDATORY
elif tier(JUDGE) < strong-tier bar:       POLICY = MANDATORY   # floor: cannot be lowered
elif SECOND_OPINION_ARG == "off":         POLICY = OFF
else:                                     POLICY = DISCRETIONARY
```

- **MANDATORY** → run the local `codex exec` juror on **every** finding, both directions
  (confirm real *and* confirm slop).
- **DISCRETIONARY** → the judge decides per finding; run the juror on anything it marks
  ambiguous/borderline.
- `--second-opinion` may **raise** the policy (force mandatory) but may **never lower it below
  a mandatory floor** — if the judge is below the bar, `off` is refused with a warning.

Announce the resolved policy and the judge model in one line, e.g.
`Second opinion: MANDATORY (judge below the strong-tier bar — every finding cross-checked)`.

Print: `=== KICKOFF: max-rounds=$MAX_ROUNDS, second-opinion=$POLICY ===`

---

## The round loop

Initialise `ROUND=0` and an empty **ledger** (findings seen, verdict, second-opinion result,
action, reason, and `github_dismissed` once the slop thread is resolved on the PR). The ledger
is the artifact you present at the checkpoint — keep it faithfully.

### Step A — Consume existing Codex feedback first; trigger only if there is none

**Never post `@codex` while unaddressed Codex feedback is already sitting on the PR.** A new
trigger on top of open threads burns a review, and the fresh review often re-raises the same
findings — which then looks like the "repeat" stop when it's really self-inflicted. Check in
this order:

1. **Unresolved Codex review threads?** Reuse the Step E GraphQL query (unresolved threads
   authored by `chatgpt-codex-connector`). If any exist — from any prior round, this session or
   not — those ARE this round's findings. **Skip the trigger and skip Step B entirely**; take
   the thread bodies straight to Step C for judging. Mark them `source: preexisting` in the
   ledger.
2. **A Codex verdict for the current HEAD already posted?** **Do not assume a push produced
   one.** Codex's own about-box lists exactly three review triggers — open a PR, mark a draft
   ready, and comment `@codex review` — and a plain push to an already-open PR is *not* among
   them (observed in practice: after a fixer push, polling returned nothing until an explicit
   `@codex review` was posted). So treat this check as opportunistic only: look once, and if
   nothing is there for **this** SHA, fall straight through to check 3 rather than waiting out
   the poll budget. Even when an all-clear comment for the current HEAD *does* exist, still
   post an explicit trigger and consume its verdict before declaring CLEAR — a requested
   review belongs on the record.
   Check for a review whose body contains `Reviewed commit: ${HEAD_SHA:0:10}`:
   ```bash
   HEAD_SHA=$(github_pr "$PR_NUM" | jq -r '.head.sha')
   SHA="${HEAD_SHA:0:10}"
   gh api repos/$REPO/pulls/$PR_NUM/reviews --paginate --jq \
     "[.[] | select(.user.login|startswith(\"chatgpt-codex-connector\"))
           | select(.body|contains(\"$SHA\"))] | length"
   ```
   Non-zero → consume that verdict directly (findings → Step C; all-clear → **CLEAR**). No
   trigger, no poll.
3. **Neither** → trigger a fresh review:
   ```bash
   gh pr comment $PR_NUM -b "@codex review"   # official documented trigger; reviews current HEAD
   ```
   `@codex review` is the canonical trigger Codex's own about-box documents. A bare `@codex`
   is equivalent — either form triggers a fresh review of current HEAD. There is also
   `@codex address that feedback`, which makes **Codex itself** update the PR with fixes —
   this skill deliberately does **not** use it (its anti-slop gate judges each finding and
   fixes only the confirmed-real set; letting Codex auto-apply would wave slop through).

Codex reacts 👀 on the trigger comment when it picks the mention up. If no 👀 after ~10 min,
the trigger was dropped — re-post `@codex review` once, then continue waiting. When a review
has findings the body opens `💡 Codex Review — Here are some automated review suggestions...`
with a `Reviewed commit: <10-char SHA>`; **no** findings = a 👍 reaction (or the all-clear
issue comment).

### Step B — Poll for the verdict on THIS HEAD

Codex signals two different ways; watch **both**, filtered to `HEAD_SHA`:

- **Findings** → a review object on `pulls/$PR_NUM/reviews`, body contains
  `Reviewed commit: ${HEAD_SHA:0:10}`. **Review bodies quote a 10-char short SHA**,
  not the full 40-char SHA — a filter matching the full SHA silently times out every round.
  **Pass `--paginate`.** `/reviews` returns 30 per page and the newest review is on the LAST
  page; a PR that has been through a few rounds already has more than one page, so an
  unpaginated poll never sees the review it is waiting for and times out with the verdict
  sitting on page 2.
- **All-clear** → a plain **issue comment** starting `Codex Review: Didn't find any major issues`.
  (All-clear is NOT reliably a 👍, and there is no review object in this case.) All-clear bodies
  **do** carry `Reviewed commit: <10-char SHA>`, same as review bodies — so filter them by SHA
  **and** by `createdAt` after this round's trigger time. Either filter alone is weaker: a stale
  all-clear from an earlier round is a false-positive waiting to happen.

**The bot's login differs by API — match it with `startswith`, never `==`.** REST
(`.user.login`) returns `chatgpt-codex-connector[bot]`; GraphQL (`.author.login`) returns
`chatgpt-codex-connector` with no suffix. An `== "chatgpt-codex-connector"` filter against
REST matches nothing, so the all-clear is invisible and every clear round times out into a
false ESCALATE. Use `select(.user.login | startswith("chatgpt-codex-connector"))` and it
works on both.

Poll every ~2 min, timeout ~12 min. If the timeout hits with no signal, re-post bare `@codex`
once; if still nothing, **ESCALATE** (connector unavailable).

**Parse with `--jq` on the `gh api` call itself — never `echo "$RESULT" | jq`.** zsh's `echo`
interprets `\n` escape sequences inside JSON string values and corrupts the document (jq fails
with "control characters must be escaped"), so the poll loop runs forever seeing no signal.

Reference poll — every trap above is already handled here (10-char SHA, `--paginate`,
`startswith` login, trigger-time filter, `--jq` on the call). Capture `TRIGGER` from the
trigger comment's own `created_at`, not from local clock arithmetic:

```bash
SHA="${HEAD_SHA:0:10}"
TRIGGER=$(gh api repos/$REPO/issues/comments/$TRIGGER_COMMENT_ID --jq '.created_at')
for i in $(seq 1 7); do
  sleep 100
  REV=$(gh api repos/$REPO/pulls/$PR_NUM/reviews --paginate --jq \
    "[.[] | select(.user.login|startswith(\"chatgpt-codex-connector\"))
          | select(.body|contains(\"$SHA\"))] | length" 2>/dev/null || echo 0)
  [ "${REV:-0}" != "0" ] && { echo "FINDINGS for $SHA"; break; }
  CLEAR=$(gh api "repos/$REPO/issues/$PR_NUM/comments?since=$TRIGGER&per_page=100" --paginate --jq \
    "[.[] | select(.user.login|startswith(\"chatgpt-codex-connector\"))
          | select(.body|startswith(\"Codex Review: Didn't find any major issues\"))
          | select(.created_at > \"$TRIGGER\")] | length" 2>/dev/null || echo 0)
  [ "${CLEAR:-0}" != "0" ] && { echo "ALLCLEAR for $SHA"; break; }
done
```

**Before concluding "no verdict", check by hand once.** Both known polling bugs presented
identically to a genuinely silent connector — the loop reports nothing while the verdict is
already on the PR. On timeout, list Codex's reviews `submitted_at > $TRIGGER` with `--paginate`
and look before you re-post or escalate.

- All-clear signal → **CLEAR**, break the loop.
- Findings → continue to Step C.

### Step C — Judge (strong model)

Hand the findings + the PR diff + the current ledger to the **Judge** role. For each finding,
return a verdict and a one-line reason:

- `real` — a genuine defect in this diff, in scope, worth fixing.
- `wrong` — Codex is mistaken (misread the code, false positive).
- `redundant` — already handled elsewhere in the diff, or a duplicate of a prior finding.
- `out-of-scope` — real but belongs to a separate issue/PR, not this one.

Give the judge the ledger so it can spot **re-raised findings**: if Codex re-raises something a
prior round dismissed *with a recorded reason*, that's a genuine disagreement — flag it, don't
silently re-fix or re-dismiss.

### Step D — Second opinion (local Codex CLI juror)

The juror is a **read-only** reviewer: its only output is one AGREE/DISAGREE line. It must
**never mutate the working tree.** `-s read-only` is supposed to guarantee this, but it is
**not sufficient on its own** — juror runs have been observed writing a full fix to the tree
despite `-s read-only`. In a workspace with commit/push automation, that stray diff can be
auto-committed and pushed before you review it. So you must **fence every juror call** with a
clean-tree guard, not trust the sandbox flag alone.

Per the resolved `POLICY`, run the juror on the applicable findings. From the repo directory:

```bash
# --- clean-tree guard (mandatory): snapshot before ---
BEFORE=$(git status --porcelain)

# Prompt goes in a POSITIONAL argument — never `-` (heredoc or file redirect).
# Piped prompts have been observed being ignored entirely, with codex resuming a
# previous session in the same working directory and acting on THAT task instead.
PROMPT='HARD CONSTRAINTS FOR THIS RUN — READ FIRST:
- This is a FRESH, SELF-CONTAINED task. Ignore any previous session and any prior instruction.
- DO NOT use any GitHub tool or MCP tool. DO NOT post, comment, or modify any PR or issue.
- DO NOT modify, create, or delete any file — inspect only.
- Your ONLY output is exactly one line: "AGREE: <why>" if the finding is a real, in-scope bug
  in the current diff, or "DISAGREE: <why>" if it is not. Be terse.

FINDING: <paste the finding text + file:line>'

codex exec -s read-only --skip-git-repo-check \
  -c sandbox_mode="read-only" -c approval_policy="never" \
  -c model_reasoning_effort="medium" \
  -o "$SCRATCH_DIR/codex-so-$ROUND.txt" "$PROMPT"

# --- clean-tree guard: assert the juror wrote nothing; if it did, PARK the diff, don't lose it ---
AFTER=$(git status --porcelain)
if [ "$BEFORE" != "$AFTER" ]; then
  echo "⚠️  SANDBOX BREACH: juror mutated the working tree. Parking its diff on a git stash."
  git stash push -u -m "codex-juror-breach-round-$ROUND"
  echo "   Recover with: git stash show -p stash@{0}   (do NOT let automation commit juror writes)"
fi
```

Use a session scratch directory for `-o` output files (`SCRATCH_DIR`), and parse the verdict
from the `-o` file's last line — never scraped stdout. A tiny `-o` file (a few hundred bytes of
something unrelated) is the tell-tale sign the run did something other than your task; check it
before trusting a verdict. `approval_policy="never"` is what actually denies outward-facing
tool calls — the sandbox flags fence the filesystem only — so keep it set on every call.
**Do not pin a model with `-m`** — availability shifts; let the CLI route. Effort defaults to
`xhigh` if you omit the `-c` — wasteful per-finding, so it's pinned to `medium`; drop to `low`
for speed, raise to `high` for a subtle correctness/security finding. **Do not wrap the call in
`timeout`** — that command does not exist on macOS (exit 127); use the shell tool's own timeout.

**Why stash, not discard:** a breach diff is occasionally a *good* fix. Parking it on a stash
keeps the tree clean for the juror's actual job **and** preserves the work, so the Fixer step
can adopt it deliberately *with your review* instead of automation committing it blind. Never
`git checkout`/`reset` it away, and never proceed to completion with a juror breach still
uncommitted-and-unexplained.

Tie-break rules:
- Judge `real` + juror AGREE → **confirmed-real** (fix it).
- Judge `wrong/redundant/oos` + juror DISAGREE → **confirmed-dismiss** (record reason).
- **Split** (judge and juror disagree) → treat as real *only* for correctness/security findings;
  otherwise record as ambiguous and surface at the checkpoint. Never let a split silently drop.

Record every finding's `{verdict, second_opinion, decision, reason}` in the ledger.

### Step E — Dismiss the slop on GitHub (mandatory, every round)

A dismissal that lives only in your ledger is **invisible on the PR** — the finding stays an
open review thread, fails any "review threads resolved" gate, and can block merging. So for
**every finding this round decided `confirmed-dismiss`** (slop / wrong / redundant /
out-of-scope), you must dismiss it *on GitHub* with a reason, not just in the ledger. Do this
**before** fixing, so the PR reflects reality regardless of how the round exits (CLEAR,
ESCALATE, or continue).

(Thread discovery/resolution is one of the few legitimate GraphQL uses in these workflows —
see the GraphQL-budget discipline in the sibling `ship` skill; everything else stays on REST.)

1. **Resolve the review thread with a reason reply.** Fetch Codex's unresolved threads, match
   each to a dismissed finding by `path`/body, reply with the recorded reason, then resolve:
   ```bash
   OWNER=${REPO%%/*}; NAME=${REPO##*/}   # from the REPO captured in Parse arguments
   # list unresolved Codex threads (id + first comment for matching)
   gh api graphql -f query='
     query($o:String!,$n:String!,$num:Int!){
       repository(owner:$o,name:$n){ pullRequest(number:$num){
         reviewThreads(first:100){ nodes{ id isResolved
           comments(first:1){ nodes{ id author{login} path body } } } } } } }' \
     -f o="$OWNER" -f n="$NAME" -F num=$PR_NUM \
     --jq '.data.repository.pullRequest.reviewThreads.nodes[]
             | select(.isResolved==false)
             | select(.comments.nodes[0].author.login|startswith("chatgpt-codex-connector"))
             | {id, path:.comments.nodes[0].path, body:.comments.nodes[0].body}'

   # reply with the dismissal reason (paper trail), then resolve the thread
   gh api graphql -f query='
     mutation($t:ID!,$b:String!){ addPullRequestReviewThreadReply(input:{
       pullRequestReviewThreadId:$t, body:$b}){ comment{ id } } }' \
     -f t="$THREAD_ID" -f b="Dismissed (slop): <one-line recorded reason>. Second opinion: <AGREE/DISAGREE>."
   gh api graphql -f query='
     mutation($t:ID!){ resolveReviewThread(input:{threadId:$t}){ thread{ isResolved } } }' \
     -f t="$THREAD_ID"
   ```
2. **If Codex submitted a blocking review** (state `CHANGES_REQUESTED`) whose findings were
   *all* dismissed, dismiss the review object too so it stops gating merge:
   ```bash
   gh api graphql -f query='
     mutation($r:ID!,$m:String!){ dismissPullRequestReview(input:{
       pullRequestReviewId:$r, message:$m}){ pullRequestReview{ state } } }' \
     -f r="$REVIEW_ID" -f m="Findings triaged as slop/out-of-scope; see resolved threads for per-finding reasons."
   ```

Only dismiss what you **recorded a reason for**. Never blanket-resolve Codex threads to clear a
gate — a confirmed-real finding's thread stays open until the Fixer's commit addresses it, and
an ambiguous/split finding stays open for the human checkpoint. Mark each dismissed finding
`github_dismissed: true` in the ledger once its thread is resolved.

### Step F — Converge or fix

The two **natural** exits — both are the loop working as designed, not failures:

- **confirmed-real is empty** → Codex surfaced only slop/wrong/out-of-scope this round → it has
  run out of genuine value → **CLEAR**, break. (This "bad findings only" round is the expected
  terminus for most PRs.)
- **Re-raised-dismissed finding present** → Codex is repeating a finding a prior round already
  dismissed *with a recorded reason* → you're going in circles → **ESCALATE** (human settles
  the disagreement). This is the "repeat" stop.

Otherwise there are new, confirmed-real findings → keep going. Dispatch the **Fixer**:
  ```
  /ts-workflow:address-review $PR_NUM --no-watch
  ```
  Restrict it to the confirmed-real set. `--no-watch` so it does one pass and exits — this loop
  owns the outer cycle. It commits + pushes. (That push does **not** trigger a Codex review —
  see Step A check 2. Next round must post an explicit `@codex review`; don't burn the poll
  budget waiting on an auto-review.)

  **If address-review rebases and force-pushes**, that is fine mid-loop — but it mints a new
  HEAD SHA, which invalidates any per-SHA CI status or in-flight CI run. If your repo gates CI
  behind a label or manual trigger, do not apply it mid-loop; wait for the final SHA (see
  Completion). In a detached review worktree, `gh pr checkout` inside the fixer also breaks the
  detached invariant — run the fixer from a normal branch checkout.
- Local safety net after the fixer: run `LOCAL_CHECKS`; fix + commit + push if red.
- `ROUND=$((ROUND+1))`. If `ROUND >= MAX_ROUNDS` → **ESCALATE** with the ledger. Hitting the
  cap is unusual — it means Codex kept surfacing new real findings for 10 straight rounds
  without converging, which is worth a human look (churn, a moving target, or a genuinely
  large PR).

Print each round: `=== ROUND $ROUND/$MAX_ROUNDS: F findings, R real, D dismissed, [continue|CLEAR|ESCALATE] ===`

---

## Pre-merge verification

Reach here only on **CLEAR**. Confirm the confidence gate:

- [ ] All Codex findings resolved or dismissed-with-reason (ledger complete)
- [ ] `LOCAL_CHECKS` green locally on the final SHA
- [ ] Branch rebased on the current base branch
- [ ] **Every dismissed (slop) finding's review thread is resolved *on GitHub* with a reason
      reply** (Step E) — not just in the ledger. Verify zero unresolved Codex threads remain:
  ```bash
  gh api graphql -f query='
    query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){
      pullRequest(number:$num){ reviewThreads(first:100){ nodes{ isResolved
        comments(first:1){ nodes{ author{login} } } } } } } }' \
    -f o="${REPO%%/*}" -f n="${REPO##*/}" -F num=$PR_NUM \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved==false)
            | select(.comments.nodes[0].author.login|startswith("chatgpt-codex-connector"))] | length'
  # must print 0
  ```

**If your repo gates CI behind a label or manual trigger** (rather than running on every
push), apply that trigger only **now**, once the head SHA is final — applying it mid-loop
wastes a run, because the next fixer push or rebase strands the per-SHA status.

---

## Checkpoint (human) — required before merging or hand-off

Present the **ledger** and stop. Do not merge or hand off without an explicit OK.

```
============================================
  #$PR_NUM — CODEX SHIP: READY
============================================
  Rounds:            $ROUND / $MAX_ROUNDS
  Confirmed & fixed: <n>   <list: finding → fix>
  Dismissed:         <n>   <list: finding → verdict → reason → second-opinion → GH thread resolved ✓>
  Ambiguous/split:   <n>   <list, if any>
  Local checks:      <LOCAL_CHECKS> ✓   |   rebased on base ✓
  Linked issue:      #$ISSUE_NUM
--------------------------------------------
  Proceed to merge?
============================================
```

Every **dismissal is shown with its reason** so nothing is silently waved through. If any
finding is ambiguous/split, call it out explicitly. Request the decision via the surface's
structured-input capability, with options:

- **Merge now via `/ts-workflow:ship`** — hands the PR to the sibling ship skill, which
  verifies, watches CI, handles remaining bot feedback, and merges.
- **Stop here** — for repos with their own merge automation (merge queues, board-driven
  lanes): report the ledger and leave the merge to that system.

---

## Completion

- **Merge now** → dispatch `/ts-workflow:ship --no-merge` first if the user wants a final
  human look at CI, otherwise `/ts-workflow:ship`. Ship owns CI-watching and the merge; do not
  duplicate its polling here.
- **Stop here** → print the ledger summary, note the final HEAD SHA, and remind the user of
  anything their automation still needs (e.g. a CI-gating label on the final SHA, a board
  status flip). This skill never flips external project-board state itself.

Print: `=== CODEX SHIP COMPLETE: PR #$PR_NUM, $ROUND rounds, <merged|handed off> ===`

---

## Escalation & bail conditions

On any **ESCALATE**, stop and report the ledger + the reason — never merge past an unresolved
disagreement or a round-cap.

| Condition | Cap | On bail |
|-----------|-----|---------|
| Codex trigger dropped (no 👀) | 1 re-post | Escalate (connector unavailable) |
| Poll for verdict | ~12 min | Check by hand once, re-post once, then escalate |
| Judge/juror split (non-correctness) | — | Record ambiguous, surface at checkpoint |
| Codex re-raises a dismissed finding | — | Escalate (human settles) — the "repeat" stop |
| Fix rounds | `--max-rounds` (default 10) | Escalate with ledger — backstop, not the intended exit |
| Local lint fix (preflight) | 5 | Ask user |
| Juror sandbox breach | — | Stash the diff, warn, continue read-only work |

**Never** merge or hand off without the human checkpoint OK. **Never** blanket-resolve review
threads without a recorded reason. **Never** apply a CI-gating trigger mid-loop — only on the
final SHA.
