#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STOP_HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
SETUP_LOOP="$PLUGIN_ROOT/scripts/setup-loop.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-workflow-stop-hook-test.XXXXXX")
MAIN_REPO="$TEST_ROOT/repo"
LINKED_WORKTREE="$TEST_ROOT/linked"

cleanup() {
  git -C "$MAIN_REPO" worktree remove --force "$LINKED_WORKTREE" >/dev/null 2>&1 || true
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

git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email test@example.com
git -C "$MAIN_REPO" config user.name "Stop Hook Test"
git -C "$MAIN_REPO" commit --allow-empty -qm init
git -C "$MAIN_REPO" worktree add -qb linked "$LINKED_WORKTREE"

STATE_DIR="$MAIN_REPO/.local/state"
STATE_FILE="$STATE_DIR/demo-loop.loop.local.json"
OWNER_TRANSCRIPT="$TEST_ROOT/owner-session.jsonl"
FOREIGN_TRANSCRIPT="$TEST_ROOT/foreign-session.jsonl"
mkdir -p "$STATE_DIR"

# Setup binds immediately from the real Claude/Codex session variables instead
# of writing the empty owner that caused cross-session stop-hook infection.
(
  unset CLAUDE_SESSION_ID CODEX_COMPANION_SESSION_ID
  export CLAUDE_CODE_SESSION_ID=setup-owner
  cd "$LINKED_WORKTREE"
  "$SETUP_LOOP" demo-loop COMPLETE >/dev/null
)
assert_eq "setup-owner" "$(jq -r '.session_id' "$STATE_FILE")" "Claude setup session binding"
rm "$STATE_FILE"
(
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  export CODEX_COMPANION_SESSION_ID=companion-owner
  cd "$LINKED_WORKTREE"
  "$SETUP_LOOP" demo-loop COMPLETE >/dev/null
)
assert_eq "companion-owner" "$(jq -r '.session_id' "$STATE_FILE")" "Codex setup session binding"
rm "$STATE_FILE"

write_state() {
  local session_id="${1:-}"
  jq -n --arg session_id "$session_id" '{
    schema_version: 2,
    owner_workflow: "demo-loop",
    loop_name: "demo-loop",
    iteration: 1,
    max_iterations: null,
    completion_promise: "COMPLETE",
    terminal_promises: ["COMPLETE"],
    phase: "",
    started_at: "2026-08-01T00:00:00Z",
    session_id: $session_id,
    awaiting_driver_input: false,
    driver_input_reason: "",
    phase_messages: {},
    components: {},
    original_prompt: "Continue demo loop"
  }' > "$STATE_FILE"
}

run_hook() {
  local input="$1"
  printf '%s' "$input" | (cd "$LINKED_WORKTREE" && "$STOP_HOOK")
}

printf '%s\n' '{"output":"Loop initialized: demo-loop\nOutput <done>COMPLETE</done> when ready."}' > "$OWNER_TRANSCRIPT"
printf '%s\n' 'Loop initialized: demo-loop-extra' > "$FOREIGN_TRANSCRIPT"

# An unbound loop must ignore a foreign linked-worktree session without mutation,
# including a transcript marker whose loop name only shares this loop's prefix.
write_state ""
output=$(run_hook "$(jq -cn --arg path "$FOREIGN_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "" "$output" "foreign unbound stop output"
assert_eq "" "$(jq -r '.session_id' "$STATE_FILE")" "foreign stop session binding"
assert_eq "1" "$(jq -r '.iteration' "$STATE_FILE")" "foreign stop iteration"

# The owner proves ownership once through the init marker and binds permanently.
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "block" "$(printf '%s' "$output" | jq -r '.decision')" "owner stop decision"
assert_eq "owner-session" "$(jq -r '.session_id' "$STATE_FILE")" "owner session binding"
assert_eq "2" "$(jq -r '.iteration' "$STATE_FILE")" "owner stop iteration"

# Once bound, transcript compaction may remove the marker without losing ownership.
printf '%s\n' 'compacted owner transcript without initialization output' > "$OWNER_TRANSCRIPT"
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "block" "$(printf '%s' "$output" | jq -r '.decision')" "compacted owner stop decision"
assert_eq "3" "$(jq -r '.iteration' "$STATE_FILE")" "compacted owner iteration"

# A second foreign state must not make the owner's loop look ambiguous.
FOREIGN_STATE="$STATE_DIR/foreign-loop.loop.local.json"
jq '
  .owner_workflow = "foreign-loop" |
  .loop_name = "foreign-loop" |
  .session_id = "foreign-session" |
  .iteration = 1
' "$STATE_FILE" > "$FOREIGN_STATE"
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "block" "$(printf '%s' "$output" | jq -r '.decision')" "owner with foreign state decision"
assert_eq "4" "$(jq -r '.iteration' "$STATE_FILE")" "owner with foreign state iteration"
assert_eq "1" "$(jq -r '.iteration' "$FOREIGN_STATE")" "foreign state preservation"
rm "$FOREIGN_STATE"

# Two loops owned by this session remain a real ambiguity and must block without
# advancing either loop.
SECOND_OWNER_STATE="$STATE_DIR/second-owner-loop.loop.local.json"
jq '
  .owner_workflow = "second-owner-loop" |
  .loop_name = "second-owner-loop" |
  .iteration = 1
' "$STATE_FILE" > "$SECOND_OWNER_STATE"
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "block" "$(printf '%s' "$output" | jq -r '.decision')" "multiple owner loops decision"
assert_eq "4" "$(jq -r '.iteration' "$STATE_FILE")" "multiple owner loops primary iteration"
assert_eq "1" "$(jq -r '.iteration' "$SECOND_OWNER_STATE")" "multiple owner loops secondary iteration"
rm "$SECOND_OWNER_STATE"

# A foreign session cannot increment or delete a bound owner's state.
output=$(run_hook "$(jq -cn --arg path "$FOREIGN_TRANSCRIPT" '{transcript_path:$path}')")
assert_eq "" "$output" "foreign bound stop output"
assert_eq "4" "$(jq -r '.iteration' "$STATE_FILE")" "foreign bound stop iteration"
[ -f "$STATE_FILE" ] || fail "foreign bound stop deleted owner state"

# A missing transcript/session identity must fail open.
output=$(run_hook '{}')
assert_eq "" "$output" "unidentifiable stop output"
assert_eq "4" "$(jq -r '.iteration' "$STATE_FILE")" "unidentifiable stop iteration"

# Accept a state owner populated from the hook's explicit session_id even when
# the transcript basename differs, then reject a different explicit id even if
# its transcript happens to contain the initialization marker.
write_state "explicit-owner"
printf '%s\n' 'Loop initialized: demo-loop' > "$OWNER_TRANSCRIPT"
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" --arg id explicit-owner '{transcript_path:$path,session_id:$id}')")
assert_eq "block" "$(printf '%s' "$output" | jq -r '.decision')" "explicit owner stop decision"
output=$(run_hook "$(jq -cn --arg path "$OWNER_TRANSCRIPT" --arg id marker-copying-foreign '{transcript_path:$path,session_id:$id}')")
assert_eq "" "$output" "explicit foreign stop output"
assert_eq "2" "$(jq -r '.iteration' "$STATE_FILE")" "explicit foreign stop iteration"
assert_eq "explicit-owner" "$(jq -r '.session_id' "$STATE_FILE")" "explicit foreign owner preservation"

printf 'PASS: stop hook session ownership\n'
