#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
awk '/^```bash$/ { block++; if (block == 1) { capture=1; next } } /^```/ { if (capture) exit } capture' \
  "$ROOT/lib/ship/merge.md" > "$SCRATCH/final-checks.sh"
test -s "$SCRATCH/final-checks.sh"
cat > "$SCRATCH/scenario.sh" <<'SCRIPT'
set -eu
VALIDATION_MODE="$1"
SAVED_HAS_CI="$2"
EXPECTED_REASON="$3"
STATE_FILE=unused
WORKFLOW_STATE_PATH='[]'
WORKTREE_PATH="$4"
PR_NUM=7
WORKFLOW_REASON=''
MOCK_PR_CASE="${5:-matching}"
PR_READ_LOG="$WORKTREE_PATH/pr-read.log"
CHECK_READ_LOG="$WORKTREE_PATH/check-read.log"
rm -f "$PR_READ_LOG" "$CHECK_READ_LOG"
get_loop_field() {
  case "$2" in
    has_ci) printf '%s' "$SAVED_HAS_CI" ;;
    head_sha) printf '%040d' 1 ;;
  esac
}
github_pr() {
  echo read >> "$PR_READ_LOG"
  case "$MOCK_PR_CASE" in
    matching) printf '{"head":{"sha":"%040d"}}' 1 ;;
    shifted) printf '{"head":{"sha":"%040d"}}' 2 ;;
    invalid) printf '{"head":{}}' ;;
    unavailable) return 1 ;;
  esac
}
github_check_snapshot() {
  echo read >> "$CHECK_READ_LOG"
  if [ "$VALIDATION_MODE" = local ]; then
    echo 'local mode queried remote checks' >&2
    return 1
  fi
  printf '{"items":[{"terminal":true,"successful":true}]}'
}
. "$WORKTREE_PATH/final-checks.sh"
test "$WORKFLOW_REASON" = "$EXPECTED_REASON"
test "$(wc -l < "$PR_READ_LOG" | tr -d ' ')" = 1
if [ "$VALIDATION_MODE" = local ] || [ "$MOCK_PR_CASE" != matching ]; then
  test ! -e "$CHECK_READ_LOG"
fi
if [ -n "$WORKFLOW_REASON" ]; then
  echo incomplete
else
  echo no-merge-completion-allowed
fi
SCRIPT
for TEST_SHELL in bash zsh; do
  "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci false required-ci-unverified "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci true '' "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" local false '' "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" local true '' "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" auto false '' "$SCRATCH"
  for SAVED_CI in false true; do
    for PR_CASE in shifted invalid unavailable; do
      case "$PR_CASE" in
        shifted) REASON=final-pr-head-shift ;;
        invalid) REASON=invalid-pr-head-metadata ;;
        unavailable) REASON=final-pr-api-error ;;
      esac
      OUTPUT=$("$TEST_SHELL" "$SCRATCH/scenario.sh" local "$SAVED_CI" "$REASON" "$SCRATCH" "$PR_CASE")
      test "$OUTPUT" = incomplete
    done
  done
done
echo 'required-ci-policy: saved skips cannot waive required CI; verified, local, and auto paths pass'
