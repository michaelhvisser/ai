#!/bin/bash
# issue-details: the deterministic half of /workflow:issue-details.
#
# Every mechanical step of the skill lives here — preflight, the rate gates,
# the per-issue fetches, the guards, the comment render, the pre-write
# refresh, and the write dispatcher. The judgement steps (class, verdict,
# priority, proposed effort, decision) are the orchestrator's: it reads
# state-<n>.json, applies the tables in triage.md, and writes
# judgement-<n>.json. Nothing here holds a fact in a shell variable across
# subcommands; every per-issue value round-trips through
# $RUN_DIR/state-<n>.json, and the dispatcher reads its snapshot back from
# that file before it writes anything.
#
# Subcommands:
#   collect  --run-dir <dir> [--base <branch>] [--no-dup-search] (--since <n>d | <n> ...)
#   finalize --run-dir <dir>
#   print    --run-dir <dir>
#   post     --run-dir <dir>
#
# Exit codes: 0 report produced; 2 usage; 3 auth, rate, or base-tip refusal
# before any issue completed (or a run-wide fetch that failed); 4 repo
# mismatch or no explicit issue found.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/pr-facts.sh"

MARKER_RE='^<!-- issue-details:v1 dev=[0-9a-f]{40} -->$'
SEARCH_RESERVE=5
SINCE_CAP=50
SWEEP_PAGE_CAP=5

# ---------------------------------------------------------------- state ----
# state-<n>.json is the only carrier of per-issue facts between steps.
id_state_path() { printf '%s/state-%s.json\n' "$RUN_DIR" "$1"; }
id_state_init() {
  local n="$1"
  [ -f "$(id_state_path "$n")" ] || printf '{"number":%s,"evaluated":false,"error":null}\n' "$n" > "$(id_state_path "$n")"
}
# id_state_set <n> <key> <jq-value-expression> [--arg name value ...]
id_state_set() {
  local n="$1" key="$2" expr="$3"; shift 3
  local f tmp
  f=$(id_state_path "$n"); tmp="$f.tmp.$$"
  jq "$@" --arg __k "$key" ".[\$__k] = ($expr)" "$f" > "$tmp" && mv "$tmp" "$f"
}
id_state_get() { jq -r "$2 // empty" "$(id_state_path "$1")"; }
id_state_get_json() { jq -c "$2" "$(id_state_path "$1")"; }

id_warn() { printf '%s\n' "$1" | tee -a "$RUN_DIR/warnings.txt" >&2; }
id_unevaluated() {  # <n> <reason>
  printf '%s\t%s\n' "$1" "$2" >> "$RUN_DIR/unevaluated.tsv"
  id_state_init "$1"; id_state_set "$1" error '$r' --arg r "$2"; id_state_set "$1" evaluated 'false'
}

# ------------------------------------------------------------------ gh -----
# id_gh <out-file> <gh-args...>: pr_facts_gh to a file. Never on the left of a
# pipe, never in $( ) — the batch-stop flag must survive. A terminal
# rate-limit 403 sets STOP_BATCH; any failure sets ISSUE_FAILED/ISSUE_ERROR.
STOP_BATCH=0; STOP_REASON=""; ISSUE_FAILED=0; ISSUE_ERROR=""
id_gh() {
  local out="$1"; shift
  local err rc
  err=$(mktemp)
  if pr_facts_gh "$@" > "$out" 2>"$err"; then rm -f "$err"; return 0; else rc=$?; fi
  # ($? after a failed `if` with no else is 0 — the status must be read inside the else)
  ISSUE_ERROR=$(head -1 "$err"); ISSUE_FAILED=1
  if grep -qiE 'rate limit|HTTP 403' "$err"; then STOP_BATCH=1; STOP_REASON="$ISSUE_ERROR"; fi
  rm -f "$err"
  return "$rc"
}
# id_graphql_ok <file>: pr_facts_graphql_ok on a file, plus a data check. A
# GraphQL errors[] response is a fetch failure, never an empty fact.
id_graphql_ok() {
  local f="$1" body
  body=$(cat "$f") || return 1
  pr_facts_graphql_ok "$body" 2>/dev/null || { ISSUE_FAILED=1; ISSUE_ERROR="GraphQL error: $(jq -r '(.errors // []) | map(.message) | join("; ")' "$f" 2>/dev/null)"
    if jq -e '(.errors // []) | map(.type // "") | any(. == "RATE_LIMITED")' "$f" >/dev/null 2>&1; then STOP_BATCH=1; STOP_REASON="$ISSUE_ERROR"; fi
    return 1; }
  jq -e '.data != null' "$f" >/dev/null 2>&1 || { ISSUE_FAILED=1; ISSUE_ERROR="GraphQL response carried no data"; return 1; }
}

# ---------------------------------------------------------------- gate -----
# id_gate <label>: one rate_limit read to a file. Core/GraphQL below reserve,
# an unreadable or malformed response → STOP_BATCH. Search below reserve →
# sleep to its reset (it refills every minute).
id_gate() {
  local label="$1" f core gql search reset v now
  f="$RUN_DIR/rate-$label.json"
  ISSUE_FAILED=0; ISSUE_ERROR=""
  if ! id_gh "$f" api --hostname "$HOST" rate_limit; then
    STOP_BATCH=1; STOP_REASON="rate_limit unreadable: $ISSUE_ERROR"; ISSUE_ERROR="$STOP_REASON"; return 1
  fi
  core=$(jq -r '.resources.core.remaining // empty' "$f" 2>/dev/null || true)
  gql=$(jq -r '.resources.graphql.remaining // empty' "$f" 2>/dev/null || true)
  search=$(jq -r '.resources.search.remaining // empty' "$f" 2>/dev/null || true)
  reset=$(jq -r '.resources.search.reset // empty' "$f" 2>/dev/null || true)
  for v in "$core" "$gql" "$search" "$reset"; do
    case "$v" in ''|*[!0-9]*) STOP_BATCH=1; STOP_REASON="rate_limit response malformed"; ISSUE_FAILED=1; ISSUE_ERROR="$STOP_REASON"; return 1 ;; esac
  done
  if [ "$core" -lt "$REST_RESERVE" ] || [ "$gql" -lt "$GRAPHQL_RESERVE" ]; then
    STOP_BATCH=1; STOP_REASON="rate limit below reserve (core $core, graphql $gql)"; ISSUE_FAILED=1; ISSUE_ERROR="$STOP_REASON"; return 1
  fi
  if [ "$search" -lt "$SEARCH_RESERVE" ]; then
    now=$(date -u +%s)
    if [ "$reset" -gt "$now" ]; then sleep $(( reset - now + 1 )); fi
  fi
  return 0
}

