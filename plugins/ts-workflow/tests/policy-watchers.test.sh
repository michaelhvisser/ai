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
MODE="${3:-fix-and-ship}"
EXPECTED_CALLS="$4"
MOCK_WATCH_STATUS="${5:-0}"
AI_WATCH_LOG="$WORKTREE_PATH/watch.log"
PR_NUM=7
PR_HEAD_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
WORKFLOW_REASON=''
GITHUB_CHECKS_FAILED=1
GITHUB_CHECKS_REGISTRATION_TIMEOUT=2
GITHUB_CHECKS_API_ERROR=3
GITHUB_CHECKS_HEAD_SHIFT=4
STATE_FILE=unused
WORKFLOW_STATE_PATH='[]'
set_loop_phase() { :; }
github_pr() { printf '{"head":{"sha":"%s"}}' "${MOCK_PUBLISHED_SHA:-$PR_HEAD_SHA}"; }
github_watch_pr_checks() {
  printf '%s\n' called >> "$AI_WATCH_LOG"
  printf '{"items":[]}'
  return "$MOCK_WATCH_STATUS"
}
. "$WORKTREE_PATH/watcher.sh"
test -z "$WORKFLOW_REASON"
if [ "$EXPECTED_CALLS" = 0 ]; then
  test ! -e "$AI_WATCH_LOG"
else
  test "$(wc -l < "$AI_WATCH_LOG" | tr -d ' ')" = 1
fi
echo finish-action-reached
SCRIPT
for DOC in skills/e2e-verify/rebase-and-build.md \
  skills/e2e-verify/mode-finish.md \
  skills/address-review/checkout-rebase.md \
  skills/address-review/fix-cycle.md \
  skills/address-review/completion-check.md; do
  awk '/^```bash$/ { capture=1; block=""; next }
    /^```/ { if (capture && block ~ /github_watch_pr_checks/) { printf "%s", block; exit } capture=0 }
    capture { block=block $0 "\n" }' "$ROOT/$DOC" > "$SCRATCH/watcher.sh"
  test -s "$SCRATCH/watcher.sh"
  TEST_MODES=fix-and-ship
  if [ "$DOC" = skills/e2e-verify/mode-finish.md ]; then
    TEST_MODES='verify fix-and-verify investigate ship-prep ship fix-and-ship'
  fi
  for TEST_SHELL in bash zsh; do
    for TEST_MODE in local pr-ci auto; do
      for TEST_E2E_MODE in $TEST_MODES; do
      EXPECTED_CALLS=1
      if [ "$TEST_MODE" = local ] || { [ "$DOC" = skills/e2e-verify/mode-finish.md ] && [ "$TEST_MODE" = auto ] && [ "$TEST_E2E_MODE" != fix-and-ship ]; }; then
        EXPECTED_CALLS=0
      fi
      rm -f "$SCRATCH/watch.log"
      "$TEST_SHELL" "$SCRATCH/scenario.sh" "$TEST_MODE" "$SCRATCH" "$TEST_E2E_MODE" "$EXPECTED_CALLS" > /dev/null
      done
    done
    if [ "$DOC" = skills/e2e-verify/mode-finish.md ]; then
      rm -f "$SCRATCH/watch.log"
      TEST_RESULT=0
      MOCK_PUBLISHED_SHA=0000000000000000000000000000000000000000 "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci "$SCRATCH" verify 0 > "$SCRATCH/shift-output" || TEST_RESULT=$?
      test "$TEST_RESULT" = 1
      test ! -e "$SCRATCH/watch.log"
      rg -q '^WORKFLOW_REASON=pr-head-shift$' "$SCRATCH/shift-output"
      for TEST_E2E_MODE in $TEST_MODES; do
        for MOCK_WATCH_STATUS in 1 2; do
          rm -f "$SCRATCH/watch.log"
          TEST_RESULT=0
          "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci "$SCRATCH" "$TEST_E2E_MODE" 1 "$MOCK_WATCH_STATUS" > "$SCRATCH/failure-output" || TEST_RESULT=$?
          test "$TEST_RESULT" = 1
          test "$(wc -l < "$SCRATCH/watch.log" | tr -d ' ')" = 1
          rg -q '^WORKFLOW_RESULT=INCOMPLETE$' "$SCRATCH/failure-output"
          if rg -q finish-action-reached "$SCRATCH/failure-output"; then exit 1; fi
        done
      done
    fi
  done
done
echo 'policy-watchers: all modes require pr-ci, retain auto applicability, and block CI failure before finish under Bash and Zsh'
