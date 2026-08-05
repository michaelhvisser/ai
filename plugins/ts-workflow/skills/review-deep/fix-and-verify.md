# Fix, Test Generation, Verification, Commit, and Push

This document details the fix phase that runs after the review completes.

When `FIX_CHANGES=false`, skip directly to **Commit and Push** with an empty
`OWNED_FILES` array and `FIXES_APPLIED=false`.

## Fix Iteration

Process findings in priority order (P0 first, then P1, P2, P3):

### For Each Finding

#### 1. Read and Evaluate

Read the file at the cited line range plus surrounding context (~10 lines above and below):

```bash
# Example: read lines 35-55 of the file
```

Evaluate the finding:
- Is this a real issue? Cross-reference with the code.
- Is it already handled elsewhere (e.g., error checked in a wrapper)?
- Is the pattern intentional (e.g., documented exception, performance trade-off)?

#### 2. Skip Criteria

Auto-skip (record skip reason) when:
- **Priority 3 AND confidence < 0.5**: Nit-level noise, not worth fixing
- **Finding is invalid**: The code is correct as written; the review was wrong
- **Finding is pre-existing**: Not introduced by this diff (should have been caught in review, but double-check)
- **Finding is intentional**: Documented exception or justified trade-off

For skipped findings, record: finding number, title, skip reason.

#### 3. Make the Fix

Apply the **minimal change** that addresses the finding. Follow existing patterns in the file:
- Match indentation, naming conventions, and style
- Prefer editing existing code over adding new code
- Don't refactor surrounding code -- fix only the flagged issue

#### 4. Track the Fix

Record: finding number, title, file(s) changed, whether the fix is testable.

A fix is **testable** if it changes observable behavior:
- Return values, thrown/rejected errors, side effects
- HTTP responses, database writes, rendered output
- Function output for given input
- Crash prevention (unhandled rejection, `undefined` property access)

A fix is **not testable** if it's purely cosmetic:
- Comments, log messages, formatting
- Variable renames (unless part of an exported API)
- Import reordering, whitespace, type-only annotations with no runtime effect

---

## Parallel Fix Dispatch

When there are **3 or more findings targeting different files**, use parallel dispatch for faster resolution:

### 1. Group Findings by File

Findings in the same file must be handled by one subagent (sequential within file).

### 2. Group by Shared Test Files

Two source files can resolve to the same test file — most often when a shared
`__tests__/` sibling directory or a single suite covers a whole module. Resolve
each source file's candidate test paths first:

```bash
# Candidate test files for a given source file
test_targets() {
  local f="$1"
  local base="${f%.*}"
  local dir; dir=$(dirname "$f")
  local name; name=$(basename "$base")
  ls "$base".test.* "$base".spec.* \
     "$dir/__tests__/$name".test.* "$dir/__tests__/$name".spec.* \
     2>/dev/null
}
```

Source files whose candidate test paths overlap must land in the same group to
avoid write conflicts on the shared test file.

### 3. Dispatch Subagents

For each file group, delegate a fresh-context implementation worker through the
active surface, selecting sonnet when the surface supports model choice, with:

- "You are fixing review findings in `{FILE_PATH}`. Working directory: `{PROJECT_ROOT}`."
- All findings for that file (title, body, line range, priority, category, confidence)
- "For each finding: read the file, evaluate validity, fix if valid (skip if not), generate test if testable. Report: STATUS (fixed/skipped), FILES_CHANGED, TEST_RESULTS, SKIPPED findings with reasons."

Dispatch all groups in parallel using `run_in_background: true`.

### 4. Collect Results

After all subagents complete, aggregate:
- Total FIXED count
- Total SKIPPED count with reasons
- All files changed
- All test results

Proceed to verification with combined results.

**Fall back to sequential processing** when:
- Fewer than 3 findings
- All findings target the same file

---

## Test Generation

For each fix marked as **testable**, generate a corresponding test.

### Check for Existing Tests

Tests are colocated (`foo.test.ts` beside `foo.ts`) or in a sibling `__tests__/`
directory. Check both, for `.ts`/`.tsx`/`.js`/`.jsx`:

```bash
BASE="${FILE%.*}"
DIR=$(dirname "$FILE")
NAME=$(basename "$BASE")

TEST_FILE=$(ls "$BASE".test.* "$BASE".spec.* \
              "$DIR/__tests__/$NAME".test.* "$DIR/__tests__/$NAME".spec.* \
              2>/dev/null | head -1)
echo "Existing test file: ${TEST_FILE:-none}"
```

### Check for Existing Case Tables

```bash
# Look for an existing suite covering the affected function
[ -n "$TEST_FILE" ] && grep -nE "(describe|it|test)(\.each)?\(.*${FUNCTION_NAME}" "$TEST_FILE" 2>/dev/null
```

### Detect Testing Patterns

Examine existing test files near the changed file:

- **Test runner**: `vitest` or `jest` (check `package.json` deps and whether the
  test file imports from `vitest`; Jest suites usually rely on globals)
- **Case tables**: `it.each([...])` / `test.each([...])`, or a `const cases = [...]`
  array iterated with `it.each(cases)`
- **File location**: colocated `*.test.ts` vs `__tests__/*.spec.ts` — match whichever
  the surrounding code already uses
- **Helper patterns**: fixtures, `__fixtures__/`, `beforeEach`/`afterEach`, custom
  render helpers (`@testing-library/react`), mocking style (`vi.mock` vs `jest.mock`)

Match these conventions.

### Write the Test

**If an existing case table covers the function:**
- Add a new case to the existing `it.each`/`test.each` table
- Name descriptively (e.g., `"returns an error when input is undefined"`)

**If no existing test for the function:**
- Create the test in the detected location (colocated `${FILE%.*}.test.ts` by
  default, or the `__tests__/` sibling if that is the repo's convention)
- Follow the detected runner and import conventions
- Prefer an `it.each` case table when there is more than one input to cover
- Include at least:
  - A case exercising the fixed behavior (the "green" case)
  - A case for the edge case the finding identified
- For async code, `await` the assertion (`await expect(fn()).rejects.toThrow(...)`)
  so the test cannot pass on an unresolved promise

### Verify Test Passes

Run only the affected test file, using the package manager detected earlier:

```bash
# vitest
$PMX vitest run "$TEST_FILE" -t "case name"

# jest
$PMX jest "$TEST_FILE" -t "case name"
```

Drop `-t` to run the whole file. All new tests must pass. If any fail, fix until green.

---

## Verification

After all fixes and tests are applied, run full verification. Run every command
from the repository root — in a monorepo (`turbo.json`, `nx.json`, or
`pnpm-workspace.yaml`) the root scripts fan out to the workspaces.

### Node/TypeScript Projects (package.json exists)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [ -f pnpm-lock.yaml ]; then PM=pnpm; PMX="pnpm exec"
elif [ -f yarn.lock ]; then PM=yarn; PMX="yarn exec"
elif [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun; PMX=bunx
else PM=npm; PMX=npx
fi

has_script() { jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }

echo "=== Build ==="
if has_script build; then
  $PM run build
fi

echo "=== Type check ==="
if has_script type-check; then
  $PM run type-check
elif has_script typecheck; then
  $PM run typecheck
elif [ -f tsconfig.json ]; then
  $PMX tsc --noEmit
fi

echo "=== Tests ==="
if has_script test; then
  $PM run test
elif ls vitest.config.* >/dev/null 2>&1; then
  $PMX vitest run
elif ls jest.config.* >/dev/null 2>&1; then
  $PMX jest
fi

echo "=== Lint ==="
if has_script lint; then
  $PM run lint
fi
```

A missing script is a skip, not a failure — but if the repository's CI runs a
step (build, type-check, test, lint) that is absent or unavailable locally, that
is a verification failure, not an optional-tool skip.

### Other Project Types

**Rust** (Cargo.toml exists):
```bash
cargo build && cargo test
if cargo clippy --version >/dev/null 2>&1; then
  cargo clippy
fi
```

If the repository explicitly configures Clippy in CI or its verification
scripts, an unavailable Clippy component is a verification failure instead of
an optional-tool skip.

**Go** (go.mod exists):
```bash
go build ./... && go test ./...
if command -v golangci-lint >/dev/null 2>&1; then
  golangci-lint run
fi
```

**Python** (pyproject.toml or setup.py exists):
```bash
pytest 2>/dev/null || python -m pytest
if command -v ruff >/dev/null 2>&1; then
  ruff check .
elif command -v flake8 >/dev/null 2>&1; then
  flake8 .
fi
```

### Handling Failures

If any verification step fails:

1. Analyze the failure output
2. Identify which fix caused the failure
3. Fix the issue (the fix, not the original code)
4. Re-run the failing verification
5. Repeat until all pass

Do NOT proceed to commit until all verifications pass.

If a failure cannot be fixed in this run, report:

```
WORKFLOW_RESULT=INCOMPLETE
WORKFLOW_REASON=verification-failed
```

Stop without committing or reporting the review workflow complete.

---

## Commit and Push

Track every file modified during this fix phase in `OWNED_FILES`. Do not include
pre-existing or unrelated changes. The helper stages only these paths and
refuses to commit when the index already contains changes.

```bash
OWNED_FILES=(
  "src/lib/fixed-file.ts"
  "src/lib/fixed-file.test.ts"
)

FIXES_APPLIED=false
if [ "${#OWNED_FILES[@]}" -gt 0 ] &&
   [ -n "$(git status --porcelain -- "${OWNED_FILES[@]}")" ]; then
  FIXES_APPLIED=true
fi

CURRENT_BRANCH=$(git branch --show-current)
PUSH_BRANCH="${PR_HEAD_BRANCH:-$CURRENT_BRANCH}"
PUSH_REMOTE=$(git config "branch.$CURRENT_BRANCH.remote" 2>/dev/null || true)
PUSH_REMOTE="${PUSH_REMOTE:-origin}"

DO_PUSH=false
case "$PUSH_CHANGES" in
  true)
    DO_PUSH=true
    ;;
  false)
    DO_PUSH=false
    ;;
  auto)
    if [ -n "${PR_NUM:-}" ] &&
       [ "$FIXES_APPLIED" = true ] &&
       [ "$COMMIT_CHANGES" = true ]; then
      DO_PUSH=true
    fi
    ;;
  *)
    echo "Error: invalid push mode: $PUSH_CHANGES"
    exit 1
    ;;
