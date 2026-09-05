#!/usr/bin/env bash
# Exercise install/rerun/failure behavior without touching real user configuration.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
# The Codex catalog must expose exactly the plugins with Codex manifests.
expected_plugins=$(for manifest in "$ROOT_DIR"/plugins/*/.codex-plugin/plugin.json; do
    jq -r '.name' "$manifest"
done | sort)
actual_plugins=$(jq -r '.plugins[].name' "$ROOT_DIR/.agents/plugins/marketplace.json" | sort)
[[ "$actual_plugins" == "$expected_plugins" ]] || { echo 'Codex catalog drift' >&2; exit 1; }
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
export INSTALL_TEST_LOG="$TEST_DIR/calls"
export INSTALL_TEST_STATE=fresh
cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -eu
cli=$(basename "$0")
printf '%s %s\n' "$cli" "$*" >> "$INSTALL_TEST_LOG"
if [[ "$*" == 'plugin add --help' ]]; then
    [[ "$INSTALL_TEST_STATE" != old-codex ]] || exit 2
    exit 0
fi
if [[ "$INSTALL_TEST_STATE" == list-fail && "$*" == 'plugin list --json' ]]; then exit 18; fi
if [[ "$*" == 'plugin marketplace list --json' ]]; then
    if [[ "$INSTALL_TEST_STATE" == existing ]]; then
        if [[ "$cli" == codex ]]; then echo '{"marketplaces":[{"name":"michaelhvisser-ai"}]}'
        else echo '[{"name":"michaelhvisser-ai"}]'; fi
    elif [[ "$cli" == codex ]]; then echo '{"marketplaces":[]}'
    else echo '[]'; fi
elif [[ "$*" == 'plugin list --json' ]]; then
    if [[ "$INSTALL_TEST_STATE" == existing ]]; then
        if [[ "$cli" == codex ]]; then
            echo '{"installed":[{"pluginId":"workflow@michaelhvisser-ai","enabled":false},{"pluginId":"ts-workflow@michaelhvisser-ai"}]}'
        else
            echo '[{"id":"workflow@michaelhvisser-ai","scope":"user","enabled":false},{"id":"ts-workflow@michaelhvisser-ai","scope":"user"},{"id":"slack-triage@michaelhvisser-ai","scope":"user"}]'
        fi
    elif [[ "$cli" == codex ]]; then echo '{"installed":[]}'
    else echo '[]'; fi
elif [[ "$INSTALL_TEST_STATE" == fail && "$1 $2 $3" == 'plugin marketplace add' ]]; then
    exit 17
elif [[ "$INSTALL_TEST_STATE" == plugin-fail && "$2 $3" == 'install workflow@michaelhvisser-ai' ]]; then
    exit 19
elif [[ "$INSTALL_TEST_STATE" == plugin-fail && "$2 $3" == 'add workflow@michaelhvisser-ai' ]]; then
    exit 19
fi
MOCK
cp "$TEST_DIR/bin/claude" "$TEST_DIR/bin/codex"
cat > "$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ "$INSTALL_TEST_STATE" == fetch-fail ]]; then exit 22; fi
# Minimal upstream fixtures, including one Claude-only plugin.
if [[ "$2" == *'.claude-plugin/'* ]]; then
    echo '{"name":"gopher-ai","plugins":[{"name":"go-dev"},{"name":"productivity"}]}' > "$4"
else
    echo '{"name":"gopher-ai","plugins":[{"name":"go-dev"}]}' > "$4"
fi
MOCK
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
run_installer() { bash "$ROOT_DIR/scripts/install-all.sh" "$@" > "$TEST_DIR/output" 2>&1; }
assert_call() { grep -Fx -- "$1" "$INSTALL_TEST_LOG" >/dev/null; }
assert_no_mutations() {
    if grep -E 'plugin (marketplace add|install|add [^-])' "$INSTALL_TEST_LOG"; then
        echo 'Unexpected mutation' >&2; exit 1
    fi
}
run_installer --platform both --with-gopher-ai
assert_call 'claude plugin install productivity@gopher-ai --scope user'
assert_call 'codex plugin add go-dev@gopher-ai'
assert_call 'codex plugin add workflow@michaelhvisser-ai'
if grep -E 'codex plugin add (productivity|slack-triage)' "$INSTALL_TEST_LOG"; then exit 1; fi
: > "$INSTALL_TEST_LOG"
run_installer --platform both --dry-run
assert_no_mutations
: > "$INSTALL_TEST_LOG"
INSTALL_TEST_STATE=existing run_installer --platform both
assert_no_mutations
: > "$INSTALL_TEST_LOG"
if INSTALL_TEST_STATE=fail run_installer --platform both; then echo 'Ignored install failure'; exit 1; fi
if grep -E 'plugin (install|add [^-])' "$INSTALL_TEST_LOG"; then exit 1; fi
: > "$INSTALL_TEST_LOG"
if INSTALL_TEST_STATE=fetch-fail run_installer --with-gopher-ai; then echo 'Ignored fetch failure'; exit 1; fi
assert_no_mutations
: > "$INSTALL_TEST_LOG"
if INSTALL_TEST_STATE=old-codex run_installer --platform both; then echo 'Accepted unsupported Codex'; exit 1; fi
assert_no_mutations
for PLATFORM in claude codex; do
    : > "$INSTALL_TEST_LOG"
    if INSTALL_TEST_STATE=list-fail run_installer --platform "$PLATFORM"; then echo 'Ignored list failure'; exit 1; fi
    assert_no_mutations
    : > "$INSTALL_TEST_LOG"
    if INSTALL_TEST_STATE=plugin-fail run_installer --platform "$PLATFORM"; then echo 'Ignored plugin failure'; exit 1; fi
    if grep -E 'plugin (install|add) (ts-workflow|slack-triage)@' "$INSTALL_TEST_LOG"; then
        echo 'Continued after failed plugin installation'; exit 1
    fi
done
: > "$INSTALL_TEST_LOG"
run_installer --platform codex
if grep '^claude ' "$INSTALL_TEST_LOG"; then exit 1; fi
if run_installer --platform unknown; then exit 1; fi
if run_installer --unknown; then exit 1; fi
echo 'PASS: platform selection, catalogs, dry run, rerun, disabled preservation, and failure propagation'
