#!/bin/bash
# Drives scripts/issue-details.sh — the deterministic half of the
# issue-details skill — against a stubbed `gh`/`git`. The script is sourced,
# so the shipped code is what runs; only GitHub responses are scripted.
#   V1  verdict vocabulary     closed; unseen numbers / foreign wording → unclear + note
#   V2  never max              proposed max clamps; an existing block is reported, never replaced
#   V3  marker lookup          owned + exact first-line grammar; create / edit / refuse
#   V4  social rule            no close/park for another author; note not field write; decision routed
#   V5  noise is mechanical    fingerprint or build-output path forces noise; prose does not
#   V6  refresh + dispatch     fail-closed on every drift; bare POST never retried; label only on decision
#   V7  arguments + selection  strict --since; URLs; explicit numbers AND --since materialise selected.txt; oldest-50 cap
#   V8  rate gates             below reserve / malformed / unreadable stop the batch; search sleeps
#   V9  merged-PR sweep        window from earliest filing; truncation from pagination; GraphQL errors are failures
#   V11 noise skips search     zero search calls on noise or --no-dup-search; exactly two otherwise
#   V12 end to end         collect → judge → finalize → post for two issues, explicit and --since;
#                              exact gh call sequence; each comment carries its own title; facts.json
#                              matches schema 1 (jq -e); a PATCH failure and a label failure each get
#                              one attempt and one confirming GET; a gate failure on the second issue
#                              leaves the first written and the second unevaluated with no call after
#                              the failed gate
#   V13 judgement boundary prose is validated and sanitised: non-object evidence → unevaluated;
#                              newlines collapsed, @mentions backticked, unfetched #N marked; a close
#                              verb on another author's issue → unevaluated; missing judgement →
#                              unevaluated in report and facts.json
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$PLUGIN_DIR/scripts/issue-details.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
bash -n "$SCRIPT"
FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }
SHA=0123456789abcdef0123456789abcdef01234567

