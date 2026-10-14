#!/bin/bash
# The PreToolUse worktree guard blocks Bash commands that reference the
# original checkout, but not sibling directories whose names merely start
# with the same path (for example `repo-2` next to `repo`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$SCRIPT_DIR/.." && pwd)/hooks/pre-tool-use.sh}"
TMP_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
FIXTURE=$(mktemp -d "$TMP_BASE/worktree-guard.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

PASS=0
FAIL=0

ORIGINAL="$FIXTURE/repo"
WORKTREE="$FIXTURE/repo-issue-19"
mkdir -p "$ORIGINAL" "$FIXTURE/home"
git -C "$ORIGINAL" init -q
git -C "$ORIGINAL" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
mkdir -p "$ORIGINAL/.git/ts-workflow"
printf '{"worktree_path":"%s","original_path":"%s"}\n' "$WORKTREE" "$ORIGINAL" \
  > "$ORIGINAL/.git/ts-workflow/worktree-state.json"

run_hook() {
  local command="$1"
  jq -n --arg cmd "$command" '{tool_name: "Bash", tool_input: {command: $cmd}}' |
    (cd "$ORIGINAL" && HOME="$FIXTURE/home" bash "$HOOK" 2>/dev/null)
}

expect() {
  local label="$1" want="$2" command="$3" output verdict
  output=$(run_hook "$command")
  if echo "$output" | grep -q '"decision":"block"'; then verdict=block; else verdict=allow; fi
  if [ "$verdict" = "$want" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected $want, got $verdict: $output)"
    FAIL=$((FAIL + 1))
  fi
}

echo "worktree guard: Bash path references"
expect "a file in the original checkout is blocked" block "cat $ORIGINAL/README.md"
expect "the original checkout itself is blocked" block "ls $ORIGINAL"
expect "cd into the original checkout is blocked" block "cd $ORIGINAL && ls"
expect "a quoted original path is blocked" block "cat \"$ORIGINAL/a b.txt\""
expect "the original path before a pipe is blocked" block "ls $ORIGINAL| wc -l"
expect "a sibling worktree with the same prefix is allowed" allow "cd $FIXTURE/repo-43 && git status"
expect "a sibling with a dotted suffix is allowed" allow "ls $FIXTURE/repo.bak"
expect "the active worktree is allowed" allow "cat $WORKTREE/README.md"
expect "the original path alongside the worktree is allowed" allow "diff $ORIGINAL/a $WORKTREE/a"
expect "a sibling prefix plus the real original is still blocked" block "ls $FIXTURE/repo-43 $ORIGINAL/x"
expect "commands without paths are allowed" allow "git status"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
