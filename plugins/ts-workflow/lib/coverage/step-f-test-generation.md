# Step F — Test Generation for Uncovered Code

Loaded by `coverage-verification.md` Step F. Owns mode selection,
`CHANGED_FUNC_NAMES` extraction, per-language test-writing conventions, and
the final `coverage_tests_generated` state-file write.

Only runs when Step E routes here for below-threshold coverage or the
no-test-files branch.

## Mode selection

Set by the Step E branch:

- **All uncovered functions mode**: Generate tests for every
  uncovered function in `CHANGED_SRC` (Node/TS: `CHANGED_SRC_GATED`), as listed
  in `UNCOVERED_FUNCS` from Step D.
- **No-test-files path**:
  `UNCOVERED_FUNCS` may be empty because Step D short-circuits when coverage
  data is missing. In this case, read each file in `CHANGED_SRC` (Node/TS:
  `CHANGED_SRC_GATED` — entrypoint/wiring files are excluded so Step F never
  generates tests for a `next.config.ts` or a provider-only `layout.tsx`)
  directly and extract all exported function/const/class declarations as test
  targets.
- **Changed functions only mode**: Available to callers that already
  selected this scope before entering the mandatory gate; it is never offered
  as a low-coverage bypass.

## Changed-functions extraction

When a caller selected this scope before the gate, identify changed functions
by mapping diff hunks to their enclosing declaration
using committed, staged, unstaged, and untracked changes (matching Step B's
file detection):

```bash
# Combine committed + staged + unstaged diffs
COMBINED_DIFF=$( (git -C "$WORKTREE_PATH" diff "${BASE_BRANCH}...HEAD" -- $CHANGED_SRC 2>/dev/null; git -C "$WORKTREE_PATH" diff HEAD -- $CHANGED_SRC 2>/dev/null; git -C "$WORKTREE_PATH" diff --cached HEAD -- $CHANGED_SRC 2>/dev/null) )
# For untracked files: generate a synthetic diff so new functions are detected
UNTRACKED_SRC=$(git -C "$WORKTREE_PATH" ls-files --others --exclude-standard 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' | grep -v -E '\.(test|spec)\.[cm]?[jt]sx?$' || true)
for uf in $UNTRACKED_SRC; do
  COMBINED_DIFF="${COMBINED_DIFF}
$(git -C "$WORKTREE_PATH" diff --no-index /dev/null "$WORKTREE_PATH/$uf" 2>/dev/null || true)"
done
# Declarations on added lines: `export function x`, `async function x`,
# `export const x = () =>`, `const x = query({...})` (Convex), `export class X`.
# This over-collects (a local `const total = 0` shows up too); the per-file
# intersection with UNCOVERED_FUNCS below discards anything the coverage report
# does not know as a function.
CHANGED_FUNC_NAMES=$(echo "$COMBINED_DIFF" | grep '^+' | grep -v '^+++' | sed 's/^+//' \
  | grep -oE '(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*|(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=|(export[[:space:]]+)?(abstract[[:space:]]+)?class[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' \
  | sed -E 's/^(.*[[:space:]])?(function|class|const|let|var)[[:space:]]+//' \
  | sed -E 's/[[:space:]]*[=(].*$//' \
  | sort -u | grep -v '^$')
# Best-effort enclosing-declaration context from hunk headers. Git ships no
# built-in userdiff driver for JS/TS, so headers are only useful when the repo
# sets one via .gitattributes — treat this as additive, not authoritative.
HUNK_FUNCS=$(echo "$COMBINED_DIFF" | grep -oE '^@@.*@@[[:space:]]+.*(function|const|class)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' | sed -E 's/.*[[:space:]](function|const|class)[[:space:]]+//' | sort -u)
CHANGED_FUNC_NAMES=$(printf '%s\n%s' "$CHANGED_FUNC_NAMES" "$HUNK_FUNCS" | sort -u | grep -v '^$')
```

**Matching logic:** Cross-reference per-file to avoid ambiguity (e.g., `run`
in `src/a.ts` vs `src/b.ts`). For each file in `CHANGED_SRC`:

1. Get the declarations changed in that file from `COMBINED_DIFF` (added
   declaration lines scoped to that file)
2. Get the uncovered functions in that file from `UNCOVERED_FUNCS` (Step D
   stores entries as `file:func1, func2`)
3. Intersect the two lists — only generate tests for functions that are BOTH
   changed AND uncovered in the same file

If no functions match across any file (all changed functions are already
covered), report this and return to the calling command's next step.

## Per-target test generation

Generate tests appropriate for the detected project type. For each target
uncovered function:

1. **Read the source file** and understand the signature, parameters,
   return types, and dependencies.

2. **Check for existing test files** and **detect testing conventions** per
   runner. Match the project's dominant convention rather than introducing a
   second one.

### Vitest (primary)

- Check for existing test files following patterns from `${CLAUDE_PLUGIN_ROOT}/skills/address-review/test-generation.md` Steps 4.5b-4.5c:
  ```bash
  ls "$WORKTREE_PATH/${FILE%.*}".{test,spec}.{ts,tsx,js,jsx} 2>/dev/null || ls "$WORKTREE_PATH/$(dirname "$FILE")"/__tests__/* 2>/dev/null
  ```
  Colocated `foo.test.ts` beside `foo.ts` is the default; use
  `__tests__/foo.test.ts` only if the repo already does.