# ---------------------------------------------------------------- stubs ----
# The stub answers every read from $STUB_DIR fixtures and logs every call.
STUB_DIR="$SANDBOX/stub"; mkdir -p "$STUB_DIR"
export STUB_DIR STUB_LOG="$SANDBOX/gh.log"
stub_env() { cat <<'STUB'
gh() {
  printf '%s\n' "$*" >> "$STUB_LOG"
  local n
  case "$*" in
    "repo view --json nameWithOwner"*) printf 'o/r' ;;
    "repo view --json url"*) printf '%s' "${STUB_HOST:-github.com}" ;;
    "repo view --json defaultBranchRef"*) printf 'main' ;;
    "auth status"*) : ;;
    *" user --jq .login") printf 'me' ;;
    *rate_limit*)
      n=$(( $(cat "$STUB_DIR/rate.count" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$STUB_DIR/rate.count"
      if [ "$n" = "${STUB_RATE_FAIL_AT:-0}" ]; then echo "HTTP 403: API rate limit exceeded" >&2; return 1; fi
      if [ -n "${STUB_RATE_OVERRIDE:-}" ]; then printf '%s' "$STUB_RATE_OVERRIDE"; else printf '{"resources":{"core":{"remaining":4000},"graphql":{"remaining":4000},"search":{"remaining":29,"reset":0}}}'; fi ;;
    "pr list -R o/r --state open --limit 100 --json number,title,isDraft,closingIssuesReferences") cat "$STUB_DIR/open-prs.json" ;;
    "label list"*) cat "$STUB_DIR/labels.json" ;;
    "issue list -R o/r --label "*) cat "$STUB_DIR/goal-issues.json" ;;
    "issue list -R o/r --state open --limit 500"*) cat "$STUB_DIR/since.json" ;;
    "issue view "*" --json number,title,body,author"*)
      n=$(printf '%s' "$*" | sed -E 's/^issue view ([0-9]+) .*/\1/'); [ -f "$STUB_DIR/issue-$n.json" ] && cat "$STUB_DIR/issue-$n.json" || { echo "HTTP 404: Not Found" >&2; return 1; } ;;
    "issue view "*" --json state,updatedAt,labels")
      n=$(printf '%s' "$*" | sed -E 's/^issue view ([0-9]+) .*/\1/'); [ -f "$STUB_DIR/refresh-$n.json" ] && cat "$STUB_DIR/refresh-$n.json" || jq -c '{state, updatedAt, labels}' "$STUB_DIR/issue-$n.json" ;;
    *"graphql"*"search(query"*)
      n=$(( $(cat "$STUB_DIR/page.count" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$STUB_DIR/page.count"
      [ -f "$STUB_DIR/sweep-$n.json" ] && cat "$STUB_DIR/sweep-$n.json" || printf '{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
    *"graphql"*"projectItems"*)
      n=$(printf '%s' "$*" | tr '\n' ' ' | sed -E 's/.* -F num=([0-9]+).*/\1/'); [ -f "$STUB_DIR/board-$n.json" ] && cat "$STUB_DIR/board-$n.json" || printf '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' ;;
    *"-X POST"*) if [ "${STUB_POST_FAIL:-0}" = 1 ]; then echo "EOF" >&2; return 1; fi; printf '{}' ;;
    *"-X PATCH"*) if [ "${STUB_PATCH_FAIL:-0}" = 1 ]; then echo "HTTP 502" >&2; return 1; fi; printf '{}' ;;
    "api --hostname github.com repos/o/r/issues/comments/"*)
      n=$(printf '%s' "$*" | sed -E 's#.*/comments/([0-9]+).*#\1#'); [ -f "$STUB_DIR/comment-after-$n.json" ] && cat "$STUB_DIR/comment-after-$n.json" || printf '{"body":"something else"}' ;;
    *"issue edit "*"--add-label"*) if [ "${STUB_LABEL_FAIL:-0}" = 1 ]; then echo "HTTP 502" >&2; return 1; fi ;;
    "api --hostname github.com repos/o/r/issues/"*"/labels")
      n=$(printf '%s' "$*" | sed -E 's#.*/issues/([0-9]+)/labels.*#\1#'); [ -f "$STUB_DIR/labels-after-$n.json" ] && cat "$STUB_DIR/labels-after-$n.json" || printf '[]' ;;
    *"/comments?"*)
      n=$(printf '%s' "$*" | sed -E 's#.*/issues/([0-9]+)/comments.*#\1#')
      if grep -q 'X POST' "$STUB_LOG" && [ -f "$STUB_DIR/comments-after-$n.json" ]; then cat "$STUB_DIR/comments-after-$n.json"
      elif [ -f "$STUB_DIR/comments-$n.json" ]; then cat "$STUB_DIR/comments-$n.json"; else printf '[[]]'; fi ;;
    "search issues"*) printf '[]' ;;
    "pr list -R o/r --state open --limit 10 --search"*) printf '[{"number":90,"title":"x","url":"u","isDraft":false,"closingIssuesReferences":[]}]' ;;   # a fetched candidate, so #90 in prose stays unmarked
    *) echo "stub: unexpected gh $*" >&2; return 1 ;;
  esac
}
git() { case "$*" in "ls-remote origin refs/heads/dev") printf '%s\trefs/heads/dev\n' "$SHA" ;; *) command git "$@" ;; esac; }
STUB
}
# with_script <shell-code>: run code in a subshell with the stub and the script's functions loaded
with_script() { ( export SHA; eval "$(stub_env)"; . "$SCRIPT"; eval "$1" ); }
reset_stub() { : > "$STUB_LOG"; rm -f "$STUB_DIR"/*.count "$STUB_DIR"/*.json; printf '[]' > "$STUB_DIR/open-prs.json"; printf '[]' > "$STUB_DIR/labels.json"; printf '[]' > "$STUB_DIR/goal-issues.json"; }
mkissue() {  # <n> <title> <author> <labels-json> <body> [updatedAt]
  jq -n --argjson n "$1" --arg t "$2" --arg a "$3" --argjson l "$4" --arg b "$5" --arg u "${6:-2026-02-01T00:00:00Z}" \
    '{number:$n, title:$t, body:$b, author:(if $a == "" then null else {login:$a} end), createdAt:"2026-01-10T00:00:00Z", updatedAt:$u,
      labels:($l | map({name: .})), state:"OPEN", url:("https://github.com/o/r/issues/" + ($n|tostring)), milestone:null}' > "$STUB_DIR/issue-$1.json"
}
RUN="$SANDBOX/run"; rm -rf "$RUN"; mkdir -p "$RUN"
run_env="RUN_DIR='$RUN'; HOST=github.com; SLUG=o/r; OWNER=o; NAME=r; ME=me; BASE=dev; BASE_SHA=$SHA; PROJECT_SLUG=PVT_x; GRAPHQL_RESERVE=1000; REST_RESERVE=1000; DO_DUP=1; : > \"$RUN/warnings.txt\"; : > \"$RUN/unevaluated.tsv\"; : > \"$RUN/failed.txt\""

# ---------- V1: closed verdict vocabulary ----------
for CASE in 'needed|needed|null' 'unclear|unclear|null' 'likely-duplicate-of #12|likely-duplicate-of #12|#12' 'already-fixed-by #7|already-fixed-by #7|#7' \
  'likely-duplicate-of #99|unclear|null' 'already-fixed-by #12|unclear|null' 'likely-duplicate-of #7|unclear|null' 'superseded-by #12|unclear|null' \
  'needed (probably)|unclear|null' 'likely-duplicate-of #12 and #40|unclear|null'; do
  IN="${CASE%%|*}"; REST="${CASE#*|}"; WANT="${REST%%|*}"; WANT_CANON="${REST#*|}"
  OUT=$(with_script "id_verdict_guard '$IN' '[12,40]' '[7]'")
  GOT="${OUT%%|*}"; GOT_CANON=$(printf '%s' "$OUT" | cut -d'|' -f2); NOTE="${OUT##*|}"
  [ "$GOT" = "$WANT" ] && [ "$GOT_CANON" = "$WANT_CANON" ] || fail V1 "'$IN' -> '$GOT' / '$GOT_CANON' (want '$WANT' / '$WANT_CANON')"
  if [ "$WANT" = unclear ] && [ "$IN" != unclear ] && [ -z "$NOTE" ]; then fail V1 "'$IN' downgraded without a note"; fi
done
[ "$FAILS" = 0 ] && pass V1 "vocabulary closed; unseen numbers and foreign wording downgrade with a note"

# ---------- V2: never max; existing block reported, never replaced ----------
OUT=$(with_script "id_effort_guard max ''");        [ "${OUT%%|*}" = xhigh ] && [ -n "${OUT##*|}" ] || fail V2 "max did not clamp with a note: $OUT"
OUT=$(with_script "id_effort_guard high max");      [ "${OUT%%|*}" = high ] && [ "$(printf '%s' "$OUT" | cut -d'|' -f2)" = disagree ] || fail V2 "existing max must be reported as disagree, not adopted: $OUT"
OUT=$(with_script "id_effort_guard medium medium"); [ "$(printf '%s' "$OUT" | cut -d'|' -f2)" = agree ] || fail V2 "matching tiers should agree"
OUT=$(with_script "id_effort_guard enormous ''");   [ "${OUT%%|*}" = xhigh ] || fail V2 "foreign tier did not clamp"
reset_stub; mkissue 1 t me '[]' $'## Plan\n\neffort: max\n\n```detent-agent\nschema: 1\neffort: medium\n```\n\n```yaml\neffort: xhigh\n```'
with_script "$run_env; id_fetch 1" >/dev/null
[ "$(jq -r .existing_effort "$RUN/state-1.json")" = medium ] || fail V2 "extractor read outside the detent-agent fence: $(jq -r .existing_effort "$RUN/state-1.json")"
mkissue 1 t me '[]' $'## Plan\n\nno block here'; with_script "$run_env; id_fetch 1" >/dev/null
[ -z "$(jq -r .existing_effort "$RUN/state-1.json")" ] || fail V2 "no block should yield empty"
[ "$FAILS" = 0 ] && pass V2 "max never proposed; existing block reported, never replaced; fence-only extraction"

# ---------- V3: marker lookup — owned, exact first-line grammar ----------
comments() { jq -n --arg sha "$SHA" "$1" > "$STUB_DIR/comments-1.json"; }
comments '[[
  {id:300, user:{login:"someone"}, body:"unrelated", updated_at:"2026-01-01T00:00:00Z"},
  {id:301, user:{login:"someone"}, body:("quoting:\n<!-- issue-details:v1 dev=" + $sha + " -->\nnot mine"), updated_at:"2026-01-02T00:00:00Z"},
  {id:302, user:{login:"other"},   body:("<!-- issue-details:v1 dev=" + $sha + " -->\nsomeone elses"), updated_at:"2026-01-02T00:00:00Z"},
  {id:303, user:{login:"me"},      body:("<!-- issue-details:v10 dev=" + $sha + " -->\nfuture"), updated_at:"2026-01-02T00:00:00Z"},
  {id:304, user:{login:"me"},      body:"<!-- issue-details:v1 dev=abc -->\nbad sha", updated_at:"2026-01-02T00:00:00Z"},
  {id:305, user:{login:"me"},      body:("<!-- issue-details:v1 dev=" + $sha + " -->junk\ntrailing"), updated_at:"2026-01-02T00:00:00Z"},
  {id:306, user:{login:"me"},      body:("reply:\n<!-- issue-details:v1 dev=" + $sha + " -->\nowned, quoted on line 2"), updated_at:"2026-01-02T00:00:00Z"}]]'
with_script "$run_env; id_comments 1" >/dev/null
[ "$(jq -r .comment_action "$RUN/state-1.json")" = create ] || fail V3 "foreign / quoted / v10 / bad-sha / trailing-junk / line-2 markers must all be ignored: $(jq -r .comment_action "$RUN/state-1.json")"
[ "$(jq -r .marker_id "$RUN/state-1.json")" = null ] || fail V3 "a non-owned or malformed marker matched"
comments '[[{id:400, user:{login:"me"}, body:("<!-- issue-details:v1 dev=" + $sha + " -->\n## Issue details"), updated_at:"2026-01-03T00:00:00Z"},
            {id:350, user:{login:"x"},  body:"hello", updated_at:"2026-01-01T00:00:00Z"}]]'
with_script "$run_env; id_comments 1" >/dev/null
[ "$(jq -r .comment_action "$RUN/state-1.json")" = edit ] && [ "$(jq -r .marker_id "$RUN/state-1.json")" = 400 ] || fail V3 "one owned marker should be edit #400"
[ "$(jq -r .marker_updated "$RUN/state-1.json")" = "2026-01-03T00:00:00Z" ] || fail V3 "marker updated_at not captured"
[ "$(jq -c .comments_fingerprint "$RUN/state-1.json")" = '[{"id":350,"updated_at":"2026-01-01T00:00:00Z"},{"id":400,"updated_at":"2026-01-03T00:00:00Z"}]' ] || fail V3 "full comment fingerprint not captured: $(jq -c .comments_fingerprint "$RUN/state-1.json")"
comments '[[{id:500, user:{login:"me"}, body:("<!-- issue-details:v1 dev=" + $sha + " -->\nnewer"), updated_at:"2026-01-05T00:00:00Z"},
            {id:400, user:{login:"me"}, body:("<!-- issue-details:v1 dev=" + $sha + " -->\nolder"), updated_at:"2026-01-01T00:00:00Z"}]]'
with_script "$run_env; id_comments 1" >/dev/null 2>&1
[ "$(jq -r .comment_action "$RUN/state-1.json")" = refuse ] && [ "$(jq -r .marker_count "$RUN/state-1.json")" = 2 ] || fail V3 "two owned markers must refuse"
grep -q 'delete all but one by hand' "$RUN/warnings.txt" || fail V3 "refusal did not name the manual cleanup"
printf '[["junk"]]' > "$STUB_DIR/comments-1.json"
with_script "$run_env; id_comments 1 && echo OKAY" | grep -q OKAY && fail V3 "malformed comments must be a fetch failure"
[ "$FAILS" = 0 ] && pass V3 "marker lookup: owned + exact grammar; create / edit / refuse; full fingerprint; malformed = failure"

# ---------- V4: the social rule and needs_decision (finalize) ----------
mkstate() {  # <n> <author> <self:true|false> <board-priority> <verdict-candidates-open> <existing-effort>
  jq -n --argjson n "$1" --arg a "$2" --argjson s "$3" --arg bp "$4" --argjson open "$5" --arg eff "$6" \
    '{number:$n, evaluated:true, error:null, title:"t", author:$a, created_at:"2026-01-10T00:00:00Z", updated_at:"2026-02-01T00:00:00Z", state:"OPEN",
      url:"u", labels:[], body_path:"", existing_effort:$eff, comments_fingerprint:[], marker_count:0, marker_id:null, marker_updated:"", comment_action:"create",
      noise_signal:"", board_status:"Todo", board_priority:$bp, dedupe_skipped:0, terms:"a b c", candidates_open:$open, candidates_shipped:[7], fixed_by_unknown:[],
      in_flight:[], dup_issues:[], dup_prs:[], goal_refs:[], goal_own_label:null, self_authored:$s}' > "$RUN/state-$1.json"
}
mkjudge() { jq -n --arg c "$1" --arg v "$2" --arg p "$3" --arg e "$4" --argjson d "${5:-false}" '{classification:$c, verdict:$v, priority:$p, proposed_effort:$e, decision_required:$d, evidence:{classification:"x", priority:"y"}}' > "$RUN/judgement-$6.json"; }
: > "$RUN/goal-registry.tsv"; : > "$RUN/goal-labels.txt"; printf '1\n' > "$RUN/selected.txt"
mkstate 1 cory false Medium '[12]' ''; mkjudge idea 'likely-duplicate-of #12' High high false 1
with_script "$run_env; id_finalize_issue 1" >/dev/null
R="$RUN/result-1.json"
[ "$(jq -r .self_authored "$R")" = false ] || fail V4 "other author marked self"
case "$(jq -r .recommendation "$R")" in *"@cory"*) : ;; *) fail V4 "recommendation not addressed to the author: $(jq -r .recommendation "$R")" ;; esac
case "$(jq -r '.recommendation + .priority_note' "$R")" in *close*|*park*) fail V4 "close/park proposed on another author's issue" ;; esac
case "$(jq -r .priority_note "$R")" in *"@cory"*"left as is"*) : ;; *) fail V4 "priority disagreement not a note to the author" ;; esac
[ "$(jq -r .needs_decision "$R")" = true ] || fail V4 "other author's duplicate must need a decision"
grep -q 'close' "$RUN/comment-1.md" && fail V4 "the word close reached another author's comment"
mkstate 1 me true Medium '[12]' ''; mkjudge bug 'already-fixed-by #7' High high false 1
with_script "$run_env; id_finalize_issue 1" >/dev/null
case "$(jq -r .recommendation "$R")" in "close"*"#7"*) : ;; *) fail V4 "self-authored fixed issue should recommend close: $(jq -r .recommendation "$R")" ;; esac
[ "$(jq -r .priority_note "$R")" = null ] && [ "$(jq -r .needs_decision "$R")" = false ] || fail V4 "own fixed issue: no author note, no decision"
mkstate 1 '' false none '[12]' ''; mkjudge idea 'likely-duplicate-of #12' Low high false 1
with_script "$run_env; id_finalize_issue 1" >/dev/null
case "$(jq -r .recommendation "$R")" in *"for @:"*) fail V4 "deleted account rendered as @:" ;; *"account deleted"*) : ;; *) fail V4 "deleted account not named" ;; esac
mkstate 1 me true none '[]' ''; mkjudge question needed none medium false 1; with_script "$run_env; id_finalize_issue 1" >/dev/null
[ "$(jq -r .needs_decision "$R")" = true ] || fail V4 "a question is a decision"
mkstate 1 me true none '[]' ''; mkjudge bug needed High high false 1; with_script "$run_env; id_finalize_issue 1" >/dev/null
[ "$(jq -r .needs_decision "$R")" = false ] || fail V4 "a plain needed bug needs no decision"
mkstate 1 me true none '[]' 'max'; mkjudge bug needed High max false 1; with_script "$run_env; id_finalize_issue 1" >/dev/null
[ "$(jq -r .effort "$R")" = xhigh ] && [ "$(jq -r .effort_stance "$R")" = disagree ] || fail V4 "proposed max must clamp and disagree with an existing max"
[ "$FAILS" = 0 ] && pass V4 "social rule: no close/park for another author, note not field write, decision routed, deleted account named"

# ---------- V5: noise needs a mechanical signal ----------
for T in 'TODO in apps/frontend/.next/dev/server/chunks/ssr/x.js:2812' 'chore: regenerate domain/storage/_generated/queries.go' 'stray file in node_modules/foo'; do
  mkissue 9 "$T" me '[]' 'body'; with_script "$run_env; id_fetch 9; id_noise 9" >/dev/null
  [ -n "$(jq -r .noise_signal "$RUN/state-9.json")" ] || fail V5 "path signal missed: $T"
done
for T in 'fix(build): recognize worktree caches' 'perf: the build output is slow' 'docs: dist tarball notes'; do
  mkissue 9 "$T" me '[]' 'body'; with_script "$run_env; id_fetch 9; id_noise 9" >/dev/null
  [ -z "$(jq -r .noise_signal "$RUN/state-9.json")" ] || fail V5 "prose mention misread as noise: $T"
done
mkissue 9 'plain title' me '[]' $'looks fine\n<!-- detent-intake:abc123 -->'; with_script "$run_env; id_fetch 9; id_noise 9" >/dev/null
[ "$(jq -r .noise_signal "$RUN/state-9.json")" = "detent-intake fingerprint" ] || fail V5 "fingerprint not named"
[ "$FAILS" = 0 ] && pass V5 "noise only on a fingerprint or a build-output/_generated/node_modules path"

# ---------- V6: refresh (fail closed) + dispatcher ----------
SNAP='{"number":1,"evaluated":true,"title":"t","state":"OPEN","updated_at":"2026-02-01T00:00:00Z","labels":["bug"],"comments_fingerprint":[{"id":1,"updated_at":"2026-01-01T00:00:00Z"}],"marker_id":null,"marker_updated":"","comment_action":"create","marker_count":0}'
C_NONE='[[{"id":1,"user":{"login":"x"},"body":"hi","updated_at":"2026-01-01T00:00:00Z"}]]'
C_NONE_EDITED='[[{"id":1,"user":{"login":"x"},"body":"hi (edited)","updated_at":"2026-01-09T00:00:00Z"}]]'
C_NONE_PLUS='[[{"id":1,"user":{"login":"x"},"body":"hi","updated_at":"2026-01-01T00:00:00Z"},{"id":2,"user":{"login":"y"},"body":"new","updated_at":"2026-01-02T00:00:00Z"}]]'
C_MINE="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nmine\",\"updated_at\":\"2026-01-03T00:00:00Z\"}]]"
C_MINE_EDITED="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nmine\",\"updated_at\":\"2026-01-09T00:00:00Z\"}]]"
C_FOREIGN="[[{\"id\":1,\"user\":{\"login\":\"other\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\ntheirs\",\"updated_at\":\"2026-01-01T00:00:00Z\"}]]"
C_TWO="[[{\"id\":400,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\na\",\"updated_at\":\"2026-01-03T00:00:00Z\"},{\"id\":500,\"user\":{\"login\":\"me\"},\"body\":\"<!-- issue-details:v1 dev=$SHA -->\\nb\",\"updated_at\":\"2026-01-04T00:00:00Z\"}]]"
SNAP_EDIT=$(jq -c '.comment_action="edit" | .marker_id=400 | .marker_updated="2026-01-03T00:00:00Z" | .marker_count=1 | .comments_fingerprint=[{id:400,updated_at:"2026-01-03T00:00:00Z"}]' <<<"$SNAP")
SNAP_TWO=$(jq -c '.comments_fingerprint=[{id:400,updated_at:"2026-01-03T00:00:00Z"},{id:500,updated_at:"2026-01-04T00:00:00Z"}]' <<<"$SNAP_EDIT")
refresh() {  # <state-json> <refresh-issue-json> <comments-json> [extra env]
  printf '%s' "$1" > "$RUN/state-1.json"; printf '%s' "$2" > "$STUB_DIR/refresh-1.json"; printf '%s' "$3" > "$STUB_DIR/comments-1.json"
  with_script "$run_env; ${4:-:}; id_refresh 1 >/dev/null 2>&1 || true; jq -r '\"\\(.write_ok)|\\(.write_note)\"' \"$RUN/state-1.json\""
}
OPEN='{"state":"OPEN","updatedAt":"2026-02-01T00:00:00Z","labels":[{"name":"bug"}]}'
OUT=$(refresh "$SNAP" "$OPEN" "$C_NONE");        [ "${OUT%%|*}" = 1 ] || fail V6 "clean create refused: $OUT"
OUT=$(refresh "$SNAP" "$OPEN" "$C_FOREIGN" "printf '%s' '$(jq -c '.comments_fingerprint=[{id:1,updated_at:"2026-01-01T00:00:00Z"}]' <<<"$SNAP")' > $RUN/state-1.json"); [ "${OUT%%|*}" = 1 ] || fail V6 "a foreign marker must not block our create: $OUT"
OUT=$(refresh "$SNAP" "$OPEN" "$C_MINE");        [ "${OUT%%|*}" = 0 ] || fail V6 "create with a marker that appeared must be refused"
OUT=$(refresh "$SNAP_EDIT" "$OPEN" "$C_MINE");   [ "${OUT%%|*}" = 1 ] || fail V6 "clean edit refused: $OUT"
OUT=$(refresh "$SNAP_EDIT" "$OPEN" "$C_MINE_EDITED"); [ "${OUT%%|*}" = 0 ] || fail V6 "stale marker must be refused"
OUT=$(refresh "$SNAP" "$OPEN" "$C_NONE_EDITED"); [ "${OUT%%|*}" = 0 ] || fail V6 "an edited non-marker comment must be refused (full fingerprint)"
OUT=$(refresh "$SNAP" "$OPEN" "$C_NONE_PLUS");   [ "${OUT%%|*}" = 0 ] || fail V6 "a new comment must be refused"
OUT=$(refresh "$SNAP_TWO" "$OPEN" "$C_TWO");     [ "${OUT%%|*}" = 0 ] || fail V6 "duplicate owned markers must be refused"; case "$OUT" in *"delete all but one"*) : ;; *) fail V6 "duplicates must name manual cleanup" ;; esac
OUT=$(refresh "$SNAP" '{"state":"CLOSED","updatedAt":"2026-02-01T00:00:00Z","labels":[{"name":"bug"}]}' "$C_NONE"); [ "${OUT%%|*}" = 0 ] || fail V6 "closed issue must never be written"
OUT=$(refresh "$SNAP" '{"state":"OPEN","updatedAt":"2026-02-02T00:00:00Z","labels":[{"name":"bug"}]}' "$C_NONE"); [ "${OUT%%|*}" = 0 ] || fail V6 "changed updatedAt must be refused"
OUT=$(refresh "$SNAP" '{"state":"OPEN","updatedAt":"2026-02-01T00:00:00Z","labels":[{"name":"bug"},{"name":"x"}]}' "$C_NONE"); [ "${OUT%%|*}" = 0 ] || fail V6 "changed labels must be refused"
OUT=$(refresh "$SNAP" "$OPEN" '[["junk"]]');     [ "${OUT%%|*}" = 0 ] || fail V6 "[[\"junk\"]] must fail closed"
OUT=$(refresh "$SNAP" "$OPEN" '');               [ "${OUT%%|*}" = 0 ] || fail V6 "empty comments must fail closed"
OUT=$(refresh "$SNAP" "$OPEN" "$C_NONE" "gh() { echo 'HTTP 403' >&2; return 1; }"); [ "${OUT%%|*}" = 0 ] || fail V6 "API failure must fail closed"
OUT=$(refresh "$(jq -c '.comment_action="refuse"' <<<"$SNAP_TWO")" "$OPEN" "$C_TWO"); [ "${OUT%%|*}" = 0 ] || fail V6 "refuse action must not write"
dispatch() {  # <state-json> <result-json> [extra env] → log
  : > "$STUB_LOG"; printf '%s' "$1" > "$RUN/state-1.json"; printf '%s' "$2" > "$RUN/result-1.json"; printf 'draft\n' > "$RUN/comment-1.md"
  with_script "$run_env; ${3:-:}; id_dispatch 1" > "$RUN/dispatch.out"; cat "$STUB_LOG"
}
ST_OK=$(jq -c '.write_ok=1 | .write_note=""' <<<"$SNAP"); ST_NO=$(jq -c '.write_ok=0 | .write_note="x"' <<<"$SNAP")
LOG=$(dispatch "$ST_NO" '{"needs_decision":true,"state":"OPEN"}');                     [ -z "$LOG" ] || fail V6 "WRITE_OK=0 must issue no gh call: $LOG"
LOG=$(dispatch "$ST_OK" '{"needs_decision":false,"state":"OPEN"}');                    [ "$(grep -c . <<<"$LOG")" = 1 ] && grep -q -- '-X POST repos/o/r/issues/1/comments' <<<"$LOG" || fail V6 "create without decision must be one bare POST: $LOG"
LOG=$(dispatch "$ST_OK" '{"needs_decision":true,"state":"OPEN"}');                     [ "$(grep -c . <<<"$LOG")" = 2 ] && [ "$(tail -1 <<<"$LOG" | grep -c 'add-label triage:needs-decision')" = 1 ] || fail V6 "create with decision must be POST then label: $LOG"
grep -q PATCH <<<"$LOG" && fail V6 "create run issued a PATCH"
LOG=$(dispatch "$(jq -c '.write_ok=1' <<<"$SNAP_EDIT")" '{"needs_decision":false,"state":"OPEN"}'); [ "$(grep -c . <<<"$LOG")" = 1 ] && grep -q -- '-X PATCH repos/o/r/issues/comments/400' <<<"$LOG" || fail V6 "edit must be one PATCH on the marker: $LOG"
printf '%s' "$C_MINE" > "$STUB_DIR/comments-after-1.json"
LOG=$(dispatch "$ST_OK" '{"needs_decision":true,"state":"OPEN"}' "STUB_POST_FAIL=1"); [ "$(grep -c 'X POST' <<<"$LOG")" = 1 ] && grep -q 'add-label' <<<"$LOG" && grep -q 'posted (confirmed' "$RUN/dispatch.out" || fail V6 "ambiguous POST that landed: one POST, confirmed, labelled: $LOG"
printf '%s' "$C_NONE" > "$STUB_DIR/comments-after-1.json"
LOG=$(dispatch "$ST_OK" '{"needs_decision":true,"state":"OPEN"}' "STUB_POST_FAIL=1"); [ "$(grep -c 'X POST' <<<"$LOG")" = 1 ] && ! grep -q 'add-label' <<<"$LOG" && grep -q 'not retried' "$RUN/dispatch.out" || fail V6 "failed POST: never retried, no label: $LOG"
rm -f "$STUB_DIR/comments-after-1.json"
# PATCH failure: one attempt, one confirming GET; confirmed when the body landed, else not retried
printf '{"body":"draft"}' > "$STUB_DIR/comment-after-400.json"
LOG=$(dispatch "$(jq -c '.write_ok=1' <<<"$SNAP_EDIT")" '{"needs_decision":false,"state":"OPEN"}' "STUB_PATCH_FAIL=1"); [ "$(grep -c 'X PATCH' <<<"$LOG")" = 1 ] && grep -q 'edited #400 (confirmed' "$RUN/dispatch.out" || fail V6 "ambiguous PATCH that landed: one attempt, confirmed: $LOG / $(cat "$RUN/dispatch.out")"
printf '{"body":"old"}' > "$STUB_DIR/comment-after-400.json"
LOG=$(dispatch "$(jq -c '.write_ok=1' <<<"$SNAP_EDIT")" '{"needs_decision":true,"state":"OPEN"}' "STUB_PATCH_FAIL=1"); [ "$(grep -c 'X PATCH' <<<"$LOG")" = 1 ] && ! grep -q 'add-label' <<<"$LOG" && grep -q 'edit failed — not retried' "$RUN/dispatch.out" || fail V6 "failed PATCH: one attempt, no label, not retried: $LOG"
rm -f "$STUB_DIR/comment-after-400.json"
# label failure: one attempt, one confirming GET
printf '[{"name":"triage:needs-decision"}]' > "$STUB_DIR/labels-after-1.json"
LOG=$(dispatch "$ST_OK" '{"needs_decision":true,"state":"OPEN"}' "STUB_LABEL_FAIL=1"); [ "$(grep -c 'add-label' <<<"$LOG")" = 1 ] && grep -q 'label added (confirmed' "$RUN/dispatch.out" || fail V6 "ambiguous label that landed: one attempt, confirmed: $LOG"
printf '[]' > "$STUB_DIR/labels-after-1.json"
LOG=$(dispatch "$ST_OK" '{"needs_decision":true,"state":"OPEN"}' "STUB_LABEL_FAIL=1"); [ "$(grep -c 'add-label' <<<"$LOG")" = 1 ] && grep -q 'label add failed — not retried' "$RUN/dispatch.out" || fail V6 "failed label: one attempt, not retried: $LOG"
rm -f "$STUB_DIR/labels-after-1.json"
LOG=$(dispatch "$(jq -c '.write_ok=1 | .comment_action="refuse"' <<<"$SNAP_TWO")" '{"needs_decision":true,"state":"OPEN"}'); [ -z "$LOG" ] || fail V6 "refuse must issue no gh call"
[ "$FAILS" = 0 ] && pass V6 "refresh fails closed on every drift; POST, PATCH, and label are one attempt each with one confirming GET; label only on decision"

# ---------- V7: arguments and selection ----------
args_rc() { with_script "RC=0; ( id_main collect --run-dir '$RUN/args' $1 ) >/dev/null 2>&1 || RC=\$?; echo \$RC" 2>/dev/null | tail -1; }
for BAD in '--since 1oopsd' '--since 0d' '--since 7' '--since' 'abc' '' '3094 --since 7d' 'https://github.com/o/r/pull/5' '3094 https://github.com/o/r/issues/5' 'https://github.com/o/r/issues/5junk'; do
  [ "$(args_rc "$BAD")" = 2 ] || fail V7 "'$BAD' should exit 2, got $(args_rc "$BAD")"
done
reset_stub; mkissue 5 five me '[]' body
RC=0; with_script "STUB_HOST=ghe.example.com; id_main collect --run-dir '$RUN/ghe' 5" > "$RUN/ghe.out" 2>&1 || RC=$?
[ "$RC" = 3 ] && grep -q 'outside the supported context' "$RUN/ghe.out" || fail V7 "a GitHub Enterprise host must be refused with exit 3: rc=$RC $(cat "$RUN/ghe.out")"
with_script "id_main collect --run-dir '$RUN/url' https://github.com/o/r/issues/5" >/dev/null 2>&1 || fail V7 "a lone issue URL should run"
[ "$(cat "$RUN/url/selected.txt")" = 5 ] || fail V7 "URL did not materialise selected.txt"
with_script "id_main collect --run-dir '$RUN/nums' 5 5" >/dev/null 2>&1 || fail V7 "explicit numbers should run"
[ "$(cat "$RUN/nums/selected.txt")" = 5 ] || fail V7 "explicit numbers must materialise selected.txt (deduped): $(cat "$RUN/nums/selected.txt")"
TODAY=$(date -u +%Y-%m-%d)
jq -nc --arg d "$TODAY" '[range(60) | {number: (1000 + .), createdAt: ($d + "T00:" + ("0" + tostring)[-2:] + ":00Z")}] | reverse' > "$STUB_DIR/since.json"
with_script "$run_env; SINCE_ARG=30d; id_select" >/dev/null 2>&1
[ "$(wc -l < "$RUN/selected.txt" | tr -d ' ')" = 50 ] && [ "$(head -1 "$RUN/selected.txt")" = 1000 ] || fail V7 "since cap must keep the oldest 50: $(wc -l < "$RUN/selected.txt") from $(head -1 "$RUN/selected.txt")"
grep -q 'evaluating the oldest 50' "$RUN/warnings.txt" || fail V7 "cap warning not recorded"
[ "$FAILS" = 0 ] && pass V7 "arguments strict; GHE refused; URL and explicit numbers materialise selected.txt; oldest-50 cap with warning"

# ---------- V8: rate gates ----------
gate() { with_script "$run_env; ${1:-:}; STOP_BATCH=0; RC=0; id_gate t || RC=\$?; echo \"rc=\$RC stop=\$STOP_BATCH reason=\$STOP_REASON\""; }
OUT=$(gate); case "$OUT" in *"rc=0 stop=0"*) : ;; *) fail V8 "healthy gate must pass: $OUT" ;; esac
OUT=$(gate "STUB_RATE_OVERRIDE='{\"resources\":{\"core\":{\"remaining\":12},\"graphql\":{\"remaining\":4000},\"search\":{\"remaining\":29,\"reset\":0}}}'"); case "$OUT" in *"stop=1"*"below reserve"*) : ;; *) fail V8 "core below reserve must stop: $OUT" ;; esac
OUT=$(gate "STUB_RATE_OVERRIDE='{\"resources\":{\"core\":{\"remaining\":4000},\"graphql\":{\"remaining\":900},\"search\":{\"remaining\":29,\"reset\":0}}}'"); case "$OUT" in *"stop=1"*) : ;; *) fail V8 "graphql below reserve must stop: $OUT" ;; esac
OUT=$(gate "STUB_RATE_OVERRIDE='{\"resources\":{\"core\":{\"remaining\":4000},\"graphql\":{\"remaining\":4000},\"search\":{\"remaining\":1,\"reset\":1}}}'"); case "$OUT" in *"rc=0 stop=0"*) : ;; *) fail V8 "search below reserve must sleep, not stop: $OUT" ;; esac
OUT=$(gate "STUB_RATE_OVERRIDE='{}'"); case "$OUT" in *"stop=1"*malformed*) : ;; *) fail V8 "{} must fail closed: $OUT" ;; esac
OUT=$(gate "STUB_RATE_OVERRIDE='{\"resources\":{\"core\":{\"remaining\":null},\"graphql\":{\"remaining\":4000},\"search\":{\"remaining\":29,\"reset\":0}}}'"); case "$OUT" in *"stop=1"*) : ;; *) fail V8 "a null bucket must fail closed: $OUT" ;; esac
OUT=$(gate "STUB_RATE_FAIL_AT=1; rm -f $STUB_DIR/rate.count"); case "$OUT" in *"stop=1"*unreadable*) : ;; *) fail V8 "unreadable rate_limit must stop: $OUT" ;; esac
[ "$FAILS" = 0 ] && pass V8 "gate: below reserve / malformed / unreadable stop the batch; search sleeps"

# ---------- V9: merged-PR sweep ----------
reset_stub; mkissue 7 seven me '[]' body; mkissue 8 eight me '[]' body
jq -c '.createdAt="2026-01-10T00:00:00Z"' "$STUB_DIR/issue-7.json" > "$STUB_DIR/t" && mv "$STUB_DIR/t" "$STUB_DIR/issue-7.json"
jq -c '.createdAt="2026-01-05T00:00:00Z"' "$STUB_DIR/issue-8.json" > "$STUB_DIR/t" && mv "$STUB_DIR/t" "$STUB_DIR/issue-8.json"
rm -f "$RUN"/state-*.json
printf '%s' '{"data":{"search":{"issueCount":150,"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"number":10,"title":"a","mergedAt":"2026-01-06T00:00:00Z","closingIssuesReferences":{"pageInfo":{"hasNextPage":false},"nodes":[{"number":8}]}}]}}}' > "$STUB_DIR/sweep-1.json"
printf '%s' '{"data":{"search":{"issueCount":150,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":11,"title":"b","mergedAt":"2026-01-12T00:00:00Z","closingIssuesReferences":{"pageInfo":{"hasNextPage":true},"nodes":[{"number":9}]}}]}}}' > "$STUB_DIR/sweep-2.json"
with_script "$run_env; id_fetch 7; id_fetch 8; id_sweep" >/dev/null 2>&1
[ "$(cat "$RUN/shipped-truncated.txt")" = false ] || fail V9 "two pages fully read must not be truncated"
[ "$(jq length "$RUN/shipped.json")" = 2 ] && [ "$(jq -c '.[0].issues' "$RUN/shipped.json")" = "[8]" ] || fail V9 "pages must accumulate with closing refs: $(cat "$RUN/shipped.json")"
[ "$(jq -r '.[1].issues_truncated' "$RUN/shipped.json")" = true ] && grep -q 'PR #11 closes more than 100' "$RUN/warnings.txt" || fail V9 ">100 closing refs must be flagged and warned"
grep -q 'merged:>=2026-01-05T00:00:00Z' "$STUB_LOG" || fail V9 "window must start at the earliest selected createdAt"
printf '[]' > "$RUN/open-prs.json"; with_script "$run_env; id_dedupe 7" >/dev/null 2>&1
[ "$(jq -c .fixed_by_unknown "$RUN/state-7.json")" = "[11]" ] && [ "$(jq -c .candidates_shipped "$RUN/state-7.json")" = "[]" ] || fail V9 "truncated PR must be an unknown match, not fixed"
rm -f "$STUB_DIR"/sweep-*.json "$STUB_DIR/page.count"
for i in 1 2 3 4 5 6; do printf '%s' '{"data":{"search":{"issueCount":900,"pageInfo":{"hasNextPage":true,"endCursor":"c"},"nodes":[]}}}' > "$STUB_DIR/sweep-$i.json"; done
with_script "$run_env; id_sweep" >/dev/null 2>&1; [ "$(cat "$RUN/shipped-truncated.txt")" = true ] && [ "$(cat "$STUB_DIR/page.count")" = 5 ] || fail V9 "page cap 5 must report truncation"
rm -f "$STUB_DIR"/sweep-*.json "$STUB_DIR/page.count"; printf '%s' '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}],"data":null}' > "$STUB_DIR/sweep-1.json"
OUT=$(with_script "$run_env; id_sweep; echo stop=\$STOP_BATCH" 2>/dev/null); case "$OUT" in *stop=1*) : ;; *) fail V9 "a RATE_LIMITED GraphQL error must stop the batch: $OUT" ;; esac
[ "$(jq length "$RUN/shipped.json")" = 0 ] && [ "$(cat "$RUN/shipped-truncated.txt")" = true ] || fail V9 "an errored page must not become an empty fact silently"
# board: GraphQL errors are a fetch failure, never "none"; the tracker project wins
printf '%s' '{"errors":[{"message":"boom"}],"data":null}' > "$STUB_DIR/board-7.json"
with_script "$run_env; id_board 7 && echo OKAY" 2>/dev/null | grep -q OKAY && fail V9 "a GraphQL error board response must be a failure"
printf '%s' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"id":"PVT_other"},"fieldValues":{"nodes":[{"name":"Done","field":{"name":"Status"}}]}},{"project":{"id":"PVT_x"},"fieldValues":{"nodes":[{"name":"Todo","field":{"name":"Status"}},{"name":"High","field":{"name":"Priority"}}]}}]}}}}}' > "$STUB_DIR/board-7.json"
with_script "$run_env; id_board 7" >/dev/null 2>&1
[ "$(jq -r .board_status "$RUN/state-7.json")" = Todo ] && [ "$(jq -r .board_priority "$RUN/state-7.json")" = High ] || fail V9 "the tracker project's item must win: $(jq -c '{board_status,board_priority}' "$RUN/state-7.json")"
[ "$FAILS" = 0 ] && pass V9 "sweep: window from earliest filing; truncation from pagination; GraphQL errors fail; tracker project wins"

# ---------- V11: noise issues zero searches ----------
reset_stub; mkissue 5 'engagement nightly lookback rewrite' me '[]' $'x\n<!-- detent-intake:abc -->'; printf '[]' > "$RUN/shipped.json"; printf '[]' > "$RUN/open-prs.json"
with_script "$run_env; id_fetch 5; id_noise 5; : > '$STUB_LOG'; id_dedupe 5" >/dev/null 2>&1
[ ! -s "$STUB_LOG" ] && [ "$(jq -r .dedupe_skipped "$RUN/state-5.json")" = 1 ] || fail V11 "noise must issue no search: $(cat "$STUB_LOG")"
mkissue 5 'engagement nightly lookback rewrite' me '[]' 'plain'
with_script "$run_env; id_fetch 5; id_noise 5; : > '$STUB_LOG'; DO_DUP=0; id_dedupe 5" >/dev/null 2>&1; [ ! -s "$STUB_LOG" ] || fail V11 "--no-dup-search must issue no search"
with_script "$run_env; id_fetch 5; id_noise 5; : > '$STUB_LOG'; id_dedupe 5" >/dev/null 2>&1
[ "$(grep -c . "$STUB_LOG")" = 2 ] && [ "$(jq -r .terms "$RUN/state-5.json")" = "engagement lookback nightly" ] || fail V11 "a searchable title must issue exactly two searches: $(cat "$STUB_LOG")"
mkissue 5 'the and of' me '[]' 'plain'; with_script "$run_env; id_fetch 5; id_noise 5; : > '$STUB_LOG'; id_dedupe 5" >/dev/null 2>&1
[ ! -s "$STUB_LOG" ] && [ "$(jq -r .dedupe_skipped "$RUN/state-5.json")" = 1 ] || fail V11 "an all-stopword title must not abort or search under pipefail"
[ "$FAILS" = 0 ] && pass V11 "dedupe: zero searches on noise / --no-dup-search / generic title; two otherwise"

# ---------- V12: end to end ----------
e2e_fixtures() {
  reset_stub
  mkissue 11 'engagement: nightly lookback window is never passed' me '["bug"]' $'## Problem\n\nno lookback.\n\n```detent-agent\nschema: 1\neffort: xhigh\n```'
  mkissue 12 'TODO in apps/frontend/.next/dev/server/chunks/x.js:1' cory '[]' $'<!-- detent-intake:abc -->\nTODO' "2026-02-02T00:00:00Z"
  printf '[[]]' > "$STUB_DIR/comments-11.json"
  printf '%s' "$C_MINE" > "$STUB_DIR/comments-12.json"
  printf '%s' '[{"number":90,"title":"x","isDraft":false,"closingIssuesReferences":[]}]' > "$STUB_DIR/open-prs.json"
  printf '%s' '[{"name":"goal:q3-2026"},{"name":"bug"}]' > "$STUB_DIR/labels.json"; printf '[]' > "$STUB_DIR/goal-issues.json"
  jq -nc '[{number:11, createdAt:"2026-01-10T00:00:00Z"},{number:12, createdAt:"2026-01-10T00:00:00Z"}]' | jq -c --arg d "$(date -u +%Y-%m-%d)" 'map(.createdAt = $d + "T00:00:00Z")' > "$STUB_DIR/since.json"
}
judge() {  # the orchestrator's step, scripted: it reads state files and writes judgements
  local d="$1"
  [ "$(jq -r .title "$d/state-11.json")" = 'engagement: nightly lookback window is never passed' ] || fail "V12/$2" "state-11 carries the wrong title"
  [ "$(jq -r .existing_effort "$d/state-11.json")" = xhigh ] && [ -z "$(jq -r .existing_effort "$d/state-12.json")" ] || fail "V12/$2" "per-issue effort blocks leaked between issues"
  jq -n '{classification:"bug", verdict:"needed", priority:"High", proposed_effort:"xhigh", decision_required:false, evidence:{classification:"expected-by: lookback contract", priority:"bug, no workaround stated"}}' > "$d/judgement-11.json"
  jq -n '{classification:"idea", verdict:"needed", priority:"Low", proposed_effort:"medium", decision_required:false, evidence:{}}' > "$d/judgement-12.json"
}
e2e() {  # <label> <collect args...>
  local label="$1"; shift; local d="$RUN/e2e-$label"; rm -rf "$d"
  e2e_fixtures
  with_script "id_main collect --run-dir '$d' $*" > "$d.collect.out" 2>&1 || fail "V12/$label" "collect failed: $(tail -3 "$d.collect.out")"
  [ "$(tr '\n' ' ' < "$d/selected.txt")" = "11 12 " ] || fail "V12/$label" "selected.txt: $(cat "$d/selected.txt")"
  judge "$d" "$label"
  with_script "id_main finalize --run-dir '$d'" > "$d.finalize.out" 2>&1 || fail "V12/$label" "finalize failed: $(tail -3 "$d.finalize.out")"
  grep -q 'engagement: nightly lookback' "$d/comment-11.md" && grep -q 'TODO in apps/frontend' "$d/comment-12.md" || fail "V12/$label" "each comment must carry its own title"
  grep -q 'engagement: nightly' "$d/comment-12.md" && fail "V12/$label" "issue 11's title leaked into 12's comment"
  [ "$(jq -r .needs_decision "$d/result-11.json")" = false ] && [ "$(jq -r .needs_decision "$d/result-12.json")" = true ] || fail "V12/$label" "needs_decision: 11 false, 12 true"
  [ "$(jq -r .classification "$d/result-12.json")" = noise ] && [ "$(jq -r .verdict "$d/result-12.json")" = unclear ] || fail "V12/$label" "noise must override the judgement"
  [ "$(jq -r .comment.action "$d/result-11.json")" = create ] && [ "$(jq -r .comment.action "$d/result-12.json")" = edit ] || fail "V12/$label" "11 create, 12 edit"
  grep -q '^  goal      none' "$d/report.txt" && grep -q 'registry: 1 goal label(s), 0 issue(s)' "$d/report.txt" || fail "V12/$label" "report: $(cat "$d/report.txt")"
  jq -e '.schema == 1 and (.generated_at|type=="string") and .host == "github.com" and .repo == "o/r" and .base == "dev" and (.dev_sha|length == 40) and .me == "me"
         and (.goal_registry | .labels == ["goal:q3-2026"] and .issues == 0)
         and (.issues | length == 2) and (.unevaluated == []) and (.warnings|type=="array") and (.files.run_dir|type=="string")
         and all(.issues[]; (.number|type=="number") and (.title|type=="string") and (.url|type=="string") and (.state|type=="string")
             and (.author|type=="string") and (.self_authored|type=="boolean") and (.created_at|type=="string") and (.labels|type=="array")
             and (.board | (.status|type=="string") and (.priority|type=="string"))
             and (.existing_effort|type=="string") and (.classification|type=="string") and (.verdict|type=="string")
             and (.canonical == null or (.canonical|type=="string"))
             and (.goal | (.source|type=="string") and (.reason|type=="string"))
             and (.priority|type=="string") and (.effort|type=="string") and (.effort_stance|type=="string") and (.needs_decision|type=="boolean")
             and (.dedupe | (.terms|type=="string") and (.skipped|type=="boolean") and (.open_issues|type=="array") and (.open_prs|type=="array")
                  and (.fixed_by|type=="array") and (.fixed_by_unknown|type=="array") and (.in_flight|type=="array") and (.shipped_truncated|type=="boolean"))
             and (.evidence|type=="object") and (.comment | (.action|type=="string") and (.body_path|type=="string") and (.add_label|type=="boolean"))
             and (.warnings|type=="array") and (.dev_sha|length == 40) and (.evaluated_at|type=="string"))
         and (.issues[] | select(.number == 11) | .self_authored == true and .board.status == "none" and .dedupe.skipped == false and .comment.action == "create")
         and (.issues[] | select(.number == 12) | .self_authored == false and .dedupe.skipped == true and .comment.action == "edit" and .comment.marker_id == 400 and .comment.add_label == true)' \
    "$d/facts.json" >/dev/null || fail "V12/$label" "facts.json does not match schema 1: $(jq -c '.issues[0] | keys' "$d/facts.json")"
  # zero searches for the noise issue, two for the other
  [ "$(grep -c 'search issues' "$STUB_LOG")" = 1 ] && [ "$(grep -c -- '--search' "$STUB_LOG")" = 1 ] || fail "V12/$label" "noise must not be searched: $(grep -c 'search' "$STUB_LOG") search calls"
  # the gate answered "post"
  : > "$STUB_LOG"
  with_script "id_main post --run-dir '$d'" > "$d.post.out" 2>&1 || fail "V12/$label" "post failed: $(tail -3 "$d.post.out")"
  local writes; writes=$(grep -E 'X POST|X PATCH|add-label' "$STUB_LOG" | sed -E 's/ -F body=@.*//; s/ --hostname github.com//' || true)
  [ "$writes" = "$(printf 'api -X POST repos/o/r/issues/11/comments\napi -X PATCH repos/o/r/issues/comments/400\nissue edit 12 -R o/r --add-label triage:needs-decision')" ] \
    || fail "V12/$label" "write sequence: $(printf '%s' "$writes" | tr '\n' ';')"
  grep -q '^#11 posted$' "$d.post.out" && grep -q '^#12 edited #400, label added$' "$d.post.out" || fail "V12/$label" "post output: $(cat "$d.post.out")"
}
e2e explicit 11 12
e2e since --since 7d
# the rate gate fails at pass B on issue 12: 11 is written, 12 is unevaluated, nothing follows the failed gate
d="$RUN/e2e-gate"; rm -rf "$d"; e2e_fixtures
with_script "STUB_RATE_FAIL_AT=6; id_main collect --run-dir '$d' 11 12" > "$d.collect.out" 2>&1 || fail V12/gate "collect must survive a mid-batch gate stop: $(tail -2 "$d.collect.out")"
[ "$(tail -1 "$STUB_LOG")" = "api --hostname github.com rate_limit" ] || fail V12/gate "no call may follow the failed gate: $(tail -1 "$STUB_LOG")"
[ "$(awk -F'\t' '$1 == 12' "$d/unevaluated.tsv" | wc -l | tr -d ' ')" = 1 ] && [ "$(awk -F'\t' '$1 == 11' "$d/unevaluated.tsv" | wc -l | tr -d ' ')" = 0 ] || fail V12/gate "12 must be unevaluated and 11 not: $(cat "$d/unevaluated.tsv")"
[ "$(jq -r .evaluated "$d/state-11.json")" = true ] || fail V12/gate "11 must be fully evaluated"
judge_one() { jq -n '{classification:"bug", verdict:"needed", priority:"High", proposed_effort:"xhigh", decision_required:false, evidence:{}}' > "$1/judgement-11.json"; }
judge_one "$d"; with_script "id_main finalize --run-dir '$d'" >/dev/null 2>&1 || fail V12/gate "finalize"
jq -e '(.issues | length) == 1 and (.unevaluated | length) == 1 and .unevaluated[0].number == 12 and (.unevaluated[0].reason | startswith("batch stopped"))' "$d/facts.json" >/dev/null || fail V12/gate "facts.json must list 12 as unevaluated with its reason: $(jq -c .unevaluated "$d/facts.json")"
grep -q '=== #12 === unevaluated: batch stopped' "$d/report.txt" || fail V12/gate "report must say 12 was unevaluated: $(grep '#12' "$d/report.txt")"
: > "$STUB_LOG"; with_script "id_main post --run-dir '$d'" > "$d.post.out" 2>&1 || fail V12/gate "post"
grep -q '^#11 posted$' "$d.post.out" && [ "$(grep -c 'issues/12' "$STUB_LOG")" = 0 ] || fail V12/gate "only 11 may be written: $(cat "$d.post.out")"
[ "$FAILS" = 0 ] && pass V12 "end to end: explicit and --since; exact write sequence; own titles; gate stop leaves 11 written, 12 unevaluated"

