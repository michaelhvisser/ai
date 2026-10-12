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
get_loop_field() {
  case "$2" in
    has_ci) printf '%s' "$SAVED_HAS_CI" ;;
    head_sha) printf '%040d' 1 ;;
  esac
}
github_pr() { printf '{"head":{"sha":"%040d"}}' 1; }
github_check_snapshot() { printf '{"items":[{"terminal":true,"successful":true}]}'; }
. "$WORKTREE_PATH/final-checks.sh"
test "$WORKFLOW_REASON" = "$EXPECTED_REASON"
SCRIPT
for TEST_SHELL in bash zsh; do
  "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci false required-ci-unverified "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" pr-ci true '' "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" local false '' "$SCRATCH"
  "$TEST_SHELL" "$SCRATCH/scenario.sh" auto false '' "$SCRATCH"
done
echo 'required-ci-policy: saved skips cannot waive required CI; verified, local, and auto paths pass'
