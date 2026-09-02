#!/bin/bash
# Executes issue-details' ACTUAL blocks — extracted from SKILL.md, facts.md,
# triage.md, and execute.md, so the doc is the code under test — against
# fixtures and a stubbed pr_facts_gh. Every block is sourced under both bash
# and zsh, because agents run them in the user's shell. Scenarios:
#   V1 verdict vocabulary  → the four forms pass; a #N that never appeared in a
#                            search result, or any wording outside the
#                            vocabulary, downgrades to `unclear` with a note
#   V2 never max           → a proposed `max` clamps to xhigh; an existing
#                            block is reported (agree/disagree), never
#                            replaced; the extractor reads only the fence
#   V3 marker lookup       → no marker = create; one owned = edit by numeric
#                            id; a foreign login's marker = create; a quoted
#                            marker mid-body or a v10 marker = create; two
#                            owned = refuse
#   V4 social rule         → another author never gets a close, gets a
#                            decision; priority disagreement is a note; a
#                            deleted account is not self and not `@:`
#   V5 noise is mechanical → fingerprint or build-output path forces noise;
#                            prose mentioning "build" does not
#   V6 refresh + dispatch  → create / edit / conditional label / foreign
#                            marker / duplicate markers / stale marker /
#                            failed refresh / empty JSON / closed issue /
#                            changed issue / WRITE_OK=0 writes nothing
#   V7 --since             → malformed values exit 2; a URL parses and must
#                            be alone; the selection caps at the oldest 50
#                            with a warning
#   V8 rate gates          → Phase-0 gate exits 3 under errexit when below
#                            reserve; the per-issue gate stops the batch on
#                            core/GraphQL, sleeps (not stops) on search,
#                            stops on an unreadable rate_limit
#   V9 merged-PR sweep     → pages accumulate; truncation comes from the page
#                            cap or a failed page, never from timestamps
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
SK="$PLUGIN_DIR/skills/issue-details"
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
extract_blocks "$SK/SKILL.md"   "$SANDBOX/skill"
extract_blocks "$SK/facts.md"   "$SANDBOX/facts"
extract_blocks "$SK/triage.md"  "$SANDBOX/triage"
extract_blocks "$SK/execute.md" "$SANDBOX/execute"
pick() { grep -l "$1" "$SANDBOX"/$2.*.sh | head -1; }
ARGS_BLOCK=$(pick 'not an issue URL' skill)
GATE0_BLOCK=$(pick 'RG_RC=0' facts)
SINCE_BLOCK=$(pick 'since-all.json' facts)
ISSUEGH_BLOCK=$(pick '^issue_gh()' facts)
SWEEP_BLOCK=$(pick 'SWEEP_GQL=' facts)
MARKER_BLOCK=$(pick 'COMMENT_ACTION="create"' facts)
EXISTING_BLOCK=$(pick 'detent-agent' facts)
NOISE_BLOCK=$(pick 'NOISE_SIGNAL=""' facts)
GATE1_BLOCK=$(pick 'RL_SEARCH_RESET=' facts)
VERDICT_BLOCK=$(pick 'outside the verdict vocabulary' triage)
EFFORT_BLOCK=$(pick 'EFFORT_STANCE="agree"' triage)
SOCIAL_BLOCK=$(pick 'SELF_AUTHORED=1; else SELF_AUTHORED=0' triage)
DECISION_BLOCK=$(pick 'NEEDS_DECISION=false' triage)
REFRESH_BLOCK=$(pick 'pre-write refresh failed' execute)
DISPATCH_BLOCK=$(pick 'WROTE=""' execute)
for B in "$ARGS_BLOCK" "$GATE0_BLOCK" "$SINCE_BLOCK" "$ISSUEGH_BLOCK" "$SWEEP_BLOCK" "$MARKER_BLOCK" "$EXISTING_BLOCK" \
         "$NOISE_BLOCK" "$GATE1_BLOCK" "$VERDICT_BLOCK" "$EFFORT_BLOCK" "$SOCIAL_BLOCK" "$DECISION_BLOCK" \
         "$REFRESH_BLOCK" "$DISPATCH_BLOCK"; do
  [ -n "$B" ] || { echo "FAIL: a block extraction came up empty"; exit 1; }
  bash -n "$B"; zsh -n "$B"
