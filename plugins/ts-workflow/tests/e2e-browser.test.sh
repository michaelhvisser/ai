#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
export E2E_FAKE_ROOT="$SCRATCH"
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/chrome-devtools" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
ACTION=$1
shift
SESSION=''
for ARG in "$@"; do
  case "$ARG" in --sessionId=*) SESSION=${ARG#*=} ;; esac
done
[ -n "$SESSION" ] || exit 99
printf '%s\n' "$ACTION $SESSION" >> "$E2E_FAKE_ROOT/calls"
case "$ACTION" in
  start)
    touch "$E2E_FAKE_ROOT/$SESSION"
    [ "${E2E_FAKE_FAIL_START:-false}" != true ] || exit 1
    ;;
  status)
    if [ -e "$E2E_FAKE_ROOT/$SESSION" ]; then
      echo "chrome-devtools-mcp daemon is running."
      echo "pid=123 socket=/tmp/chrome-devtools-mcp-$SESSION-501.sock"
    else
      echo "chrome-devtools-mcp daemon is not running."
    fi
    ;;
  stop)
    [ "${E2E_FAKE_FAIL_STOP:-false}" != true ] || exit 1
    rm -f "$E2E_FAKE_ROOT/$SESSION"
    ;;
  new_page)
    if [ "${1#data:text/html,<title>e2e-}" != "$1" ]; then
      jq -cn --arg url "$1" '{pages:[{id:1,url:$url}]}' > "$E2E_FAKE_ROOT/$SESSION.pages"
    fi
    cat "$E2E_FAKE_ROOT/$SESSION.pages"
    ;;
  list_pages) cat "$E2E_FAKE_ROOT/$SESSION.pages" ;;
  *)
    printf '%s\n' "$@" > "$E2E_FAKE_ROOT/tool-args"
    if [ "${E2E_FAKE_TOOL_ERROR:-false}" = true ]; then
      echo '[{"type":"text","text":"Page not found"}]'
    else
      echo '{"message":"ok"}'
    fi
    if [ "${E2E_FAKE_REPLACE_BROWSER:-false}" = true ]; then
      echo '{"pages":[]}' > "$E2E_FAKE_ROOT/$SESSION.pages"
    fi
    ;;

esac
CLI
chmod +x "$SCRATCH/bin/chrome-devtools"
export PATH="$SCRATCH/bin:$PATH"
HELPER="$PLUGIN_ROOT/scripts/e2e-browser.sh"

expect_failure() {
  if "$@" > "$SCRATCH/error" 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
}

# Concurrent runs must never share the default daemon or each other's session.
bash "$HELPER" start "$SCRATCH/one.json"
bash "$HELPER" start "$SCRATCH/two.json"
ONE=$(jq -r '.session' "$SCRATCH/one.json")
TWO=$(jq -r '.session' "$SCRATCH/two.json")
[ "$ONE" != "$TWO" ]
expect_failure bash "$HELPER" start "$SCRATCH/one.json"
bash "$HELPER" call "$SCRATCH/one.json" fill 7 input 'value with spaces'
grep -Fx 'value with spaces' "$SCRATCH/tool-args" >/dev/null
grep -Fx -- "--sessionId=$ONE" "$SCRATCH/tool-args" >/dev/null
bash "$HELPER" stop "$SCRATCH/one.json"
[ -e "$SCRATCH/$TWO" ]
jq -e '.active == false' "$SCRATCH/one.json" >/dev/null
expect_failure bash "$HELPER" call "$SCRATCH/one.json" list_pages
BEFORE=$(wc -l < "$SCRATCH/calls")
bash "$HELPER" stop "$SCRATCH/one.json"
[ "$BEFORE" -eq "$(wc -l < "$SCRATCH/calls")" ]

# Losing the daemon must not let a CLI tool implicitly restart it mid-evidence.
rm "$SCRATCH/$TWO"
expect_failure bash "$HELPER" call "$SCRATCH/two.json" list_pages
grep -F 'refusing automatic reconnection' "$SCRATCH/error" >/dev/null
bash "$HELPER" stop "$SCRATCH/two.json"