# ----------------------------------------------------------- preflight -----
id_preflight() {
  local f
  SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || { echo "issue-details: cannot resolve the repository" >&2; exit 4; }
  HOST=$(gh repo view --json url --jq '.url | sub("^https?://";"") | split("/")[0]')
  if [ "$HOST" != "github.com" ]; then
    echo "issue-details: $HOST is outside the supported context — same-repository work on github.com only; GitHub Enterprise hosts are refused at the boundary rather than supported by accident (AGENTS.md §Supported context)" >&2; exit 3
  fi
  if [ -n "${URL_SLUG:-}" ] && { [ "$URL_SLUG" != "$SLUG" ] || [ "$URL_HOST" != "$HOST" ]; }; then
    echo "issue-details: URL names ${URL_HOST}/${URL_SLUG} but the checkout is ${HOST}/${SLUG}" >&2; exit 4
  fi
  OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
  gh auth status --hostname "$HOST" >/dev/null 2>&1 || { echo "issue-details: not authenticated for $HOST" >&2; exit 3; }
  ME=$(pr_facts_gh api --hostname "$HOST" user --jq .login) || { echo "issue-details: cannot resolve the running user" >&2; exit 3; }
  GRAPHQL_RESERVE=$(awk '/^ *github_graphql_min_remaining_reserve:/{print $2; exit}' detent.yaml 2>/dev/null || true)
  REST_RESERVE=$(awk '/^ *github_rest_min_remaining_reserve:/{print $2; exit}' detent.yaml 2>/dev/null || true)
  PROJECT_SLUG=$(awk '/^ *project_slug:/{print $2; exit}' detent.yaml 2>/dev/null || true)
  GRAPHQL_RESERVE="${GRAPHQL_RESERVE:-1000}"; REST_RESERVE="${REST_RESERVE:-1000}"
  if ! id_gate preflight; then printf 'issue-details: %s\n' "$STOP_REASON" >&2; exit 3; fi
  BASE="${BASE_ARG:-dev}"
  BASE_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
  if [ -z "$BASE_SHA" ] && [ -z "${BASE_ARG:-}" ]; then
    BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
    BASE_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
  fi
  [ -n "$BASE_SHA" ] || { echo "issue-details: cannot resolve the tip of $BASE" >&2; exit 3; }
  : > "$RUN_DIR/unevaluated.tsv"; : > "$RUN_DIR/warnings.txt"; : > "$RUN_DIR/failed.txt"
  jq -n --arg host "$HOST" --arg slug "$SLUG" --arg me "$ME" --arg base "$BASE" --arg sha "$BASE_SHA" \
     --arg ps "$PROJECT_SLUG" --arg gr "$GRAPHQL_RESERVE" --arg rr "$REST_RESERVE" \
     '{host:$host, repo:$slug, me:$me, base:$base, base_sha:$sha, project_slug:$ps,
       graphql_reserve:($gr|tonumber), rest_reserve:($rr|tonumber)}' > "$RUN_DIR/run.json"
  # Run-wide: open PRs (in-flight detection) — proven shape, or the run stops.
  f="$RUN_DIR/open-prs.raw"
  id_gh "$f" pr list -R "$SLUG" --state open --limit 100 --json number,title,isDraft,closingIssuesReferences \
    && jq -e 'type == "array"' "$f" >/dev/null 2>&1 \
    || { echo "issue-details: open-PR list failed: ${ISSUE_ERROR:-bad shape}" >&2; exit 3; }
  jq -c '[.[] | {number, title, isDraft, issues: [.closingIssuesReferences[].number]}]' "$f" > "$RUN_DIR/open-prs.json"
  [ "$(jq length "$RUN_DIR/open-prs.json")" -lt 100 ] || id_warn "open-PR list capped at 100 — in-flight detection may miss older PRs"
  # Run-wide: the goal registry — every goal:* label and the issues carrying it.
  f="$RUN_DIR/labels.raw"
  id_gh "$f" label list -R "$SLUG" --limit 300 --json name \
    && jq -e 'type == "array"' "$f" >/dev/null 2>&1 \
    || { echo "issue-details: label list failed: ${ISSUE_ERROR:-bad shape}" >&2; exit 3; }
  jq -r '.[].name | select(startswith("goal:"))' "$f" > "$RUN_DIR/goal-labels.txt"
  : > "$RUN_DIR/goal-registry.tsv"
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    id_gh "$RUN_DIR/goal-$l.raw" issue list -R "$SLUG" --label "$l" --state all --limit 100 --json number \
      && jq -e 'type == "array"' "$RUN_DIR/goal-$l.raw" >/dev/null 2>&1 \
      || { echo "issue-details: goal registry fetch for $l failed: ${ISSUE_ERROR:-bad shape}" >&2; exit 3; }
    jq -r '.[].number' "$RUN_DIR/goal-$l.raw" | awk -v l="$l" '{print $0 "\t" l}' >> "$RUN_DIR/goal-registry.tsv"
  done < "$RUN_DIR/goal-labels.txt"
  [ -s "$RUN_DIR/goal-registry.tsv" ] || id_warn "goal registry: empty — no issue carries a goal:* label yet"
}

# ----------------------------------------------------------- selection -----
# Both modes materialise selected.txt; nothing downstream reads the argv.
id_select() {
  local since_days since f total
  if [ -n "${SINCE_ARG:-}" ]; then
    since_days="${SINCE_ARG%d}"
    since=$(date -u -v-"${since_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "${since_days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || since=""
    [ -n "$since" ] || { echo "issue-details: cannot compute the --since boundary with this date(1)" >&2; exit 3; }
    f="$RUN_DIR/since.raw"
    id_gh "$f" issue list -R "$SLUG" --state open --limit 500 --json number,createdAt \
      && jq -e 'type == "array"' "$f" >/dev/null 2>&1 \
      || { echo "issue-details: issue list failed: ${ISSUE_ERROR:-bad shape}" >&2; exit 3; }
    jq -c --arg since "$since" '[.[] | select(.createdAt >= $since)] | sort_by(.createdAt, .number)' "$f" > "$RUN_DIR/since-all.json"
    total=$(jq length "$RUN_DIR/since-all.json")
    jq -r --argjson cap "$SINCE_CAP" '.[0:$cap] | .[].number' "$RUN_DIR/since-all.json" > "$RUN_DIR/selected.txt"
    [ "$total" -le "$SINCE_CAP" ] || id_warn "--since matched $total open issues; evaluating the oldest $SINCE_CAP — re-run with a shorter window for the rest"
  else
    printf '%s\n' $ISSUE_ARGS | awk 'NF && !seen[$0]++' > "$RUN_DIR/selected.txt"
  fi
  [ -s "$RUN_DIR/selected.txt" ] || { echo "issue-details: nothing selected" >&2; exit 2; }
}

# ----------------------------------------------------------- per issue -----
id_fetch() {  # pass A: the record, to the file; a failure is persisted
  local n="$1" f="$RUN_DIR/issue-$1.json"
  if ! id_gh "$f" issue view "$n" -R "$SLUG" --json number,title,body,author,createdAt,updatedAt,labels,state,url,milestone \
     || ! jq -e --argjson n "$n" '.number == $n' "$f" >/dev/null 2>&1; then
    ISSUE_FAILED=1; ISSUE_ERROR="${ISSUE_ERROR:-record for #$n missing or not this issue}"
    echo "$n" >> "$RUN_DIR/failed.txt"; return 1
  fi
  id_state_init "$n"
  jq -r '.body // ""' "$f" > "$RUN_DIR/body-$n.md"
  local eff
  eff=$(awk '/^```detent-agent[[:space:]]*$/ {inb=1; next} /^```/ {inb=0} inb && $1 == "effort:" {print $2; exit}' "$RUN_DIR/body-$n.md")
  local tmp="$RUN_DIR/state-$n.json.tmp.$$"
  jq -c --arg eff "$eff" --arg body "$RUN_DIR/body-$n.md" --slurpfile i "$f" \
    '$i[0] as $i | . + {title: $i.title, author: ($i.author.login // ""), created_at: $i.createdAt, updated_at: $i.updatedAt,
          state: $i.state, url: $i.url, labels: ([$i.labels[].name] | sort), body_path: $body, existing_effort: $eff}' \
    "$(id_state_path "$n")" > "$tmp" && mv "$tmp" "$(id_state_path "$n")"
}

id_sweep() {  # once, after pass A; window from the earliest selected filing
  local since q gql cursor="null" page=0 f="$RUN_DIR/sweep-page.json"
  : > "$RUN_DIR/shipped-pages.jsonl"; SHIPPED_TRUNCATED=false
  since=$(cat "$RUN_DIR"/state-*.json 2>/dev/null | jq -rs '[.[].created_at // empty] | min // empty' || true)
  if [ -z "$since" ]; then printf '[]' > "$RUN_DIR/shipped.json"; return 0; fi
  q="repo:${SLUG} is:pr is:merged base:${BASE} merged:>=${since}"
  gql='query($q:String!,$after:String){ search(query:$q, type:ISSUE, first:100, after:$after){
  issueCount pageInfo{hasNextPage endCursor}
  nodes{ ... on PullRequest { number title mergedAt
    closingIssuesReferences(first:100){ pageInfo{hasNextPage} nodes{ number } } } } } }'
  while :; do
    page=$(( page + 1 ))
    if ! id_gh "$f" api --hostname "$HOST" graphql -f query="$gql" -f q="$q" -F after="$cursor" || ! id_graphql_ok "$f" \
       || ! jq -e '.data.search.nodes | type == "array"' "$f" >/dev/null 2>&1; then
      id_warn "merged-PR sweep failed on page $page (${ISSUE_ERROR:-bad shape}) — already-fixed detection incomplete"; SHIPPED_TRUNCATED=true; break
    fi
    jq -c . "$f" >> "$RUN_DIR/shipped-pages.jsonl"
    [ "$(jq -r '.data.search.pageInfo.hasNextPage' "$f")" = "true" ] || break
    if [ "$page" -ge "$SWEEP_PAGE_CAP" ]; then SHIPPED_TRUNCATED=true; break; fi
    cursor=$(jq -r '.data.search.pageInfo.endCursor' "$f")
  done
  jq -sc '[.[].data.search.nodes[] | {number, title, mergedAt, issues: [.closingIssuesReferences.nodes[].number],
            issues_truncated: (.closingIssuesReferences.pageInfo.hasNextPage == true)}]' "$RUN_DIR/shipped-pages.jsonl" > "$RUN_DIR/shipped.json"
  jq -r '.[] | select(.issues_truncated) | "PR #\(.number) closes more than 100 issues — matches against it are unknown, not absent"' "$RUN_DIR/shipped.json" \
    | while IFS= read -r l; do id_warn "$l"; done
  [ "$SHIPPED_TRUNCATED" = false ] || id_warn "merged-PR sweep stopped after $page page(s) — merged work since $since may be unexamined"
  printf '%s\n' "$SHIPPED_TRUNCATED" > "$RUN_DIR/shipped-truncated.txt"
}

