#!/bin/bash
# Repo gate: version sync + plugin manifest validation + per-plugin tests.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
node "$SCRIPT_DIR/sync-versions.mjs" --check
if command -v claude >/dev/null 2>&1; then
  claude plugin validate "$SCRIPT_DIR/.." --strict
else
  echo "claude CLI not found; skipping plugin validate" >&2
fi
bash "$SCRIPT_DIR/tests/install-all.test.sh"
# Per-plugin shell tests (plugins/*/tests/*.test.sh), plain bash. These carry
# the scenario corpus from live review rounds — a failing one is a regression
# into a class Codex already caught once.
for T in "$SCRIPT_DIR"/../plugins/*/tests/*.test.sh; do
  [ -e "$T" ] || continue
  echo "== $(basename "$(dirname "$(dirname "$T")")")/$(basename "$T")"
  bash "$T"
done
