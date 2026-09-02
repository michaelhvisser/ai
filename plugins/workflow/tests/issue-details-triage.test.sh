#!/bin/bash
# Executes issue-details' ACTUAL guard blocks — extracted from triage.md and
# facts.md, so the doc is the code under test — against fixtures. Each block
# is sourced under both bash and zsh, because agents run them in the user's
# shell. Scenarios:
#   V1 verdict vocabulary  → the four forms pass; a #N that never appeared in a
#                            search result, or any wording outside the
#                            vocabulary, downgrades to `unclear` with a note
#   V2 never max           → a proposed `max` clamps to xhigh; an existing
#                            block is reported (agree/disagree) and never
#                            replaced; the block extractor reads the fenced
#                            detent-agent block and nothing else
#   V3 marker lookup       → no marker = create; one = edit with its numeric
#                            id; two = the oldest is edited, both counted; a
#                            marker quoted mid-body does not match
#   V4 social rule         → another author never gets a close in the
#                            recommendation, gets a decision instead, and a
#                            priority disagreement becomes a note to them;
#                            the running user gets the close recommendation;
#                            a deleted-account author counts as not-self
#   V5 noise is mechanical → a build-output / _generated path or a
#                            detent-intake fingerprint forces `noise`; prose
#                            mentioning "build" does not
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
TRIAGE="$PLUGIN_DIR/skills/issue-details/triage.md"
FACTS="$PLUGIN_DIR/skills/issue-details/facts.md"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
command -v zsh >/dev/null 2>&1 || { echo "issue-details-triage: zsh is required (bash-and-zsh is the invariant)"; exit 1; }

extract_blocks() {  # $1 = md file, $2 = output prefix
  awk -v out="$2" '
    /^```bash$/ {inb=1; n++; f=out "." n ".sh"; next}
    /^```/      {inb=0; next}
    inb         {print > f}
  ' "$1"
}
extract_blocks "$TRIAGE" "$SANDBOX/triage"
extract_blocks "$FACTS"  "$SANDBOX/facts"
VERDICT_BLOCK=$(grep -l 'outside the verdict vocabulary' "$SANDBOX"/triage.*.sh | head -1)
EFFORT_BLOCK=$(grep -l 'EFFORT_STANCE="agree"' "$SANDBOX"/triage.*.sh | head -1)
SOCIAL_BLOCK=$(grep -l 'SELF_AUTHORED=1; else SELF_AUTHORED=0' "$SANDBOX"/triage.*.sh | head -1)
DECISION_BLOCK=$(grep -l 'NEEDS_DECISION=false' "$SANDBOX"/triage.*.sh | head -1)
NOISE_BLOCK=$(grep -l 'NOISE_SIGNAL=""' "$SANDBOX"/triage.*.sh | head -1)
MARKER_BLOCK=$(grep -l 'COMMENT_ACTION="create"' "$SANDBOX"/facts.*.sh | head -1)
EXISTING_BLOCK=$(grep -l 'detent-agent' "$SANDBOX"/facts.*.sh | head -1)
for B in "$VERDICT_BLOCK" "$EFFORT_BLOCK" "$SOCIAL_BLOCK" "$DECISION_BLOCK" "$NOISE_BLOCK" "$MARKER_BLOCK" "$EXISTING_BLOCK"; do
  [ -n "$B" ] || { echo "FAIL: a guard block extraction came up empty"; exit 1; }
  bash -n "$B"; zsh -n "$B"
done

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

# run_block <shell> <block> <var-assignments...> — sources the block under the
# given shell with the assignments as preset state; prints the resulting
# environment lines the scenarios read.
run_block() {
  local RB_SHELL="$1" RB_BLOCK="$2"; shift 2
  local RB_SCRIPT="$SANDBOX/run.$$.sh"
  {
    printf 'set -u\n'
    for KV in "$@"; do printf '%s\n' "$KV"; done
    printf '. "%s"\n' "$RB_BLOCK"
    printf 'for V in CLASSIFICATION NOISE_SIGNAL VERDICT VERDICT_NOTE CANONICAL PROPOSED_EFFORT EFFORT EFFORT_STANCE EFFORT_NOTE SELF_AUTHORED RECOMMENDATION PRIORITY_NOTE NEEDS_DECISION MARKER_ID MARKER_COUNT MARKER_UPDATED COMMENT_ACTION EXISTING_EFFORT; do\n'
    printf '  eval "X=\\${$V-__unset__}"; printf "%%s=%%s\\n" "$V" "$X"\n'
    printf 'done\n'
  } > "$RB_SCRIPT"
  "$RB_SHELL" "$RB_SCRIPT"
}
get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