id_comments() {  # pass B: comments, the owned marker, the full fingerprint
  local n="$1" raw="$RUN_DIR/comments-$1.raw" f="$RUN_DIR/comments-$1.json"
  id_gh "$raw" api --hostname "$HOST" --paginate --slurp "repos/$SLUG/issues/$n/comments?per_page=100" || return 1
  jq -e 'type == "array" and all(.[]; type == "array" and all(.[]; type == "object" and (.id|type=="number") and (.body|type=="string") and (.updated_at|type=="string")))' "$raw" >/dev/null 2>&1 \
    || { ISSUE_FAILED=1; ISSUE_ERROR="comments response malformed"; return 1; }
  jq -c '[.[][] | {id, login: (.user.login // null), body, created_at, updated_at}]' "$raw" > "$f"
  local count mid mupd action
  count=$(jq --arg me "$ME" --arg re "$MARKER_RE" '[.[] | select(.login == $me) | select(.body | split("\n")[0] | test($re))] | length' "$f")
  mid=$(jq -r --arg me "$ME" --arg re "$MARKER_RE" '[.[] | select(.login == $me) | select(.body | split("\n")[0] | test($re))] | sort_by(.id) | .[0].id // empty' "$f")
  mupd=""
  if [ "$count" -gt 1 ]; then
    action="refuse"; id_warn "#$n: $count issue-details marker comments by $ME — delete all but one by hand (deletion is outside this skill's write set); not writing"
  elif [ -n "$mid" ]; then
    action="edit"; mupd=$(jq -r --argjson id "$mid" '.[] | select(.id == $id) | .updated_at' "$f")
  else
    action="create"
  fi
  id_state_set "$n" comments_fingerprint "$(jq -c '[.[] | {id, updated_at}] | sort_by(.id)' "$f")"
  id_state_set "$n" marker_count "$count"
  id_state_set "$n" marker_id "$(if [ -n "$mid" ]; then printf '%s' "$mid"; else printf null; fi)"
  id_state_set "$n" marker_updated '$v' --arg v "$mupd"
  id_state_set "$n" comment_action '$v' --arg v "$action"
}

id_noise() {  # mechanical, before any search; the model does not override it
  local n="$1" sig="" title
  title=$(id_state_get "$n" .title)
  if grep -q '<!-- detent-intake:' "$RUN_DIR/body-$n.md"; then sig="detent-intake fingerprint"
  elif printf '%s\n' "$title" | cat - "$RUN_DIR/body-$n.md" | grep -qE '(^|/|[[:space:]]|`)(\.next|dist|build|out|node_modules|_generated)/'; then
    sig="path under build output / node_modules / _generated"; fi
  id_state_set "$n" noise_signal '$v' --arg v "$sig"
}

id_board() {  # the tracker project's item first; first item only when none matches
  local n="$1" f="$RUN_DIR/board-$1.json" gql
  gql='query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ issue(number:$num){
  projectItems(first:20){ nodes{ id project{ id title }
    fieldValues(first:30){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue { name field{ ... on ProjectV2FieldCommon { name } } } } } } } } } }'
  id_gh "$f" api --hostname "$HOST" graphql -f query="$gql" -f o="$OWNER" -f n="$NAME" -F num="$n" || return 1
  id_graphql_ok "$f" || return 1
  local sel='(.data.repository.issue.projectItems.nodes // []) as $items
    | ([ $items[] | select(.project.id == $ps) ] | first) // ($items | first) // {}
    | [ .fieldValues.nodes[]? | select(.field.name == $field) | .name ] | .[0] // "none"'
  id_state_set "$n" board_status '$v' --arg v "$(jq -r --arg ps "$PROJECT_SLUG" --arg field Status "$sel" "$f")"
  id_state_set "$n" board_priority '$v' --arg v "$(jq -r --arg ps "$PROJECT_SLUG" --arg field Priority "$sel" "$f")"
}

id_terms() {  # three longest non-stop-word tokens, ties alphabetical; scope words kept
  printf '%s' "$1" | tr -cs 'A-Za-z0-9_' '\n' | tr 'A-Z' 'a-z' \
    | { grep -vxE 'a|an|the|and|or|of|to|in|on|for|with|from|by|is|are|be|not|no|when|because|never|ever|any|all|into|via|as|at|it|its|this|that|we|our|per|vs|use|uses|using|add|adds|fix|fixes|feat|docs|test|chore|refactor|perf|make|makes|support|allow|allows|should|can|does|do|after|before|instead|still|only|new|without|across|between|under|over|each|every' || true; } \
    | awk 'length($0) >= 4 && !seen[$0]++' | awk '{print length($0) "\t" $0}' | sort -k1,1rn -k2,2 | head -3 | cut -f2 \
    | tr '\n' ' ' | sed 's/ $//'
}