done

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

# The stub every scenario runs against. It logs each call, fails when told to,
# and answers reads from STUB_* fixtures. Writes are logged and succeed.
STUB='
pr_facts_gh() {
  printf "%s\n" "$*" >> "${STUB_LOG:-/dev/null}"
  if [ "${STUB_FAIL:-0}" = 1 ]; then echo "HTTP 403: API rate limit exceeded" >&2; return 1; fi
  case "$*" in
    *"issue view"*)   printf "%s" "${STUB_ISSUE:-}" ;;
    *"issue list"*)   printf "%s" "${STUB_LIST:-}" ;;
    *"/comments?"*)   printf "%s" "${STUB_COMMENTS:-}" ;;
    *rate_limit*)     printf "%s" "${STUB_RATE:-}" ;;
    *graphql*)        STUB_PAGE=$(( $(cat "$STUB_LOG.page" 2>/dev/null || echo 0) + 1 )); printf "%s" "$STUB_PAGE" > "$STUB_LOG.page"
                      if [ "$STUB_PAGE" -gt "${STUB_PAGES_OK:-99}" ]; then echo "HTTP 502" >&2; return 1; fi
                      printf "%s" "$(eval "printf %s \"\${STUB_GQL_$STUB_PAGE:-}\"")" ;;
  esac
  return 0
}
pr_facts_rate_gate() { [ "${STUB_GATE_RC:-0}" = 0 ] || { echo "core 5/5000 < reserve 1000"; return "${STUB_GATE_RC}"; }; return 0; }
pr_facts_graphql_ok() { jq -e "(.errors // []) | length == 0" <<<"$1" >/dev/null 2>&1; }
'
VARS='CLASSIFICATION NOISE_SIGNAL VERDICT VERDICT_NOTE CANONICAL PROPOSED_EFFORT EFFORT EFFORT_STANCE EFFORT_NOTE SELF_AUTHORED AUTHOR_REF RECOMMENDATION PRIORITY_NOTE NEEDS_DECISION MARKER_ID MARKER_COUNT MARKER_UPDATED COMMENT_ACTION EXISTING_EFFORT WRITE_OK WRITE_NOTE WROTE STOP_BATCH STOP_REASON ISSUE_FAILED ISSUE_ERROR SHIPPED_TRUNCATED SWEEP_PAGE SINCE_TOTAL SINCE_ARG BASE_ARG URL_SLUG URL_HOST ISSUE_ARGS DO_DUP AS_JSON'
# run_block <shell> <block> <var-assignments...> — sources the block under the
# given shell with the stub and the assignments as preset state; prints the
# resulting variables as NAME=VALUE lines and, last, RC=<exit status>.
run_block() {
  local RB_SHELL="$1" RB_BLOCK="$2"; shift 2
  local RB_SCRIPT="$SANDBOX/run.$$.sh"
  {
    printf 'set -u\n'
    printf '%s\n' "$STUB"
    for KV in "$@"; do printf '%s\n' "$KV"; done
    printf 'RC=0; . "%s" || RC=$?\n' "$RB_BLOCK"
    printf 'for V in %s; do\n' "$VARS"
    printf '  eval "X=\\${$V-__unset__}"; printf "%%s=%%s\\n" "$V" "$X"\n'
    printf 'done; printf "RC=%%s\\n" "$RC"\n'
  } > "$RB_SCRIPT"
  "$RB_SHELL" "$RB_SCRIPT" 2>/dev/null || true
}
# run_script <shell> <block> — runs the block as a whole script (for exit codes)
run_script() {
  local RS_SHELL="$1" RS_BLOCK="$2"; shift 2
  local RS_SCRIPT="$SANDBOX/script.$$.sh"
  { printf '%s\n' "$STUB"; for KV in "$@"; do printf '%s\n' "$KV"; done; printf 'set -e\n'; cat "$RS_BLOCK"; printf '\nexit 0\n'; } > "$RS_SCRIPT"
  "$RS_SHELL" "$RS_SCRIPT" >/dev/null 2>&1; echo $?
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
  printf '## Plan\n\neffort: max\n\n```detent-agent\nschema: 1\neffort: medium\n```\n\n```yaml\neffort: xhigh\n```\n' > "$SANDBOX/body-1.md"
  OUT=$(run_block "$SH" "$EXISTING_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ "$(get "$OUT" EXISTING_EFFORT)" = medium ] || fail "V2/$SH" "extractor read outside the detent-agent fence: $(get "$OUT" EXISTING_EFFORT)"
  printf '## Plan\n\nno block here\n' > "$SANDBOX/body-1.md"
  OUT=$(run_block "$SH" "$EXISTING_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1")
  [ -z "$(get "$OUT" EXISTING_EFFORT)" ] || fail "V2/$SH" "no block should yield empty"
  [ "$FAILS" = 0 ] && pass "V2/$SH" "max never proposed; existing block reported, never replaced; fence-only extraction"

  # ---------- V3: marker comment lookup — owned, exact grammar ----------
  SHA=0123456789abcdef0123456789abcdef01234567
  jq -n --arg sha "$SHA" '[
    {id: 300, login: "someone", body: "unrelated", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"},
    {id: 301, login: "someone", body: ("quoting:\n<!-- issue-details:v1 dev=" + $sha + " -->\nnot mine"), created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z"},
    {id: 302, login: "other",   body: ("<!-- issue-details:v1 dev=" + $sha + " -->\nsomeone elses marker"), created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z"},
    {id: 303, login: "me",      body: ("<!-- issue-details:v10 dev=" + $sha + " -->\nfuture"), created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z"},
    {id: 304, login: "me",      body: "<!-- issue-details:v1 dev=abc -->\nbad sha", created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1" "ME=me")
  [ "$(get "$OUT" COMMENT_ACTION)" = create ] || fail "V3/$SH" "foreign / quoted / v10 / bad-sha markers must all be ignored: $(get "$OUT" COMMENT_ACTION)"
  [ -z "$(get "$OUT" MARKER_ID)" ] || fail "V3/$SH" "a non-owned or malformed marker matched: $(get "$OUT" MARKER_ID)"
  jq -n --arg sha "$SHA" '[
    {id: 400, login: "me", body: ("<!-- issue-details:v1 dev=" + $sha + " -->\n## Issue details"), created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-03T00:00:00Z"},
    {id: 350, login: "x",  body: "hello", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1" "ME=me")
  [ "$(get "$OUT" COMMENT_ACTION)" = edit ] || fail "V3/$SH" "one owned marker should be edit"
  [ "$(get "$OUT" MARKER_ID)" = 400 ] || fail "V3/$SH" "wrong marker id: $(get "$OUT" MARKER_ID)"
  [ "$(get "$OUT" MARKER_UPDATED)" = "2026-01-03T00:00:00Z" ] || fail "V3/$SH" "snapshot updated_at not captured"
  jq -n --arg sha "$SHA" '[
    {id: 500, login: "me", body: ("<!-- issue-details:v1 dev=" + $sha + " -->\nnewer"), created_at: "2026-01-05T00:00:00Z", updated_at: "2026-01-05T00:00:00Z"},
    {id: 400, login: "me", body: ("<!-- issue-details:v1 dev=" + $sha + " -->\nolder"), created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}
  ]' > "$SANDBOX/comments-1.json"
  OUT=$(run_block "$SH" "$MARKER_BLOCK" "RUN_DIR='$SANDBOX'" "ISSUE_NUM=1" "ME=me")
  [ "$(get "$OUT" COMMENT_ACTION)" = refuse ] || fail "V3/$SH" "two owned markers must refuse, got $(get "$OUT" COMMENT_ACTION)"
  [ "$(get "$OUT" MARKER_COUNT)" = 2 ] || fail "V3/$SH" "duplicate markers not counted"
  grep -q 'delete all but one by hand' "$SANDBOX/warnings.txt" || fail "V3/$SH" "refusal did not name the manual cleanup"
  [ "$FAILS" = 0 ] && pass "V3/$SH" "marker lookup: owned + exact grammar; create / edit / refuse"

  # ---------- V4: the social rule ----------
  OUT=$(run_block "$SH" "$SOCIAL_BLOCK" "ISSUE_AUTHOR=cory" "ME=michael" "VERDICT='likely-duplicate-of #12'" "CANONICAL='#12'" "BOARD_PRIORITY=Medium" "PRIORITY=High")
  [ "$(get "$OUT" SELF_AUTHORED)" = 0 ] || fail "V4/$SH" "other author marked self"
  case "$(get "$OUT" RECOMMENDATION)" in
    *"@cory"*) : ;; *) fail "V4/$SH" "other author's recommendation not addressed to them: $(get "$OUT" RECOMMENDATION)" ;;
  esac
  case "$(get "$OUT" RECOMMENDATION)$(get "$OUT" PRIORITY_NOTE)" in
    *close*|*park*) fail "V4/$SH" "close/park proposed on another author's issue" ;;
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
  OUT=$(run_block "$SH" "$SOCIAL_BLOCK" "ISSUE_AUTHOR=" "ME=michael" "VERDICT='likely-duplicate-of #12'" "CANONICAL='#12'" "BOARD_PRIORITY=none" "PRIORITY=Low")
  [ "$(get "$OUT" SELF_AUTHORED)" = 0 ] || fail "V4/$SH" "deleted-account author must not count as self"
  case "$(get "$OUT" RECOMMENDATION)" in
    *"for @:"*) fail "V4/$SH" "deleted account rendered as a dangling @: $(get "$OUT" RECOMMENDATION)" ;;
    *"account deleted"*) : ;; *) fail "V4/$SH" "deleted account not named as such: $(get "$OUT" RECOMMENDATION)" ;;
  esac
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT='likely-duplicate-of #12'" "CLASSIFICATION=idea" "SELF_AUTHORED=0" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = true ] || fail "V4/$SH" "other author's duplicate must need a decision"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT='likely-duplicate-of #12'" "CLASSIFICATION=idea" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = false ] || fail "V4/$SH" "own duplicate needs no decision label"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT=needed" "CLASSIFICATION=question" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = true ] || fail "V4/$SH" "a question is a decision"
  OUT=$(run_block "$SH" "$DECISION_BLOCK" "VERDICT=needed" "CLASSIFICATION=bug" "SELF_AUTHORED=1" "DECISION_REQUIRED=0")
  [ "$(get "$OUT" NEEDS_DECISION)" = false ] || fail "V4/$SH" "a plain needed bug needs no decision"
  [ "$FAILS" = 0 ] && pass "V4/$SH" "social rule: no close/park for another author, note not field write, decision routed"

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

  # ---------- V6: refresh (fail closed) + guarded dispatcher ----------
  ISSUE_OPEN='{"state":"OPEN","updatedAt":"2026-02-01T00:00:00Z"}'
  ISSUE_CLOSED='{"state":"CLOSED","updatedAt":"2026-02-01T00:00:00Z"}'
  ISSUE_MOVED='{"state":"OPEN","updatedAt":"2026-02-02T00:00:00Z"}'
  C_NONE='[[{"id":1,"user":{"login":"x"},"body":"hi","updated_at":"2026-01-01T00:00:00Z"}]]'
  C_MINE="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nmine\",\"updated_at\":\"2026-01-03T00:00:00Z\"}]]"
  C_MINE_EDITED="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nmine\",\"updated_at\":\"2026-01-09T00:00:00Z\"}]]"
  C_FOREIGN="[[{\"id\":401,\"user\":{\"login\":\"other\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\ntheirs\",\"updated_at\":\"2026-01-03T00:00:00Z\"}]]"
  C_TWO="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\na\",\"updated_at\":\"2026-01-03T00:00:00Z\"},{\"id\":500,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nb\",\"updated_at\":\"2026-01-04T00:00:00Z\"}]]"
  printf 'draft\n' > "$SANDBOX/comment-1.md"
  COMMON=("RUN_DIR='$SANDBOX'" "ISSUE_NUM=1" "SLUG=o/r" "HOST=h" "ME=me" "ISSUE_UPDATED=2026-02-01T00:00:00Z" "STUB_LOG='$SANDBOX/log'")
  refresh() { : > "$SANDBOX/log"; run_block "$SH" "$REFRESH_BLOCK" "${COMMON[@]}" "$@"; }
  # create, clean
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_NONE'")
  [ "$(get "$OUT" WRITE_OK)" = 1 ] || fail "V6/$SH" "clean create refused: $(get "$OUT" WRITE_NOTE)"
  # create, but a foreign marker exists → still create (theirs is not ours)
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_FOREIGN'")
  [ "$(get "$OUT" WRITE_OK)" = 1 ] || fail "V6/$SH" "foreign marker must not block our create: $(get "$OUT" WRITE_NOTE)"
  # create, but our marker appeared since the read
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_MINE'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "create with a marker that appeared must be refused"
  # edit, clean
  OUT=$(refresh "COMMENT_ACTION=edit" "MARKER_ID=400" "MARKER_UPDATED=2026-01-03T00:00:00Z" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_MINE'")
  [ "$(get "$OUT" WRITE_OK)" = 1 ] || fail "V6/$SH" "clean edit refused: $(get "$OUT" WRITE_NOTE)"
  # edit, marker edited since the read
  OUT=$(refresh "COMMENT_ACTION=edit" "MARKER_ID=400" "MARKER_UPDATED=2026-01-03T00:00:00Z" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_MINE_EDITED'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "stale marker must be refused"
  # duplicate owned markers
  OUT=$(refresh "COMMENT_ACTION=edit" "MARKER_ID=400" "MARKER_UPDATED=2026-01-03T00:00:00Z" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_TWO'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "duplicate owned markers must be refused"
  case "$(get "$OUT" WRITE_NOTE)" in *"delete all but one"*) : ;; *) fail "V6/$SH" "duplicate markers must name manual cleanup" ;; esac
  # closed issue
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_CLOSED'" "STUB_COMMENTS='$C_NONE'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "closed issue must never be written"
  # issue changed since evaluation
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_MOVED'" "STUB_COMMENTS='$C_NONE'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "changed updatedAt must be refused"
  # API failure → fail closed
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_FAIL=1")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "failed refresh must fail closed"
  # empty JSON → fail closed (jq on empty input exits 0 without -e)
  OUT=$(refresh "COMMENT_ACTION=create" "MARKER_ID=" "MARKER_UPDATED=" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS=")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "empty comments response must fail closed"
  # refuse action never becomes a write
  OUT=$(refresh "COMMENT_ACTION=refuse" "MARKER_ID=400" "MARKER_UPDATED=2026-01-03T00:00:00Z" "STUB_ISSUE='$ISSUE_OPEN'" "STUB_COMMENTS='$C_MINE'")
  [ "$(get "$OUT" WRITE_OK)" = 0 ] || fail "V6/$SH" "refuse action must not write"
  # dispatcher: WRITE_OK=0 writes nothing at all
  dispatch() { : > "$SANDBOX/log"; run_block "$SH" "$DISPATCH_BLOCK" "${COMMON[@]}" "$@" >/dev/null; cat "$SANDBOX/log"; }
  LOG=$(dispatch "WRITE_OK=0" "COMMENT_ACTION=create" "MARKER_ID=" "NEEDS_DECISION=true" "WRITE_NOTE=x")
  [ -z "$LOG" ] || fail "V6/$SH" "WRITE_OK=0 must issue no gh call: $LOG"
  # create + no decision → exactly one call, a comment
  LOG=$(dispatch "WRITE_OK=1" "COMMENT_ACTION=create" "MARKER_ID=" "NEEDS_DECISION=false" "WRITE_NOTE=")
  [ "$(printf '%s\n' "$LOG" | grep -c .)" = 1 ] || fail "V6/$SH" "create without decision must be one call: $LOG"
  case "$LOG" in *"issue comment 1 -R o/r"*) : ;; *) fail "V6/$SH" "create did not post a comment: $LOG" ;; esac
  # create + decision → comment then label, no PATCH
  LOG=$(dispatch "WRITE_OK=1" "COMMENT_ACTION=create" "MARKER_ID=" "NEEDS_DECISION=true" "WRITE_NOTE=")
  [ "$(printf '%s\n' "$LOG" | grep -c .)" = 2 ] || fail "V6/$SH" "create with decision must be two calls: $LOG"
  case "$LOG" in *PATCH*) fail "V6/$SH" "create run issued a PATCH" ;; esac
  case "$LOG" in *"--add-label triage:needs-decision"*) : ;; *) fail "V6/$SH" "decision label missing: $LOG" ;; esac
  printf '%s\n' "$LOG" | tail -1 | grep -q 'add-label' || fail "V6/$SH" "label must come after the comment"
  # edit + no decision → exactly one PATCH on the marker id
  LOG=$(dispatch "WRITE_OK=1" "COMMENT_ACTION=edit" "MARKER_ID=400" "NEEDS_DECISION=false" "WRITE_NOTE=")
  [ "$(printf '%s\n' "$LOG" | grep -c .)" = 1 ] || fail "V6/$SH" "edit must be one call: $LOG"
  case "$LOG" in *"-X PATCH repos/o/r/issues/comments/400"*) : ;; *) fail "V6/$SH" "edit did not PATCH the marker: $LOG" ;; esac
  case "$LOG" in *"issue comment"*) fail "V6/$SH" "edit run posted a second comment" ;; esac
  # refuse action with WRITE_OK somehow 1 → still no write
  LOG=$(dispatch "WRITE_OK=1" "COMMENT_ACTION=refuse" "MARKER_ID=400" "NEEDS_DECISION=true" "WRITE_NOTE=")
  [ -z "$LOG" ] || fail "V6/$SH" "refuse must issue no gh call: $LOG"
  [ "$FAILS" = 0 ] && pass "V6/$SH" "refresh fails closed on stale/closed/changed/failed/empty; dispatcher writes one comment, label only on decision"

  # ---------- V7: --since validation, URL parsing, the 50 cap ----------
  args_rc() {  # $1 = argument string, substituted for $ARGUMENTS the way the driver does
    sed "s|\$ARGUMENTS|$1|" "$ARGS_BLOCK" > "$SANDBOX/args.sh"
    run_script "$SH" "$SANDBOX/args.sh"
  }
  for BAD in '--since 1oopsd' '--since 0d' '--since 7' '--since' 'abc' '' '3094 --since 7d' 'https://github.com/o/r/pull/5' '3094 https://github.com/o/r/issues/5'; do
    [ "$(args_rc "$BAD")" = 2 ] || fail "V7/$SH" "'$BAD' should exit 2"
  done
  for GOOD in '--since 7d' '3094' '3094 3087 --json' 'https://github.com/o/r/issues/5'; do
    [ "$(args_rc "$GOOD")" = 0 ] || fail "V7/$SH" "'$GOOD' should parse"
  done
  sed "s|\$ARGUMENTS|https://github.com/o/r/issues/5|" "$ARGS_BLOCK" > "$SANDBOX/args.sh"
  OUT=$(run_block "$SH" "$SANDBOX/args.sh")
  [ "$(get "$OUT" URL_SLUG)" = "o/r" ] && [ "$(get "$OUT" URL_HOST)" = "github.com" ] && [ "$(get "$OUT" ISSUE_ARGS)" = " 5" ] \
    || fail "V7/$SH" "URL not parsed into host/slug/number: $(get "$OUT" URL_SLUG) $(get "$OUT" ISSUE_ARGS)"
  # the cap: 60 in-window issues, newest first as gh returns them → oldest 50 selected, warning emitted
  TODAY=$(date -u +%Y-%m-%d)   # inside any --since window; the boundary is computed from now
  LIST=$(jq -nc --arg d "$TODAY" '[range(60) | {number: (1000 + .), createdAt: ($d + "T00:" + ("0" + tostring)[-2:] + ":00Z")}] | reverse')
  : > "$SANDBOX/warnings.txt"
  OUT=$(run_block "$SH" "$SINCE_BLOCK" "RUN_DIR='$SANDBOX'" "SLUG=o/r" "SINCE_ARG=30d" "STUB_LIST='$LIST'")
  [ "$(get "$OUT" SINCE_TOTAL)" = 60 ] || fail "V7/$SH" "expected 60 in-window matches, got $(get "$OUT" SINCE_TOTAL)"
  [ "$(wc -l < "$SANDBOX/selected.txt" | tr -d ' ')" = 50 ] || fail "V7/$SH" "cap not applied: $(wc -l < "$SANDBOX/selected.txt") selected"
  FIRST=$(head -1 "$SANDBOX/selected.txt"); OLDEST=$(jq -r 'min_by(.createdAt) | .number' <<<"$LIST")
  [ "$FIRST" = "$OLDEST" ] || fail "V7/$SH" "selection must start at the oldest issue ($OLDEST), got $FIRST"
  grep -q 'evaluating the oldest 50' "$SANDBOX/warnings.txt" || fail "V7/$SH" "cap warning not recorded"
  [ "$FAILS" = 0 ] && pass "V7/$SH" "--since strict; URL parsed and alone; oldest-50 cap with warning"

  # ---------- V8: the two rate gates ----------
  [ "$(run_script "$SH" "$GATE0_BLOCK" "HOST=h" "STUB_GATE_RC=1")" = 3 ] || fail "V8/$SH" "phase-0 gate below reserve must exit 3"
  [ "$(run_script "$SH" "$GATE0_BLOCK" "HOST=h" "STUB_GATE_RC=2")" = 3 ] || fail "V8/$SH" "phase-0 gate unreadable must exit 3"
  [ "$(run_script "$SH" "$GATE0_BLOCK" "HOST=h" "STUB_GATE_RC=0")" = 0 ] || fail "V8/$SH" "phase-0 gate clean must continue"
  G1=("RUN_DIR='$SANDBOX'" "HOST=h" "REST_RESERVE=1000" "GRAPHQL_RESERVE=1000" "SEARCH_RESERVE=5" "STOP_BATCH=0" "STOP_REASON=" "ISSUE_FAILED=0" "STUB_LOG='$SANDBOX/log'")
  RATE_OK='{"resources":{"core":{"remaining":4000},"graphql":{"remaining":4000},"search":{"remaining":29,"reset":0}}}'
  RATE_CORE='{"resources":{"core":{"remaining":12},"graphql":{"remaining":4000},"search":{"remaining":29,"reset":0}}}'
  RATE_GQL='{"resources":{"core":{"remaining":4000},"graphql":{"remaining":900},"search":{"remaining":29,"reset":0}}}'
  RATE_SEARCH='{"resources":{"core":{"remaining":4000},"graphql":{"remaining":4000},"search":{"remaining":1,"reset":1}}}'
  ( . "$ISSUEGH_BLOCK" ) 2>/dev/null || true
  gate1() { run_block "$SH" "$SANDBOX/gate1.sh" "${G1[@]}" "$@"; }
  { cat "$ISSUEGH_BLOCK"; cat "$GATE1_BLOCK"; } > "$SANDBOX/gate1.sh"
  OUT=$(gate1 "STUB_RATE='$RATE_OK'");     [ "$(get "$OUT" STOP_BATCH)" = 0 ] && [ "$(get "$OUT" ISSUE_FAILED)" = 0 ] || fail "V8/$SH" "healthy gate must not stop"
  OUT=$(gate1 "STUB_RATE='$RATE_CORE'");   [ "$(get "$OUT" STOP_BATCH)" = 1 ] && [ "$(get "$OUT" ISSUE_FAILED)" = 1 ] || fail "V8/$SH" "core below reserve must stop the batch"
  OUT=$(gate1 "STUB_RATE='$RATE_GQL'");    [ "$(get "$OUT" STOP_BATCH)" = 1 ] || fail "V8/$SH" "graphql below reserve must stop the batch"
  OUT=$(gate1 "STUB_RATE='$RATE_SEARCH'"); [ "$(get "$OUT" STOP_BATCH)" = 0 ] || fail "V8/$SH" "search below reserve must sleep, not stop"
  OUT=$(gate1 "STUB_FAIL=1");              [ "$(get "$OUT" STOP_BATCH)" = 1 ] || fail "V8/$SH" "unreadable rate_limit must stop the batch"
  # issue_gh itself: a terminal 403 sets STOP_BATCH and ISSUE_ERROR when written to a file
  printf 'issue_gh issue view 1 -R o/r > "$RUN_DIR/x.json" || ISSUE_FAILED=1\n' > "$SANDBOX/ig.sh"
  { cat "$ISSUEGH_BLOCK"; cat "$SANDBOX/ig.sh"; } > "$SANDBOX/ig-run.sh"
  OUT=$(run_block "$SH" "$SANDBOX/ig-run.sh" "${G1[@]}" "STUB_FAIL=1")
  [ "$(get "$OUT" STOP_BATCH)" = 1 ] && [ "$(get "$OUT" ISSUE_FAILED)" = 1 ] || fail "V8/$SH" "a 403 through issue_gh must stop the batch and fail the issue"
  case "$(get "$OUT" ISSUE_ERROR)" in *403*) : ;; *) fail "V8/$SH" "ISSUE_ERROR should carry the error line: $(get "$OUT" ISSUE_ERROR)" ;; esac
  [ "$FAILS" = 0 ] && pass "V8/$SH" "phase-0 gate exits 3 under errexit; per-issue gate stops on core/graphql, sleeps on search; 403 stops the batch"

  # ---------- V9: merged-PR sweep pagination ----------
  jq -n '{createdAt: "2026-01-10T00:00:00Z"}' > "$SANDBOX/issue-7.json"
  jq -n '{createdAt: "2026-01-05T00:00:00Z"}' > "$SANDBOX/issue-8.json"
  P1='{"data":{"search":{"issueCount":150,"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"number":10,"title":"a","mergedAt":"2026-01-06T00:00:00Z","closingIssuesReferences":{"nodes":[{"number":8}]}}]}}}'
  P2='{"data":{"search":{"issueCount":150,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":11,"title":"b","mergedAt":"2026-01-07T00:00:00Z","closingIssuesReferences":{"nodes":[]}}]}}}'
  PN='{"data":{"search":{"issueCount":900,"pageInfo":{"hasNextPage":true,"endCursor":"c"},"nodes":[{"number":12,"title":"c","mergedAt":"2026-01-08T00:00:00Z","closingIssuesReferences":{"nodes":[]}}]}}}'
  SW=("RUN_DIR='$SANDBOX'" "SLUG=o/r" "BASE=dev" "HOST=h" "STUB_LOG='$SANDBOX/log'")
  : > "$SANDBOX/warnings.txt"; rm -f "$SANDBOX/log.page"
  OUT=$(run_block "$SH" "$SWEEP_BLOCK" "${SW[@]}" "STUB_GQL_1='$P1'" "STUB_GQL_2='$P2'")
  [ "$(get "$OUT" SHIPPED_TRUNCATED)" = false ] || fail "V9/$SH" "two pages fully read must not be truncated"
  [ "$(jq length "$SANDBOX/shipped.json")" = 2 ] || fail "V9/$SH" "both pages must accumulate: $(cat "$SANDBOX/shipped.json")"
  [ "$(jq -c '.[0].issues' "$SANDBOX/shipped.json")" = "[8]" ] || fail "V9/$SH" "closingIssuesReferences not extracted"
  grep -q 'merged:>=2026-01-05T00:00:00Z' "$SANDBOX/log" || fail "V9/$SH" "window must start at the earliest selected createdAt: $(cat "$SANDBOX/log")"
  rm -f "$SANDBOX/log.page"
  OUT=$(run_block "$SH" "$SWEEP_BLOCK" "${SW[@]}" "STUB_GQL_1='$PN'" "STUB_GQL_2='$PN'" "STUB_GQL_3='$PN'" "STUB_GQL_4='$PN'" "STUB_GQL_5='$PN'" "STUB_GQL_6='$PN'")
  [ "$(get "$OUT" SHIPPED_TRUNCATED)" = true ] || fail "V9/$SH" "hasNextPage at the page cap must report truncation"
  [ "$(get "$OUT" SWEEP_PAGE)" = 5 ] || fail "V9/$SH" "page cap is 5, ran $(get "$OUT" SWEEP_PAGE)"
  rm -f "$SANDBOX/log.page"
  OUT=$(run_block "$SH" "$SWEEP_BLOCK" "${SW[@]}" "STUB_PAGES_OK=0")
  [ "$(get "$OUT" SHIPPED_TRUNCATED)" = true ] || fail "V9/$SH" "a failed page must report truncation"
  [ "$(jq length "$SANDBOX/shipped.json")" = 0 ] || fail "V9/$SH" "a failed first page must yield an empty sweep, not stale data"
  [ "$FAILS" = 0 ] && pass "V9/$SH" "sweep window from earliest filing; truncation from pagination only"
done

if [ "$FAILS" -gt 0 ]; then echo "issue-details-triage: $FAILS failure(s)"; exit 1; fi
echo "issue-details-triage: OK"
