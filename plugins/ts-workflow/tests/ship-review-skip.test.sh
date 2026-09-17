#!/usr/bin/env bash
# Ship and review-deep never delegate a review to a sub-agent automatically.
# An unavailable external CLI records a skipped review that still runs
# verification, coverage, and E2E; a new PR head invalidates that skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOOP_LIB="$PLUGIN_ROOT/lib/loop-state.sh"
PREREQUISITES="$PLUGIN_ROOT/lib/ship/prerequisites.md"
LOCAL_REVIEW="$PLUGIN_ROOT/lib/ship/local-review.md"
CI_WATCH="$PLUGIN_ROOT/lib/ship/ci-watch.md"
STATE_FIELDS="$PLUGIN_ROOT/lib/ship/state-fields.md"
SHIP_SKILL="$PLUGIN_ROOT/skills/ship/SKILL.md"
SHIP_REENTRY="$PLUGIN_ROOT/lib/ship/reentry.md"
STATIC_ANALYSIS="$PLUGIN_ROOT/skills/review-deep/static-analysis.md"
REVIEW_DEEP_SKILL="$PLUGIN_ROOT/skills/review-deep/SKILL.md"
REVIEW_DEEP_FIX="$PLUGIN_ROOT/skills/review-deep/fix-and-verify.md"
STOP_HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-workflow-review-skip.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

ERRORS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; ERRORS=$((ERRORS + 1)); }
require_text() { grep -qE -e "$2" "$1" || fail "$3"; }
reject_text() { ! grep -qE -e "$2" "$1" || fail "$3"; }

# Prompt-level guards: routing and fix dispatch stay in the current session.
reject_text "$PREREQUISITES" 'native Fable delegation|agent-based review|USE_AGENT_REVIEW=true' \
  "ship must not select a sub-agent as an automatic fallback"
reject_text "$LOCAL_REVIEW" 'USE_AGENT_REVIEW=true|driver-selected as an unpinned fallback|prefer.*--llm fable|Delegated agent review' \
  "ship must not route automatic reviews to delegated backends"
require_text "$PREREQUISITES" 'review-backend-unavailable' \
  "ship must explain unavailable review backends"
require_text "$PREREQUISITES" 'set_loop_field.*"review_result" "skipped"' \
  "ship must persist unavailable-backend skips"
require_text "$LOCAL_REVIEW" 'skip Steps 5a through 6' \
  "skipped reviews must bypass planning, execution, and finding parsing"
require_text "$LOCAL_REVIEW" 'REVIEW_RESULT=skipped.*Phase 2' \
  "skipped reviews must not loop back into review"
require_text "$LOCAL_REVIEW" 'REVIEW_RESULT != skipped' \
  "skipped reviews must still run final coverage verification"
require_text "$LOCAL_REVIEW" 'explicitly selected.*--llm fable' \
  "Fable delegation must require explicit opt-in"
reject_text "$STATE_FIELDS" 'use_agent_review' \
  "state fields must not document the removed agent-review flag"
require_text "$STATE_FIELDS" 'review-backend-unavailable' \
  "state fields must document the unavailable-backend skip reason"
require_text "$SHIP_REENTRY" 'Ignore legacy `use_agent_review`' \
  "ship re-entry must ignore legacy agent-review state"
require_text "$SHIP_SKILL" 'backend-unavailable' \
  "ship completion contract must accept the unavailable-backend skip"
reject_text "$REVIEW_DEEP_FIX" 'Parallel Fix Dispatch|Dispatch Subagents|run_in_background|delegate a fresh-context' \
  "review-deep must fix findings in the current session"
require_text "$REVIEW_DEEP_FIX" 'current context' \
  "review-deep must document same-context processing"
reject_text "$REVIEW_DEEP_SKILL" 'Delegate fresh-context reviewers|REVIEW_CONCURRENCY=auto' \
  "review-deep router must not restore parallel dispatch"
require_text "$STATIC_ANALYSIS" 'REVIEW_CONCURRENCY=no' \
  "review-deep planner must keep review units in the current session"

# Execute the documented skip transition against standalone and embedded state.
awk '
  /^  ```bash$/ { block = ""; capture = 1; next }
  capture && /^  ```$/ {
    if (block ~ /REVIEW_RESULT=skipped/) printf "%s", block
    capture = 0
    next
  }
  capture { sub(/^  /, ""); block = block $0 "\n" }
