# Review-Deep Diff Planning and Static Analysis

Loaded by `SKILL.md` Steps 3-4. Execute the adaptive coverage plan and collect informational static-analysis evidence before semantic review.

## Step 3: Generate Diff and Coverage Plan

Based on detected scope:

- **Changes vs base branch** (default when PR detected): `git diff ${BASE_BRANCH}...HEAD`
- **Uncommitted changes** (no PR + uncommitted changes exist): `git diff HEAD` plus untracked files via `git ls-files --others --exclude-standard`
- **Explicit `PR_ARG`:** always use changes vs base branch

```bash
DIFF=$(git diff "${BASE_BRANCH}...HEAD")
REVIEW_BASE="$BASE_BRANCH"
REVIEW_BACKEND=agent
REVIEW_CONCURRENCY=no
```

Read `../../lib/review-planning.md`, run the shared planner, display its coverage
plan, and follow it through the final coordinated pass. Do not interrupt solely
because of raw diff size. Process every review unit and the final pass in the
current context; the agent backend describes this session, not a child agent. Preserve `SCOPE_HINT` as review emphasis.

## Step 4: Static Analysis

Detect the package manager once and reuse it for every command in this skill.
Run all root scripts from the repository root — in a monorepo (`turbo.json`,
`nx.json`, or `pnpm-workspace.yaml` present) the root scripts fan out to the
workspaces, so never `cd` into a package to run them.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# Sets PM/PMX/IS_MONOREPO and defines has_script().
source "<PLUGIN_ROOT>/lib/detect-pm.sh"
pm_detect "$REPO_ROOT"

echo "Package manager: $PM"
```

If a Node/TypeScript project is detected (`package.json` exists):

```bash
CHANGED=$(git diff --name-only "${BASE_BRANCH}...HEAD" | grep -E '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$' || true)
if [ -n "$CHANGED" ] && [ -f package.json ]; then
  echo "=== Type check ==="
  if has_script type-check; then
    $PM run type-check 2>&1 || true
  elif has_script typecheck; then
    $PM run typecheck 2>&1 || true
  elif [ -f tsconfig.json ]; then
    $PMX tsc --noEmit 2>&1 || true
  fi

  echo "=== Lint ==="
  if has_script lint; then
    $PM run lint 2>&1 || true
  fi

  echo "=== Tests ==="
  if has_script test; then
    $PM run test 2>&1 || true
  elif ls vitest.config.* >/dev/null 2>&1; then
    $PMX vitest run 2>&1 || true
  elif ls jest.config.* >/dev/null 2>&1; then
    $PMX jest 2>&1 || true
  fi
fi
```

**Rust fallback** (`Cargo.toml` exists, no `package.json`):

```bash
cargo clippy 2>&1 || true
cargo test 2>&1 || true
```

**Go fallback** (`go.mod` exists, no `package.json`):

```bash
go vet ./... 2>&1 || true
go test -race -count=1 ./... 2>&1 || true
```

Static-analysis failures are informational — they feed into the review, not block it.

When review includes browser screenshots, read
`<PLUGIN_ROOT>/lib/screenshot-evidence.md` before capturing. Initialize the
manifest and record every inspected route/capture, including failures, for the
Step 7 report. This does not add browser testing to reviews without visual work.