# Startup failures still stop the just-recorded session.
export E2E_FAKE_FAIL_START=true
expect_failure bash "$HELPER" start "$SCRATCH/failed.json"
FAILED=$(jq -r '.session' "$SCRATCH/failed.json")
[ ! -e "$SCRATCH/$FAILED" ]
jq -e '.active == false' "$SCRATCH/failed.json" >/dev/null
unset E2E_FAKE_FAIL_START

# A failed stop retains ownership for retry and cannot report successful cleanup.
bash "$HELPER" start "$SCRATCH/retry.json"
export E2E_FAKE_FAIL_STOP=true
expect_failure bash "$HELPER" stop "$SCRATCH/retry.json"

jq -e '.active == true' "$SCRATCH/retry.json" >/dev/null
unset E2E_FAKE_FAIL_STOP
bash "$HELPER" stop "$SCRATCH/retry.json"

# Exit-zero tool errors, a lost Chrome, and replacement during a call fail closed.
bash "$HELPER" start "$SCRATCH/errors.json"
ERRORS=$(jq -r '.session' "$SCRATCH/errors.json")
export E2E_FAKE_TOOL_ERROR=true
expect_failure bash "$HELPER" call "$SCRATCH/errors.json" take_snapshot 1
unset E2E_FAKE_TOOL_ERROR
expect_failure bash "$HELPER" call "$SCRATCH/errors.json" list_pages --sessionId=other
export E2E_FAKE_REPLACE_BROWSER=true
expect_failure bash "$HELPER" call "$SCRATCH/errors.json" take_snapshot 1
grep -F 'evidence discarded' "$SCRATCH/error" >/dev/null
unset E2E_FAKE_REPLACE_BROWSER
expect_failure bash "$HELPER" call "$SCRATCH/errors.json" list_pages
grep -F 'owned browser is unavailable' "$SCRATCH/error" >/dev/null
bash "$HELPER" stop "$SCRATCH/errors.json"

# Invalid state must never fall back to the shared, unnamed session.
printf '%s\n' '{"schema":1,"cli":"/bin/true","session":"","active":true}' > "$SCRATCH/invalid.json"
expect_failure bash "$HELPER" stop "$SCRATCH/invalid.json"

# Execute the skill's own startup and cleanup blocks in both supported shells.
python3 - "$PLUGIN_ROOT/skills/e2e-verify/e2e-test-execution.md" "$SCRATCH" "$PLUGIN_ROOT" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
for heading, name in [('## 5f.', 'start-block'), ('## 5j.', 'stop-block')]:
    section = text[text.index(heading):]
    block = re.search(r'```bash\n(.*?)\n```', section, re.S).group(1)
    pathlib.Path(sys.argv[2], name).write_text(block.replace("<PLUGIN_ROOT>", sys.argv[3]) + '\n')
for doc, heading, name in [('loop-state.md', '## Bootstrap Block', 'bootstrap-block'), ('loop-state.md', '## Terminal Re-entry', 'terminal-block'), ('mode-finish.md', '## Step 7.0', 'gate-block')]:
    source = pathlib.Path(sys.argv[1]).with_name(doc).read_text()
    section = source[source.index(heading):]
    block = re.search(r'```bash\n(.*?)\n```', section, re.S).group(1)
    pathlib.Path(sys.argv[2], name).write_text(block.replace("<PLUGIN_ROOT>", sys.argv[3]) + '\n')
