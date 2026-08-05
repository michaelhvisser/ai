# Step C — Run Coverage

Loaded by `coverage-verification.md` Step C. Per-language coverage tool
invocations and the rule for distinguishing tool failure (stop incomplete)
from zero coverage (continue to Step D).

## Detect the package manager and workspace root

Every command below runs through the repo's own package manager. Detect it from
the lockfile at `WORKTREE_PATH`:

```bash
detect_pm() {
  if   [ -f "$1/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$1/yarn.lock" ]; then echo yarn
  elif [ -f "$1/bun.lock" ] || [ -f "$1/bun.lockb" ]; then echo bun
  else echo npm
  fi
}
PM=$(detect_pm "$WORKTREE_PATH")

# Monorepo? Root scripts are the entry point — never cd into a package to run them.
IS_MONOREPO=false
if [ -f "$WORKTREE_PATH/turbo.json" ] || [ -f "$WORKTREE_PATH/nx.json" ] || [ -f "$WORKTREE_PATH/pnpm-workspace.yaml" ]; then
  IS_MONOREPO=true
fi

# True when package.json declares the named script.
has_script() {
  node -e 'const p=require(process.argv[1]+"/package.json");process.exit((p.scripts||{})[process.argv[2]]?0:1)' "$WORKTREE_PATH" "$1" 2>/dev/null
}
```

`package-lock.json` or no lockfile at all → `npm`. On a monorepo, run the root
script (`$PM run <script>` from `$WORKTREE_PATH`) and let turbo/nx fan out; the
per-package coverage files are collected below.

## Node/TypeScript (primary path — `package.json` exists)

Prefer a project-provided coverage script; otherwise drive the detected runner
directly. Both reporters are requested: `json-summary` produces
`coverage/coverage-summary.json` (per-file totals, used for the gate) and `json`
produces `coverage/coverage-final.json` (per-function hit counts, used to name
uncovered functions in the report).

```bash
COVERAGE_JSON=""
COVERAGE_FINAL=""

if has_script "test:coverage"; then
  (cd "$WORKTREE_PATH" && "$PM" run test:coverage 2>&1) || true
elif has_script "coverage"; then
  (cd "$WORKTREE_PATH" && "$PM" run coverage 2>&1) || true
elif [ -f "$WORKTREE_PATH/vitest.config.ts" ] || [ -f "$WORKTREE_PATH/vitest.config.js" ] || [ -f "$WORKTREE_PATH/vitest.config.mts" ] || grep -q '"vitest"' "$WORKTREE_PATH/package.json" 2>/dev/null; then
  (cd "$WORKTREE_PATH" && npx vitest run --coverage --coverage.all --coverage.reporter=json-summary --coverage.reporter=json 2>&1) || true
elif [ -f "$WORKTREE_PATH/jest.config.ts" ] || [ -f "$WORKTREE_PATH/jest.config.js" ] || grep -q '"jest"' "$WORKTREE_PATH/package.json" 2>/dev/null; then
  (cd "$WORKTREE_PATH" && npx jest --coverage --coverageReporters=json-summary --coverageReporters=json 2>&1) || true
elif grep -q '"c8"' "$WORKTREE_PATH/package.json" 2>/dev/null || grep -q '"nyc"' "$WORKTREE_PATH/package.json" 2>/dev/null; then
  (cd "$WORKTREE_PATH" && npx c8 --reporter=json-summary --reporter=json "$PM" test 2>&1) || true
elif has_script "test"; then
  # Unknown runner (node:test, mocha, ...) — wrap it in c8 for V8 coverage.
  (cd "$WORKTREE_PATH" && npx c8 --reporter=json-summary --reporter=json "$PM" test 2>&1) || true
fi

# Locate the summary. Monorepos emit one per package; merge-free approach:
# Step D looks up each changed file across every summary it is given.
COVERAGE_JSON="$WORKTREE_PATH/coverage/coverage-summary.json"
COVERAGE_FINAL="$WORKTREE_PATH/coverage/coverage-final.json"
if [ ! -f "$COVERAGE_JSON" ]; then
  COVERAGE_JSON=$(find "$WORKTREE_PATH" -maxdepth 4 -name node_modules -prune -o -name 'coverage-summary.json' -print 2>/dev/null | head -1)
  COVERAGE_FINAL=$(find "$WORKTREE_PATH" -maxdepth 4 -name node_modules -prune -o -name 'coverage-final.json' -print 2>/dev/null | head -1)
fi
```