id_dedupe() {  # skipped for noise or --no-dup-search: zero search calls
  local n="$1" skipped=0 terms="" title
  title=$(id_state_get "$n" .title)
  printf '[]' > "$RUN_DIR/dup-issues-$n.json"; printf '[]' > "$RUN_DIR/dup-prs-$n.json"
  if [ -n "$(id_state_get "$n" .noise_signal)" ] || [ "${DO_DUP:-1}" = 0 ]; then skipped=1; fi
  if [ "$skipped" = 0 ]; then
    terms=$(id_terms "$title")
    if [ "$(printf '%s' "$terms" | wc -w | tr -d ' ')" -ge 2 ]; then
      id_gh "$RUN_DIR/dup-issues-$n.raw" search issues --repo "$SLUG" --state open --limit 10 "$terms" --json number,title,url,labels,updatedAt || return 1
      jq -c --argjson me "$n" '[.[] | select(.number != $me)]' "$RUN_DIR/dup-issues-$n.raw" > "$RUN_DIR/dup-issues-$n.json"
      id_gh "$RUN_DIR/dup-prs-$n.json" pr list -R "$SLUG" --state open --limit 10 --search "$terms" --json number,title,url,isDraft,closingIssuesReferences || return 1
    else
      skipped=1; terms=""   # title too generic to search
    fi
  fi
  local created
  created=$(id_state_get "$n" .created_at)
  jq -c --arg since "$created" --argjson me "$n" '[.[] | select(.mergedAt >= $since) | select(.issues | index($me) != null)]' "$RUN_DIR/shipped.json" > "$RUN_DIR/fixed-by-$n.json"
  jq -c --arg since "$created" --argjson me "$n" '[.[] | select(.mergedAt >= $since) | select(.issues_truncated) | select(.issues | index($me) == null) | .number]' "$RUN_DIR/shipped.json" > "$RUN_DIR/fixed-by-unknown-$n.json"
  jq -c --argjson me "$n" '[.[] | select(.issues | index($me) != null)]' "$RUN_DIR/open-prs.json" > "$RUN_DIR/in-flight-$n.json"
  id_state_set "$n" dedupe_skipped "$skipped"
  id_state_set "$n" terms '$v' --arg v "$terms"
  id_state_set "$n" candidates_open "$(jq -sc '[.[0][].number] + [.[1][].number] + [.[2][].number] | unique' "$RUN_DIR/dup-issues-$n.json" "$RUN_DIR/dup-prs-$n.json" "$RUN_DIR/in-flight-$n.json")"
  id_state_set "$n" candidates_shipped "$(jq -c '[.[].number] | unique' "$RUN_DIR/fixed-by-$n.json")"
  id_state_set "$n" fixed_by_unknown "$(cat "$RUN_DIR/fixed-by-unknown-$n.json")"
  id_state_set "$n" in_flight "$(jq -c '[.[].number]' "$RUN_DIR/in-flight-$n.json")"
  id_state_set "$n" dup_issues "$(jq -c '[.[] | {number, title}]' "$RUN_DIR/dup-issues-$n.json")"
  id_state_set "$n" dup_prs "$(jq -c '[.[] | {number, title}]' "$RUN_DIR/dup-prs-$n.json")"
}

id_goalrefs() {  # part of #N, epic #N, #N in a heading — first-appearance order, cap 5
  local n="$1" refs
  refs=$(cat "$RUN_DIR/body-$n.md" <(jq -r '.[].body' "$RUN_DIR/comments-$n.json") \
    | { grep -oiE '(part of #[0-9]+|epic #[0-9]+|^#{1,6} .*#[0-9]+)' || true; } \
    | { grep -oE '#[0-9]+' || true; } | tr -d '#' | awk '!seen[$0]++' | head -5 | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  id_state_set "$n" goal_refs "$refs"
  id_state_set "$n" goal_own_label "$(id_state_get_json "$n" '[.labels[] | select(startswith("goal:"))] | .[0] // null')"
}

# --------------------------------------------------------------- driver ----
# id_fail <n>: record why this issue stopped — the batch stop when one is
# in force (so every later issue reads the same reason), else its own error.
id_fail() { if [ "$STOP_BATCH" = 1 ]; then id_unevaluated "$1" "batch stopped: $STOP_REASON"; else id_unevaluated "$1" "$ISSUE_ERROR"; fi; }
id_collect() {
  id_preflight
  id_select
  local n
  # pass A
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ "$STOP_BATCH" = 1 ]; then id_unevaluated "$n" "batch stopped: $STOP_REASON"; continue; fi
    ISSUE_FAILED=0; ISSUE_ERROR=""
    id_gate "a-$n" || { id_fail "$n"; continue; }
    id_fetch "$n" || { id_fail "$n"; continue; }
  done < "$RUN_DIR/selected.txt"
  # the sweep, gated
  if [ "$STOP_BATCH" = 0 ]; then
    ISSUE_FAILED=0; ISSUE_ERROR=""
    if id_gate sweep; then id_sweep; else printf '[]' > "$RUN_DIR/shipped.json"; fi
  else printf '[]' > "$RUN_DIR/shipped.json"; fi
  # pass B
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qx "$n" "$RUN_DIR/failed.txt" && continue
    cut -f1 "$RUN_DIR/unevaluated.tsv" | grep -qx "$n" && continue
    if [ "$STOP_BATCH" = 1 ]; then id_unevaluated "$n" "batch stopped: $STOP_REASON"; continue; fi
    ISSUE_FAILED=0; ISSUE_ERROR=""
    id_gate "b-$n"   || { id_fail "$n"; continue; }
    id_comments "$n" || { id_fail "$n"; continue; }
    id_noise "$n"
    id_board "$n"    || { id_fail "$n"; continue; }
    id_dedupe "$n"   || { id_fail "$n"; continue; }
    id_goalrefs "$n"
    id_state_set "$n" self_authored "$(if [ "$(id_state_get "$n" .author)" = "$ME" ] && [ -n "$ME" ]; then echo true; else echo false; fi)"
    id_state_set "$n" evaluated 'true'
  done < "$RUN_DIR/selected.txt"
  if [ "$(cut -f1 "$RUN_DIR/unevaluated.tsv" | sort -u | wc -l | tr -d ' ')" -ge "$(sort -u "$RUN_DIR/selected.txt" | wc -l | tr -d ' ')" ]; then
    if [ -z "${SINCE_ARG:-}" ] && ! grep -qiE 'rate' "$RUN_DIR/unevaluated.tsv"; then exit 4; fi
    [ -n "${SINCE_ARG:-}" ] || exit 3
  fi
}

