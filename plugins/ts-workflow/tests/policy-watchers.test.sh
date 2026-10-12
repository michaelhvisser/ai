#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=Test -c user.email=test@example.invalid commit -qm initial --allow-empty
cat > "$SCRATCH/scenario.sh" <<'SCRIPT'
set -eu
VALIDATION_MODE="$1"
WORKTREE_PATH="$2"
AI_WATCH_LOG="$WORKTREE_PATH/watch.log"
PR_NUM=7
PR_HEAD_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
WORKFLOW_REASON=''
github_pr() { printf '{"head":{"sha":"%s"}}' "$PR_HEAD_SHA"; }
github_watch_pr_checks() {
  printf '%s\n' called >> "$AI_WATCH_LOG"
  printf '{"items":[]}'
}
. "$WORKTREE_PATH/watcher.sh"
test -z "$WORKFLOW_REASON"
if [ "$VALIDATION_MODE" = local ]; then
  test ! -e "$AI_WATCH_LOG"
else
  test "$(wc -l < "$AI_WATCH_LOG" | tr -d ' ')" = 1
fi
SCRIPT
for DOC in skills/e2e-verify/rebase-and-build.md \
  skills/address-review/checkout-rebase.md \
  skills/address-review/fix-cycle.md \
  skills/address-review/completion-check.md; do
  awk '/^```bash$/ { capture=1; block=""; next }
    /^```/ { if (capture && block ~ /github_watch_pr_checks/) { printf "%s", block; exit } capture=0 }
    capture { block=block $0 "\n" }' "$ROOT/$DOC" > "$SCRATCH/watcher.sh"
  test -s "$SCRATCH/watcher.sh"
  for TEST_SHELL in bash zsh; do
    for TEST_MODE in local pr-ci auto; do
      rm -f "$SCRATCH/watch.log"
      "$TEST_SHELL" "$SCRATCH/scenario.sh" "$TEST_MODE" "$SCRATCH" > /dev/null
    done
  done
done
echo 'policy-watchers: actual E2E and nested review blocks skip only local mode under Bash and Zsh'
