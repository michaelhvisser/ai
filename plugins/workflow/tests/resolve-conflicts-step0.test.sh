#!/bin/bash
# Executes resolve-conflicts' ACTUAL Step 0 block — extracted from SKILL.md,
# so the doc is the code under test — against scripted git scenarios. Each
# scenario is a regression from a live review round of PR #10:
#   S1 plain rebase        → per-pick baselines + theirs-before, state file parses
#   S2 rebase --onto       → deliberately excluded commit gets NO baseline
#   S3 reordered todo      → BOTH picks keep baselines despite reordering
#   S4 rebase --apply      → From-line parsing yields per-pick baselines
#   S5 merge               → ours-before AND theirs-before non-empty
#   S6 multi cherry-pick   → RC_ONTO = sequencer/head; every outstanding pick baselined
#   S7 hostile branch name → state file is parsed, never executed
#   S8 stale state, no op  → leftover state file removed
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$PLUGIN_DIR/skills/resolve-conflicts/SKILL.md"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"

# --- extract the Step 0 block (the first fenced bash block in the file) ---
STEP0="$SANDBOX/step0.sh"
awk '/^```bash$/{if(!done){inb=1; next}} /^```$/{if(inb){done=1; inb=0}} inb{print}' "$SKILL" > "$STEP0"
grep -q 'RC_STATE_FILE=' "$STEP0" || { echo "FAIL: Step 0 extraction came up empty"; exit 1; }
bash -n "$STEP0"

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

run_step0() {  # in the current repo dir; step 0 must not abort the test on nonzero
  bash "$STEP0" >"$SANDBOX/step0.out" 2>&1 || true
}
state() { sed -n "s/^$2=//p" "$(git rev-parse --git-dir)/resolve-conflicts.state" | head -1; }
rundir() { state "$1" RC_RUN_DIR; }

new_repo() {
  R="$SANDBOX/$1"; rm -rf "$R"; mkdir -p "$R"; cd "$R"
  git init -q -b main; git commit -q --allow-empty -m c0
  printf 'base\n' > f; git add f; git commit -qm base
}

# ---------- S1: plain rebase ----------
new_repo s1
git checkout -q -b feat
printf 'base\nA\n' > f; git commit -qam A
printf 'base\nA\nB\n' > f; git commit -qam B
git checkout -q -b newbase main; printf 'nb\n' > f; git commit -qam nb
git checkout -q feat
git rebase newbase >/dev/null 2>&1 || true
run_step0
[ "$(state s1 RC_OP)" = rebase ] || fail S1 "RC_OP=$(state s1 RC_OP)"
D=$(rundir s1)
N=$(find "$D" -name 'ours-before-*.diff' | wc -l | tr -d ' ')
[ "$N" = 2 ] || fail S1 "expected 2 per-pick baselines, got $N"
[ -s "$D/theirs-before.diff" ] || fail S1 "theirs-before.diff empty or missing"
[ "$FAILS" = 0 ] && pass S1 "rebase: 2 baselines + theirs-before"
git rebase --abort 2>/dev/null || true

# ---------- S2: rebase --onto excludes UPSTREAM ancestors ----------
new_repo s2
git checkout -q -b feat
printf 'excluded\n' > f; git commit -qam excluded; UP=$(git rev-parse HEAD)
printf 'excluded\nreplayed\n' > f; git commit -qam replayed
git checkout -q -b newbase main; printf 'conflict\n' > f; git commit -qam nb
git checkout -q feat
git rebase --onto newbase "$UP" >/dev/null 2>&1 || true
run_step0
D=$(rundir s2)
if grep -rql '^+excluded' "$D"/ours-before-*.diff 2>/dev/null; then
  fail S2 "excluded commit's content leaked into a baseline"
else
  pass S2 "--onto: excluded ancestor has no baseline"
fi
git rebase --abort 2>/dev/null || true

