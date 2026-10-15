#!/bin/bash
# Exercise the real hook with isolated tool directories standing in for Homebrew.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE=${HOOK_UNDER_TEST:-"$SCRIPT_DIR/../hooks/pre-tool-use.sh"}
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE"/{arm,intel,system,home,custom}
# Remap absolute install locations so this runs without Homebrew or root access.
sed -e "s|/opt/homebrew/bin|$FIXTURE/arm|g" \
    -e "s|/usr/local/bin|$FIXTURE/intel|g" \
    -e "s|/usr/bin:/bin:/usr/sbin:/sbin|$FIXTURE/system|g" \
    "$SOURCE" > "$FIXTURE/hook.sh"
for tool in cat jq grep; do
  ln -s "$(command -v "$tool")" "$FIXTURE/system/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$FIXTURE/system/git"
chmod +x "$FIXTURE/system/git"
make_tool() {
  printf '#!/bin/sh\nexit 0\n' > "$1"
  chmod +x "$1"
}
run_case() {
  local label=$1 want=$2 command=$3 mode=$4 output
  local -a environment=("HOME=$FIXTURE/home")
  case "$mode" in
    minimal) environment+=("PATH=$FIXTURE/system");;
    custom) environment+=("PATH=$FIXTURE/custom:$FIXTURE/system");;
    unset) ;;
  esac
  output=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command" |
    /usr/bin/env -i "${environment[@]}" /bin/bash "$FIXTURE/hook.sh")
  if [ "$want" = block ]; then
    [[ "$output" == *'"decision":"block"'* ]] || { echo "FAIL: $label: $output"; exit 1; }
  else
    [ -z "$output" ] || { echo "FAIL: $label: $output"; exit 1; }
  fi
  echo "PASS: $label"
}
make_tool "$FIXTURE/arm/gh"
make_tool "$FIXTURE/arm/node"
run_case 'Apple Silicon Homebrew gh' allow 'gh pr list' minimal
run_case 'Apple Silicon Homebrew node' allow 'node --version' minimal
run_case 'unset PATH uses system fallback' allow 'gh pr list' unset
mv "$FIXTURE/arm/gh" "$FIXTURE/intel/gh"
run_case 'Intel Homebrew gh' allow 'gh pr list' minimal
mv "$FIXTURE/intel/gh" "$FIXTURE/custom/gh"
run_case 'existing PATH retained' allow 'gh pr list' custom
run_case 'missing gh remains blocked' block 'gh pr list' minimal