PY
cat > "$SCRATCH/doc-scenario" <<'SCENARIO'
set -eu
CLAUDE_PLUGIN_ROOT=$1
WORKTREE_PATH=$2
STATE_FILE="$WORKTREE_PATH/workflow.json"
WORKFLOW_STATE_PATH='[]'
E2E_RESULT=pass
mkdir -p "$WORKTREE_PATH"
echo '{}' > "$STATE_FILE"
get_loop_field() { jq -r --arg field "$2" '.[$field] // empty' "$1"; }
set_loop_field() {
  jq --arg field "$2" --arg value "$3" '.[$field] = $value' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
source "$E2E_FAKE_ROOT/start-block"
jq -e '.active == true' "$E2E_BROWSER_STATE" >/dev/null
# A resumed invocation must keep the same session.
FIRST_STATE=$E2E_BROWSER_STATE
source "$E2E_FAKE_ROOT/start-block"
[ "$FIRST_STATE" = "$E2E_BROWSER_STATE" ]
export E2E_FAKE_FAIL_STOP=true
source "$E2E_FAKE_ROOT/stop-block"
[ "$E2E_RESULT" = fail ]
[ "$E2E_CLEANUP_FAILED" = true ]
jq -e '.e2e_browser_cleanup == "failed"' "$STATE_FILE" >/dev/null
unset E2E_FAKE_FAIL_STOP
source "$E2E_FAKE_ROOT/stop-block"
[ "$E2E_CLEANUP_FAILED" = false ]
jq -e '.active == false' "$E2E_BROWSER_STATE" >/dev/null
jq -e '.e2e_browser_cleanup == "stopped"' "$STATE_FILE" >/dev/null
[ "$E2E_RESULT" = fail ]
# Failed cleanup stays blocking on a terminal resume or direct finish resume.
source "$E2E_FAKE_ROOT/start-block"
# Explicit new run for these independent exit-path fixtures.
bash "$CLAUDE_PLUGIN_ROOT/scripts/e2e-browser.sh" start "$WORKTREE_PATH/terminal.json"
set_loop_field "$STATE_FILE" e2e_browser_state "$WORKTREE_PATH/terminal.json"
PHASE=e2e-failed
EMBEDDED_WORKFLOW=true
export E2E_FAKE_FAIL_STOP=true
( source "$E2E_FAKE_ROOT/terminal-block" )
jq -e '.e2e_browser_cleanup == "failed"' "$STATE_FILE" >/dev/null
set_workflow_result() { set_loop_field "$1" reason "$4"; }
( source "$E2E_FAKE_ROOT/gate-block"; echo gate-continued ) > "$WORKTREE_PATH/gate-output"
! grep -F 'gate-continued' "$WORKTREE_PATH/gate-output"
jq -e '.reason == "browser-cleanup-failed"' "$STATE_FILE" >/dev/null
unset E2E_FAKE_FAIL_STOP
( source "$E2E_FAKE_ROOT/terminal-block" )
jq -e '.e2e_browser_cleanup == "stopped"' "$STATE_FILE" >/dev/null
jq -e '.active == false' "$WORKTREE_PATH/terminal.json" >/dev/null
SCENARIO
for DOC_SHELL in bash zsh; do
  "$DOC_SHELL" "$SCRATCH/doc-scenario" "$PLUGIN_ROOT" "$SCRATCH/doc-$DOC_SHELL"
done
# Hook cleanup and explicit cancellation must not forget embedded ownership.
source "$PLUGIN_ROOT/lib/loop-state.sh"
bash "$HELPER" start "$SCRATCH/cancel.json"
jq -n --arg path "$SCRATCH/cancel.json" '{workflows:{e2e:{e2e_browser_state:$path}}}' > "$SCRATCH/loop.json"
export E2E_FAKE_FAIL_STOP=true
expect_failure cleanup_loop "$SCRATCH/loop.json"
[ -f "$SCRATCH/loop.json" ]
jq -e '.active == true' "$SCRATCH/cancel.json" >/dev/null
unset E2E_FAKE_FAIL_STOP
cleanup_loop "$SCRATCH/loop.json"
[ ! -f "$SCRATCH/loop.json" ]
jq -e '.active == false' "$SCRATCH/cancel.json" >/dev/null
# Stale terminal bootstrap must use cleanup rather than discard ownership.
bash "$HELPER" start "$SCRATCH/stale.json"
jq -n --arg path "$SCRATCH/stale.json" '{e2e_browser_state:$path,workflow_result:"e2e-fail"}' > "$SCRATCH/stale-loop.json"
(
  EMBEDDED_WORKFLOW=false
  STATE_FILE="$SCRATCH/stale-loop.json"
  loop_state_is_terminal() { return 0; }
  loop_state_owned_by_current_session() { return 1; }
  export E2E_FAKE_FAIL_STOP=true
  source "$SCRATCH/bootstrap-block"
) > "$SCRATCH/stale-output" 2>&1 && { echo 'stale state unexpectedly discarded' >&2; exit 1; }
[ -f "$SCRATCH/stale-loop.json" ]
jq -e '.active == true' "$SCRATCH/stale.json" >/dev/null
cleanup_loop "$SCRATCH/stale-loop.json"
echo 'e2e-browser: OK' \n\n