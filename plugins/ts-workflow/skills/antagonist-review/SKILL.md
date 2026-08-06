---
name: antagonist-review
description: "Cross-model adversarial review with quorum tie-breaks: a strong subagent finds defects, the local Codex CLI attacks every finding, a third model breaks ties, and a human settles only what the models genuinely cannot — then, on approval, Codex fixes the confirmed set and the loop re-reviews until clean. Use for high-stakes review of a PR, branch, or working tree. SKIP routine single-pass review; use review-deep."
argument-hint: "[PR-number] [--base <ref>] [--max-fix-rounds <n>] [--effort low|medium|high|xhigh] [focus ...]"
disable-model-invocation: true
---

# Antagonist Review — cross-model adversarial review with quorum tie-breaks

Find the strongest possible set of real defects in a change by making two model families
fight over every finding: **a strong finder model finds, the local Codex CLI attacks, a third
model breaks ties, a human settles only what the models genuinely cannot** — then, on explicit
approval, Codex fixes the confirmed set, the finder verifies each fix, and the loop re-reviews
the fixed code until a round comes back clean.

The premise: a single reviewer (any model) produces plausible-but-wrong findings and misses
what its family is blind to. Consensus across model families is a much stronger signal than
confidence within one. Disagreement is **diagnostic, not noise** — every split gets debated,
escalated, and resolved on the record. Nothing is silently dropped and nothing is fixed
without a recorded verdict.

Before requesting decisions or delegating work, read
`${CLAUDE_PLUGIN_ROOT}/lib/driver-interaction.md` and follow its
cross-platform capability-binding rules.

Read `${CLAUDE_PLUGIN_ROOT}/lib/decision-gates.md` before resolving any workflow
choice.

**Usage:** `/ts-workflow:antagonist-review [PR-number] [--base <ref>] [--max-fix-rounds <n>] [--effort low|medium|high|xhigh] [focus ...]`

**Examples:**
`/ts-workflow:antagonist-review` (current branch vs auto-detected base) ·
`/ts-workflow:antagonist-review 196` · `/ts-workflow:antagonist-review --base main concurrency in the sync loop`

This skill is **repo-agnostic**: it auto-detects the base branch, the lint/test commands, and
the repo guidelines file. It never pushes and never comments on GitHub.

---

## Model roles (edit this block; never hard-pin a model name in loop logic)

| Role | Model | Job | Token posture |
|------|-------|-----|---------------|
| **Orchestrator** | session model | scope, dispatch, ledger, checkpoints. No code judgment. | cheap |
| **Finder** | strongest available subagent tier (e.g. `model: "opus"`) | multi-lens review → scored findings | the big spend; runs once per review round |
| **Antagonist** | local `codex exec` (read-only) | refute every finding; flag what the finder missed | one CLI call per round, effort `xhigh` |
| **Tie-break juror** | a third strong tier, distinct from the Finder's default when available | 2-of-3 quorum vote on splits only | one batched call, splits only |
| **Fixer** | local `codex exec` (write-capable) | apply the approved fix set | one call per fix batch |
| **Fix verifier** | Finder-tier subagent | confirm each fix resolves its finding | one call per fix batch |

Cost story: the finder does one thorough pass per round, Codex is subscription-side and
attacks everything, the juror only ever sees the (usually small) split set, and re-review
rounds are scoped to changed files only. `--effort` tunes the Codex calls (default `xhigh` —
maximum scrutiny; drop it explicitly for quick passes on small diffs).

---

## Parse arguments

```bash
BASE_REF=""; MAX_FIX_ROUNDS=3; CODEX_EFFORT="xhigh"; PR_NUM=""; FOCUS=""
SKIP_NEXT=""
for arg in $ARGUMENTS; do
  case "$SKIP_NEXT" in
    base)   BASE_REF="$arg"; SKIP_NEXT=""; continue ;;
    rounds) MAX_FIX_ROUNDS="$arg"; SKIP_NEXT=""; continue ;;
    effort) CODEX_EFFORT="$arg"; SKIP_NEXT=""; continue ;;
  esac
  case "$arg" in
    --base)           SKIP_NEXT="base" ;;
    --max-fix-rounds) SKIP_NEXT="rounds" ;;
    --effort)         SKIP_NEXT="effort" ;;
    [0-9]*)           [ -z "$PR_NUM" ] && PR_NUM="$arg" || FOCUS="$FOCUS $arg" ;;
    *)                FOCUS="$FOCUS $arg" ;;
  esac
done
```