# ---------- S3: reordered interactive todo keeps both baselines ----------
new_repo s3
git checkout -q -b feat
printf 'base\nA\n' > f; git commit -qam A
printf 'base\nA\nB\n' > f; git commit -qam B
git checkout -q -b newbase main; printf 'nb\n' > f; git commit -qam nb
git checkout -q feat
ED="$SANDBOX/reorder.sh"; printf '#!/bin/bash\ngrep "^pick " "$1" | tail -r > "$1.n" 2>/dev/null || { grep "^pick " "$1" | tac > "$1.n"; }\nmv "$1.n" "$1"\n' > "$ED"; chmod +x "$ED"
GIT_SEQUENCE_EDITOR="$ED" git rebase -i newbase >/dev/null 2>&1 || true
run_step0
D=$(rundir s3)
grep -ql '^+A$' "$D"/ours-before-*.diff && grep -ql '^+B$' "$D"/ours-before-*.diff \
  && pass S3 "reordered todo: both picks baselined" \
  || fail S3 "a pick lost its baseline under reordering"
git rebase --abort 2>/dev/null || true

# ---------- S4: apply backend parses From-lines ----------
new_repo s4
git checkout -q -b feat
printf 'base\nA\n' > f; git commit -qam A
printf 'base\nA\nB\n' > f; git commit -qam B
git checkout -q -b newbase main; printf 'nb\n' > f; git commit -qam nb
git checkout -q feat
git rebase --apply newbase >/dev/null 2>&1 || true
run_step0
D=$(rundir s4)
N=$(find "$D" -name 'ours-before-*.diff' | wc -l | tr -d ' ')
[ "$N" = 2 ] && pass S4 "apply backend: 2 baselines via From-lines" \
  || fail S4 "expected 2 baselines from patch From-lines, got $N"
git rebase --abort 2>/dev/null || true

# ---------- S5: merge captures both directions ----------
new_repo s5
git checkout -q -b side; printf 'side\n' > f; git commit -qam side
git checkout -q main; printf 'ours\n' > f; git commit -qam ours
git merge side >/dev/null 2>&1 || true
run_step0
D=$(rundir s5)
[ -s "$D/ours-before.diff" ] && [ -s "$D/theirs-before.diff" ] \
  && pass S5 "merge: ours-before and theirs-before both captured" \
  || fail S5 "one merge baseline empty or missing"
git merge --abort 2>/dev/null || true

# ---------- S6: multi cherry-pick — sequencer/head scope + outstanding picks ----------
new_repo s6
git checkout -q -b src
printf 'base\nP1\n' > f; git commit -qam P1; C1=$(git rev-parse HEAD)
printf 'base\nP1\nP2\n' > f; git commit -qam P2; C2=$(git rev-parse HEAD)
git checkout -q main; printf 'conflict\n' > f; git commit -qam mainside
START=$(git rev-parse HEAD)
git cherry-pick "$C1" "$C2" >/dev/null 2>&1 || true
run_step0
[ "$(state s6 RC_ONTO)" = "$START" ] || fail S6 "RC_ONTO != sequencer start"
D=$(rundir s6)
N=$(find "$D" -name 'ours-before-*.diff' | wc -l | tr -d ' ')
[ "$N" = 2 ] || fail S6 "expected 2 outstanding-pick baselines, got $N"
[ "$FAILS" = 0 ] && pass S6 "cherry-pick: sequencer/head scope, 2 baselines"
git cherry-pick --abort 2>/dev/null || true

# ---------- S7: hostile branch name is data, not code ----------
new_repo s7
git checkout -q -b 'a;>pwned'
printf 'base\nX\n' > f; git commit -qam X
git checkout -q -b newbase main; printf 'nb\n' > f; git commit -qam nb
git checkout -q 'a;>pwned'
git rebase newbase >/dev/null 2>&1 || true
run_step0
run_step0   # second entry parses the state file written by the first
[ -e "$R/pwned" ] && fail S7 "state file was executed: pwned created" \
  || pass S7 "hostile branch name round-trips as data"
git rebase --abort 2>/dev/null || true

# ---------- S8: leftover state with no operation is removed ----------
new_repo s8
printf 'RC_OP=rebase\nRC_RUN_DIR=%s/bogus\n' "$TMPDIR" > .git/resolve-conflicts.state
run_step0
[ -f .git/resolve-conflicts.state ] && fail S8 "stale state file survived a no-op run" \
  || pass S8 "no-op run removes leftover state"

if [ "$FAILS" -gt 0 ]; then echo "resolve-conflicts-step0: $FAILS failure(s)"; exit 1; fi
echo "resolve-conflicts-step0: OK"
