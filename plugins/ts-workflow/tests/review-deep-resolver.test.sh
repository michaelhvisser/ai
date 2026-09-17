#!/usr/bin/env bash
# Run the published review-deep discovery recipes, including their failure
# paths, in bash and zsh.
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
for DOC in scope-discovery context-gathering; do
  awk -v prefix="$TEST_DIR/$DOC" '
    /^```bash$/ { inside=1; n++; next }
    /^```/ { inside=0; next }
    inside { print > (prefix "." n ".sh") }
  ' "$PLUGIN_DIR/skills/review-deep/$DOC.md"
done
export RESOLVER_BLOCK CONTEXT_BLOCK TEST_DIR
RESOLVER_BLOCK=$(grep -l 'commits/$HEAD_SHA/pulls' "$TEST_DIR"/scope-discovery.*.sh)
CONTEXT_BLOCK=$(grep -l '^if ! PR_FULL=' "$TEST_DIR"/context-gathering.*.sh)
[[ -n "$RESOLVER_BLOCK" && -n "$CONTEXT_BLOCK" ]]
mkdir "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" init -q -b feature
git -C "$TEST_DIR/repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m initial
cd "$TEST_DIR/repo"
cat > "$TEST_DIR/run.sh" <<'SH'
gh() {
  printf '%s\n' "$*" >> "$TEST_DIR/calls"
  if [ "$1" = api ]; then
    [ "${API_FAIL:-false}" = false ] || return 17
    [ "$2 $3" = '--paginate --slurp' ] || return 18
    printf '%s\n' "$PAGES"
  elif [ "$1 $2" = 'pr view' ]; then
    [ "${VIEW_FAIL:-false}" = false ] || return 19
    printf '{"number":%s,"url":%s}\n' "$3" "${PR_URL_JSON:-\"https://github.com/example/project/pull/$3\"}"
  else
    return 20
  fi
}
PR_JSON=${INITIAL_JSON:-}
PR_NUM=7
if [ "$MODE" = resolver ]; then
  . "$RESOLVER_BLOCK"
  printf '%s\n' "$PR_JSON"
else
  . "$CONTEXT_BLOCK"
  printf '%s\n' "$REPO_FULL|$OWNER|$REPO"
fi
SH
export MODE=resolver PAGES='[]'
for SHELL_BIN in bash zsh; do
  command -v "$SHELL_BIN" >/dev/null
  run_recipe() { "$SHELL_BIN" "$TEST_DIR/run.sh" > "$TEST_DIR/out" 2> "$TEST_DIR/err"; }
  assert_number() {
    run_recipe
    [[ $(jq -r .number "$TEST_DIR/out") = "$1" ]]
  }
  # The matching branch is on a later page, after another open PR.
  PAGES='[[{"number":1,"state":"open","head":{"ref":"other"}}],[{"number":2,"state":"open","head":{"ref":"feature"}}]]'
  assert_number 2
  PAGES='[[{"number":3,"state":"closed","head":{"ref":"old"}},{"number":4,"state":"open","head":{"ref":"other"}}]]'
  assert_number 4
  PAGES='[[{"number":3,"state":"closed","head":{"ref":"old"}}]]'
  assert_number 3
  PAGES='[[]]'
  run_recipe
  [[ ! -s "$TEST_DIR/out" || $(wc -c < "$TEST_DIR/out") -eq 1 ]]
  : > "$TEST_DIR/calls"
  INITIAL_JSON='{"number":8}' assert_number 8
  [[ ! -s "$TEST_DIR/calls" ]]
  if API_FAIL=true run_recipe; then echo 'FAIL: swallowed API error'; exit 1; fi
  grep -q 'PR discovery failed' "$TEST_DIR/err"
  PAGES='not json'
  if run_recipe; then echo 'FAIL: accepted invalid JSON'; exit 1; fi
  PAGES='[[{"number":3,"state":"closed","head":{"ref":"old"}}]]'
  if VIEW_FAIL=true run_recipe; then echo 'FAIL: swallowed PR read error'; exit 1; fi
  grep -q 'PR metadata lookup failed' "$TEST_DIR/err"
  MODE=context
  run_recipe
  [[ $(cat "$TEST_DIR/out") = 'example/project|example|project' ]]
  # Fork PRs resolve to the canonical repository from the PR URL, not the checkout remote.
  PR_URL_JSON='"https://github.com/upstream-org/canonical/pull/7"' run_recipe
  [[ $(cat "$TEST_DIR/out") = 'upstream-org/canonical|upstream-org|canonical' ]]
  for BAD in '"https://github.com/example/project"' '"https://github.com/example/project/pull/7/files"' 'null' '""'; do
    if PR_URL_JSON="$BAD" run_recipe; then echo "FAIL: accepted PR url $BAD"; exit 1; fi
    grep -q 'no valid canonical repository URL' "$TEST_DIR/err"
  done
  if VIEW_FAIL=true run_recipe; then echo 'FAIL: swallowed PR context read error'; exit 1; fi
  grep -q 'PR context lookup failed' "$TEST_DIR/err"
  MODE=resolver
  echo "PASS: $SHELL_BIN resolver pagination, selection, failures, and repository guards"
done
