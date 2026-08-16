#!/bin/bash
# Covers three lane-wedging failures found on client-portals #118/#131:
#  1. finished loop states counted as active by setup-loop's singleton guard
#  2. lib/loop-state.sh sourced into zsh (the Claude Code Bash tool) clobbering
#     PATH through the special `path` array, so every path-aware helper failed
#  3. the stop hook must still reap an owned finished state on <done>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_ROOT/lib/loop-state.sh"
SETUP_LOOP="$PLUGIN_ROOT/scripts/setup-loop.sh"
STOP_HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-workflow-loop-state-test.XXXXXX")
REPO="$TEST_ROOT/repo"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Loop State Test"
git -C "$REPO" commit --allow-empty -qm init
STATE_DIR="$REPO/.local/state"
mkdir -p "$STATE_DIR"

write_state() {
  local file="$1"
  local loop_name="$2"
  local workflow_result="$3"
  local session_id="${4:-}"
  jq -n --arg loop_name "$loop_name" --arg result "$workflow_result" --arg session_id "$session_id" '{
    schema_version: 2,
    owner_workflow: "e2e-verify",
    loop_name: $loop_name,
    iteration: 1,
    max_iterations: null,
    completion_promise: (if $result == "" then "VERIFIED" else "E2E_FAIL" end),
    terminal_promises: ["VERIFIED","E2E_FAIL","INCOMPLETE"],
    phase: (if $result == "" then "" else "e2e-failed" end),
    started_at: "2026-08-12T05:36:53Z",
    session_id: $session_id,
    awaiting_driver_input: false,
    driver_input_reason: "",
    phase_messages: {},
    components: {},
    workflow_result: $result,
    workflow_reason: (if $result == "" then "" else "missing-browser-tooling" end)
  }' > "$file"
}

# --- 1. finished states must not wedge the singleton guard -------------------

FINISHED_120="$STATE_DIR/e2e-verify-120.loop.local.json"
LEGACY_103="$STATE_DIR/e2e-verify-103.loop.local.json"
write_state "$FINISHED_120" "e2e-verify-120" "e2e-fail" ""
# pre-schema record shaped like the real e2e-verify-103 leftover
jq -n '{phase: "complete", workflow_result: "verified"}' > "$LEGACY_103"

(
  cd "$REPO"
  source "$LIB"
  assert_eq "0" "$(count_active_loops "$STATE_DIR")" "finished states are not active"
  assert_eq "2" "$(find_terminal_loops "$STATE_DIR" | wc -l | tr -d ' ')" "finished states are listed as terminal"
  assert_eq "2" "$(find_loop_state_files "$STATE_DIR" | wc -l | tr -d ' ')" "raw listing keeps finished states"
)

output=$(cd "$REPO" && CLAUDE_CODE_SESSION_ID=fresh-session "$SETUP_LOOP" e2e-verify-131 VERIFIED 30 "" '{}' "" '["VERIFIED","E2E_FAIL","INCOMPLETE"]')
printf '%s\n' "$output" | grep -q "Loop initialized: e2e-verify-131" || fail "setup-loop did not start with finished states present: $output"
printf '%s\n' "$output" | grep -q "Discarding finished loop state 'e2e-verify-120' (e2e-fail)" || fail "setup-loop did not report discarding e2e-verify-120: $output"
[ ! -f "$FINISHED_120" ] || fail "finished e2e-verify-120 state survived setup"
[ ! -f "$LEGACY_103" ] || fail "legacy finished e2e-verify-103 state survived setup"
NEW_131="$STATE_DIR/e2e-verify-131.loop.local.json"
[ -f "$NEW_131" ] || fail "setup-loop did not create the new state"

# A live (non-finished) loop still blocks a second one.
if (cd "$REPO" && CLAUDE_CODE_SESSION_ID=fresh-session "$SETUP_LOOP" e2e-verify-132 VERIFIED >/dev/null 2>&1); then
  fail "setup-loop allowed a second loop while e2e-verify-131 is live"
fi

