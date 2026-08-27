# Fix Cycle: Steps 3-9

## Step 3: Display and Categorize Comments

**Group A — Resolvable threads** (from `reviewThreads`): Track thread ID, file/line, body, author.

**Group B — Pending reviews** (`CHANGES_REQUESTED`): Track review body, author. Cannot be auto-resolved.

**Track unique reviewers** from both groups for Step 10.

### If no feedback found:

Return structured clean-review state and persist it to the active caller-owned
state file when one is available:

```bash
REVIEW_CLEAN=true
echo "REVIEW_CLEAN=$REVIEW_CLEAN"

SAFE_LOOP_NAME=$(echo "address-review-${RESOLVED_PR:-auto}" | sed 's/[^a-zA-Z0-9_-]/-/g')
REVIEW_STATE_FILE="${STATE_FILE:-${LOOP_STATE_FILE:-$ORIGINAL_REPO_ROOT/.local/state/${SAFE_LOOP_NAME}.loop.local.json}}"
if [ -n "$REVIEW_STATE_FILE" ] && [ -f "$REVIEW_STATE_FILE" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/lib/loop-state.sh"
  set_loop_field "$REVIEW_STATE_FILE" "review_clean" "true" "$WORKFLOW_STATE_PATH"
  echo "Persisted review_clean=true to $REVIEW_STATE_FILE"
fi
```

Skip Steps 4, 4.5, 6, 8, 9, and 10 because there are no edits, tests, commits,
replies, threads, or re-review requests to process. Continue to Step 5 for
local verification, then Step 7 for CI, then Step 11 for completion
verification. Fresh runs, watch mode with no detected bots, and no-watch mode
all follow these verification gates.

After Step 11 succeeds, a standalone address-review run with
`CURRENT_PHASE=fixing`, `WATCH_MODE=true`, and detected bots may transition its
active state to `watching` before entering Step 12:

```bash
if [ "${EMBEDDED_WORKFLOW:-false}" != "true" ] &&
   [ "${CURRENT_PHASE:-}" = "fixing" ] &&
   [ "${WATCH_MODE:-false}" = "true" ] &&
   [ -n "${DETECTED_BOTS:-}" ] &&
   [ -n "${REVIEW_STATE_FILE:-}" ] &&
   [ -f "$REVIEW_STATE_FILE" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/lib/loop-state.sh"
  set_loop_phase "$REVIEW_STATE_FILE" "watching" "$WORKFLOW_STATE_PATH"
  echo "Phase set to: watching (post-fix-cycle path)"
fi
```

This supporting file never decides the successful terminal outcome. After the
applicable gates pass, return `REVIEW_CLEAN=true` to the top-level owner.

### If only pending reviews (no threads):

Address feedback, but note: "This PR has pending review feedback that cannot be auto-resolved. After pushing fixes, you'll need to request re-review from the reviewer."

---

## Step 4: Address Each Comment

**Set phase to `fixing`:**

```bash
SAFE_LOOP_NAME=$(echo "address-review-${RESOLVED_PR:-auto}" | sed 's/[^a-zA-Z0-9_-]/-/g')
LOOP_STATE_FILE="${STATE_FILE:-$ORIGINAL_REPO_ROOT/.local/state/${SAFE_LOOP_NAME}.loop.local.json}"
if [ -f "$LOOP_STATE_FILE" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/lib/loop-state.sh"
  set_loop_phase "$LOOP_STATE_FILE" "fixing" "$WORKFLOW_STATE_PATH"
fi
```

### Protect Pre-existing Target Changes

Before the first edit to each unique source or test path in this fix cycle, verify that the target path has no staged, unstaged, or untracked changes. Run this guard exactly once per path, before sequential work or agent dispatch:

```bash
TARGET_FILE="path/from-review-thread"
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain -- "$TARGET_FILE")" ]; then
  echo "Error: $TARGET_FILE already has changes that are not owned by this review-fix cycle."
  exit 1
fi
```