---

## Phase 0 — Preflight & scope

1. **Codex CLI available?** `command -v codex` — if missing, stop and tell the user this
   skill needs the Codex CLI (the antagonist and fixer roles both run on it).
2. **Resolve the diff scope** (first match wins):
   - `PR_NUM` given → `gh pr diff $PR_NUM` and `gh pr view $PR_NUM --json title,body` for context.
   - `--base` given → `git diff $BASE_REF...HEAD`.
   - Otherwise auto-detect the base:
     ```bash
     BASE_REF=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null \
       || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@.*/@@')
     [ -z "$BASE_REF" ] && BASE_REF=main
     ```
     If the current branch IS the base branch, fall back to reviewing the working tree
     (staged + unstaged + untracked). If the scoped diff is empty, say so and stop.
3. **Repo conventions:** locate `CLAUDE.md`/`AGENTS.md` at the root and in changed
   directories. Locate the check commands:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/detect-pm.sh"
   pm_detect
   ```
   Prefer `package.json` scripts (`$PM run lint`, `$PM run typecheck`, `$PM run test` — each
   only if `has_script` says it exists); fall back to `Makefile` targets `lint`/`test`; if
   neither exists, ask the user — never guess. Record the commands: the fix phase needs them.
4. **Working tree:** review runs fine on a dirty tree, but the **fix phase requires a clean
   tree** (the Codex tree-guard depends on it). Note the state now; re-check before fixing.
5. **Ledger:** create `$SCRATCH_DIR/antagonist-ledger.json` (a session scratch directory) —
   an array of findings, each:
   ```json
   { "id": "F1", "source": "finder|codex", "round": 1, "file": "...", "line": 0,
     "severity": "critical|high|medium|low", "class": "security|data-loss|correctness|other",
     "title": "...", "detail": "...", "confidence": 0,
     "codex_verdict": "", "rebuttal": "", "juror_verdict": "",
     "status": "open|confirmed|dismissed|human", "reason": "", "fixed_in": "" }
   ```
   The ledger is the single source of truth for every checkpoint and the final report.
   Findings are deduped against it across all rounds (same file + same defect = same entry).

Print: `=== SCOPE: <target> vs <base> | N files, M lines | checks: <cmds> ===`

---

## The review round (runs on the initial diff, then again on each fix batch)

### Step A — FIND (finder model, multi-lens, parallel)

Launch **parallel finder subagents in a single message**, one per lens, each returning a raw
findings list (file, line, severity, class, title, detail, and why it was flagged):

- **Bugs/correctness** — the changed hunks only; large bugs, not nitpicks.
- **Security & data safety** — auth, trust boundaries, data loss, corruption,
  irreversible state, injection.
- **Failure modes** — retries, partial failure, idempotency, races, ordering, null/undefined/
  empty/timeout paths, unhandled promise rejections, rollback safety.
- **Guidelines compliance** — only what the located CLAUDE.md/AGENTS.md *explicitly* calls out.
- **History & context** — git blame/log of the touched code; regressions against documented
  intent and code comments.

If the user gave focus text, every lens weights it heavily.

Then score each finding with the confidence rubric (0 = false positive under light scrutiny;
25 = unverified maybe; 50 = real but minor/rare; 75 = verified, likely hit in practice;
100 = certain, frequent). **Keep everything ≥ 50** — the antagonist exists to kill borderline
findings, so don't pre-filter aggressively; do drop obvious false-positive shapes
(pre-existing issues, linter-catchable problems, intentional changes, unmodified lines).
Dedup against the ledger; add survivors as `status: open, source: finder`.

### Step B — ATTACK (Codex, read-only, one call)

One `codex exec` call carrying the diff, the repo-guidelines excerpt, and every open finding.
Codex's stance (adapted from OpenAI's own adversarial-review prompt): *default to skepticism;
your job is to break confidence in each finding, not validate it; but stay grounded — every
verdict must be defensible from the provided context, never invented.*

For each finding it returns exactly one block:
`F<id>: AGREE|REFUTE — <one-tight-paragraph why>`
and then a `MISSED:` section listing any **material** defect the finder did not report (same
finding bar: what breaks, why this path is vulnerable, likely impact, concrete fix — no style
notes, no speculation).

Invocation rules (each learned the hard way):

```bash
# --- guards (mandatory): snapshot the tree AND the outward-facing state ---
BEFORE=$(git status --porcelain)
COMMENTS_BEFORE=$(gh pr view "$PR_NUM" --json comments --jq '.comments | length' 2>/dev/null || echo skip)