' "$PREREQUISITES" > "$TEST_ROOT/skip.sh"
[ -s "$TEST_ROOT/skip.sh" ] || fail "unavailable-backend skip transition must be executable"
for skip_scope in '[]' '["components","ship"]'; do
  printf '%s\n' '{"schema_version":2,"owner_workflow":"ship","loop_name":"ship","completion_promise":"SHIPPED","terminal_promises":["SHIPPED","INCOMPLETE"],"phase":"parent-phase","review_clean":"true","components":{"ship":{"review_clean":"true"}}}' > "$TEST_ROOT/state.json"
  SKIP_OUTPUT=$(
    source "$LOOP_LIB"
    STATE_FILE="$TEST_ROOT/state.json"
    WORKFLOW_STATE_PATH="$skip_scope"
    source "$TEST_ROOT/skip.sh"
    test "$REVIEW_RESULT" = skipped && test "$REVIEW_CLEAN" = false
  ) || fail "skip transition must set REVIEW_RESULT and REVIEW_CLEAN ($skip_scope)"
  if [[ "$SKIP_OUTPUT" != *"Local LLM review skipped:"* ]] ||
     ! jq -e --argjson scope "$skip_scope" '
       getpath($scope) |
       .review_result == "skipped" and
       .review_skip_reason == "review-backend-unavailable" and
       .review_clean == "false"
     ' "$TEST_ROOT/state.json" >/dev/null; then
    fail "unavailable-backend skip must report and persist an honest result ($skip_scope)"
  fi
  if [ "$skip_scope" != '[]' ] &&
     ! jq -e '.phase == "parent-phase" and .review_clean == "true" and .review_result == null' "$TEST_ROOT/state.json" >/dev/null; then
    fail "embedded review skip must preserve parent workflow state"
  fi
done