# --------------------------------------------------------------- guards ----
# id_verdict_guard <verdict> <open-json> <shipped-json> → "verdict|canonical|note"
id_verdict_guard() {
  local v="$1" open="$2" shipped="$3" verb ref set where note="" canon="null"
  verb=$(printf '%s' "$v" | sed -nE 's/^(likely-duplicate-of|already-fixed-by) #[0-9]+$/\1/p')
  ref=$(printf '%s' "$v" | sed -nE 's/^(likely-duplicate-of|already-fixed-by) #([0-9]+)$/\2/p')
  case "$v" in
    needed|unclear) ;;
    *)
      if [ "$verb" = likely-duplicate-of ]; then set="$open"; where="any open-issue or open-PR search result"
      elif [ "$verb" = already-fixed-by ]; then set="$shipped"; where="the PRs merged into the base branch after filing that name this issue"
      else note="'$v' is outside the verdict vocabulary; downgraded"; v="unclear"; fi
      if [ -n "$verb" ]; then
        if jq -e --argjson n "$ref" 'index($n) != null' <<<"$set" >/dev/null 2>&1; then canon="#$ref"
        else note="#$ref did not appear in $where; downgraded"; v="unclear"; fi
      fi ;;
  esac
  printf '%s|%s|%s\n' "$v" "$canon" "$note"
}
# id_effort_guard <proposed> <existing> → "effort|stance|note"
id_effort_guard() {
  local p="$1" e="$2" note="" stance
  case "$p" in medium|high|xhigh) ;; *) note="proposed '$p' is outside medium|high|xhigh (max is operator-only); clamped to xhigh"; p="xhigh" ;; esac
  if [ -n "$e" ]; then if [ "$e" = "$p" ]; then stance=agree; else stance=disagree; fi; else stance=propose; fi
  printf '%s|%s|%s\n' "$p" "$stance" "$note"
}
id_quarter() { local m; m=$(date -u +%m); m="${m#0}"; printf 'q%s-%s\n' "$(( (m - 1) / 3 + 1 ))" "$(date -u +%Y)"; }