# Re-invoking a finished loop of the same name starts fresh instead of
# reporting "already active".
write_state "$NEW_131" "e2e-verify-131" "e2e-fail" "fresh-session"
output=$(cd "$REPO" && CLAUDE_CODE_SESSION_ID=fresh-session "$SETUP_LOOP" e2e-verify-131 VERIFIED 30 "" '{}' "" '["VERIFIED","E2E_FAIL","INCOMPLETE"]')
printf '%s\n' "$output" | grep -q "Loop initialized: e2e-verify-131" || fail "same-name finished state was not restarted: $output"
assert_eq "" "$(jq -r '.workflow_result // ""' "$NEW_131")" "restarted state has no stale result"

# --- 2. helpers must work when sourced into zsh --------------------------------

if command -v zsh >/dev/null 2>&1; then
  zsh_out=$(cd "$REPO" && zsh -c '
    set -e
    source "$1"
    STATE_FILE="$2"
    WORKFLOW_STATE_PATH="[]"
    normalize_workflow_state_path >/dev/null || { echo "normalize-failed"; exit 1; }
    set_loop_phase "$STATE_FILE" "rebasing" "$WORKFLOW_STATE_PATH" || { echo "set-phase-failed"; exit 1; }
    set_loop_field "$STATE_FILE" "pr_number" "131" "$WORKFLOW_STATE_PATH" || { echo "set-field-failed"; exit 1; }
    set_loop_json_field "$STATE_FILE" "pages_tested" 3 "$WORKFLOW_STATE_PATH" || { echo "set-json-failed"; exit 1; }
    child=$(child_workflow_path "$WORKFLOW_STATE_PATH" address-review) || { echo "child-path-failed"; exit 1; }
    set_workflow_result "$STATE_FILE" "$child" incomplete some-reason incomplete || { echo "set-result-failed"; exit 1; }
    read_loop_state "$STATE_FILE" "$WORKFLOW_STATE_PATH" || { echo "read-failed"; exit 1; }
    printf "%s|%s|%s|%s\n" "$PHASE" "$(get_loop_field "$STATE_FILE" pr_number "$WORKFLOW_STATE_PATH")" "$(jq -c .pages_tested "$STATE_FILE")" "$(jq -r ".components[\"address-review\"].result" "$STATE_FILE")"
  ' zsh "$LIB" "$NEW_131") || fail "zsh helper run failed: $zsh_out"
  assert_eq "rebasing|131|3|incomplete" "$zsh_out" "zsh-sourced helpers persist fields"
fi

# --- 3. the stop hook still reaps an owned finished state on <done> ------------

OWNER_TRANSCRIPT="$TEST_ROOT/owner.jsonl"
jq -cn '{role:"assistant", message:{content:[{type:"text", text:"Result recorded.\n<done>E2E_FAIL</done>"}]}}' > "$OWNER_TRANSCRIPT"
write_state "$NEW_131" "e2e-verify-131" "e2e-fail" "owner"
output=$(printf '%s' "$(jq -cn --arg path "$OWNER_TRANSCRIPT" '{transcript_path:$path, session_id:"owner"}')" | (cd "$REPO" && "$STOP_HOOK"))
assert_eq "" "$output" "owner stop with done marker allows exit"
[ ! -f "$NEW_131" ] || fail "stop hook did not remove the owned finished state"

# A foreign session leaves a finished state alone (setup-loop reaps it later).
FOREIGN_TRANSCRIPT="$TEST_ROOT/someone-else.jsonl"
cp "$OWNER_TRANSCRIPT" "$FOREIGN_TRANSCRIPT"
write_state "$NEW_131" "e2e-verify-131" "e2e-fail" "owner"
output=$(printf '%s' "$(jq -cn --arg path "$FOREIGN_TRANSCRIPT" '{transcript_path:$path, session_id:"someone-else"}')" | (cd "$REPO" && "$STOP_HOOK"))
assert_eq "" "$output" "foreign stop output"
[ -f "$NEW_131" ] || fail "foreign stop hook removed a state it does not own"

printf 'PASS: loop state terminal handling\n'