- Detect: explicit imports (`import { describe, it, expect, vi } from "vitest"`)
  vs `globals: true` in `vitest.config.*`; `it` vs `test`; assertion style.
- Use `it.each` / `test.each` case tables for multi-case coverage — the
  JS/TS equivalent of a table-driven test:
  ```ts
  it.each([
    { name: "empty input", input: "", expected: null },
    { name: "trims whitespace", input: " a ", expected: "a" },
  ])("$name", ({ input, expected }) => {
    expect(parse(input)).toEqual(expected);
  });
  ```
- Mocks and isolation: `vi.mock()`, `vi.fn()`, `vi.spyOn()`,
  `vi.useFakeTimers()`; reset in `beforeEach` when the file already does.
- React components: `@testing-library/react` with a `jsdom`/`happy-dom`
  environment — only if the project already depends on them.
- **Convex**: use `convex-test` with the project schema
  (`const t = convexTest(schema)`) and call functions through
  `api`/`internal` from `./_generated/api`. Never edit `convex/_generated/`; if
  the generated types are stale run
  `(cd "$WORKTREE_PATH" && npx convex codegen)`.
- Verify one file: `(cd "$WORKTREE_PATH" && npx vitest run path/to/file.test.ts)`
- Verify one case: `(cd "$WORKTREE_PATH" && npx vitest run path/to/file.test.ts -t "case name")`

### Jest

- Check for existing test files: `*.test.ts`, `*.spec.ts`, `__tests__/*.ts`
- Detect: `ts-jest` vs `babel-jest` vs SWC transform in `jest.config.*`;
  globals are injected, so tests normally import nothing from the runner.
- Use `test.each` / `describe.each` case tables; `jest.mock()`, `jest.fn()`,
  `jest.spyOn()`, `jest.useFakeTimers()`.
- Verify one file: `(cd "$WORKTREE_PATH" && npx jest path/to/file.test.ts)`
- Verify one case: `(cd "$WORKTREE_PATH" && npx jest -t "case name")`

### node:test / mocha

- `import { test } from "node:test"` with `node:assert/strict`, or mocha's
  `describe`/`it` with the project's assertion library.
- Verify: `(cd "$WORKTREE_PATH" && node --test path/to/file.test.ts)` or
  `(cd "$WORKTREE_PATH" && npx mocha path/to/file.test.ts)`

### Verify generated tests compile and lint

Before rerunning coverage, confirm the new files pass the repo's own checks.
`PM` and `has_script` come from Step C's detection block — re-run that block
first if this step is entered in a fresh shell:

```bash
if has_script "type-check"; then
  (cd "$WORKTREE_PATH" && "$PM" run type-check) || true
elif [ -f "$WORKTREE_PATH/tsconfig.json" ]; then
  (cd "$WORKTREE_PATH" && npx tsc --noEmit) || true
fi
if has_script "lint"; then
  (cd "$WORKTREE_PATH" && "$PM" run lint) || true
fi
```

Fix any type or lint errors in the generated tests before continuing. Then
re-run coverage using the same command Step C selected.

### Rust

- Check for existing `#[cfg(test)]` modules in the same file or `tests/`
  directory
- Detect: built-in `#[test]` vs `rstest` vs `proptest`
- Generate test functions with `#[test]` attribute, `assert_eq!` / `assert!`
  macros
- Verify: `(cd "$WORKTREE_PATH" && cargo test <test-name>)`

### Python

- Check for existing test files: `test_*.py`, `*_test.py` in the same or
  `tests/` directory
- Detect: pytest vs unittest, fixture patterns, parametrize decorators
- Generate pytest functions with `@pytest.mark.parametrize` for multiple cases
- Verify: `(cd "$WORKTREE_PATH" && pytest <test-file> -v)`

### Go (secondary fallback)

- Check for an existing `${FILE%.*}_test.go` or other `*_test.go` in the
  package; detect stdlib `testing` vs `testify`
- Generate table-driven tests with `t.Run()` / `t.Parallel()`
- Verify: `go -C "$WORKTREE_PATH" test ./path/to/package/... -run "TestFunctionName" -v`

## Test scenarios (all languages)

For each target function include:

- Happy path with typical inputs
- Edge cases (null/undefined/empty/boundary values)
- Error scenarios (invalid input, rejected promises, thrown errors —
  assert with `await expect(fn()).rejects.toThrow(...)` for async code)
- If existing `it.each` / `test.each` case tables exist for the function, add
  new cases to them
- If no test exists, create a new test following project conventions

## Persist count and return

Track the number of tests generated and persist in the state file:

```bash
set_loop_json_field "$STATE_FILE" "coverage_tests_generated" "$TESTS_GENERATED" "$WORKFLOW_STATE_PATH"
```

Generated test files will be staged and committed alongside other changes by
the calling command. Return to Step C and rerun coverage once; Step E stops
incomplete if the threshold is still not met.

If tests cannot be generated or made to pass, follow Step E.4 with:

```
WORKFLOW_RESULT=INCOMPLETE
WORKFLOW_REASON=coverage-test-generation-failed
```

Stop without returning to the calling workflow or emitting its success marker.