for SH in bash zsh; do
  # ---------- V1: closed verdict vocabulary ----------
  OPEN='[12,40]'; SHIPPED='[7]'
  for CASE in \
    'needed|needed|null' \
    'unclear|unclear|null' \
    'likely-duplicate-of #12|likely-duplicate-of #12|#12' \
    'already-fixed-by #7|already-fixed-by #7|#7' \
    'likely-duplicate-of #99|unclear|null' \
    'already-fixed-by #12|unclear|null' \
    'likely-duplicate-of #7|unclear|null' \
    'superseded-by #12|unclear|null' \
    'needed (probably)|unclear|null' \
    'likely-duplicate-of #12 and #40|unclear|null'
  do
    IN="${CASE%%|*}"; REST="${CASE#*|}"; WANT="${REST%%|*}"; WANT_CANON="${REST#*|}"
    OUT=$(run_block "$SH" "$VERDICT_BLOCK" "VERDICT='$IN'" "CANDIDATES_OPEN='$OPEN'" "CANDIDATES_SHIPPED='$SHIPPED'")
    GOT=$(get "$OUT" VERDICT); GOT_CANON=$(get "$OUT" CANONICAL); NOTE=$(get "$OUT" VERDICT_NOTE)
    if [ "$GOT" != "$WANT" ] || [ "$GOT_CANON" != "$WANT_CANON" ]; then
      fail "V1/$SH" "'$IN' -> '$GOT' canonical '$GOT_CANON' (want '$WANT' / '$WANT_CANON')"
    elif [ "$WANT" = unclear ] && [ "$IN" != unclear ] && [ -z "$NOTE" ]; then
      fail "V1/$SH" "'$IN' downgraded without a note"
    fi
  done
  [ "$FAILS" = 0 ] && pass "V1/$SH" "vocabulary closed; unseen numbers and foreign wording downgrade with a note"

  # ---------- V2: never max, existing block reported not replaced ----------
  OUT=$(run_block "$SH" "$EFFORT_BLOCK" "PROPOSED_EFFORT=max" "EXISTING_EFFORT=")
  [ "$(get "$OUT" EFFORT)" = xhigh ] || fail "V2/$SH" "proposed max did not clamp to xhigh: $(get "$OUT" EFFORT)"
  [ -n "$(get "$OUT" EFFORT_NOTE)" ] || fail "V2/$SH" "clamp left no note"
  [ "$(get "$OUT" EFFORT_STANCE)" = propose ] || fail "V2/$SH" "no block should be 'propose'"
  OUT=$(run_block "$SH" "$EFFORT_BLOCK" "PROPOSED_EFFORT=high" "EXISTING_EFFORT=max")
  [ "$(get "$OUT" EFFORT)" = high ] || fail "V2/$SH" "existing max must not become the proposal"
  [ "$(get "$OUT" EFFORT_STANCE)" = disagree ] || fail "V2/$SH" "existing max vs proposed high should disagree"
  [ "$(get "$OUT" EXISTING_EFFORT)" = max ] || fail "V2/$SH" "existing block value was rewritten"
  OUT=$(run_block "$SH" "$EFFORT_BLOCK" "PROPOSED_EFFORT=medium" "EXISTING_EFFORT=medium")
  [ "$(get "$OUT" EFFORT_STANCE)" = agree ] || fail "V2/$SH" "matching tiers should agree"
  OUT=$(run_block "$SH" "$EFFORT_BLOCK" "PROPOSED_EFFORT=enormous" "EXISTING_EFFORT=")
  [ "$(get "$OUT" EFFORT)" = xhigh ] || fail "V2/$SH" "foreign tier did not clamp"
  # the extractor reads only the fenced detent-agent block
  RUN_DIR="$SANDBOX"; ISSUE_NUM=1
  printf '## Plan\n\neffort: max\n\n```detent-agent\nschema: 1\neffort: medium\n```\n\n```yaml\neffort: xhigh\n```\n' > "$SANDBOX/body-1.md"
  OUT=$(run_block "$SH" "$EXISTING_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ "$(get "$OUT" EXISTING_EFFORT)" = medium ] || fail "V2/$SH" "extractor read outside the detent-agent fence: $(get "$OUT" EXISTING_EFFORT)"
  printf '## Plan\n\nno block here\n' > "$SANDBOX/body-1.md"
  OUT=$(run_block "$SH" "$EXISTING_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ -z "$(get "$OUT" EXISTING_EFFORT)" ] || fail "V2/$SH" "no block should yield empty"
  [ "$FAILS" = 0 ] && pass "V2/$SH" "max never proposed; existing block reported, never replaced; fence-only extraction"

  # ---------- V3: marker comment lookup for edit-in-place ----------
  jq -n '[
    {id: 300, login: "someone", body: "unrelated", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"},
    {id: 301, login: "someone", body: "quoting:\n<!-- issue-details:v1 dev=abc -->\nnot mine", created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ "$(get "$OUT" COMMENT_ACTION)" = create ] || fail "V3/$SH" "no marker should be create"
  [ -z "$(get "$OUT" MARKER_ID)" ] || fail "V3/$SH" "a quoted marker mid-body matched"
  jq -n '[
    {id: 400, login: "me", body: "<!-- issue-details:v1 dev=abc -->\n## Issue details", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-03T00:00:00Z"},
    {id: 350, login: "x", body: "hello", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ "$(get "$OUT" COMMENT_ACTION)" = edit ] || fail "V3/$SH" "one marker should be edit"
  [ "$(get "$OUT" MARKER_ID)" = 400 ] || fail "V3/$SH" "wrong marker id: $(get "$OUT" MARKER_ID)"
  [ "$(get "$OUT" MARKER_UPDATED)" = "2026-01-03T00:00:00Z" ] || fail "V3/$SH" "snapshot updated_at not captured"
  jq -n '[
    {id: 500, login: "me", body: "<!-- issue-details:v1 dev=def -->\nnewer", created_at: "2026-01-05T00:00:00Z", updated_at: "2026-01-05T00:00:00Z"},
    {id: 400, login: "me", body: "<!-- issue-details:v1 dev=abc -->\nolder", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ "$(get "$OUT" MARKER_ID)" = 400 ] || fail "V3/$SH" "two markers: the oldest must be edited, got $(get "$OUT" MARKER_ID)"
  [ "$(get "$OUT" MARKER_COUNT)" = 2 ] || fail "V3/$SH" "duplicate markers not counted"
  [ "$FAILS" = 0 ] && pass "V3/$SH" "marker lookup: create / edit oldest by numeric id / quoted marker ignored"

  # ---------- V4: the social rule ----------
  OUT=$(run_block "$SH" "$SOCIAL_BLOCK" "ISSUE_AUTHOR=cory" "ME=michael" "VERDICT='likely-duplicate-of #12'" "CANONICAL='#12'" "BOARD_PRIORITY=Medium" "PRIORITY=High")
  [ "$(get "$OUT" SELF_AUTHORED)" = 0 ] || fail "V4/$SH" "other author marked self"
  case "$(get "$OUT" RECOMMENDATION)" in
    *"@cory"*) : ;; *) fail "V4/$SH" "other author's recommendation not addressed to them: $(get "$OUT" RECOMMENDATION)" ;;
  esac
  case "$(get "$OUT" RECOMMENDATION)" in
    "close"*) fail "V4/$SH" "close proposed on another author's issue" ;;
  esac
  case "$(get "$OUT" PRIORITY_NOTE)" in
    *"@cory"*"left as is"*) : ;; *) fail "V4/$SH" "priority disagreement not phrased as a note to the author: $(get "$OUT" PRIORITY_NOTE)" ;;
  esac
  OUT=$(run_block "$SH" "$SOCIAL_BLOCK" "ISSUE_AUTHOR=michael" "ME=michael" "VERDICT='already-fixed-by #7'" "CANONICAL='#7'" "BOARD_PRIORITY=Medium" "PRIORITY=High")
  [ "$(get "$OUT" SELF_AUTHORED)" = 1 ] || fail "V4/$SH" "running user not marked self"
  case "$(get "$OUT" RECOMMENDATION)" in
    "close"*"#7"*) : ;; *) fail "V4/$SH" "self-authored fixed issue should recommend close: $(get "$OUT" RECOMMENDATION)" ;;
  esac
  [ -z "$(get "$OUT" PRIORITY_NOTE)" ] || fail "V4/$SH" "self-authored priority disagreement needs no note to the author"
  OUT=$(run_block "$SH" "$SOCIAL_BLOCK" "ISSUE_AUTHOR=" "ME=michael" "VERDICT=needed" "CANONICAL=null" "BOARD_PRIORITY=none" "PRIORITY=Low")
  [ "$(get "$OUT" SELF_AUTHORED)" = 0 ] || fail "V4/$SH" "deleted-account author must not count as self"
  [ -z "$(get "$OUT" RECOMMENDATION)" ] || fail "V4/$SH" "needed verdict should carry no recommendation"
  # the decision flag follows: another author's duplicate is their decision; the running user's is not
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT='likely-duplicate-of #12'" "CLASSIFICATION=idea" "SELF_AUTHORED=0" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = true ] || fail "V4/$SH" "other author's duplicate must need a decision"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT='likely-duplicate-of #12'" "CLASSIFICATION=idea" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = false ] || fail "V4/$SH" "own duplicate needs no decision label"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT=needed" "CLASSIFICATION=question" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = true ] || fail "V4/$SH" "a question is a decision"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT=needed" "CLASSIFICATION=bug" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = false ] || fail "V4/$SH" "a plain needed bug needs no decision"
  [ "$FAILS" = 0 ] && pass "V4/$SH" "social rule: no close for another author, note not field write, decision routed"

  # ---------- V5: noise needs a mechanical signal ----------
  printf 'body\n' > "$SANDBOX/body-9.md"
  for T in 'TODO in apps/frontend/.next/dev/server/chunks/ssr/x.js:2812' 'chore: regenerate domain/storage/_generated/queries.go' 'stray file in node_modules/foo'; do
    OUT=$(run_block "$SH" "$NOISE_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=9" "ISSUE_TITLE='$T'" "CLASSIFICATION=idea")
    [ "$(get "$OUT" CLASSIFICATION)" = noise ] || fail "V5/$SH" "path signal missed: $T"
  done
  for T in 'fix(build): recognize worktree caches' 'perf: the build output is slow' 'docs: dist tarball notes'; do
    OUT=$(run_block "$SH" "$NOISE_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=9" "ISSUE_TITLE='$T'" "CLASSIFICATION=idea")
    [ "$(get "$OUT" CLASSIFICATION)" = idea ] || fail "V5/$SH" "prose mention misread as noise: $T"
  done
  printf 'looks fine\n<!-- detent-intake:abc123 -->\n' > "$SANDBOX/body-9.md"
  OUT=$(run_block "$SH" "$NOISE_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=9" "ISSUE_TITLE='plain title'" "CLASSIFICATION=bug")
  [ "$(get "$OUT" CLASSIFICATION)" = noise ] || fail "V5/$SH" "fingerprint did not force noise"
  [ "$(get "$OUT" NOISE_SIGNAL)" = "detent-intake fingerprint" ] || fail "V5/$SH" "fingerprint signal not named"
  [ "$FAILS" = 0 ] && pass "V5/$SH" "noise only on a fingerprint or a build-output/_generated/node_modules path"
done

if [ "$FAILS" -gt 0 ]; then echo "issue-details-triage: $FAILS failure(s)"; exit 1; fi
echo "issue-details-triage: OK"
