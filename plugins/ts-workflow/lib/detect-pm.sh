#!/bin/bash
# Shared package-manager detection for ts-workflow skills.
#
# Usage (from any skill bash block):
#   source "${CLAUDE_PLUGIN_ROOT}/lib/detect-pm.sh"
#   pm_detect "$WORKTREE_PATH"        # or pm_detect  (defaults to cwd)
#
# Sets (and exports):
#   PM          — pnpm | yarn | bun | npm
#   PMX         — exec runner: "pnpm exec" | "yarn exec" | bunx | npx
#   IS_MONOREPO — true when turbo.json / nx.json / pnpm-workspace.yaml /
#                 package.json "workspaces" is present at the root
#   PM_ROOT     — the root the detection ran against
#
# Defines:
#   has_script <name> — succeeds when package.json at PM_ROOT has that script.
#
# Shell state does not persist across separate Bash tool calls: any block that
# uses $PM/$PMX/has_script must source this file and call pm_detect in the
# same invocation.

pm_detect() {
  PM_ROOT="${1:-$(pwd -P)}"
  if [ -f "$PM_ROOT/pnpm-lock.yaml" ]; then
    PM=pnpm
    PMX="pnpm exec"
  elif [ -f "$PM_ROOT/yarn.lock" ]; then
    PM=yarn
    PMX="yarn exec"
  elif [ -f "$PM_ROOT/bun.lock" ] || [ -f "$PM_ROOT/bun.lockb" ]; then
    PM=bun
    PMX=bunx
  else
    PM=npm
    PMX=npx
  fi

  IS_MONOREPO=false
  if [ -f "$PM_ROOT/turbo.json" ] || [ -f "$PM_ROOT/nx.json" ] \
    || [ -f "$PM_ROOT/pnpm-workspace.yaml" ] \
    || jq -e '.workspaces // empty' "$PM_ROOT/package.json" >/dev/null 2>&1; then
    IS_MONOREPO=true
  fi

  export PM PMX IS_MONOREPO PM_ROOT
}

# Succeeds when package.json at PM_ROOT declares the named script.
# Run scripts as "$PM run <name>" for every manager — including bun, where
# bare `bun test` would invoke bun's built-in runner instead of the script.
has_script() {
  jq -e --arg s "$1" '.scripts[$s] // empty' "$PM_ROOT/package.json" >/dev/null 2>&1
}