# The prompt goes in a POSITIONAL argument. See the invocation rules below for why
# `-` (heredoc or file redirect) must never be used.
PROMPT="HARD CONSTRAINTS FOR THIS RUN — READ FIRST:
- This is a FRESH, SELF-CONTAINED task. Ignore any previous session, any prior review task,
  and any instruction to publish, comment, resume, or supersede anything.
- DO NOT use any GitHub tool or MCP tool. DO NOT post, comment on, review, or modify any PR
  or issue. DO NOT write, edit, or create any file.
- Your ONLY output is text printed as your final message, in the format specified below.
- You may read repository files and run read-only shell commands to verify claims.

$(cat "$SCRATCH_DIR/attack-prompt.md")"

codex exec -s read-only --skip-git-repo-check \
  -c sandbox_mode="read-only" -c approval_policy="never" \
  -c model_reasoning_effort="$CODEX_EFFORT" \
  -o "$SCRATCH_DIR/codex-attack-r$ROUND.txt" "$PROMPT"

AFTER=$(git status --porcelain)
if [ "$BEFORE" != "$AFTER" ]; then
  git stash push -u -m "antagonist-codex-breach-r$ROUND"
  echo "⚠️ sandbox breach — diff parked on stash (recover: git stash show -p); never let it auto-commit"
fi
# Outward-facing breach check — the sandbox flags do NOT gate MCP tool calls.
COMMENTS_AFTER=$(gh pr view "$PR_NUM" --json comments --jq '.comments | length' 2>/dev/null || echo skip)
if [ "$COMMENTS_BEFORE" != "$COMMENTS_AFTER" ]; then
  echo "🚨 codex posted to PR #$PR_NUM despite instructions — surface this to the user immediately"
