#!/bin/bash
# Exercises worktree-create.sh's pure functions, extracted from the script so
# the shipped code is what runs. Regressions from live review rounds of PR #9:
#   F1 slugify caps at 60 chars (255-byte path-component limit)
#   F2 copy_env_files refuses a symlinked destination FILE
#   F3 copy_env_files refuses a symlinked PARENT before any mkdir escapes
#   F4 a legitimate nested env file still copies
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$PLUGIN_DIR/scripts/worktree-create.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

FNS="$SANDBOX/fns.sh"
awk '/^slugify\(\)/,/^}/'        "$SCRIPT"  > "$FNS"
awk '/^copy_env_files\(\)/,/^}/' "$SCRIPT" >> "$FNS"
grep -q 'slugify()' "$FNS" && grep -q 'copy_env_files()' "$FNS" \
  || { echo "FAIL: function extraction came up empty"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

# F1: slugify cap
LONG=$(printf 'a very long pull request title %.0s' 1 2 3 4 5 6 7 8)
S=$(slugify "$LONG")
[ "${#S}" -le 60 ] && pass F1 "slugify caps at ${#S} chars" \
  || fail F1 "slug is ${#S} chars (>60)"

# F2–F4: env copy guards
mkdir -p "$SANDBOX/src/sub" "$SANDBOX/wt/sub" "$SANDBOX/victim"
printf 'S=1\n' > "$SANDBOX/src/.env"
printf 'S=2\n' > "$SANDBOX/src/sub/.env.local"
mkdir -p "$SANDBOX/src/evil/deep"; printf 'S=3\n' > "$SANDBOX/src/evil/deep/.env"
ln -s "$SANDBOX/victim/stolen" "$SANDBOX/wt/.env"   # dest file is a symlink out
ln -s "$SANDBOX/victim"        "$SANDBOX/wt/evil"   # dest parent is a symlink out

printf '.env\nsub/.env.local\nevil/deep/.env\n' \
  | copy_env_files "$SANDBOX/src" "$SANDBOX/wt" > "$SANDBOX/copy.out" 2>&1 || true

[ -e "$SANDBOX/victim/stolen" ] && fail F2 "symlinked destination was written through" \
  || pass F2 "symlinked destination file refused"
[ -z "$(ls -A "$SANDBOX/victim")" ] && pass F3 "symlinked parent refused with zero filesystem mutation" \
  || fail F3 "something escaped into the victim dir: $(ls -A "$SANDBOX/victim")"
[ -f "$SANDBOX/wt/sub/.env.local" ] && pass F4 "legitimate nested copy landed" \
  || fail F4 "legitimate nested env file did not copy"

if [ "$FAILS" -gt 0 ]; then echo "worktree-create-fns: $FAILS failure(s)"; exit 1; fi
echo "worktree-create-fns: OK"