esac

if [ "$DO_PUSH" = true ] &&
   [ -n "${PR_NUM:-}" ] &&
   [ "$CURRENT_BRANCH" != "$PR_HEAD_BRANCH" ]; then
  echo "Error: current branch $CURRENT_BRANCH does not match PR head $PR_HEAD_BRANCH."
  exit 1
fi

ACTION_ARGS=()
if [ "$FIX_CHANGES" = false ]; then
  ACTION_ARGS+=(--no-commit)
elif [ "$COMMIT_CHANGES" = true ]; then
  ACTION_ARGS+=(--commit)
else
  ACTION_ARGS+=(--no-commit)
fi

case "$PUSH_CHANGES" in
  true)
    ACTION_ARGS+=(--push)
    ;;
  false)
    ACTION_ARGS+=(--no-push)
    ;;
  auto)
    ACTION_ARGS+=(--auto-push --pr-number "${PR_NUM:-}")
    ;;
esac

if git remote get-url "$PUSH_REMOTE" >/dev/null 2>&1; then
  ACTION_ARGS+=(--remote "$PUSH_REMOTE" --branch "$PUSH_BRANCH")
elif [ "$DO_PUSH" = true ]; then
  echo "Error: push requested but remote $PUSH_REMOTE is unavailable."
  exit 1
fi

COMMIT_MESSAGE="fix: address review-deep findings

- <brief summary of each fix>
- <tests added for testable fixes, if any>"

POST_FIX_RESULT=$(
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-deep-post-fix.sh" \
    "${ACTION_ARGS[@]}" \
    --message "$COMMIT_MESSAGE" \
    -- "${OWNED_FILES[@]}"
)
echo "$POST_FIX_RESULT"
```

`PUSH_CHANGES=auto` pushes only a newly created review commit for a detected
PR. It never auto-pushes a review-only run, a zero-fix run, or uncommitted
review fixes. `--push` may push a clean existing local HEAD, but the helper
refuses to push while any supplied review-owned file remains uncommitted.

The helper returns one JSON object:

```json
{"commit":"created|none|skipped","push":"pushed|skipped","local_head":"<sha>","remote_head":"<sha or empty>"}
```

When push is enabled, `local_head` and `remote_head` must match. If the helper
exits nonzero, stop and report the review as incomplete.