If the guard fails, inspect the pre-existing diff, review request, and current
workflow-owned file list. State `Decision`, `Evidence`, and `Rationale`. Because
Git cannot distinguish those hunks from a new review fix, do not edit or stage
the path. Stop incomplete with
`WORKFLOW_REASON=unowned-review-target-changes` until the changes are committed,
stashed, or otherwise separated. Follow the caller's **Hard Invariant Failure**
procedure so the workflow cannot advance.

### Parallel Fix Dispatch (when 3+ comments target different files)

When there are 3 or more unresolved comments targeting **different files**, dispatch parallel Implementer subagents:

1. **Group comments by file** — comments in the same file are handled by one subagent
2. **Group by shared test files** — if two source files are covered by the same test file (one colocated `*.test.ts`/`*.spec.ts`, a shared `__tests__/` module, or a shared test-utils/fixture module), they must be in the same group to avoid write conflicts
3. **For each file group**, delegate a fresh-context implementation worker
   through the active surface, selecting sonnet when the surface supports model
   choice, with:
   - "You are addressing PR review comments in `{FILE_PATH}`. Working directory: `{PROJECT_ROOT}`."
   - All comments for that file (reviewer text, line number, suggested change)
   - The full text of the Step 4c fix ladder (instance → siblings → origin, with its
     scope guards) — the subagent cannot read this file
   - "Before editing, run the pre-existing target changes guard. For each comment: understand the request, locate the code, fix it at the root per the ladder (sweep confined to this PR's diff), validate against feedback. Report: files changed, fixes applied, per-fix class statement + siblings fixed + root fix (or none), testability of each fix."
3. **Dispatch all file-group agents in parallel** using `run_in_background: true`
4. **Collect results** — proceed to Step 4.5 (test generation) with combined fix list

**Fall back to sequential processing** when fewer than 3 comments or all target the same file.

For each unresolved review comment (sequential mode, or when parallel dispatch is not used):

### 4a. Understand the Request
Determine what change is requested: code style, logic, docs, test, refactoring? Is it testable (alters observable behavior)?

### 4b. Locate the Code
Use file path and line number from the thread.

### 4c. Make the Fix
Fix the **defect at its root** with the smallest diff that does so. Follow existing
patterns. A review comment reports an *instance* (a defect at file:line); most defects
are instances of a *class* — a general property the change violates, which other sites
in the same PR may violate too. Climb this ladder, in order, stopping when a rung finds
nothing:

1. **Fix the reported instance.** The floor — later rungs never replace it.
2. **Sweep for siblings.** State in one line the class the comment is an instance of,
   then sweep this PR's diff (not the whole repo) for other sites with the same defect.
   Fix each sibling whose failure you can trace the same way; resemblance alone is not
   a defect — a lookalike that is guarded upstream, or differs in the fact that
   matters, is left alone.
3. **Fix the origin.** When the instances share one mechanical origin inside this PR —
   a copy-pasted shape, a wrong value produced upstream of every consumer, a missing
   guard repeated at each call site — fix the origin once instead of patching each site.