# ---------- V13: the judgement boundary ----------
d="$RUN/e2e-prose"; rm -rf "$d"; e2e_fixtures
with_script "id_main collect --run-dir '$d' 11 12" >/dev/null 2>&1 || fail V13 "collect"
jfin() { with_script "id_main finalize --run-dir '$d'" >/dev/null 2>&1 || fail V13 "finalize died: $1"; }
jq -n '{classification:"bug", verdict:"needed", priority:"High", proposed_effort:"xhigh", evidence:"free text"}' > "$d/judgement-11.json"
jq -n '{classification:"idea", verdict:"needed", priority:"Low", proposed_effort:"medium", evidence:{}}' > "$d/judgement-12.json"
jfin "non-object evidence"
[ ! -f "$d/result-11.json" ] && grep -q '=== #11 === unevaluated: judgement-11.json malformed' "$d/report.txt" || fail V13 "non-object evidence must land in unevaluated: $(grep '#11' "$d/report.txt")"
jq -e '.unevaluated | map(.number) == [11]' "$d/facts.json" >/dev/null || fail V13 "facts.json must list the malformed judgement: $(jq -c .unevaluated "$d/facts.json")"
rm -rf "$d"; e2e_fixtures; with_script "id_main collect --run-dir '$d' 11 12" >/dev/null 2>&1
jq -n '{classification:"bug", verdict:"needed", priority:"High", proposed_effort:"xhigh", decision_required:true,
        decision_reason:"line one\nline two — ask @cory and see #4242", evidence:{classification:"expected-by: docs\r\nsee @michaelhvisser", priority:"bug, no workaround"}}' > "$d/judgement-11.json"