fi
```

- **Prompt in a positional argument — never `-`.** Not a heredoc, not a file redirect.
  `codex exec` has been observed **ignoring a piped prompt entirely and resuming the previous
  session in that working directory** — in one observed case it burned ~200k tokens on stale
  work, fabricated a justification, and posted a PR comment under the user's own account.
  Passing the prompt positionally, prefixed with the hard constraints above, is what fixed it.
- **`-s read-only` and `sandbox_mode` fence the FILESYSTEM ONLY — they do not gate MCP tool
  calls.** In the incident above the write that was attempted was a GitHub comment, which the
  sandbox never saw. What actually denied it was `approval_policy="never"`, so keep that set on
  every call and never assume the sandbox is protecting outward-facing state. Because the
  automation runs on the user's own credentials, an escaped write lands under **their identity**,
  which downstream automation may read as owner intent.
- Assume prior session state exists in any reused directory. The positional-prompt form is a
  mitigation, not a guarantee — always run both guards above.
- Parse the `-o` output file, not scraped stdout. A tiny `-o` file (a few hundred bytes) is the
  tell-tale sign the run did something other than your task; check it before trusting a verdict.
- `xhigh` runs are slow: give every codex call the shell tool's maximum timeout; for large
  diffs run it as a background task and continue when it completes. **Do not wrap the call in
  `timeout`** — that command does not exist on macOS (exit 127).
- **Do not pin a model with `-m`** — availability shifts; let the CLI route. `--effort` is the knob.
- Effort defaults to `xhigh`. If the user lowered it via `--effort`, still raise this call
  back to `xhigh` when any open finding is `security`/`data-loss` class.

Record `codex_verdict` per finding. Each `MISSED` item enters the ledger as
`source: codex, status: open` — and gets the **mirror treatment**: a single finder subagent
judges every codex-sourced finding with the same skeptical stance (AGREE/REFUTE + why). The
antagonism is symmetric; neither family's findings are trusted unexamined.

### Step C — CONVERGE

- Both agree **real** → `status: confirmed`.
- Both agree **not real** (the finder scored < 75 *and* Codex REFUTEd with a reason the
  finder's evidence can't answer — or the finder REFUTEd a codex-sourced finding and nothing
  contradicts it) → `status: dismissed` with the reason recorded. A dismissal without a
  recorded reason is a bug in this process.
- Disagreement → **one rebuttal exchange** before anyone escalates: the finding's sponsor
  (a finder subagent for finder-sourced, the next Codex call for codex-sourced) writes a
  rebuttal answering the refutation's specific argument with specific evidence (code lines, a
  traced failure path). The opponent re-verdicts *given the rebuttal*. Flip → resolve as above.
  Still split → Step D. One exchange only — a second round of the same two voices is where
  loops stop converging and start burning tokens.

### Step D — QUORUM (third model, splits only, one batched call)

Dispatch **one** tie-break juror subagent (a strong tier distinct from the Finder's default
when the surface offers one; otherwise the session model) with the full debate record for
every still-split finding: the finding, the refutation, the rebuttal, the re-verdict, and the
relevant diff hunks. For each it returns `REAL|NOT-REAL`, a one-line reason, and its own
confidence `high|low`. 2-of-3 quorum resolves the finding — **except** these three, which go
to the human instead:

1. **Low-confidence quorum** — the juror voted but flagged its own confidence `low`.
2. **Security/data-loss split** — any 2-1 outcome on a `security` or `data-loss` class
   finding, whichever way it fell. Wrong in either direction is too expensive to automate.
3. **Repeat** — a model re-raises a finding the ledger already dismissed with a reason.
   That's a genuine standing disagreement, not a vote.

Everything else: quorum verdict → `confirmed` or `dismissed`, reason recorded.

### Step E — HUMAN TIE-BREAK (only if Step D routed anything here)

Build a decision brief the user can act on in two minutes. If the active surface can publish
a rich document (e.g. an HTML artifact — load any available artifact-design guidance first),
do that; otherwise write the brief to `$SCRATCH_DIR/antagonist-brief.md` and present it in
the response. Per contested finding include:

- **The issue** in plain language, with the actual code snippet and file:line.
- **Impact on this code** — the concrete failure scenario, traced.
- **The debate** — the finder's claim, Codex's refutation, the rebuttal, the juror's vote,
  side by side.
- **Options** — typically: fix now (with the proposed fix sketch) / dismiss (with what you're
  accepting) / defer to a follow-up issue. State the ramifications and effort of each.
- **Urgency** — ship-blocker vs. eventually vs. cosmetic, and why.

Then request one structured decision per contested finding via the surface's native
structured-input capability (options `Fix it` / `Dismiss` / `Defer to issue`), referencing
the brief. Record each answer as the finding's final status with `reason: "human decision"`.
If the user picks Defer, note it for the final report — do not create issues without being
asked.

### Round exit

- New confirmed findings exist → they queue for the fix checkpoint.
- **No new confirmed findings and no open splits → the round is CLEAN.**
- A round may also **ESCALATE** wholesale if it stops converging: no ledger status has
  changed for a full round, or the same finding has bounced twice. Present the ledger and stop.

---

## Fix checkpoint (human) — required before any fix

Present the ledger summary and stop. Never fix without an explicit go.

```
============================================
  ANTAGONIST REVIEW — ROUND <n> COMPLETE
============================================
  Confirmed:   <n>  <list: id · severity · title · who agreed (finder+codex | quorum | human)>
  Dismissed:   <n>  <list: id · title · reason>
  Human calls: <n>  <list: id · your decision>
  Deferred:    <n>