# ------------------------------------------------------------- finalize ----
# Reads state-<n>.json + judgement-<n>.json, applies the guards, writes
# result-<n>.json, comment-<n>.md, report.txt, facts.json. Nothing is fetched.
id_finalize_issue() {
  local n="$1" st jd
  st=$(id_state_path "$n"); jd="$RUN_DIR/judgement-$n.json"
  [ "$(jq -r .evaluated "$st")" = true ] || return 0
  if [ ! -f "$jd" ]; then id_unevaluated "$n" "no judgement-$n.json — the orchestrator has not judged this issue"; return 0; fi
  if ! jq -e '(.classification|type=="string") and (.verdict|type=="string") and (.priority|type=="string") and (.proposed_effort|type=="string")
              and ((.evidence // {}) | type == "object" and all(.[]; type == "string"))
              and ((.decision_reason // null) | type == "string" or type == "null")
              and ((.decision_required // false) | type == "boolean")' "$jd" >/dev/null 2>&1; then
    id_unevaluated "$n" "judgement-$n.json malformed — classification/verdict/priority/proposed_effort must be strings, evidence an object of strings, decision_reason a string or null"; return 0
  fi
  local cls verdict prio peff decreq noise author self bp
  cls=$(jq -r .classification "$jd"); verdict=$(jq -r .verdict "$jd"); prio=$(jq -r .priority "$jd"); peff=$(jq -r .proposed_effort "$jd")
  decreq=$(jq -r '.decision_required // false' "$jd")
  noise=$(jq -r '.noise_signal // ""' "$st"); author=$(jq -r '.author // ""' "$st"); self=$(jq -r '.self_authored' "$st"); bp=$(jq -r '.board_priority // "none"' "$st")
  if [ -n "$noise" ]; then cls=noise; verdict=unclear; prio=none; fi
  if [ "$(jq -r .dedupe_skipped "$st")" = 1 ] && [ "$verdict" != unclear ] && [ -z "$noise" ]; then verdict=unclear; fi
  case "$cls" in bug|goal|idea|question|noise) ;; *) cls=question ;; esac
  case "$prio" in Urgent|High|Medium|Low|none) ;; *) prio=none ;; esac
  # Prose from the judgement is untrusted: one line each, @mentions neutralised in
  # backticks, #N kept only when N is in the fetched candidate set, else marked.
  local allowed
  allowed=$(jq -c '[(.candidates_open // [])[], (.candidates_shipped // [])[], (.fixed_by_unknown // [])[], (.in_flight // [])[], (.goal_refs // [])[]] | unique' "$st")
  jq -c --argjson allowed "$allowed" '
    def clean: gsub("[\r\n]+"; " ") | gsub("[[:space:]]+"; " ") | gsub("(?<u>@[A-Za-z0-9][A-Za-z0-9-]*)"; "`\(.u)`")
               | gsub("#(?<n>[0-9]+)"; (.n | tonumber) as $k | if ($allowed | index($k)) != null then "#\($k)" else "#\($k) (unverified)" end);
    {evidence: ((.evidence // {}) | with_entries(.value |= clean)), decision_reason: ((.decision_reason // null) | if . == null then null else clean end)}' \
    "$jd" > "$RUN_DIR/prose-$n.json"
  if [ "$self" != true ] && jq -r '[.evidence[], (.decision_reason // "")] | join(" ")' "$RUN_DIR/prose-$n.json" \
       | grep -qiE "(^|[^a-z])(close|closes|closed|closing|park|parked|parking|wontfix|won't fix|not planned)([^a-z]|$)"; then
    id_unevaluated "$n" "social rule: prose proposes close on another author's issue"; return 0
  fi
  local vg canon vnote eg effort stance enote
  vg=$(id_verdict_guard "$verdict" "$(jq -c '.candidates_open // []' "$st")" "$(jq -c '.candidates_shipped // []' "$st")")
  verdict="${vg%%|*}"; canon=$(printf '%s' "$vg" | cut -d'|' -f2); vnote="${vg##*|}"
  eg=$(id_effort_guard "$peff" "$(jq -r '.existing_effort // ""' "$st")")
  effort="${eg%%|*}"; stance=$(printf '%s' "$eg" | cut -d'|' -f2); enote="${eg##*|}"
  # goal
  local goal="null" gsrc=none gvia="" greason="" own ref l cur
  own=$(jq -r '.goal_own_label // empty' "$st")
  if [ -n "$own" ]; then goal="$own"; gsrc=own-label
  else
    if [ ! -s "$RUN_DIR/goal-registry.tsv" ]; then greason="goal registry empty"
    else
      for ref in $(jq -r '.goal_refs[]?' "$st"); do
        l=$(awk -F'\t' -v r="$ref" '$1 == r {print $2; exit}' "$RUN_DIR/goal-registry.tsv")
        if [ -n "$l" ]; then
          if [ "$goal" = null ]; then goal="$l"; gsrc=reference; gvia="$ref"
          elif [ "$l" != "$goal" ]; then greason="two goal epics referenced: #$gvia ($goal) and #$ref ($l)"; goal=null; gsrc=none; gvia=""; decreq=true; break; fi
        fi
      done
      [ "$gsrc" != none ] || [ -n "$greason" ] || greason="$(if [ "$(jq '.goal_refs | length' "$st")" = 0 ]; then echo "no part-of/epic reference"; else echo "referenced issues carry no goal:* label"; fi)"
    fi
  fi
  cur=$(id_quarter)
  # social rule
  local aref rec="" pnote=""
  if [ -n "$author" ]; then aref="@$author"; else aref="the author (account deleted)"; fi
  case "$verdict" in
    "likely-duplicate-of #"*) if [ "$self" = true ]; then rec="close as a duplicate of $canon"; else rec="for $aref: this reads as a duplicate of $canon — your call"; fi ;;
    "already-fixed-by #"*)    if [ "$self" = true ]; then rec="close — fixed by $canon"; else rec="for $aref: $canon appears to have fixed this — your call"; fi ;;
  esac
  if [ "$self" != true ] && [ "$bp" != none ] && [ "$bp" != "$prio" ]; then pnote="for $aref: the table says $prio; the board says $bp — left as is"; fi
  # needs_decision
  local nd=false
  [ "$verdict" = unclear ] && nd=true
  [ "$cls" = question ] && nd=true
  [ "$decreq" = true ] && nd=true
  case "$verdict" in "likely-duplicate-of #"*|"already-fixed-by #"*) [ "$self" = true ] || nd=true ;; esac
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg cls "$cls" --arg verdict "$verdict" --arg canon "$canon" --arg vnote "$vnote" --arg goal "$goal" --arg gsrc "$gsrc" --arg gvia "$gvia" --arg greason "$greason" \
     --arg prio "$prio" --arg effort "$effort" --arg stance "$stance" --arg enote "$enote" --arg rec "$rec" --arg pnote "$pnote" --argjson nd "$nd" \
     --arg sha "$BASE_SHA" --arg now "$now" --arg cur "$cur" --arg body "$RUN_DIR/comment-$n.md" \
     --arg trunc "$(cat "$RUN_DIR/shipped-truncated.txt" 2>/dev/null || echo false)" --slurpfile pr "$RUN_DIR/prose-$n.json" \
     '{number, title, url, state, author, self_authored, created_at, labels, existing_effort,
       board: {status: (.board_status // "none"), priority: (.board_priority // "none")},
       noise_signal, classification: $cls, verdict: $verdict, canonical: (if $canon == "null" then null else $canon end), verdict_note: $vnote,
       goal: {label: (if $goal == "null" then null else $goal end), source: $gsrc, via: (if $gvia == "" then null else ($gvia|tonumber) end), reason: $greason},
       priority: $prio, effort: $effort, effort_stance: $stance, effort_note: $enote, needs_decision: $nd,
       decision_reason: $pr[0].decision_reason, evidence: $pr[0].evidence,
       dedupe: {terms: (.terms // ""), skipped: ((.dedupe_skipped // 0) == 1), open_issues: (.dup_issues // []), open_prs: (.dup_prs // []),
                fixed_by: (.candidates_shipped // []), fixed_by_unknown: (.fixed_by_unknown // []), in_flight: (.in_flight // []), shipped_truncated: ($trunc == "true")},
       recommendation: (if $rec == "" then null else $rec end), priority_note: (if $pnote == "" then null else $pnote end),
       comment: {action: .comment_action, marker_id: .marker_id, body_path: $body, add_label: $nd},
       warnings: ([ $vnote, $enote ] | map(select(. != ""))),
       dev_sha: $sha, evaluated_at: $now, current_quarter: $cur}' \
     "$st" > "$RUN_DIR/result-$n.json"
  id_render_comment "$n"
}

id_render_comment() {
  local n="$1" r="$RUN_DIR/result-$n.json" out="$RUN_DIR/comment-$n.md"
  {
    printf '<!-- issue-details:v1 dev=%s -->\n## Issue details\n\n' "$(jq -r .dev_sha "$r")"
    printf '**#%s** %s\n\n' "$n" "$(jq -r .title "$r")"
    printf '```yaml\nclassification: %s\nverdict: %s\ncanonical: %s\ngoal: %s\npriority: %s\neffort: %s\nneeds_decision: %s\ndev_sha: %s\nevaluated_at: %s\n```\n\n' \
      "$(jq -r .classification "$r")" "$(jq -r .verdict "$r")" "$(jq -r '.canonical // "null" | if . == "null" then "null" else "\"" + . + "\"" end' "$r")" \
      "$(jq -r '.goal.label // "null" | if . == "null" then "null" else "\"" + . + "\"" end' "$r")" "$(jq -r .priority "$r")" "$(jq -r .effort "$r")" \
      "$(jq -r .needs_decision "$r")" "$(jq -r .dev_sha "$r")" "$(jq -r .evaluated_at "$r")"
    printf -- '- classification: %s — %s\n' "$(jq -r .classification "$r")" "$(jq -r '(.noise_signal // "") as $s | if $s != "" then $s else (.evidence.classification // "") end' "$r")"
    printf -- '- dedupe: %s\n' "$(jq -r '.dedupe | (if .skipped then "not run" else "searched `\(.terms)` → \(.open_issues | length) open issues, \(.open_prs | length) open PRs" end)
      + "; merged into base since filing naming this issue: " + (if (.fixed_by | length) == 0 then "none" else (.fixed_by | map("#\(.)") | join(", ")) end)
      + (if (.fixed_by_unknown | length) > 0 then " (unknown: " + (.fixed_by_unknown | map("#\(.)") | join(", ")) + " — closing list truncated)" else "" end)
      + "; in flight: " + (if (.in_flight | length) == 0 then "none" else (.in_flight | map("#\(.)") | join(", ")) end)' "$r")"
    [ -z "$(jq -r .verdict_note "$r")" ] || printf '  %s\n' "$(jq -r .verdict_note "$r")"
    printf -- '- goal: %s — %s\n' "$(jq -r '.goal.label // "none"' "$r")" "$(jq -r '.goal | if .source == "own-label" then "own label" elif .source == "reference" then "via #\(.via) (proposed: stamp the label)" else .reason end' "$r")"
    printf -- '- priority: %s — %s; board: %s / %s\n' "$(jq -r .priority "$r")" "$(jq -r '.evidence.priority // ""' "$r")" "$(jq -r '.board.status' "$r")" "$(jq -r '.board.priority' "$r")"
    [ -z "$(jq -r '.priority_note // ""' "$r")" ] || printf '  %s\n' "$(jq -r .priority_note "$r")"
    printf -- '- effort: %s — %s\n' "$(jq -r .effort "$r")" "$(jq -r 'if .effort_stance == "propose" then "proposed (no detent-agent block on the issue)" elif .effort_stance == "agree" then "agrees with the issue'"'"'s block" else "the issue'"'"'s block says \(.existing_effort); left as is" end + (if (.evidence.effort // "") != "" then "; " + .evidence.effort else "" end)' "$r")"
    [ -z "$(jq -r .effort_note "$r")" ] || printf '  %s\n' "$(jq -r .effort_note "$r")"
    printf -- '- decision: %s\n' "$(jq -r 'if .needs_decision then (.decision_reason // "a decision is required (see verdict / class)") else "none needed" end' "$r")"
    printf -- '- still-needed: not checked (v1)\n'
    [ -z "$(jq -r '.recommendation // ""' "$r")" ] || printf '%s\n' "$(jq -r .recommendation "$r")"
  } > "$out"
}

id_finalize() {
  local n
  while IFS= read -r n; do [ -n "$n" ] && id_finalize_issue "$n"; done < "$RUN_DIR/selected.txt"
  id_render_report
  id_render_facts
}

id_render_report() {
  local n r out="$RUN_DIR/report.txt"
  {
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      r="$RUN_DIR/result-$n.json"
      if [ ! -f "$r" ]; then printf '=== #%s === unevaluated: %s\n\n' "$n" "$(awk -F'\t' -v n="$n" '$1 == n {print $2; exit}' "$RUN_DIR/unevaluated.tsv")"; continue; fi
      jq -r --arg slug "$SLUG" '
        "=== #\(.number) · \(.title) ===\n" +
        "\($slug) · by \(.author // "(deleted)")\(if .self_authored then ", you" else "" end) · \(.state) · board \(.board.status)/\(.board.priority) · created \(.created_at[0:10])\n" +
        "  class     \(.classification | . + "               " | .[0:15]) \((.noise_signal // "") as $s | if $s != "" then $s else (.evidence.classification // "") end)\n" +
        "  verdict   \(.verdict | . + "               " | .[0:15]) \(.dedupe | if .skipped then "dedupe not run" else "`\(.terms)` → \(.open_issues|length) open issues, \(.open_prs|length) open PRs" end) · shipped naming it: \(.dedupe.fixed_by | if length==0 then "none" else map("#\(.)")|join(", ") end) · in flight: \(.dedupe.in_flight | if length==0 then "none" else map("#\(.)")|join(", ") end)\n" +
        "  goal      \((.goal.label // "none") | . + "               " | .[0:15]) \(.goal | if .source == "own-label" then "own label" elif .source == "reference" then "via #\(.via)" else .reason end)\n" +
        "  priority  \(.priority | . + "               " | .[0:15]) \(.evidence.priority // "")\(if .priority_note then "  (" + .priority_note + ")" else "" end)\n" +
        "  effort    \("\(.effort) (\(.effort_stance))" | . + "               " | .[0:15]) \(if .existing_effort != "" then "issue block: \(.existing_effort)" else "no detent-agent block on the issue" end)\n" +
        "  decision  \(if .needs_decision then "yes" else "no" end | . + "               " | .[0:15]) \(.decision_reason // "")\n" +
        "  comment   \(.comment.action)\(if .comment.action == "edit" then " #\(.marker_id)" else "" end)\(if .needs_decision and (.comment.action == "create" or .comment.action == "edit") then "  + label triage:needs-decision" else "" end)\n"' "$r"
    done < "$RUN_DIR/selected.txt"
    printf -- '--- %s issue(s) · %s @ %s · registry: %s goal label(s), %s issue(s) · files: %s\n' \
      "$(sort -u "$RUN_DIR/selected.txt" | wc -l | tr -d ' ')" "$BASE" "$(printf '%s' "$BASE_SHA" | cut -c1-7)" \
      "$(grep -c . "$RUN_DIR/goal-labels.txt" || true)" "$(grep -c . "$RUN_DIR/goal-registry.tsv" || true)" "$RUN_DIR"
  } > "$out"
}

id_render_facts() {
  local files
  files=$(ls "$RUN_DIR"/result-*.json 2>/dev/null || true)
  jq -n --slurpfile run "$RUN_DIR/run.json" \
     --slurpfile results <(if [ -n "$files" ]; then cat $files; fi) \
     --slurpfile unev <(awk -F'\t' '{printf "{\"number\":%s,\"reason\":%s}\n", $1, ($2 | @json)}' "$RUN_DIR/unevaluated.tsv" 2>/dev/null || jq -nR 'inputs | split("\t") | {number: (.[0]|tonumber), reason: .[1]}' "$RUN_DIR/unevaluated.tsv") \
     --slurpfile warns <(jq -R . "$RUN_DIR/warnings.txt") \
     --arg labels "$(tr '\n' ' ' < "$RUN_DIR/goal-labels.txt")" --arg reg "$(grep -c . "$RUN_DIR/goal-registry.tsv" || true)" --arg run_dir "$RUN_DIR" \
     '{schema: 1, generated_at: (now | todate), host: $run[0].host, repo: $run[0].repo, base: $run[0].base, dev_sha: $run[0].base_sha, me: $run[0].me,
       goal_registry: {labels: ($labels | split(" ") | map(select(length > 0))), issues: ($reg | tonumber)},
       issues: $results, unevaluated: $unev, warnings: $warns, files: {run_dir: $run_dir}}' > "$RUN_DIR/facts.json"
}

# ----------------------------------------------------------------- post ----
# id_refresh <n>: fail-closed re-read against the state file's snapshot.
id_refresh() {
  local n="$1" st r rf ok=0 note=""
  st=$(id_state_path "$n"); rf="$RUN_DIR/refresh-$n"
  local action mid mupd
  action=$(jq -r '.comment_action // ""' "$st"); mid=$(jq -r '.marker_id // empty' "$st"); mupd=$(jq -r '.marker_updated // ""' "$st")
  if pr_facts_gh issue view "$n" -R "$SLUG" --json state,updatedAt,labels > "$rf.issue" 2>/dev/null \
     && jq -e '(.state|type=="string") and (.updatedAt|type=="string") and (.labels|type=="array")' "$rf.issue" >/dev/null 2>&1 \
     && pr_facts_gh api --hostname "$HOST" --paginate --slurp "repos/$SLUG/issues/$n/comments?per_page=100" > "$rf.raw" 2>/dev/null \
     && jq -e 'type == "array" and all(.[]; type == "array" and all(.[]; type == "object" and (.id|type=="number") and (.body|type=="string") and (.updated_at|type=="string")))' "$rf.raw" >/dev/null 2>&1; then
    local now_state now_updated now_labels now_fp now_count now_mid now_mupd
    now_state=$(jq -r .state "$rf.issue"); now_updated=$(jq -r .updatedAt "$rf.issue"); now_labels=$(jq -c '[.labels[].name] | sort' "$rf.issue")
    now_fp=$(jq -c '[.[][] | {id, updated_at}] | sort_by(.id)' "$rf.raw")
    jq -c --arg me "$ME" --arg re "$MARKER_RE" '[.[][] | select((.user.login // null) == $me) | select(.body | split("\n")[0] | test($re)) | {id, updated_at}] | sort_by(.id)' "$rf.raw" > "$rf.markers" 2>/dev/null || printf 'x' > "$rf.markers"
    now_count=$(jq 'length' "$rf.markers" 2>/dev/null || true); now_mid=$(jq -r '.[0].id // empty' "$rf.markers" 2>/dev/null || true); now_mupd=$(jq -r '.[0].updated_at // empty' "$rf.markers" 2>/dev/null || true)
    case "$now_count" in ''|*[!0-9]*) now_count=-1 ;; esac
    if [ "$now_count" -lt 0 ]; then note="refresh returned unreadable comments — not writing"
    elif [ "$now_state" != OPEN ]; then note="issue is $now_state — not writing"
    elif [ "$now_updated" != "$(jq -r .updated_at "$st")" ]; then note="issue changed since evaluation (updatedAt) — re-run"
    elif [ "$now_labels" != "$(jq -c .labels "$st")" ]; then note="labels changed since evaluation — re-run"
    elif [ "$now_fp" != "$(jq -c .comments_fingerprint "$st")" ]; then note="comments changed since evaluation (a comment was added, removed, or edited) — re-run"
    elif [ "$now_count" -gt 1 ]; then note="$now_count owned marker comments — delete all but one by hand; not writing"
    elif [ "$action" = create ] && [ -n "$now_mid" ]; then note="a marker comment appeared since the read (#$now_mid) — not posting a second"
    elif [ "$action" = edit ] && [ "$now_mid" != "$mid" ]; then note="the marker comment changed since the read — re-run"
    elif [ "$action" = edit ] && [ "$now_mupd" != "$mupd" ]; then note="marker comment $mid was edited since the read — re-run"
    elif [ "$action" = create ] || [ "$action" = edit ]; then ok=1
    else note="no write action for this issue ($action)"; fi
  else
    note="pre-write refresh failed (API or JSON error) — not writing"
  fi
  id_state_set "$n" write_ok "$ok"
  id_state_set "$n" write_note '$v' --arg v "$note"
  [ "$ok" = 1 ]
}

# id_dispatch <n>: exactly one of create/edit, label only after success and
# only when needs_decision. The create is a bare gh api -X POST — never the
# retry wrapper — with one confirming read on failure and no retry.
id_dispatch() {
  local n="$1" st r wrote="" note action mid nd body rf
  st=$(id_state_path "$n"); r="$RUN_DIR/result-$n.json"; rf="$RUN_DIR/refresh-$n"; body="$RUN_DIR/comment-$n.md"
  note=$(jq -r '.write_note // ""' "$st"); action=$(jq -r '.comment_action // ""' "$st"); mid=$(jq -r '.marker_id // empty' "$st"); nd=$(jq -r '.needs_decision // false' "$r")
  if [ "$(jq -r '.write_ok // 0' "$st")" = 1 ]; then
    case "$action" in
      create)
        if gh api --hostname "$HOST" -X POST "repos/$SLUG/issues/$n/comments" -F body=@"$body" > "$rf.post" 2>/dev/null; then wrote="posted"
        elif gh api --hostname "$HOST" --paginate --slurp "repos/$SLUG/issues/$n/comments?per_page=100" > "$rf.after" 2>/dev/null \
             && jq -e --arg me "$ME" --arg re "$MARKER_RE" '[.[][] | select((.user.login // null) == $me) | select(.body | split("\n")[0] | test($re))] | length > 0' "$rf.after" >/dev/null 2>&1; then
          wrote="posted (confirmed after an ambiguous response)"
        else note="comment create failed — not retried (a POST is not idempotent); re-run, which edits it if it landed"; fi ;;
      edit)
        if gh api --hostname "$HOST" -X PATCH "repos/$SLUG/issues/comments/$mid" -F body=@"$body" > "$rf.patch" 2>/dev/null; then wrote="edited #$mid"
        elif gh api --hostname "$HOST" "repos/$SLUG/issues/comments/$mid" > "$rf.patched" 2>/dev/null \
             && jq -e --rawfile want "$body" '.body == ($want | rtrimstr("\n"))' "$rf.patched" >/dev/null 2>&1; then
          wrote="edited #$mid (confirmed after an ambiguous response)"
        else note="comment edit failed — not retried; re-run"; fi ;;
      *) note="no write action for this issue ($action)" ;;
    esac
    if [ -n "$wrote" ] && [ "$nd" = true ]; then
      if gh issue edit "$n" -R "$SLUG" --add-label "triage:needs-decision" > "$rf.label" 2>/dev/null; then wrote="$wrote, label added"
      elif gh api --hostname "$HOST" "repos/$SLUG/issues/$n/labels" > "$rf.labels" 2>/dev/null \
           && jq -e 'map(.name) | index("triage:needs-decision") != null' "$rf.labels" >/dev/null 2>&1; then
        wrote="$wrote, label added (confirmed after an ambiguous response)"
      else wrote="$wrote, label add failed — not retried"; fi
    fi
  fi
  if [ -n "$wrote" ]; then printf '#%s %s\n' "$n" "$wrote"; else printf '#%s skipped — %s\n' "$n" "${note:-no write}"; fi
}

id_post() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ -f "$RUN_DIR/result-$n.json" ] || continue
    if [ "$(jq -r .state "$RUN_DIR/result-$n.json")" != OPEN ]; then printf '#%s skipped — issue is %s\n' "$n" "$(jq -r .state "$RUN_DIR/result-$n.json")"; continue; fi
    case "$(jq -r .comment.action "$RUN_DIR/result-$n.json")" in create|edit) ;; *) printf '#%s skipped — %s\n' "$n" "$(jq -r .comment.action "$RUN_DIR/result-$n.json")"; continue ;; esac
    id_refresh "$n" || true
    id_dispatch "$n"
  done < "$RUN_DIR/selected.txt"
}

