#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/scripts" "$SCRATCH/plugins/workflow/lib" "$SCRATCH/plugins/ts-workflow/lib"
cp "$ROOT/scripts/sync-workflow-libs.mjs" "$SCRATCH/scripts/"
printf '%s\n' 'canonical method' > "$SCRATCH/plugins/workflow/lib/work-method.md"
printf '%s\n' 'canonical policy' > "$SCRATCH/plugins/workflow/lib/validation-policy.md"
if node "$SCRATCH/scripts/sync-workflow-libs.mjs" --check >/dev/null 2>&1; then
  echo 'missing packaged references must fail the gate' >&2; exit 1
fi
node "$SCRATCH/scripts/sync-workflow-libs.mjs" >/dev/null
node "$SCRATCH/scripts/sync-workflow-libs.mjs" --check >/dev/null
for REF in work-method.md validation-policy.md; do
  cmp "$SCRATCH/plugins/workflow/lib/$REF" "$SCRATCH/plugins/ts-workflow/lib/$REF"
done
printf '%s\n' 'stale policy' > "$SCRATCH/plugins/ts-workflow/lib/validation-policy.md"
if node "$SCRATCH/scripts/sync-workflow-libs.mjs" --check >/dev/null 2>&1; then
  echo 'a stale packaged policy must fail the gate' >&2; exit 1
fi
# Check mode must preserve the stale file for diagnosis.
test "$(cat "$SCRATCH/plugins/ts-workflow/lib/validation-policy.md")" = 'stale policy'
node "$SCRATCH/scripts/sync-workflow-libs.mjs" >/dev/null
cmp "$SCRATCH/plugins/workflow/lib/validation-policy.md" "$SCRATCH/plugins/ts-workflow/lib/validation-policy.md"
printf '%s\n' 'new canonical method' > "$SCRATCH/plugins/workflow/lib/work-method.md"
node "$SCRATCH/scripts/sync-workflow-libs.mjs" >/dev/null
cmp "$SCRATCH/plugins/workflow/lib/work-method.md" "$SCRATCH/plugins/ts-workflow/lib/work-method.md"
echo 'shared-workflow-libs: missing, stale, read-only check, and republish scenarios passed'