jq -n '{classification:"idea", verdict:"needed", priority:"Low", proposed_effort:"medium", evidence:{}}' > "$d/judgement-12.json"
jfin "sanitise"
grep -q 'line one line two — ask `@cory` and see #4242 (unverified)' "$d/comment-11.md" || fail V13 "decision_reason not sanitised: $(grep -- '- decision' "$d/comment-11.md")"
grep -q 'expected-by: docs see `@michaelhvisser`' "$d/comment-11.md" || fail V13 "evidence not sanitised: $(grep -- '- classification' "$d/comment-11.md")"
! grep -qE '(^|[^`])@(cory|michaelhvisser)' "$d/comment-11.md" || fail V13 "a bare @mention reached the comment"
rm -rf "$d"; e2e_fixtures; with_script "id_main collect --run-dir '$d' 11 12" >/dev/null 2>&1
jq -n '{classification:"bug", verdict:"needed", priority:"High", proposed_effort:"xhigh", evidence:{classification:"we should close this once #90 lands"}}' > "$d/judgement-11.json"
jq -n '{classification:"idea", verdict:"needed", priority:"Low", proposed_effort:"medium", decision_reason:"park this", evidence:{}}' > "$d/judgement-12.json"
jfin "close verb"
[ -f "$d/result-11.json" ] && grep -q 'once #90 lands' "$d/comment-11.md" && [ "$(jq -c .dedupe.open_prs "$d/result-11.json")" = '[{"number":90,"title":"x"}]' ] || fail V13 "a close verb on your own issue is allowed, and a fetched #90 stays unmarked: $(grep -- '- classification' "$d/comment-11.md")"
[ ! -f "$d/result-12.json" ] && grep -q "social rule: prose proposes close on another author's issue" "$d/report.txt" || fail V13 "close/park prose on another author's issue must be refused: $(grep '#12' "$d/report.txt")"
jq -e '.unevaluated[0].number == 12 and (.unevaluated[0].reason | startswith("social rule"))' "$d/facts.json" >/dev/null || fail V13 "facts.json must carry the social-rule refusal"
rm -rf "$d"; e2e_fixtures; with_script "id_main collect --run-dir '$d' 11 12" >/dev/null 2>&1
jq -n '{classification:"idea", verdict:"needed", priority:"Low", proposed_effort:"medium", evidence:{}}' > "$d/judgement-12.json"
jfin "missing"
grep -q '=== #11 === unevaluated: no judgement-11.json' "$d/report.txt" && jq -e '.unevaluated | map(.number) == [11]' "$d/facts.json" >/dev/null || fail V13 "a missing judgement must be unevaluated everywhere"
: > "$STUB_LOG"; with_script "id_main post --run-dir '$d'" > "$d.post.out" 2>&1 || fail V13 "post"
[ "$(grep -c 'issues/11' "$STUB_LOG")" = 0 ] || fail V13 "an unjudged issue must never be written"
[ "$FAILS" = 0 ] && pass V13 "judgement boundary: malformed/missing → unevaluated; prose single-line, @mentions backticked, unfetched #N marked; close verb refused on another author's issue"

if [ "$FAILS" -gt 0 ]; then echo "issue-details-triage: $FAILS failure(s)"; exit 1; fi
echo "issue-details-triage: OK"