id_print() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] && [ -f "$RUN_DIR/comment-$n.md" ] && { printf '\n----- comment for #%s -----\n' "$n"; cat "$RUN_DIR/comment-$n.md"; }
  done < "$RUN_DIR/selected.txt"
}

# ---------------------------------------------------------------- main -----
id_load_run() {  # run-wide constants for finalize/print/post, from run.json
  [ -f "$RUN_DIR/run.json" ] || { echo "issue-details: $RUN_DIR has no run.json — run collect first" >&2; exit 2; }
  HOST=$(jq -r .host "$RUN_DIR/run.json"); SLUG=$(jq -r .repo "$RUN_DIR/run.json"); ME=$(jq -r .me "$RUN_DIR/run.json")
  BASE=$(jq -r .base "$RUN_DIR/run.json"); BASE_SHA=$(jq -r .base_sha "$RUN_DIR/run.json"); PROJECT_SLUG=$(jq -r '.project_slug // ""' "$RUN_DIR/run.json")
  OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
}

id_main() {
  local cmd="${1:-}"; shift || true
  RUN_DIR=""; SINCE_ARG=""; BASE_ARG=""; DO_DUP=1; ISSUE_ARGS=""; URL_HOST=""; URL_SLUG=""
  local skip="" arg url_num
  for arg in "$@"; do
    case "$skip" in
      run) RUN_DIR="$arg"; skip=""; continue ;;
      since) SINCE_ARG="$arg"; skip=""; continue ;;
      base) BASE_ARG="$arg"; skip=""; continue ;;
    esac
    case "$arg" in
      --run-dir) skip=run ;;
      --since) skip=since ;;
      --base) skip=base ;;
      --no-dup-search) DO_DUP=0 ;;
      --*) echo "issue-details: unknown flag $arg" >&2; exit 2 ;;
      https://*)
        URL_HOST=$(printf '%s' "$arg" | sed -nE 's#^https?://([^/]+)/.*#\1#p')
        URL_SLUG=$(printf '%s' "$arg" | sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/issues/[0-9]+/?$#\1#p')
        url_num=$(printf '%s' "$arg" | sed -nE 's#^https?://[^/]+/[^/]+/[^/]+/issues/([0-9]+)/?$#\1#p')
        [ -n "$URL_SLUG" ] && [ -n "$url_num" ] || { echo "issue-details: not an issue URL: $arg" >&2; exit 2; }
        ISSUE_ARGS="$ISSUE_ARGS $url_num" ;;
      *) printf '%s' "$arg" | grep -qE '^[0-9]+$' || { echo "issue-details: not an issue number: $arg" >&2; exit 2; }
         ISSUE_ARGS="$ISSUE_ARGS $arg" ;;
    esac
  done
  [ -z "$skip" ] || { echo "issue-details: $skip flag needs a value" >&2; exit 2; }
  [ -n "$RUN_DIR" ] || { echo "issue-details: --run-dir is required" >&2; exit 2; }
  case "$cmd" in
    collect)
      if [ -n "$SINCE_ARG" ] && ! printf '%s' "$SINCE_ARG" | grep -qE '^[1-9][0-9]*d$'; then echo "issue-details: --since takes <n>d with n a positive integer" >&2; exit 2; fi
      [ -n "$SINCE_ARG" ] || [ -n "${ISSUE_ARGS# }" ] || { echo "issue-details: give issue numbers or --since <n>d" >&2; exit 2; }
      if [ -n "$SINCE_ARG" ] && [ -n "${ISSUE_ARGS# }" ]; then echo "issue-details: --since and issue numbers are mutually exclusive" >&2; exit 2; fi
      if [ -n "$URL_SLUG" ] && [ "$(printf '%s' "${ISSUE_ARGS# }" | wc -w | tr -d ' ')" -gt 1 ]; then echo "issue-details: a URL argument must be the only issue argument" >&2; exit 2; fi
      mkdir -p "$RUN_DIR"; id_collect ;;
    finalize) id_load_run; id_finalize ;;
    print)    id_load_run; id_print ;;
    post)     id_load_run; id_post ;;
    *) sed -n '2,20p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then id_main "$@"; fi