# Resume an interrupted skip at verification, preserving the owning scope.
awk '
  /^## 2\. Re-entry Check/ { section=1 }
  section && /^```bash$/ { capture=1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$SHIP_REENTRY" > "$TEST_ROOT/reentry.sh"
[ -s "$TEST_ROOT/reentry.sh" ] || fail "ship re-entry block must be executable"
for resume_scope in '[]' '["components","ship"]'; do
  for resume_result in skipped pending; do
    jq -n --argjson scope "$resume_scope" --arg result "$resume_result" '
      {phase:"parent-phase",review_result:"parent-result",components:{}} |
      setpath($scope; {phase:"reviewing",review_result:$result,
        review_skip_reason:"review-backend-unavailable",review_clean:"false",components:{}}) |
      . + {schema_version:2,owner_workflow:"ship",loop_name:"ship",
        completion_promise:"SHIPPED",terminal_promises:["SHIPPED","INCOMPLETE"]}
    ' > "$TEST_ROOT/state.json"
    (
      source "$LOOP_LIB"
      STATE_FILE="$TEST_ROOT/state.json"
      WORKFLOW_STATE_PATH="$resume_scope"
      source "$TEST_ROOT/reentry.sh"
      expected_phase=reviewing
      if [ "$resume_result" = skipped ]; then expected_phase=verifying; fi
      test "$PHASE" = "$expected_phase" || exit 1
      test "$(get_loop_field "$STATE_FILE" phase "$WORKFLOW_STATE_PATH")" = "$expected_phase" || exit 1
      test "$(get_loop_field "$STATE_FILE" review_result "$WORKFLOW_STATE_PATH")" = "$resume_result"
    ) || fail "interrupted $resume_result review must resume at the safe phase ($resume_scope)"
    if [ "$resume_scope" != '[]' ] &&
       ! jq -e '.phase == "parent-phase" and .review_result == "parent-result"' "$TEST_ROOT/state.json" >/dev/null; then
      fail "embedded review recovery must preserve parent state"
    fi
  done
done

# A new head must invalidate an unavailable-backend skip in either state scope.
awk '
  /^## 10d\./ { section=1 }
  section && /^```bash$/ { block=1; next }
  block && /^```$/ { exit }
  block { print }
' "$CI_WATCH" > "$TEST_ROOT/ci-shift.sh"
[ -s "$TEST_ROOT/ci-shift.sh" ] || fail "ci-watch head-shift block must be executable"
for shift_scope in '[]' '["components","ship"]'; do
  jq -n '{schema_version:2,owner_workflow:"ship",loop_name:"ship",completion_promise:"SHIPPED",terminal_promises:["SHIPPED","INCOMPLETE"],phase:"parent-phase",review_result:"parent-result",components:{}}' > "$TEST_ROOT/shift.json"
  (
    source "$LOOP_LIB"
    STATE_FILE="$TEST_ROOT/shift.json"
    WORKFLOW_STATE_PATH="$shift_scope"
    set_loop_field "$STATE_FILE" "review_result" "skipped" "$WORKFLOW_STATE_PATH"
    set_loop_field "$STATE_FILE" "review_skip_reason" "review-backend-unavailable" "$WORKFLOW_STATE_PATH"
    set_loop_field "$STATE_FILE" "review_clean" "false" "$WORKFLOW_STATE_PATH"
    set_loop_json_field "$STATE_FILE" "pass" 3 "$WORKFLOW_STATE_PATH"
    github_pr() { printf '%s\n' '{"head":{"sha":"new-sha","ref":"fixture"}}'; }
    git() {
      case "$3" in
        config) echo origin ;;
        branch) echo fixture ;;
        status|fetch|checkout|reset) return 0 ;;
        *) return 1 ;;
      esac
    }
    HEAD_SHA="old-sha"
    PR_NUM=1
    WORKTREE_PATH="$TEST_ROOT"
    source "$TEST_ROOT/ci-shift.sh"
  ) >/dev/null || fail "head-shift block must run against fixture state ($shift_scope)"
  if ! jq -e --argjson scope "$shift_scope" '
    getpath($scope) | .head_sha == "new-sha" and .phase == "review-required" and
    .pass == 0 and .review_clean == "" and .review_result == "" and .review_skip_reason == ""
  ' "$TEST_ROOT/shift.json" >/dev/null; then
    fail "head shift must invalidate stale review skips ($shift_scope)"
  fi
  if [ "$shift_scope" != '[]' ] && ! jq -e '
    .phase == "parent-phase" and .review_result == "parent-result"
  ' "$TEST_ROOT/shift.json" >/dev/null; then
    fail "embedded head shift must preserve parent review state"
  fi
done

# The stop hook resumes a skipped review at verification instead of voiding it
# into pushing, and still voids a review that was actually in flight.
HOOK_REPO="$TEST_ROOT/repo"
git init -q "$HOOK_REPO"
git -C "$HOOK_REPO" config user.email test@example.com
git -C "$HOOK_REPO" config user.name "Review Skip Test"
git -C "$HOOK_REPO" commit --allow-empty -qm init
# A ship loop in "reviewing" needs a repository target; staged work is one.
printf '%s\n' staged > "$HOOK_REPO/staged.txt"
git -C "$HOOK_REPO" add staged.txt
HOOK_STATE="$HOOK_REPO/.local/state/ship.loop.local.json"
HOOK_TRANSCRIPT="$TEST_ROOT/owner.jsonl"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' > "$HOOK_TRANSCRIPT"
write_hook_state() {
  rm -f "$HOOK_STATE"
  (
    cd "$HOOK_REPO"
    CLAUDE_SESSION_ID=owner bash "$PLUGIN_ROOT/scripts/setup-loop.sh" ship SHIPPED 50 "" \
      "$(jq -c . "$PLUGIN_ROOT/lib/ship/resume-messages.json")" "" '["SHIPPED","INCOMPLETE"]' >/dev/null
  )
  jq --arg review_result "$1" '
    .phase = "reviewing" |
    .review_result = $review_result |
    .review_skip_reason = (if $review_result == "skipped" then "review-backend-unavailable" else "" end) |
    .components.ship = {phase: "reviewing", review_result: $review_result, components: {}}
  ' "$HOOK_STATE" > "$HOOK_STATE.tmp" && mv "$HOOK_STATE.tmp" "$HOOK_STATE"
}
run_hook() {
  printf '%s' "$(jq -cn --arg path "$HOOK_TRANSCRIPT" '{transcript_path:$path,session_id:"owner"}')" |
    (cd "$HOOK_REPO" && bash "$STOP_HOOK")
}
write_hook_state skipped
HOOK_OUTPUT=$(run_hook)
if [ "$(printf '%s' "$HOOK_OUTPUT" | jq -r '.decision')" != block ] ||
   [[ "$(printf '%s' "$HOOK_OUTPUT" | jq -r '.systemMessage')" != *"Run verification, coverage, and E2E"* ]] ||
   ! jq -e '.phase == "verifying" and .review_result == "skipped" and
            .review_skip_reason == "review-backend-unavailable" and
            .components.ship.phase == "verifying" and .components.ship.review_result == "skipped"' "$HOOK_STATE" >/dev/null; then
  fail "stop hook must resume a skipped review at verification"
fi
write_hook_state ""
HOOK_OUTPUT=$(run_hook)
if [ "$(printf '%s' "$HOOK_OUTPUT" | jq -r '.decision')" != block ] ||
   ! jq -e '.phase == "pushing" and .review_result == "void" and .review_skip_reason == "session-boundary"' "$HOOK_STATE" >/dev/null; then
  fail "stop hook must still void an in-flight review into pushing"
fi

if [ "$ERRORS" -ne 0 ]; then
  printf 'FAILED: %s check(s)\n' "$ERRORS" >&2
  exit 1
fi
printf 'PASS: ship review skip contract\n'