`coverage-summary.json` is the same istanbul shape for vitest, jest, c8, and
nyc:

```json
{
  "/abs/path/to/file.ts": {
    "lines":      { "total": 100, "covered": 75, "pct": 75.0 },
    "statements": { "total": 104, "covered": 78, "pct": 75.0 },
    "functions":  { "total": 12,  "covered": 8,  "pct": 66.67 },
    "branches":   { "total": 20,  "covered": 12, "pct": 60.0 }
  },
  "total": { "lines": { "total": 500, "covered": 350, "pct": 70.0 } }
}
```

Keys are usually **absolute** paths, so Step D matches changed files by path
suffix rather than equality.

### Coverage must include untested files

A changed file that no test imports must appear in the report at 0%, not vanish
from it — otherwise an untested file silently passes the gate.

- **vitest**: `--coverage.all` (passed above) reports every included file.
  If the project narrows `coverage.include`, make sure it still covers the
  changed paths.
- **jest**: requires `collectCoverageFrom` in the jest config (e.g.
  `["src/**/*.{ts,tsx}", "!**/*.d.ts"]`). Without it jest only reports files a
  test touched.

Step D treats a changed gated file that is absent from the summary as 0%
covered (see its "missing entry" rule) rather than skipping it.

### Convex projects

Convex functions are covered by `convex-test` running under vitest, so the
vitest branch above applies unchanged. Two rules:

- Never edit `convex/_generated/` — it is machine-written.
- If tests fail on stale generated types, run
  `(cd "$WORKTREE_PATH" && npx convex codegen)` and rerun the coverage command
  once. That is a codegen refresh, not a coverage-tool failure.

## Rust

```bash
if command -v cargo-llvm-cov >/dev/null 2>&1; then
  (cd "$WORKTREE_PATH" && cargo llvm-cov --json > .local/state/coverage.json 2>/dev/null) || true
elif command -v cargo-tarpaulin >/dev/null 2>&1; then
  (cd "$WORKTREE_PATH" && cargo tarpaulin --out Json --output-dir .local/state 2>/dev/null) || true
fi
```

## Python

```bash
if command -v pytest >/dev/null 2>&1 && python3 -c "import pytest_cov" 2>/dev/null; then
  (cd "$WORKTREE_PATH" && pytest --cov --cov-report=json:.local/state/coverage.json 2>/dev/null) || true
elif command -v coverage >/dev/null 2>&1; then
  (cd "$WORKTREE_PATH" && coverage run -m pytest 2>/dev/null && coverage json -o .local/state/coverage.json 2>/dev/null) || true
fi
```

## Go (secondary fallback — `go.mod` and no `package.json`)

```bash
go -C "$WORKTREE_PATH" test -coverprofile=.local/state/coverage.out ./... 2>/dev/null || true
go -C "$WORKTREE_PATH" tool cover -func=.local/state/coverage.out 2>/dev/null
```

Each `-func` line reads `file:line: functionName  coverage%`; Step D's Go
fallback reads per-file percentages from it.

## Tool-unavailable vs zero-coverage

If the coverage tool is genuinely missing or unusable, follow Step E.4 with
`WORKFLOW_REASON=coverage-tool-unavailable` and stop incomplete. On the Node
path that means:

- no `coverage-summary.json` was produced anywhere, **and**
- the run failed for a tooling reason — no test runner is installed, or the
  runner reported a missing coverage provider (vitest's
  `@vitest/coverage-v8` / `@vitest/coverage-istanbul`).

However, if the coverage command ran and produced output (`coverage-summary.json`
exists with data, or the JSON/coverprofile file exists with data), the tool did
NOT fail — proceed to Step D even if coverage is 0%. **Do NOT treat low coverage
as a tool failure.** Failing *tests* are also not a tool failure: the runner
still writes a summary, and Step D analyzes it.
