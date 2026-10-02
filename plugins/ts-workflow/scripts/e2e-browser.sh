#!/usr/bin/env bash
# A named Chrome DevTools session owned by one E2E run.
set -euo pipefail

ACTION=${1:?Usage: e2e-browser.sh start|call|stop STATE_FILE [TOOL ARGS...]}
BROWSER_STATE=${2:?A browser state file is required}
shift 2
umask 077

fail() { echo "e2e-browser: $*" >&2; exit 1; }

# CLI tool errors can have exit code zero. Its JSON error format is an array
# of MCP content objects; success is structured content or an array of strings.
invoke() {
  local response
  response=$("$CLI_PATH" "$@" --sessionId="$SESSION_ID" --output-format=json) || return 1
  if ! jq -e 'type == "object" or (type == "array" and all(.[]; type == "string"))' \
      <<< "$response" >/dev/null; then
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s\n' "$response"
}


if [ "$ACTION" = start ]; then
  [ "$#" -eq 0 ] || fail "start takes no tool arguments"
  CLI_PATH=$(command -v chrome-devtools) || fail "chrome-devtools CLI is required"
  case "$CLI_PATH" in /*) ;; *) fail "chrome-devtools must resolve to an absolute executable" ;; esac
  SESSION_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  mkdir -p "$(dirname "$BROWSER_STATE")"
  STATE_JSON=$(jq -n --arg cli "$CLI_PATH" --arg session "$SESSION_ID" \
    '{schema:1,cli:$cli,session:$session,active:true}')
  (set -o noclobber; printf '%s\n' "$STATE_JSON" > "$BROWSER_STATE") || \
    fail "state file already exists; stop or resume its recorded session"
  # Record ownership before launch so a failed start can still be cleaned up.
  if ! "$CLI_PATH" start --sessionId="$SESSION_ID" --isolated --headless=false \
      --no-usage-statistics --no-performance-crux; then
    bash "$0" stop "$BROWSER_STATE" || true
    fail "browser startup failed"
  fi
elif [ "$ACTION" != call ] && [ "$ACTION" != stop ]; then
  fail "unknown action: $ACTION"
fi

[ -f "$BROWSER_STATE" ] && [ ! -L "$BROWSER_STATE" ] || fail "missing browser state file"
jq -e '.schema == 1 and (.cli | type == "string" and startswith("/")) and
  (.session | type == "string" and test("^[a-f0-9]{32}$")) and
  (.active | type == "boolean")' "$BROWSER_STATE" >/dev/null || fail "invalid browser state"
CLI_PATH=$(jq -r '.cli' "$BROWSER_STATE")
SESSION_ID=$(jq -r '.session' "$BROWSER_STATE")
ACTIVE=$(jq -r '.active' "$BROWSER_STATE")
[ -x "$CLI_PATH" ] || fail "recorded Chrome DevTools CLI is unavailable"

if [ "$ACTION" = stop ]; then
  [ "$#" -eq 0 ] || fail "stop takes no tool arguments"
  [ "$ACTIVE" = true ] || exit 0
  "$CLI_PATH" stop --sessionId="$SESSION_ID" || fail "browser shutdown failed"
  BROWSER_STATUS=$("$CLI_PATH" status --sessionId="$SESSION_ID") || fail "cannot verify shutdown"
  case "$BROWSER_STATUS" in
    *'chrome-devtools-mcp daemon is not running.'*) ;;
    *) fail "browser daemon remains running" ;;
  esac
  STATE_TMP=$(mktemp "${BROWSER_STATE}.XXXXXX")
  trap 'rm -f "$STATE_TMP"' EXIT
  jq '.active = false' "$BROWSER_STATE" > "$STATE_TMP"
  mv "$STATE_TMP" "$BROWSER_STATE"
  echo "E2E browser session stopped."
  exit 0
fi

[ "$ACTIVE" = true ] || fail "session was stopped; do not restart it to collect evidence"
BROWSER_STATUS=$("$CLI_PATH" status --sessionId="$SESSION_ID") || fail "cannot verify browser session"
case "$BROWSER_STATUS" in
  *"socket="*"$SESSION_ID"*) ;;
  *) fail "owned browser session is unavailable; refusing automatic reconnection" ;;
esac
if [ "$ACTION" = start ]; then
  # Keep a private marker tab to detect Chrome replacement while its daemon
  # survives. Never accept evidence from a replacement browser.
  MARKER_URL="data:text/html,<title>e2e-$SESSION_ID</title>"
  if ! PAGES=$(invoke new_page "$MARKER_URL"); then
    bash "$0" stop "$BROWSER_STATE" || true
    fail "browser ownership initialization failed"
  fi
  MARKER_ID=$(jq -er --arg url "$MARKER_URL" '.pages[] | select(.url == $url) | .id' <<< "$PAGES") || {
    bash "$0" stop "$BROWSER_STATE" || true
    fail "CLI does not expose named-session page ownership"
  }
  STATE_TMP=$(mktemp "${BROWSER_STATE}.XXXXXX")
  trap 'rm -f "$STATE_TMP"' EXIT
  jq --arg url "$MARKER_URL" --argjson id "$MARKER_ID" \
    '.marker_url = $url | .marker_id = $id' "$BROWSER_STATE" > "$STATE_TMP"
  mv "$STATE_TMP" "$BROWSER_STATE"
fi

verify_browser() {
  local pages
  pages=$(invoke list_pages) || return 1
  jq -e --slurpfile state "$BROWSER_STATE" \
    'any(.pages[]; .id == $state[0].marker_id and .url == $state[0].marker_url)' \
    <<< "$pages" >/dev/null
}

if [ "$ACTION" = call ]; then
  [ "$#" -gt 0 ] || fail "a Chrome DevTools tool is required"
  case "$1" in start|stop|status) fail "use the helper's lifecycle actions" ;; esac
  for ARG in "$@"; do
    case "$ARG" in --sessionId|--sessionId=*|--output-format|--output-format=*) fail "session and output format are owned by the helper" ;; esac
  done
  verify_browser || fail "owned browser is unavailable; do not reconnect to collect evidence"
  TOOL_RESULT=$(invoke "$@") || fail "browser tool failed"
  # The daemon can disappear between status and call, so validate ownership
  # again before returning the result to the E2E workflow.
  verify_browser || fail "browser changed during tool call; evidence discarded"
  printf '%s\n' "$TOOL_RESULT"
else
  echo "E2E browser session started: $SESSION_ID"
fi
