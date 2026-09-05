#!/usr/bin/env bash
# Inspired by gopherguides/gopher-ai/scripts/install-all.sh (MIT).
# Install missing plugins through the platforms' own marketplace commands.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM=auto
WITH_GOPHER=false
DRY_RUN=false

usage() {
    cat <<'HELP'
Usage: bash scripts/install-all.sh [--platform auto|claude|codex|both] [--with-gopher-ai] [--dry-run]

Install this checkout's plugins for detected CLIs (or the explicit platform).
--with-gopher-ai also installs every supported plugin from Gopher AI's main branch.
--dry-run prints the plan without changing plugin configuration.
Requires git, jq, curl, and at least one supported CLI. Existing installations
are preserved, including disabled plugins. This is not an update command.
Keep this checkout: newly registered michaelhvisser-ai marketplaces use its path.
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            PLATFORM=$2; shift 2 ;;
        --with-gopher-ai) WITH_GOPHER=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
case "$PLATFORM" in auto|claude|codex|both) ;; *) usage >&2; exit 1 ;; esac
for tool in git jq curl; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
platforms=()
for cli in claude codex; do
    if [[ "$PLATFORM" == auto ]]; then
        if command -v "$cli" >/dev/null; then platforms+=("$cli"); fi
    elif [[ "$PLATFORM" == both || "$PLATFORM" == "$cli" ]]; then
        command -v "$cli" >/dev/null || { echo "Missing requested CLI: $cli" >&2; exit 1; }
        platforms+=("$cli")
    fi
done
[[ ${#platforms[@]} -gt 0 ]] || { echo 'No Claude or Codex CLI found.' >&2; exit 1; }
# Fail before making any changes when Codex is too old for plugin installation.
for cli in "${platforms[@]}"; do
    if [[ "$cli" == codex ]]; then
        codex plugin add --help >/dev/null
    fi
done
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if ! $DRY_RUN; then "$@"; fi
}

install_marketplace() {
    local cli=$1 name=$2 source=$3 catalog=$4
    local marketplaces installed registered plugin_names plugin selector
    plugin_names=$(jq -er '.plugins | select(length > 0) | .[].name' "$catalog")
    # Check names before using a downloaded catalog to construct CLI arguments.
    while IFS= read -r plugin; do
        [[ "$plugin" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid plugin name: $plugin" >&2; return 1; }
    done <<< "$plugin_names"
    marketplaces=$("$cli" plugin marketplace list --json)
    installed=$("$cli" plugin list --json)
    if [[ "$cli" == codex ]]; then
        registered=$(jq -r --arg name "$name" '[.marketplaces[]? | select(.name == $name)] | length' <<< "$marketplaces")
    else
        registered=$(jq -r --arg name "$name" '[.[] | select(.name == $name)] | length' <<< "$marketplaces")
    fi
    if [[ "$registered" == 0 ]]; then
        run "$cli" plugin marketplace add "$source"
    else
        echo "$cli: preserving registered marketplace $name"
    fi
    while IFS= read -r plugin; do
        selector="$plugin@$name"
        if [[ "$cli" == codex ]]; then
            if jq -e --arg id "$selector" '.installed[]? | select(.pluginId == $id)' <<< "$installed" >/dev/null; then
                echo "$cli: already installed $selector"; continue
            fi
            run codex plugin add "$selector"
        else
            if jq -e --arg id "$selector" '.[] | select(.id == $id and .scope == "user")' <<< "$installed" >/dev/null; then
                echo "$cli: already installed $selector"; continue
            fi
            run claude plugin install "$selector" --scope user
        fi
    done <<< "$plugin_names"
}

# Fetch both upstream catalogs before installing anything. Never execute downloaded scripts.
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
for cli in "${platforms[@]}"; do
    if [[ "$cli" == codex ]]; then catalog_path=.agents/plugins/marketplace.json
    else catalog_path=.claude-plugin/marketplace.json; fi
    jq -e '.plugins | length > 0' "$ROOT_DIR/$catalog_path" >/dev/null
    if $WITH_GOPHER; then
        curl -fsSL "https://raw.githubusercontent.com/gopherguides/gopher-ai/main/$catalog_path" -o "$TEMP_DIR/$cli.json"
        jq -e '.name == "gopher-ai" and (.plugins | length > 0)' "$TEMP_DIR/$cli.json" >/dev/null
    fi
done
for cli in "${platforms[@]}"; do
    if [[ "$cli" == codex ]]; then catalog_path=.agents/plugins/marketplace.json
    else catalog_path=.claude-plugin/marketplace.json; fi
    install_marketplace "$cli" michaelhvisser-ai "$ROOT_DIR" "$ROOT_DIR/$catalog_path"
    if $WITH_GOPHER; then
        install_marketplace "$cli" gopher-ai https://github.com/gopherguides/gopher-ai.git "$TEMP_DIR/$cli.json"
    fi
done
if $DRY_RUN; then
    echo 'Dry run complete; no plugin configuration changed.'
else
    echo 'Installation complete. Start a new Codex session and reload Claude plugins.'
    echo 'Use codex plugin list and claude plugin list to verify. Existing plugins were not updated.'
fi