--------------------------------------------
  Approve fixes? (all / select / none)
============================================
```

Request the decision via the surface's structured-input capability:
**Fix all confirmed (Recommended)** / **Let me pick** (multi-select over the confirmed list) /
**Stop here** (report only, no changes).

---

## Fix phase (Codex fixes, finder verifies, loop re-reviews)

Requires a clean working tree (stash or commit anything unrelated first — ask, don't assume).

1. **FIX** — one write-capable `codex exec` call (`-s workspace-write`,
   `-c sandbox_mode="workspace-write"`, and the same **positional-prompt** / `-o` / no-`-m`
   rules from Step B) with the approved findings and their debate records. Keep the
   no-GitHub/no-MCP and ignore-prior-session constraints in the prompt preamble — this call is
   allowed to write **files in this workspace only**, never to post or comment anywhere. Keep
   the `COMMENTS_BEFORE`/`COMMENTS_AFTER` outward-facing guard on it too; only the tree guard
   is relaxed here, because file writes are the point. Instruction: *fix each finding minimally
   and in the codebase's existing style; do not refactor beyond the finding; do not touch
   unrelated files; list what you changed per finding.*
2. **Local checks** — run the recorded lint/typecheck/test commands. Red → give Codex one
   repair pass with the failure output; still red → revert the batch (`git checkout -- .` on
   the touched files) and escalate to the user with the failure.
3. **VERIFY** — one finder-tier subagent per fix batch: for each finding, does the diff
   actually resolve the traced failure scenario (not just pattern-match it)? Any fix judged
   insufficient goes back to step 1 once; twice-failed → route to the user.
4. **Commit** the batch: `fix(review): address antagonist review round <n> findings <ids>`.
   Never push.

   **Check for a detached HEAD first — `git symbolic-ref -q HEAD || echo DETACHED`.** PR review
   worktrees are routinely checked out detached at the PR head, and committing there **orphans
   the commit**: it lands on no branch and never reaches the PR. Do not "fix" this by checking
   out the PR's own branch either — if any automation (a merge queue, a bot, another agent)
   operates on that branch, having it checked out in a second worktree blocks or races it.
   Instead commit to a **new local branch** (`git switch -c review/antagonist-<pr>`), which is
   durable, orphans nothing, and touches neither the PR branch nor any automation. Then tell
   the user the commit is on that branch and not on the PR, so they can cherry-pick it.
   Leaving the fixes uncommitted is **not** the safe alternative — automation has been
   observed wiping uncommitted edits in review worktrees.
5. **Re-review** — run one more full review round (Steps A–E) **scoped to the files the fix
   batch touched**, so the fix itself gets the same adversarial treatment. Mark fixed
   findings `fixed_in: <sha>`.
6. Repeat until a round comes back CLEAN or `MAX_FIX_ROUNDS` (default 3) is hit — the cap is
   an oscillation backstop, not the intended exit.

---

## Final report

Lead with the verdict: CLEAN (and after how many rounds) or what remains open. Then the
ledger: every finding, its journey (found → attacked → verdict → fix/dismiss/defer), commits
made, and lint/test state. Every dismissal shows its reason. If anything was deferred,
list it so the user can open issues.

## Escalation & bail conditions

| Condition | Cap | On bail |
|-----------|-----|---------|
| Codex CLI missing/erroring | 1 retry | Stop — the skill needs both model families |
| Rebuttal exchanges per finding | 1 | → quorum juror |
| Repeat of a dismissed finding | — | → human (standing disagreement, not a vote) |
| Ledger unchanged for a full round | — | ESCALATE with ledger |
| Fix→verify failures per finding | 2 | → human |
| Checks red after repair pass | 1 | Revert batch, escalate |
| Fix rounds | `--max-fix-rounds` (3) | Report with remaining findings |
| Codex sandbox breach | — | Stash the diff, warn, continue read-only work |

**Never** fix without the checkpoint OK. **Never** push. **Never** resolve a split by
dropping it — every finding ends `confirmed`, `dismissed`+reason, or a recorded human call.
