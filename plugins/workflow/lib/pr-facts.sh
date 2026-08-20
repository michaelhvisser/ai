#!/bin/bash
# Read-only GitHub fact recipes for the pr-details skill.
#
# Every function here issues GET requests only: `gh api` with no --method, or
# `gh api graphql` with a query operation. Nothing in this file mutates GitHub,
# the working tree, or the index.
#
# Sourced into both bash and zsh. Globals are UPPERCASE; locals are prefixed and
# never named `path`, `status`, `cdpath`, `argv`, or any other name zsh ties to
# special shell state. No GNU-only flags, no `timeout(1)` (absent on macOS).
#
# Complements lib/github-rest.sh — source both. `github_pr`,
# `github_current_pr`, `github_pr_reviews`, and `github_check_snapshot` stay
# there and are used unchanged.

PR_FACTS_RETRIES="${PR_FACTS_RETRIES:-3}"
PR_FACTS_BACKOFF="${PR_FACTS_BACKOFF:-2}"

# pr_facts_gh <gh-args...>
# Retry wrapper for read-only `gh` calls. 3 attempts, 2s/4s/8s with ±20% jitter.
# Retries 5xx, secondary rate limits, and connection resets. Never retries 401,
# 404, or a primary rate-limit 403 — those are terminal for the caller.
# stdout is the response; stderr carries the last error. Returns gh's exit code.
pr_facts_gh() {
  local pf_attempt=1
  local pf_delay="$PR_FACTS_BACKOFF"
  local pf_err
  local pf_out
  local pf_rc
  local pf_jitter

  while :; do
    pf_err=$(mktemp) || return 1
    pf_out=$(gh "$@" 2>"$pf_err")
    pf_rc=$?
    if [ "$pf_rc" -eq 0 ]; then
      rm -f "$pf_err"
      printf '%s' "$pf_out"
      return 0
    fi
    if [ "$pf_attempt" -ge "$PR_FACTS_RETRIES" ]; then
      cat "$pf_err" >&2
      rm -f "$pf_err"
      return "$pf_rc"
    fi
    if ! grep -qEi 'HTTP (5[0-9][0-9])|secondary rate limit|Retry-After|connection reset|EOF' "$pf_err"; then
      cat "$pf_err" >&2
      rm -f "$pf_err"
      return "$pf_rc"
    fi
    rm -f "$pf_err"
    pf_jitter=$(( (RANDOM % 5) - 2 ))
    sleep "$(( pf_delay + pf_jitter < 1 ? 1 : pf_delay + pf_jitter ))"
    pf_delay=$(( pf_delay * 2 ))
    pf_attempt=$(( pf_attempt + 1 ))
  done
}

# pr_facts_graphql_ok <response-json>
# A GraphQL response carrying both `data` and a non-empty `errors[]` is a
# failure of the fact it was fetching, not a success. Returns 1 and prints the
# error messages when the response is partial.
pr_facts_graphql_ok() {
  local pf_resp="${1:?response JSON is required}"
  local pf_errs

  pf_errs=$(jq -r '(.errors // []) | map(.message) | join("; ")' <<<"$pf_resp" 2>/dev/null) || return 1
  [ -z "$pf_errs" ] && return 0
  printf 'partial GraphQL data: %s\n' "$pf_errs" >&2
  return 1
}

