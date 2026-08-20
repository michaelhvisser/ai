#!/bin/bash
# Language-agnostic check-command detection for workflow skills.
#
# Usage (from any skill bash block):
#   source "${CLAUDE_PLUGIN_ROOT}/lib/detect-checks.sh"
#   detect_checks "$WORKTREE_PATH"     # or detect_checks  (defaults to cwd)
#
# Sets (and exports) — every command is a full shell command line, or the
# empty string when that check does not exist for this project:
#   CHECK_LINT       — e.g. "pnpm run lint" | "golangci-lint run" | "make lint"
#   CHECK_TYPECHECK  — e.g. "pnpm run typecheck" | "go build ./..." | "cargo check"
#   CHECK_TEST       — e.g. "pnpm run test" | "go test ./..." | "make test"
#   CHECK_BUILD      — e.g. "pnpm run build" | "cargo build" | "make build"
#   PROJECT_KIND     — node | go | rust | make | unknown
#   CHECK_ROOT       — the root the detection ran against
#
# Node projects additionally get:
#   PM               — pnpm | yarn | bun | npm
#   PMX              — exec runner: "pnpm exec" | "yarn exec" | bunx | npx
#   IS_MONOREPO      — true when turbo.json / nx.json / pnpm-workspace.yaml /
#                      package.json "workspaces" is present at the root
#
# Any check the primary toolchain does not provide is backfilled from a
# Makefile target of the same name when one exists. Whatever is still empty
# afterwards genuinely does not exist — ask the driver, never guess.
#
# This file is sourced into both bash and zsh. Every variable it defines is
# UPPERCASE or `DC_`-prefixed on purpose: zsh ties several lowercase names
# (`path`, `cdpath`, `manpath`, `status`, `argv`) to special shell state, and
# assigning to them from a sourced helper corrupts the caller's environment.
# Do not introduce a lowercase global here.
#
# Shell state does not persist across separate Bash tool calls: any block that
# uses $CHECK_* must source this file and call detect_checks in the same
# invocation.

# Succeeds when package.json at CHECK_ROOT declares the named script.
# Run scripts as "$PM run <name>" for every manager — including bun, where
# bare `bun test` would invoke bun's built-in runner instead of the script.
dc_has_script() {
  if [ ! -f "$CHECK_ROOT/package.json" ]; then
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg s "$1" '.scripts[$s] // empty' "$CHECK_ROOT/package.json" >/dev/null 2>&1
    return $?
  fi
  # jq-less fallback: good enough to spot a declared script name.
  grep -qE "\"$1\"[[:space:]]*:" "$CHECK_ROOT/package.json" 2>/dev/null
}

# Succeeds when the Makefile at CHECK_ROOT declares the named target.
dc_has_make_target() {
  [ -f "$CHECK_ROOT/Makefile" ] || return 1
  grep -qE "^$1:" "$CHECK_ROOT/Makefile" 2>/dev/null
}

# Echoes "$PM run <name>" for the first script name that exists, else nothing.
dc_first_script() {
  DC_NAME=""
  for DC_NAME in "$@"; do
    if dc_has_script "$DC_NAME"; then
      printf '%s run %s' "$PM" "$DC_NAME"
      return 0
    fi
  done
  return 1
}

detect_checks() {
  CHECK_ROOT="${1:-$(pwd -P)}"
  CHECK_LINT=""
  CHECK_TYPECHECK=""
  CHECK_TEST=""
  CHECK_BUILD=""
  PROJECT_KIND="unknown"

  if [ -f "$CHECK_ROOT/package.json" ]; then
    PROJECT_KIND="node"

    if [ -f "$CHECK_ROOT/pnpm-lock.yaml" ]; then
      PM=pnpm
      PMX="pnpm exec"
    elif [ -f "$CHECK_ROOT/yarn.lock" ]; then
      PM=yarn
      PMX="yarn exec"
    elif [ -f "$CHECK_ROOT/bun.lock" ] || [ -f "$CHECK_ROOT/bun.lockb" ]; then
      PM=bun
      PMX=bunx
    else
      PM=npm
      PMX=npx
    fi

    IS_MONOREPO=false
    if [ -f "$CHECK_ROOT/turbo.json" ] || [ -f "$CHECK_ROOT/nx.json" ] \
      || [ -f "$CHECK_ROOT/pnpm-workspace.yaml" ] \
      || (command -v jq >/dev/null 2>&1 \
        && jq -e '.workspaces // empty' "$CHECK_ROOT/package.json" >/dev/null 2>&1); then
      IS_MONOREPO=true
    fi
    export PM PMX IS_MONOREPO

    CHECK_LINT=$(dc_first_script lint) || CHECK_LINT=""
    CHECK_TYPECHECK=$(dc_first_script typecheck type-check check-types) || CHECK_TYPECHECK=""
    CHECK_TEST=$(dc_first_script test) || CHECK_TEST=""
    CHECK_BUILD=$(dc_first_script build) || CHECK_BUILD=""

  elif [ -f "$CHECK_ROOT/go.mod" ]; then
    PROJECT_KIND="go"
    if command -v golangci-lint >/dev/null 2>&1; then
      CHECK_LINT="golangci-lint run"
    else
      CHECK_LINT="go vet ./..."
    fi
    CHECK_TYPECHECK="go build ./..."
    CHECK_TEST="go test ./..."
    CHECK_BUILD="go build ./..."

  elif [ -f "$CHECK_ROOT/Cargo.toml" ]; then
    PROJECT_KIND="rust"
    CHECK_LINT="cargo clippy"
    CHECK_TYPECHECK="cargo check"
    CHECK_TEST="cargo test"
    CHECK_BUILD="cargo build"

  elif [ -f "$CHECK_ROOT/Makefile" ]; then
    PROJECT_KIND="make"
  fi

  # Backfill anything the primary toolchain did not provide from the Makefile.
  if [ -f "$CHECK_ROOT/Makefile" ]; then
    [ -z "$CHECK_LINT" ] && dc_has_make_target lint && CHECK_LINT="make lint"
    [ -z "$CHECK_TYPECHECK" ] && dc_has_make_target typecheck && CHECK_TYPECHECK="make typecheck"
    [ -z "$CHECK_TEST" ] && dc_has_make_target test && CHECK_TEST="make test"
    [ -z "$CHECK_BUILD" ] && dc_has_make_target build && CHECK_BUILD="make build"
  fi

  export CHECK_ROOT CHECK_LINT CHECK_TYPECHECK CHECK_TEST CHECK_BUILD PROJECT_KIND
  return 0
}
