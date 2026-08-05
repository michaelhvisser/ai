# Step B — Detect Changed Source Files

Loaded by `coverage-verification.md` Step B. This file owns the file-detection
plumbing: the `CHANGED_FILES` collector, per-language source-file filters, the
`is_entrypoint` path classifier, and the gated/info partitioning.

## Collect changed files

Detect changed files including committed, uncommitted, staged, and untracked
files. Uncommitted/untracked changes are common when called from `$ts-workflow:start-issue`
before the commit step:

```bash
mkdir -p "$WORKTREE_PATH/.local/state"
rm -f "$WORKTREE_PATH/coverage/coverage-summary.json" "$WORKTREE_PATH/coverage/coverage-final.json" "$WORKTREE_PATH/.local/state/coverage.json" "$WORKTREE_PATH/.local/state/coverage.out" 2>/dev/null
# Monorepos write per-package coverage dirs; clear those too (never descend into node_modules).
find "$WORKTREE_PATH" -maxdepth 4 -name node_modules -prune -o -name 'coverage-summary.json' -delete 2>/dev/null || true
CHANGED_FILES=$( (git -C "$WORKTREE_PATH" diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null; git -C "$WORKTREE_PATH" diff --name-only HEAD 2>/dev/null; git -C "$WORKTREE_PATH" diff --name-only --cached HEAD 2>/dev/null; git -C "$WORKTREE_PATH" ls-files --others --exclude-standard 2>/dev/null) | sort -u )
```

The `rm -f`/`find -delete` removes stale coverage artifacts from prior runs to
prevent false results if the current coverage command fails.

## Per-language source filters

Filter `CHANGED_FILES` to source files for the detected project type. Exclude
test files, type-only declarations, generated files, and build output.

**Node/TypeScript** (`package.json` exists — the primary path):

```bash
CHANGED_SRC=$(echo "$CHANGED_FILES" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|astro)$' \
  | grep -v -E '\.(test|spec)\.[cm]?[jt]sx?$' \
  | grep -v -E '(^|/)__(tests|mocks)__/' \
  | grep -v -E '\.d\.ts$' \
  | grep -v -E '\.stories\.[jt]sx?$' \
  | grep -v -E '(^|/)(node_modules|dist|build|out|coverage|\.next|\.turbo|\.astro|\.svelte-kit|\.vercel)/' \
  | grep -v -E '(^|/)convex/_generated/' \
  | grep -v -E '(^|/)(generated|__generated__)/' \
  || true)
```

Notes on the exclusions:

- `*.d.ts` carries no executable statements — coverage tools never report it.
- `convex/_generated/` is machine-written by `npx convex codegen`; it is never
  edited by hand and never gated. The same applies to any `generated/` or
  `__generated__/` directory (GraphQL codegen, Prisma clients, route types).
- `.next/`, `.turbo/`, `.astro/`, `.svelte-kit/`, `dist/`, `build/`, `out/` are
  build output, not source.

**Rust** (`Cargo.toml` exists):

```bash
CHANGED_SRC=$(echo "$CHANGED_FILES" | grep '\.rs$' \
  | grep -v -E '(^tests/|/tests/)' \
  || true)
```

**Python** (`pyproject.toml` or `setup.py` exists):

```bash
CHANGED_SRC=$(echo "$CHANGED_FILES" | grep '\.py$' \
  | grep -v -E '(^tests?/|/tests?/|test_[^/]*\.py$|_test\.py$|conftest\.py$)' \
  || true)
```

**Go** (fallback — `go.mod` exists and no `package.json`):

```bash
CHANGED_SRC=$(echo "$CHANGED_FILES" | grep '\.go$' \
  | grep -v -E '(_test|_mock|_gen)\.go$' \
  | grep -v -E '\.pb\.go$' \
  | grep -v '^vendor/' \
  || true)
```

If `CHANGED_SRC` is empty → return empty to Step A's "no source files" skip
condition.

## Partition into gated vs info files

Partition `CHANGED_SRC` into **gated** files (counted toward the aggregate and
the threshold) and **info** files (framework entrypoint / wiring modules —
shown in the report but excluded from the gate):

```bash
# Path-based classifier: returns 0 for entrypoint/wiring modules that are
# excluded from the gate. In JS/TS frameworks the *filename* is the framework
# contract (Next.js routes by file name, config files are loaded by convention),
# so path matching — not file content — is the correct signal. This also means
# deleted files classify correctly with no `git show` round-trip.
is_entrypoint() {
  case "$1" in
    # Build / framework / tooling config: next.config.*, vite.config.*,
    # vitest.config.*, tailwind.config.*, astro.config.*, eslint.config.*,
    # convex/convex.config.ts, convex/auth.config.ts, ...
    *.config.ts|*.config.tsx|*.config.js|*.config.jsx|*.config.mjs|*.config.cjs) return 0 ;;
    # Runtime entry shims registered by the framework, not called by app code.
    middleware.ts|middleware.js|*/middleware.ts|*/middleware.js) return 0 ;;
    instrumentation.ts|instrumentation.js|*/instrumentation.ts|*/instrumentation.js) return 0 ;;
    instrumentation-client.ts|*/instrumentation-client.ts) return 0 ;;
    main.ts|main.tsx|*/main.ts|*/main.tsx) return 0 ;;
    # Next.js App Router shells: provider wiring and trivial fallback UI.
    layout.tsx|*/layout.tsx|*/layout.jsx|*/template.tsx|*/template.jsx) return 0 ;;
    */loading.tsx|*/loading.jsx|*/error.tsx|*/error.jsx|*/global-error.tsx|*/not-found.tsx|*/not-found.jsx) return 0 ;;
    # Declarative Convex wiring — table/index and cron definitions, no logic.
    convex/schema.ts|*/convex/schema.ts|convex/crons.ts|*/convex/crons.ts) return 0 ;;
  esac
  return 1
}

CHANGED_SRC_GATED=""
CHANGED_SRC_INFO=""
for f in $CHANGED_SRC; do
  if is_entrypoint "$f"; then
    CHANGED_SRC_INFO="${CHANGED_SRC_INFO}${f}
"
  else
    CHANGED_SRC_GATED="${CHANGED_SRC_GATED}${f}
"
  fi
done
CHANGED_SRC_GATED=$(printf '%s' "$CHANGED_SRC_GATED" | sed '/^$/d')
CHANGED_SRC_INFO=$(printf '%s'  "$CHANGED_SRC_INFO"  | sed '/^$/d')
```

On the Rust, Python, and Go fallback paths the carve-out does not apply: set
`CHANGED_SRC_GATED="$CHANGED_SRC"` and leave `CHANGED_SRC_INFO` empty.

## Why exclude entrypoint/wiring modules?

These modules are the JS/TS analogue of a thin `func main()` shim: config
objects the bundler reads, a `middleware.ts` the framework mounts, a `layout.tsx`
that only nests providers, a `schema.ts` that only declares tables. There is
little to assert against, and what's left is awkward to test without refactoring
purely to satisfy the metric.

This is an **entrypoint-only** carve-out — touching a route handler, a Convex
query/mutation, a hook, or a component with real logic still trips the gate (the
"if you touch it, you own it" rule is unchanged). `page.tsx`, `route.ts`, and
`convex/http.ts` are deliberately **not** carved out: they routinely hold real
behavior. See [#143](https://github.com/gopherguides/gopher-ai/issues/143) for
the full rationale and external references behind the carve-out.