Scope guards: the sweep and any origin fix stay inside this PR's diff and blast radius;
siblings already on the base branch are left alone (pre-existing, not this PR's work);
never grow a review fix into a refactor of shared components other surfaces depend on.
When rungs 2–3 find nothing, the minimal instance fix **is** the correct fix. When a
caller (e.g. `codex-ship`) supplies a class statement or a fuller fix-at-the-root
doctrine with the finding, follow that — it is this ladder with the caller's triage
already done.

### 4d. Validate Fix Against Feedback
1. Re-read the reviewer's comment
2. Compare your change against reviewer's intent
3. Check for completeness
4. Avoid mechanical edits that miss the underlying concern

### 4e. Track the Fix
Note: thread ID, what was fixed, brief explanation, the class statement with
`siblings_fixed` count (0 is fine — state it) and `root_fix` (what changed at the
origin, or `none (<reason>)`), testability (`testable`/`not-testable`), source
file/function/package if testable, and every file modified by the fix. Maintain one explicit owned-files list for this fix cycle. Do not add files that were already modified before the cycle or changed for unrelated work.

## Step 4.5: Generate Tests for Testable Fixes

Read `test-generation.md` for full test generation guidelines including testability rules, existing test detection, pattern matching, and test writing procedures. Run the pre-existing target changes guard before modifying an existing test path, then add every generated or modified test file to the owned-files list.

---

## Step 5: Verify Fixes Locally

Detect the package manager once, from the repository root:

```bash
# Sets PM/PMX/IS_MONOREPO and defines has_script().
source "${CLAUDE_PLUGIN_ROOT}/lib/detect-pm.sh"
pm_detect "$WORKTREE_PATH"
echo "Package manager: $PM"
```

`package-lock.json` or no lockfile at all both mean `npm`. Then read the
available scripts so you only run checks the repo actually defines:

```bash
jq -r '.scripts // {} | keys[]' "$WORKTREE_PATH/package.json" 2>/dev/null
```

**Every applicable check must pass before proceeding:**

| Check | Command |
|---|---|
| Build | `(cd "$WORKTREE_PATH" && $PM run build)` — only when a `build` script exists |
| Type-check | `(cd "$WORKTREE_PATH" && $PM run type-check)` when that script exists; otherwise `(cd "$WORKTREE_PATH" && npx tsc --noEmit)` when a `tsconfig.json` is present |
| Test | `(cd "$WORKTREE_PATH" && $PM run test)` when a `test` script exists; otherwise the detected runner — `(cd "$WORKTREE_PATH" && npx vitest run)` or `(cd "$WORKTREE_PATH" && npx jest)` |
| Lint | `(cd "$WORKTREE_PATH" && $PM run lint)` — only when a `lint` script exists |

With `bun`, invoke scripts as `bun run <script>` (bare `bun test` runs Bun's own
runner instead of the package script). In a monorepo (`turbo.json`, `nx.json`,
or `pnpm-workspace.yaml` present) run these as **root** scripts from
`$WORKTREE_PATH` so the task runner fans out to every affected workspace
package.

If any fix touched Convex functions, refresh the generated types before
type-checking: `(cd "$WORKTREE_PATH" && npx convex codegen)`. Never edit
`convex/_generated/` by hand — regenerate it.

Also check dev server logs for errors if applicable.

Fix any failures and re-run until all green.

---

## Step 6: Commit and Push

Stage only files modified during this fix cycle. Build `OWNED_FILES` from the paths tracked in Steps 4 and 4.5, inspect `git -C "$WORKTREE_PATH" status --short`, and exclude every pre-existing or unrelated change. Start from an empty index so an earlier staged change cannot enter the review-fix commit.

```bash
PR_JSON=$(cd "$WORKTREE_PATH" && github_pr "$PR_NUM") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=pr-metadata-api-failure
}
EXPECTED_REMOTE_HEAD_SHA=$(jq -er '.head.sha' <<< "$PR_JSON") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=invalid-pr-head-metadata
}
PR_HEAD_BRANCH=$(jq -er '.head.ref' <<< "$PR_JSON") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=invalid-pr-head-metadata
}
PR_HEAD_OWNER_REPO=$(jq -er '.head.repo.full_name' <<< "$PR_JSON") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=missing-pr-head-repository
}
PR_HEAD_CLONE_URL=$(jq -er '.head.repo.clone_url' <<< "$PR_JSON") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=missing-pr-head-repository
}
PR_HEAD_PUSH_TARGET=""
for remote in $(git -C "$WORKTREE_PATH" remote); do
  REMOTE_URL=$(git -C "$WORKTREE_PATH" remote get-url "$remote")
  REMOTE_OWNER_REPO=$(printf '%s\n' "$REMOTE_URL" | sed 's|\.git$||' | sed -E 's|^https?://[^/]+/||' | sed -E 's|^ssh://[^/]+/||' | sed -E 's|^[^@]+@[^:]+:||')
  if [ "$REMOTE_OWNER_REPO" = "$PR_HEAD_OWNER_REPO" ]; then
    PR_HEAD_PUSH_TARGET="$remote"
    break
  fi
done
PR_HEAD_PUSH_TARGET="${PR_HEAD_PUSH_TARGET:-$PR_HEAD_CLONE_URL}"
if [ "$(git -C "$WORKTREE_PATH" rev-parse HEAD)" != "$EXPECTED_REMOTE_HEAD_SHA" ]; then
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=pr-head-shift
fi

if ! git -C "$WORKTREE_PATH" diff --cached --quiet; then
  echo "Error: Pre-existing staged changes must be committed or unstaged before address-review can commit."
  exit 1
fi

OWNED_FILES=(
  "path/to/fixed-file.ts"
  "path/to/fixed-file.test.ts"
)
git -C "$WORKTREE_PATH" add -- "${OWNED_FILES[@]}"

if ! git -C "$WORKTREE_PATH" diff --cached --quiet; then
  git -C "$WORKTREE_PATH" commit -m "address review comments

- [brief summary of each fix]
- [tests added for testable fixes, if any]"
else
  echo "No owned review-fix changes to commit."
fi
git -C "$WORKTREE_PATH" push "$PR_HEAD_PUSH_TARGET" "HEAD:refs/heads/$PR_HEAD_BRANCH"
PR_HEAD_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
PUBLISHED_HEAD_SHA=$(cd "$WORKTREE_PATH" && github_pr "$PR_NUM" | jq -er '.head.sha') || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=pr-metadata-api-failure
}
if [ "$PUBLISHED_HEAD_SHA" != "$PR_HEAD_SHA" ]; then
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=pr-head-shift
fi
```

Any PR metadata failure or head shift is a top-level **Hard Invariant
Failure**. Stop without pushing when the local parent no longer matches the PR
head, and stop without claiming success when the published head cannot be
verified. The push target is re-derived here so nested callers and watch-mode
re-entry do not depend on checkout-phase shell state.

**CRITICAL: Capture bot review baseline IMMEDIATELY after pushing:**

```bash
BOT_REVIEW_BASELINE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Bot review baseline captured: $BOT_REVIEW_BASELINE"
```

Store this value for all Step 12 bot checks. Do NOT recompute later.

---

## Step 7: Watch CI

```bash
CI_PR_JSON=$(cd "$WORKTREE_PATH" && github_pr "$PR_NUM") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=pr-metadata-api-failure
}
if [ -z "${WORKFLOW_REASON:-}" ]; then
  PR_HEAD_SHA=$(jq -er '.head.sha' <<< "$CI_PR_JSON") || {
    WORKFLOW_RESULT=INCOMPLETE
    WORKFLOW_REASON=invalid-pr-head-metadata
  }
fi
if [ -z "${WORKFLOW_REASON:-}" ]; then
  CHECK_STATUS=0
  CHECKS_JSON=$(cd "$WORKTREE_PATH" && github_watch_pr_checks "$PR_NUM" "$PR_HEAD_SHA") || CHECK_STATUS=$?
  case "$CHECK_STATUS" in
    0) printf '%s\n' "$CHECKS_JSON" | jq '.' ;;
    1) echo "CI failed. Analyze and fix every failing check, then commit, push, update PR_HEAD_SHA, and re-watch." ;;
    2) WORKFLOW_RESULT=INCOMPLETE; WORKFLOW_REASON=checks-registration-timeout ;;
    3) WORKFLOW_RESULT=INCOMPLETE; WORKFLOW_REASON=checks-api-failure ;;
    4) WORKFLOW_RESULT=INCOMPLETE; WORKFLOW_REASON=pr-head-shift ;;
    *) WORKFLOW_RESULT=INCOMPLETE; WORKFLOW_REASON=checks-unknown-failure ;;
  esac
fi
```

For PR metadata failures, statuses 2-4, or an unknown status, follow the
top-level **Hard Invariant Failure** procedure. Registration timeout, API
failure, and head shift are non-success outcomes. If CI fails, analyze, fix,
commit, push, update the exact head SHA, and re-watch. **Do not proceed until
CI is green for the freshly resolved `PR_HEAD_SHA`.**

---

## Step 8: Reply to Each Comment

```bash
gh pr comment "$PR_NUM" --repo "$REPO_SLUG" --body "Fixed in latest commit: [brief explanation]"
```

Keep replies brief and professional.

---

## Step 9: Resolve Review Threads (Group A only)

**Only resolve after CI passes and fixes are pushed.** Only for line-specific threads (Group A).

```bash
(cd "$WORKTREE_PATH" && gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }
' -f threadId="THREAD_ID_HERE")
```

Repeat for each unresolved thread.
