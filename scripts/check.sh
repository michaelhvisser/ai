#!/bin/bash
# Repo gate: version sync + plugin manifest validation.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
node "$SCRIPT_DIR/sync-versions.mjs" --check
if command -v claude >/dev/null 2>&1; then
  claude plugin validate "$SCRIPT_DIR/.." --strict
else
  echo "claude CLI not found; skipping plugin validate" >&2
fi
