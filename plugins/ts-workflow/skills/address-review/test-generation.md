# Test Generation for Review Fixes

## Step 4.5: Generate Tests for Testable Fixes

After all fixes are applied (Step 4 complete), generate tests for fixes classified as `testable` in Step 4e.

### Testability Guidelines

**DO write tests for:**
- Bug fixes that change function/method output or behavior
- Logic changes (conditionals, error handling, edge cases)
- New or modified validation rules
- Data transformation or parsing changes
- API response changes
- Async ordering or race condition fixes (unawaited promises, stale-response handling, effect cleanup)
- Any change that alters what a function returns, how it mutates state, or what side effects it produces

**DO NOT write tests for:**
- Removing or adding comments
- Adding/changing log statements
- Formatting or whitespace changes
- Import reordering
- Variable/function renames (unless public API)
- Documentation updates
- Config file tweaks that don't affect runtime behavior
- Typo fixes in non-user-facing strings

**Rule of thumb:** If the change affects something a caller or user could observe — a return value, an error, a side effect, an HTTP response — it's testable and should get a test. If it's purely cosmetic or informational, skip it.

### 4.5a. Identify Testable Fixes

Review the tracking notes from Step 4e. Collect all fixes marked `testable` along with their affected function/component/module and its directory or workspace package.

If no fixes are testable, skip to Step 5.

### 4.5b. Check for Existing Tests

For each testable fix, check if a test file already exists — colocated beside the source or in a sibling `__tests__/` directory:

```bash
BASE="${FILE%.*}"
ls "$WORKTREE_PATH/$BASE".{test,spec}.{ts,tsx,js,jsx} 2>/dev/null
ls "$WORKTREE_PATH/$(dirname "$FILE")"/*.{test,spec}.{ts,tsx,js,jsx} 2>/dev/null
ls "$WORKTREE_PATH/$(dirname "$FILE")"/__tests__/* 2>/dev/null
```

If a test file exists, look for existing coverage of the affected symbol across ALL sibling test files (tests may be split across multiple files):

```bash
grep -rn -e "${FUNCTION_NAME}" -e '\.each(' \
  --include='*.test.ts' --include='*.test.tsx' \
  --include='*.spec.ts' --include='*.spec.tsx' \
  "$WORKTREE_PATH/$(dirname "$FILE")" 2>/dev/null
```

### 4.5c. Detect Testing Patterns

Examine existing test files in the same directory or workspace package to detect conventions:

- **Test runner**: vitest, jest, or `node:test` — check `devDependencies` in the nearest `package.json` and the imports at the top of neighbouring test files (`from "vitest"` vs `@jest/globals` vs `node:test`)
- **Case tables**: look for `it.each(`, `test.each(`, or `describe.each(` usage
- **File naming and placement**: colocated `*.test.ts` beside the source vs a `__tests__/` directory; `.test.` vs `.spec.`
- **Assertion and helper libraries**: `@testing-library/react` for components, `convex-test` for Convex functions, `msw` for network stubs, snapshot usage
- **Helper patterns**: shared fixtures, `beforeEach`/`afterEach` setup, `test-utils`/`__fixtures__` modules

Match these conventions when writing new tests.

### 4.5d. Write Tests

For each testable fix:

**If an existing `it.each`/`test.each` case table covers the affected function:**
- Add a new case to the existing table that covers the scenario the review comment flagged
- Name the case descriptively (e.g., `"returns an error when input is null"`)

**If no existing test exists:**
- Create a new test in the appropriate `*.test.ts` / `*.spec.ts` file, placed per the detected convention (4.5c)
- Follow the detected runner, naming, and helper conventions
- Use an `it.each` case table when the fix has more than one meaningful input variation; a plain `it()` is fine for a single behavior
- Include at least:
  - A case that exercises the fixed behavior (the "green" case)
  - A case for the edge case or incorrect input the review comment identified

### 4.5e. Verify Tests Pass

Run only the affected test file — filter to the new case by name when the file is large:

```bash
# vitest
(cd "$WORKTREE_PATH" && npx vitest run path/to/file.test.ts -t "returns an error when input is null")

# jest
(cd "$WORKTREE_PATH" && npx jest path/to/file.test.ts -t "returns an error when input is null")
```

All new tests must pass (green). If any fail, fix the test until green.

**Note on red-green:** The traditional red-green cycle (verify test fails without fix, then passes with fix) is impractical here because fixes are applied in batch during Step 4. The review comment itself serves as the "red" evidence — it identified broken or incorrect behavior. The green confirmation in this step validates the test correctly covers the fixed behavior.
