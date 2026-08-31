#!/bin/bash
# Every fenced ```bash block in this plugin's skill and lib docs must parse
# under BOTH bash and zsh — agents execute these blocks in the user's shell,
# and zsh has bitten this repo before (NOMATCH globs, word-splitting).
#
# Blocks containing angle-bracket placeholders (<file>, <sha>, ...) are
# illustrative and skipped, as is any block whose info string is not exactly
# "bash" (e.g. ```bash notest).
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
FAILS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

while IFS= read -r MD; do
  BASE=$(printf '%s' "$MD" | sed "s#^$PLUGIN_DIR/##; s#[/ ]#_#g")
  # split the file into per-block files, numbered
  awk -v out="$TMP/$BASE" '
    /^```bash$/ {inblock=1; n++; f=out "." n ".sh"; next}
    /^```/      {inblock=0; next}
    inblock     {print > f}
  ' "$MD"
  for BLOCK in "$TMP/$BASE".*.sh; do
    [ -e "$BLOCK" ] || continue
    # skip illustrative blocks: placeholders like <file> or <sha7> (heredoc
    # markers and comparisons do not match this shape)
    if grep -qE '<[a-zA-Z][a-zA-Z0-9 _.|:-]*>' "$BLOCK"; then continue; fi
    if ! bash -n "$BLOCK" 2>"$TMP/err"; then
      echo "FAIL bash -n: $MD ($(basename "$BLOCK"))"; sed 's/^/    /' "$TMP/err"; FAILS=$((FAILS+1))
    fi
    if command -v zsh >/dev/null 2>&1 && ! zsh -n "$BLOCK" 2>"$TMP/err"; then
      echo "FAIL zsh -n: $MD ($(basename "$BLOCK"))"; sed 's/^/    /' "$TMP/err"; FAILS=$((FAILS+1))
    fi
  done
done < <(find "$PLUGIN_DIR/skills" "$PLUGIN_DIR/lib" -name '*.md' 2>/dev/null)

if [ "$FAILS" -gt 0 ]; then echo "skill-blocks-syntax: $FAILS failure(s)"; exit 1; fi
echo "skill-blocks-syntax: OK"