# pr_facts_rate_gate <host> <graphql-reserve> <rest-reserve> <search-reserve>
# One `gh api rate_limit` call covering all three independent buckets. Prints
# one line per bucket below its reserve and returns 1; silent and 0 otherwise.
# Returns 2 when the endpoint itself is unreadable.
pr_facts_rate_gate() {
  local pf_host="${1:?host is required}"
  local pf_gmin="${2:-1000}"
  local pf_rmin="${3:-1000}"
  local pf_smin="${4:-5}"
  local pf_rl
  local pf_violations

  pf_rl=$(pr_facts_gh api --hostname "$pf_host" rate_limit) || return 2
  pf_violations=$(jq -r \
    --argjson gmin "$pf_gmin" --argjson rmin "$pf_rmin" --argjson smin "$pf_smin" '
    .resources
    | [ (if .graphql.remaining < $gmin then "graphql \(.graphql.remaining)/\(.graphql.limit) < reserve \($gmin)" else empty end),
        (if .core.remaining    < $rmin then "core \(.core.remaining)/\(.core.limit) < reserve \($rmin)"          else empty end),
        (if .search.remaining  < $smin then "search \(.search.remaining)/\(.search.limit) < reserve \($smin)"    else empty end) ]
    | .[]' <<<"$pf_rl") || return 2

  [ -z "$pf_violations" ] && return 0
  printf '%s\n' "$pf_violations"
  return 1
}

# pr_facts_rules <host> <slug> <base-branch>
# Aggregated merge contract for the base branch. Several rulesets can contribute
# rules to one branch, so every aggregate is explicit: union for required
# checks, ANY for booleans, MAX for approvals, intersection for merge methods.
#
# `rules/branches/<branch>` returns an EMPTY ARRAY (exit 0) when no ruleset
# applies — verified; it is not a 404 — so emptiness, not the exit code, selects
# the branch-protection fallback.
#
# `unknown[]` holds rule types this skill does not model. Types that cannot
# block merging an already-open PR (`creation`, `deletion`, `update`,
# `non_fast_forward` — they restrict branch mutation, not merge) are recorded in
# `ignored[]` instead, so they never sit in the ready predicate's way.
pr_facts_rules() {
  local pf_host="${1:?host is required}"
  local pf_slug="${2:?slug is required}"
  local pf_base="${3:?base branch is required}"
  local pf_raw
  local pf_count
  local pf_prot

  pf_raw=$(pr_facts_gh api --hostname "$pf_host" "repos/$pf_slug/rules/branches/$pf_base" 2>/dev/null) || pf_raw=""
  pf_count=$(jq 'length' <<<"${pf_raw:-[]}" 2>/dev/null) || pf_count=0

  if [ "${pf_count:-0}" -gt 0 ]; then
    jq -c '
      def anyrule($t; f): [ .[] | select(.type == $t) | .parameters | f ] | any;
      {
        source: "ruleset",
        advisory: false,
        ruleset_ids: ([ .[] | .ruleset_id ] | unique),
        required_checks: ([ .[] | select(.type == "required_status_checks")
                            | .parameters.required_status_checks[]?
                            | {context, integration_id: (.integration_id // null)} ] | unique),
        strict_up_to_date: anyrule("required_status_checks"; .strict_required_status_checks_policy == true),
        threads_required: anyrule("pull_request"; .required_review_thread_resolution == true),
        approvals_required: ([ .[] | select(.type == "pull_request")
                               | .parameters.required_approving_review_count // 0 ] | max // 0),
        code_owner_review: anyrule("pull_request"; .require_code_owner_review == true),
        last_push_approval: anyrule("pull_request"; .require_last_push_approval == true),
        extra_approval_unattributed: anyrule("pull_request"; .require_extra_approval_for_unattributed_changes == true),
        dismiss_stale_on_push: anyrule("pull_request"; .dismiss_stale_reviews_on_push == true),
        merge_methods: ([ .[] | select(.type == "pull_request")
                          | .parameters.allowed_merge_methods // empty ]
                        | if length == 0 then ["merge","squash","rebase"]
                          else reduce .[] as $m (.[0]; [ .[] | select(. as $x | $m | index($x)) ]) end),
        ignored: ([ .[] | select(.type as $t
                                 | ["creation","deletion","update","non_fast_forward"] | index($t))
                    | .type ] | unique),
        unknown: ([ .[] | select(.type as $t
                                 | ["required_status_checks","pull_request",
                                    "creation","deletion","update","non_fast_forward"]
                                 | index($t) | not)
                    | {type, ruleset_id} ] | unique)
      }' <<<"$pf_raw"
    return 0
  fi

  pf_prot=$(pr_facts_gh api --hostname "$pf_host" "repos/$pf_slug/branches/$pf_base/protection" 2>/dev/null) || pf_prot=""
  if [ -n "$pf_prot" ]; then
    jq -c '{
      source: "protection", advisory: false, ruleset_ids: [],
      required_checks: ([ .required_status_checks.checks[]? | {context, integration_id: (.app_id // null)} ]),
      strict_up_to_date: (.required_status_checks.strict // false),
      threads_required: (.required_conversation_resolution.enabled // false),
      approvals_required: (.required_pull_request_reviews.required_approving_review_count // 0),
      code_owner_review: (.required_pull_request_reviews.require_code_owner_reviews // false),
      last_push_approval: (.required_pull_request_reviews.require_last_push_approval // false),
      extra_approval_unattributed: false,
      dismiss_stale_on_push: (.required_pull_request_reviews.dismiss_stale_reviews // false),
      merge_methods: ["merge","squash","rebase"], ignored: [], unknown: []
    }' <<<"$pf_prot"
    return 0
  fi

  printf '%s\n' '{"source":"none","advisory":true,"ruleset_ids":[],"required_checks":[],"strict_up_to_date":false,"threads_required":false,"approvals_required":0,"code_owner_review":false,"last_push_approval":false,"extra_approval_unattributed":false,"dismiss_stale_on_push":false,"merge_methods":["merge","squash","rebase"],"ignored":[],"unknown":[]}'
}

# pr_facts_check_matrix <host> <slug> <head-sha>
# Check runs merged with legacy commit statuses, carrying the `app_id` that a
# ruleset's `integration_id` is matched against. `gh pr view --json
# statusCheckRollup` does NOT expose an app id, and `github_check_snapshot`
# drops it, so the required-set match needs this shape.
# Legacy statuses have no app and report `app_id: null`.
pr_facts_check_matrix() {
  local pf_host="${1:?host is required}"
  local pf_slug="${2:?slug is required}"
  local pf_sha="${3:?head SHA is required}"
  local pf_runs
  local pf_status

  pf_runs=$(pr_facts_gh api --hostname "$pf_host" --paginate --slurp \
    "repos/$pf_slug/commits/$pf_sha/check-runs?per_page=100") || return 1
  pf_status=$(pr_facts_gh api --hostname "$pf_host" \
    "repos/$pf_slug/commits/$pf_sha/status") || return 1

  jq -cn --arg sha "$pf_sha" --argjson runs "$pf_runs" --argjson st "$pf_status" '
    ([ $runs[]?.check_runs[]? ]
     | sort_by([(.app.slug // ""), .name, .id]) | group_by([(.app.slug // ""), .name])
     | map(max_by(.id))
     | map({kind:"check-run", name:.name, app_id:(.app.id // null), app_slug:(.app.slug // null),
            state:(if .status == "completed" then (.conclusion // "unknown") else .status end),
            terminal:(.status == "completed"),
            successful:(.status == "completed"
                        and ((.conclusion) as $c | ["success","neutral","skipped"] | index($c) != null))})) as $checks
    | ([ $st.statuses[]? ] | sort_by([.context, .id]) | group_by(.context) | map(max_by(.id))
     | map({kind:"status", name:.context, app_id:null, app_slug:null,
            state:.state, terminal:(.state != "pending"), successful:(.state == "success")})) as $legacy
    | {sha:$sha, items: (($checks + $legacy) | sort_by(.name))}'
}

# pr_facts_ci_state <rules-json> <matrix-json>
# Materializes the REQUIRED set first, then matches observations into it. A
# required context absent from the head SHA's checks is `missing` and folds into
# `pending` — never into green. This is the vacuous-green guard: without it,
# "all required pass" is trivially true when nothing required reported at all.
pr_facts_ci_state() {
  local pf_rules="${1:?rules JSON is required}"
  local pf_matrix="${2:?matrix JSON is required}"

  jq -cn --argjson rules "$pf_rules" --argjson matrix "$pf_matrix" '
    ($matrix.items) as $obs
    | ([ $rules.required_checks[]
         | . as $r
         | ($obs | map(select(.name == $r.context
                              and ($r.integration_id == null or .app_id == $r.integration_id)))
                 | first) as $hit
         | $r + {state: (if $hit == null then "missing"
                         elif ($hit.terminal | not) then "pending"
                         elif $hit.successful then "pass"
                         else "fail" end)} ]) as $required
    | ([ $required[] | select(.state == "missing") | .context ]) as $missing
    | ($required | map(.context)) as $reqnames
    | {
        required: $required,
        missing: $missing,
        observed: [ $obs[] | . + {required: (.name as $nm | ($reqnames | index($nm)) != null)} ],
        state: (
          if ($required | any(.state == "fail")) then "red"
          elif ($required | any(.state == "pending" or .state == "missing")) then "pending"
          elif ($required | length) > 0 then
            (if ([ $obs[] | select(.terminal and (.successful | not))
                   | select(.name as $nm | ($reqnames | index($nm)) == null) ] | length) > 0
             then "partial-red" else "green" end)
          elif ($obs | length) == 0 then "none"
          elif ($obs | any(.terminal and (.successful | not))) then "red"
          elif ($obs | any(.terminal | not)) then "pending"
          else "green" end)
      }'
}

# pr_facts_review_threads <host> <owner> <name> <pr-number>
# Fully paginated review threads. The first page passes NO cursor (`-F
# after=null` — gh converts the literal to JSON null); an empty string is not a
# valid cursor. Comments are `first:1` + `last:1` because only the thread's
# origin author and its latest author are classification inputs; `first:50`
# silently reports the wrong last commenter on any thread past 50 comments.
# `paginated_complete:false` means the caller must treat thread counts as
# unknown, never as zero.
pr_facts_review_threads() {
  local pf_host="${1:?host is required}"
  local pf_owner="${2:?owner is required}"
  local pf_name="${3:?repo name is required}"
  local pf_num="${4:?PR number is required}"
  local pf_query
  local pf_cursor="null"
  local pf_page
  local pf_acc="[]"
  local pf_total=0
  local pf_complete="true"

  pf_query='query($o:String!,$n:String!,$num:Int!,$after:String){
  repository(owner:$o,name:$n){ pullRequest(number:$num){
    reviewThreads(first:100, after:$after){ totalCount pageInfo{hasNextPage endCursor}
      nodes{ id isResolved isOutdated path line
        origin: comments(first:1){ totalCount nodes{ author{login __typename} body createdAt } }
        latest: comments(last:1){ nodes{ author{login __typename} body createdAt } } } } } } }'

  while :; do
    pf_page=$(pr_facts_gh api --hostname "$pf_host" graphql -f query="$pf_query" \
      -f o="$pf_owner" -f n="$pf_name" -F num="$pf_num" -F after="$pf_cursor") \
      || { pf_complete="false"; break; }
    pr_facts_graphql_ok "$pf_page" || { pf_complete="false"; break; }
    pf_total=$(jq -r '.data.repository.pullRequest.reviewThreads.totalCount' <<<"$pf_page")
    pf_acc=$(jq -c --argjson acc "$pf_acc" \
      '$acc + .data.repository.pullRequest.reviewThreads.nodes' <<<"$pf_page") \
      || { pf_complete="false"; break; }
    [ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$pf_page")" = "true" ] || break
    pf_cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$pf_page")
  done

  jq -cn --argjson nodes "$pf_acc" --argjson total "${pf_total:-0}" \
    --argjson complete "$pf_complete" \
    '{total:$total, fetched:($nodes|length), paginated_complete:$complete, nodes:$nodes}'
}

# pr_facts_board <host> <owner> <name> issue|pullRequest <number>
# Projects v2 items and their field values for one issue or PR. Detent's board
# item is the ISSUE; the PR usually carries a stray row that must not be read as
# the issue's state.
pr_facts_board() {
  local pf_host="${1:?host is required}"
  local pf_owner="${2:?owner is required}"
  local pf_name="${3:?repo name is required}"
  local pf_kind="${4:?issue or pullRequest is required}"
  local pf_num="${5:?number is required}"
  local pf_query
  local pf_resp

  pf_query="query(\$o:String!,\$n:String!,\$num:Int!,\$after:String){
  repository(owner:\$o,name:\$n){ ${pf_kind}(number:\$num){
    number title state url
    labels(first:50){ nodes{ name } }
    projectItems(first:20, after:\$after){ totalCount pageInfo{hasNextPage endCursor}
      nodes{ id project{ id number title }
        fieldValues(first:30){ nodes{
          ... on ProjectV2ItemFieldSingleSelectValue { name field{ ... on ProjectV2FieldCommon { name } } }
          ... on ProjectV2ItemFieldTextValue      { text field{ ... on ProjectV2FieldCommon { name } } }
          ... on ProjectV2ItemFieldNumberValue    { number field{ ... on ProjectV2FieldCommon { name } } }
        } } } } } } }"

  pf_resp=$(pr_facts_gh api --hostname "$pf_host" graphql -f query="$pf_query" \
    -f o="$pf_owner" -f n="$pf_name" -F num="$pf_num" -F after=null) || return 1
  pr_facts_graphql_ok "$pf_resp" || return 1

  jq -c --arg kind "$pf_kind" '.data.repository[$kind]
    | {number, title, state, url,
       labels: [.labels.nodes[].name],
       items: [ .projectItems.nodes[]
                | {item_id:.id, project_id:.project.id, project:.project.title,
                   fields: ([ .fieldValues.nodes[] | select(.field != null)
                              | {key:.field.name, value:(.name // .text // (.number|tostring))} ]
                            | map({(.key): .value}) | add // {})} ],
       items_complete: (.projectItems.pageInfo.hasNextPage | not)}' <<<"$pf_resp"
}

# pr_facts_compare <host> <slug> <base> <head-ref-or-sha>
# Behind/ahead counts. `behind_by > 0` under a strict ruleset is *rebase
# required* — the server refuses the merge regardless of CI.
# For a fork PR the head side must be `<head-owner>:<head-ref>`.
pr_facts_compare() {
  local pf_host="${1:?host is required}"
  local pf_slug="${2:?slug is required}"
  local pf_base="${3:?base is required}"
  local pf_head="${4:?head is required}"

  pr_facts_gh api --hostname "$pf_host" "repos/$pf_slug/compare/$pf_base...$pf_head" \
    | jq -c '{status, ahead_by, behind_by}'
}

# pr_facts_shared_files <host> <slug> <pr-number> <this-pr-files-json>
# Duplicate signal 2: other open PRs touching this PR's files. `gh` has no
# --argjson and `--jq` takes exactly one expression, so this pipes into
# standalone jq. The 50-PR cap is the caller's `truncated` flag.
pr_facts_shared_files() {
  local pf_host="${1:?host is required}"
  local pf_slug="${2:?slug is required}"
  local pf_num="${3:?PR number is required}"
  local pf_mine="${4:?file list JSON is required}"

  pr_facts_gh pr list -R "$pf_slug" --state open --limit 50 \
    --json number,title,headRefName,files \
    | jq -c --argjson mine "$pf_mine" --argjson me "$pf_num" '
        [ .[]
          | select(.number != $me)
          | {number, title, headRefName,
             shared: ([.files[].path]
                      | map(select(test("(^|/)(_generated|__snapshots__)/") | not))
                      | map(select(test("(pnpm-lock\\.yaml|package-lock\\.json|yarn\\.lock|bun\\.lock)$") | not))
                      | map(select(. as $f | $mine | index($f))))}
          | select((.shared | length) > 0) ]'
}

# pr_facts_run_dir <scratch-dir> <pr-number> <head-sha>
# Unique per invocation: PR number + head SHA + random suffix. Two concurrent
# runs on the same PR at the same SHA never share a mutable path, which is why
# there is no lock file, no shared facts.json, and no `.done` marker.
pr_facts_run_dir() {
  local pf_scratch="${1:?scratch dir is required}"
  local pf_num="${2:?PR number is required}"
  local pf_sha="${3:?head SHA is required}"
  local pf_rand
  local pf_dir

  pf_rand=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  pf_dir="$pf_scratch/pr-details/run/${pf_num}-$(printf '%s' "$pf_sha" | cut -c1-12)-${pf_rand}"
  mkdir -p "$pf_dir" || return 1
  printf '%s\n' "$pf_dir"
}
