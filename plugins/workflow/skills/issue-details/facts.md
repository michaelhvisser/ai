# Facts — Phases 0–1

Every recipe here is read-only and was executed against `getparable/parable` before being
written down. After identity is resolved, every `gh` call goes through `pr_facts_gh` (the
retry wrapper from `lib/pr-facts.sh`) or `issue_gh` (§1, the per-issue wrapper over it) and
is host- and repo-explicit. The two identity probes in §0a are deliberately raw — their exit
code *is* the fact, and a retry would only delay a refusal.

---

## §0 Phase 0 — Preflight

Ordering is load-bearing: **identity first**, then auth for that host, then the rate gate,
then the run-wide fetches every issue shares.

### §0a Resolve identity

An issue argument may be a full URL; it sets host, repository, and number, and the
`SKILL.md` argument loop has already split it into `URL_HOST`, `URL_SLUG`, and the bare
number. A URL that resolves a different repository from the checkout's is exit 4 — never
report on repo A while sitting in repo B.

```bash
SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 4
HOST=$(gh repo view --json url --jq '.url | sub("^https?://";"") | split("/")[0]')
if [ -n "${URL_SLUG:-}" ] && { [ "$URL_SLUG" != "$SLUG" ] || [ "$URL_HOST" != "$HOST" ]; }; then
  echo "issue-details: URL names ${URL_HOST}/${URL_SLUG} but the checkout is ${HOST}/${SLUG}" >&2
  exit 4
fi
OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
gh auth status --hostname "$HOST" >/dev/null 2>&1 \
  || { echo "issue-details: not authenticated for $HOST" >&2; exit 3; }
ME=$(pr_facts_gh api --hostname "$HOST" user --jq .login) \
  || { echo "issue-details: cannot resolve the running user" >&2; exit 3; }
```

`gh repo view` takes the repository as a **positional** argument — no `-R` flag. `ME` is the
login the marker lookup (§1b) and the social rule (`triage.md` §5) compare against; one call
per run, whatever the issue count.

### §0b Rate gate

The reserves are loaded explicitly — from the checkout's `detent.yaml` when present, because
that file is the fleet's declared floor and this skill must not undercut it — and defaulted
otherwise (the `|| true` keeps a missing `detent.yaml` from tripping `errexit` — an
assignment from a failing command substitution is itself a failing command). The gate call
sits inside `||` for the same reason:

```bash
GRAPHQL_RESERVE=$(awk '/^ *github_graphql_min_remaining_reserve:/{print $2; exit}' detent.yaml 2>/dev/null || true)
REST_RESERVE=$(awk '/^ *github_rest_min_remaining_reserve:/{print $2; exit}' detent.yaml 2>/dev/null || true)
GRAPHQL_RESERVE="${GRAPHQL_RESERVE:-1000}"; REST_RESERVE="${REST_RESERVE:-1000}"; SEARCH_RESERVE=5
RG_RC=0
VIOLATIONS=$(pr_facts_rate_gate "$HOST" "$GRAPHQL_RESERVE" "$REST_RESERVE" "$SEARCH_RESERVE") || RG_RC=$?
case "$RG_RC" in
  0) : ;;
  1) printf 'issue-details: rate limit below reserve:\n%s\n' "$VIOLATIONS" >&2; exit 3 ;;
  *) echo "issue-details: rate_limit unreadable" >&2; exit 3 ;;
esac
```

**Below any reserve here: stop, exit 3, no report.** The quota is shared by every agent on
the account, and a triage comment is never worth starving a merge lane. The full gate runs
**again before each issue** (§1f), where a core or GraphQL shortfall stops the batch and a
search-bucket shortfall (30/min) is a sleep to its reset, not an abort.

### §0c Pin the base branch

```bash
BASE="${BASE_ARG:-dev}"
DEV_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
if [ -z "$DEV_SHA" ] && [ -z "${BASE_ARG:-}" ]; then
  BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  DEV_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
fi
[ -n "$DEV_SHA" ] || { echo "issue-details: cannot resolve the tip of $BASE" >&2; exit 3; }
```

The default-branch fallback exists only for the *implicit* `dev`; an explicit `--base` that
does not resolve is exit 3, never a silent substitution — a typo must not stamp verdicts
against a branch the caller did not name. `DEV_SHA` goes into every marker comment
(`<!-- issue-details:v1 dev=<sha> -->`) and into the YAML as `dev_sha`, so a later reader —
a human, or `pr-details` — knows which tip the verdict was judged against. No object is
fetched: this version reads no source (`triage.md` §7). Brace the variable before a colon
(`${BASE}:`) if you ever extend this into a `git show` — under zsh `$BASE:r` is a history
modifier.

### §0d Run directory

```bash
ID_RAND=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
RUN_DIR="$SCRATCH_DIR/issue-details/run/$(date -u +%Y%m%dT%H%M%SZ)-${ID_RAND}"
mkdir -p "$RUN_DIR"
: > "$RUN_DIR/unevaluated.tsv"; : > "$RUN_DIR/warnings.txt"; STOP_BATCH=0; STOP_REASON=""
```

Per invocation, never shared: `issue-<n>.json`, `comments-<n>.json`, `board-<n>.json`,
`comment-<n>.md` (the drafted marker comment), `facts.json`. Nothing here is cached across
runs — labels, comments, board state, and the base tip all move between runs.
`unevaluated.tsv` collects `<number>\t<reason>` for every selected issue that did not
complete; `warnings.txt` collects the lines that also go to `warnings[]`.

### §0e Run-wide fetches (once, shared by every issue)

*Open PRs* — a PR already in flight for the issue changes the advice from "start" to
"watch #N". One list call (GraphQL bucket, not search); newest-created first, cap 100, which
on the reference repo (~25 open) is the whole set. When the cap is hit the report carries a
warning — in-flight detection is advisory and the cap is stated, not hidden:

```bash
pr_facts_gh pr list -R "$SLUG" --state open --limit 100 \
  --json number,title,isDraft,closingIssuesReferences \
  | jq -c '[.[] | {number, title, isDraft, issues: [.closingIssuesReferences[].number]}]' \
  > "$RUN_DIR/open-prs.json"
if [ "$(jq length "$RUN_DIR/open-prs.json")" -eq 100 ]; then
  echo "open-PR list capped at 100 — in-flight detection may miss older PRs" >> "$RUN_DIR/warnings.txt"
fi
```

*The goal registry* — every `goal:*` label and the issues carrying each. Epics in the
reference repo are body-text lists, not native sub-issues, so the registry is the whole
mechanism: an issue aligns with a goal when it references (or is) an issue in this set.

```bash
pr_facts_gh label list -R "$SLUG" --limit 300 --json name \
  | jq -r '.[].name | select(startswith("goal:"))' > "$RUN_DIR/goal-labels.txt"
: > "$RUN_DIR/goal-registry.tsv"
while IFS= read -r GOAL_LABEL; do
  [ -n "$GOAL_LABEL" ] || continue
  pr_facts_gh issue list -R "$SLUG" --label "$GOAL_LABEL" --state all --limit 100 \
    --json number --jq '.[].number' \
    | awk -v l="$GOAL_LABEL" '{print $0 "\t" l}' >> "$RUN_DIR/goal-registry.tsv"
done < "$RUN_DIR/goal-labels.txt"
```

An empty registry is a fact, not an error: the report says `goal registry: empty — no
issue carries a goal:* label yet`, and every issue's goal resolves to `null` with that
reason. Verified on the reference repo on 2026-09-02: the label `goal:q3-2026` exists, and
no issue carries it yet.

### §0f `--since` selection

`SINCE_ARG` has already passed the exact `^[1-9][0-9]*d$` check in the `SKILL.md` argument
loop. Both `date` forms are tried (`-v` is BSD/macOS, `-d` is GNU); when neither works the
run stops rather than selecting against an empty boundary:

```bash
SINCE_DAYS="${SINCE_ARG%d}"
SINCE=$(date -u -v-"${SINCE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${SINCE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || SINCE=""
[ -n "$SINCE" ] || { echo "issue-details: cannot compute the --since boundary with this date(1)" >&2; exit 3; }
pr_facts_gh issue list -R "$SLUG" --state open --limit 500 --json number,createdAt \
  | jq -c --arg since "$SINCE" '[.[] | select(.createdAt >= $since)] | sort_by(.createdAt, .number)' \
  > "$RUN_DIR/since-all.json"
SINCE_TOTAL=$(jq length "$RUN_DIR/since-all.json")
jq -r '.[0:50] | .[].number' "$RUN_DIR/since-all.json" > "$RUN_DIR/selected.txt"
if [ "$SINCE_TOTAL" -gt 50 ]; then
  echo "--since matched $SINCE_TOTAL open issues; evaluating the oldest 50 — re-run with a shorter window for the rest" \
    | tee -a "$RUN_DIR/warnings.txt" >&2
fi
```

The list limit is 500, not 100: `gh issue list` returns newest-created first, so a limit
smaller than the number of open issues created inside the window would silently drop the
oldest ones before the cap ever applied (300 open issues, 137 created in the last 30 days
at the time of writing). The cap is **50 issues per run, oldest first** — `.[0:50]` after
the sort, with the warning on stderr and in `warnings[]`. Each issue costs two search
calls (§1g), and the 30/min search bucket makes 50 issues roughly four minutes of sleeping
even when nothing else is running; the cap keeps one run inside one person's patience.
Explicit numbers on the command line are never capped. This block is executed against a
fixture by `plugins/workflow/tests/issue-details-triage.test.sh`.

---

## §1 Phase 1 — Per-issue record

Phase 1 runs in **two passes** over `selected.txt`: pass A gates and fetches every issue
record (§1a, §1b) so the merged-PR sweep (§1c) can start its window at the earliest filing
date with one paginated query for the whole run; pass B gates again, **reloads every
per-issue value from `issue-<n>.json`** (§1b), and does the rest (§1d–§1i). Shell
variables never carry an issue's facts across the pass boundary — the file does.

Every per-issue `gh` call goes through `issue_gh`, which turns a failure into a per-issue
result instead of a dead run, and turns a **terminal rate-limit 403** into a batch stop:

```bash
issue_gh() {
  IG_ERR=$(mktemp) || return 1
  pr_facts_gh "$@" 2>"$IG_ERR" && { rm -f "$IG_ERR"; return 0; }
  IG_RC=$?
  ISSUE_ERROR=$(head -1 "$IG_ERR")
  if grep -qiE 'rate limit|HTTP 403' "$IG_ERR"; then STOP_BATCH=1; STOP_REASON="$ISSUE_ERROR"; fi
  rm -f "$IG_ERR"
  return "$IG_RC"
}
```

The driver:

```
pass A — for each ISSUE_NUM in selected.txt:
    if STOP_BATCH == 1: record "<n>\tbatch stopped: <STOP_REASON>"; continue
    ISSUE_FAILED=0; §1a gate; §1b fetch (a failure appends <n> to failed.txt)
    if ISSUE_FAILED == 1: record "<n>\t<ISSUE_ERROR>"; continue
§1a gate (with ISSUE_NUM=sweep); §1c sweep — unless STOP_BATCH
pass B — for each ISSUE_NUM in selected.txt:
    if STOP_BATCH == 1: record; continue
    if <n> is in failed.txt or unevaluated.tsv: continue        (already recorded)
    ISSUE_FAILED=0; §1a gate; §1b load; §1d … §1i, each `issue_gh … || ISSUE_FAILED=1`
    if ISSUE_FAILED == 1: record "<n>\t<ISSUE_ERROR>"; continue
```

**`issue_gh` always writes to a file — never on the left of a pipe, never inside `$( )`.**
Both put it in a subshell, where `STOP_BATCH` and `ISSUE_ERROR` die with the subshell (bash
forks every pipeline stage; zsh forks all but the last). Fetch raw, then `jq` the file.

`pr_facts_gh` already refuses to retry a primary rate-limit 403, a 401, or a 404, so the
first such error reaches `issue_gh` immediately. An issue that fails for its own reason (a
404, a partial GraphQL response) is recorded and the batch continues; a rate-limit 403
records that issue **and every issue after it** as unevaluated, and the gate is offered on
what completed. Exit 4 applies only when the run selected explicit numbers and **none** of
them was found.

### §1a Per-issue gate (both passes, and once before the sweep)

The full gate, before any fetch for the issue, in one `rate_limit` read written to a file.
Core or GraphQL below reserve **stops the batch**; the search bucket below reserve is a
sleep to its reset — it refills every minute, and a batch two issues in should not abort
over it. A response that is not the expected shape (a `{}`, a null bucket, a non-numeric
remaining) **fails closed** — every operand is checked before any comparison:

```bash
RL_FAIL=0
issue_gh api --hostname "$HOST" rate_limit > "$RUN_DIR/rate-${ISSUE_NUM}.json" || RL_FAIL=1
if [ "$RL_FAIL" = 1 ]; then
  STOP_BATCH=1; STOP_REASON="rate_limit unreadable${ISSUE_ERROR:+: $ISSUE_ERROR}"
else
  RL_CORE=$(jq -r '.resources.core.remaining // empty' "$RUN_DIR/rate-${ISSUE_NUM}.json" 2>/dev/null || true)
  RL_GQL=$(jq -r '.resources.graphql.remaining // empty' "$RUN_DIR/rate-${ISSUE_NUM}.json" 2>/dev/null || true)
  RL_SEARCH=$(jq -r '.resources.search.remaining // empty' "$RUN_DIR/rate-${ISSUE_NUM}.json" 2>/dev/null || true)
  RL_SEARCH_RESET=$(jq -r '.resources.search.reset // empty' "$RUN_DIR/rate-${ISSUE_NUM}.json" 2>/dev/null || true)
  RL_SHAPE_OK=1
  for RL_V in "$RL_CORE" "$RL_GQL" "$RL_SEARCH" "$RL_SEARCH_RESET"; do
    case "$RL_V" in ''|*[!0-9]*) RL_SHAPE_OK=0 ;; esac
  done
  if [ "$RL_SHAPE_OK" = 0 ]; then
    STOP_BATCH=1; STOP_REASON="rate_limit response malformed"
  elif [ "$RL_CORE" -lt "$REST_RESERVE" ] || [ "$RL_GQL" -lt "$GRAPHQL_RESERVE" ]; then
    STOP_BATCH=1; STOP_REASON="rate limit below reserve (core $RL_CORE, graphql $RL_GQL)"
  elif [ "$RL_SEARCH" -lt "$SEARCH_RESERVE" ]; then
    RL_NOW=$(date -u +%s)
    if [ "$RL_SEARCH_RESET" -gt "$RL_NOW" ]; then sleep $(( RL_SEARCH_RESET - RL_NOW + 1 )); fi
  fi
fi
if [ "$STOP_BATCH" = 1 ]; then ISSUE_FAILED=1; ISSUE_ERROR="$STOP_REASON"; fi
```

This block is executed against fixtures by
`plugins/workflow/tests/issue-details-triage.test.sh` — the doc is the code under test;
edit both together.

### §1b The issue record — fetch (pass A) and load (both passes)

Fetch, in pass A. A failure is **persisted** to `failed.txt`, which pass B consults, so a
missing record is never mistaken for the previous issue's:

```bash
issue_gh issue view "$ISSUE_NUM" -R "$SLUG" \
  --json number,title,body,author,createdAt,updatedAt,labels,state,url,milestone \
  > "$RUN_DIR/issue-${ISSUE_NUM}.json" || { ISSUE_FAILED=1; echo "$ISSUE_NUM" >> "$RUN_DIR/failed.txt"; }
```

Load, from the file — pass A right after the fetch, pass B first thing. Every per-issue
value the later sections read comes from here, including the body file and the existing
effort block, so no value can leak from another issue:

```bash
PASS_SKIP=0
if grep -qx "$ISSUE_NUM" "$RUN_DIR/failed.txt" 2>/dev/null; then PASS_SKIP=1; fi
if [ "$PASS_SKIP" = 0 ] && jq -e '.number == ($n | tonumber)' --arg n "$ISSUE_NUM" "$RUN_DIR/issue-${ISSUE_NUM}.json" >/dev/null 2>&1; then
  ISSUE_TITLE=$(jq -r .title "$RUN_DIR/issue-${ISSUE_NUM}.json")
  ISSUE_AUTHOR=$(jq -r '.author.login // ""' "$RUN_DIR/issue-${ISSUE_NUM}.json")
  ISSUE_CREATED=$(jq -r .createdAt "$RUN_DIR/issue-${ISSUE_NUM}.json")
  ISSUE_UPDATED=$(jq -r .updatedAt "$RUN_DIR/issue-${ISSUE_NUM}.json")
  ISSUE_STATE=$(jq -r .state "$RUN_DIR/issue-${ISSUE_NUM}.json")
  ISSUE_LABELS=$(jq -c '[.labels[].name] | sort' "$RUN_DIR/issue-${ISSUE_NUM}.json")
  jq -r '.body // ""' "$RUN_DIR/issue-${ISSUE_NUM}.json" > "$RUN_DIR/body-${ISSUE_NUM}.md"
  EXISTING_EFFORT=$(awk '
    /^```detent-agent[[:space:]]*$/ {inb=1; next}
    /^```/ {inb=0}
    inb && $1 == "effort:" {print $2; exit}
  ' "$RUN_DIR/body-${ISSUE_NUM}.md")
else
  PASS_SKIP=1; ISSUE_FAILED=1; ISSUE_ERROR="${ISSUE_ERROR:-record for #$ISSUE_NUM missing or not this issue}"
fi
```

`author` is null for deleted accounts; `ISSUE_AUTHOR` is then empty and the social rule
treats the issue as **not** self-authored (the conservative side). `ISSUE_UPDATED` and
`ISSUE_LABELS` (sorted) are the evaluation snapshot the gate re-checks before writing
(`execute.md` §3). `EXISTING_EFFORT` is the fenced `detent-agent` block's `effort:` —
empty means no block; whatever value is there, including `max`, is reported as-is beside
the proposal (`triage.md` §4) and the body is never edited. A closed issue is still
evaluated — the report says `state: CLOSED` and the gate writes nothing to it. Both blocks
are executed by the test file, two issues through both passes.

### §1c Merged-PR sweep (once, after pass A, gated)

The "already fixed" candidates: every PR merged into the base branch since the **earliest**
selected issue was filed, with the issues it closed. This is a GraphQL `search` with an
explicit `merged:>=` window, not `gh pr list --state merged` — that list is ordered by
*creation* date with no sort flag (cli/cli#10244), so an old PR merged recently can fall
outside any cap, and a cap in creation order says nothing about coverage in merge order.
Verified live on the reference repo: the qualifier, `closingIssuesReferences` on the
search node, `issueCount`, and `pageInfo` all come back; the query charges the **GraphQL**
bucket only (the 30/min search bucket was untouched, checked before and after). Each page
goes through `issue_gh` to a file, so a 403 here stops the batch like any other.

```bash
SWEEP_SINCE=$(jq -rs '[.[].createdAt] | min' "$RUN_DIR"/issue-*.json)
SWEEP_Q="repo:${SLUG} is:pr is:merged base:${BASE} merged:>=${SWEEP_SINCE}"
SWEEP_GQL='query($q:String!,$after:String){ search(query:$q, type:ISSUE, first:100, after:$after){
  issueCount pageInfo{hasNextPage endCursor}
  nodes{ ... on PullRequest { number title mergedAt
    closingIssuesReferences(first:100){ pageInfo{hasNextPage} nodes{ number } } } } } }'
: > "$RUN_DIR/shipped-pages.jsonl"; SWEEP_CURSOR="null"; SWEEP_PAGE=0; SHIPPED_TRUNCATED=false
while :; do
  SWEEP_PAGE=$(( SWEEP_PAGE + 1 ))
  issue_gh api --hostname "$HOST" graphql -f query="$SWEEP_GQL" -f q="$SWEEP_Q" -F after="$SWEEP_CURSOR" \
    > "$RUN_DIR/sweep-page.json" \
    || { echo "merged-PR sweep failed on page $SWEEP_PAGE — already-fixed detection incomplete" >> "$RUN_DIR/warnings.txt"; SHIPPED_TRUNCATED=true; break; }
  if ! jq -e '(.errors // []) | length == 0' "$RUN_DIR/sweep-page.json" >/dev/null 2>&1 \
     || ! jq -e '.data.search.nodes | type == "array"' "$RUN_DIR/sweep-page.json" >/dev/null 2>&1; then
    echo "merged-PR sweep returned partial or malformed data on page $SWEEP_PAGE" >> "$RUN_DIR/warnings.txt"; SHIPPED_TRUNCATED=true; break
  fi
  jq -c . "$RUN_DIR/sweep-page.json" >> "$RUN_DIR/shipped-pages.jsonl"
  if [ "$(jq -r '.data.search.pageInfo.hasNextPage' "$RUN_DIR/sweep-page.json")" != "true" ]; then break; fi
  if [ "$SWEEP_PAGE" -ge 5 ]; then SHIPPED_TRUNCATED=true; break; fi
  SWEEP_CURSOR=$(jq -r '.data.search.pageInfo.endCursor' "$RUN_DIR/sweep-page.json")
done
jq -sc '[.[].data.search.nodes[] | {number, title, mergedAt,
          issues: [.closingIssuesReferences.nodes[].number],
          issues_truncated: (.closingIssuesReferences.pageInfo.hasNextPage == true)}]' \
  "$RUN_DIR/shipped-pages.jsonl" > "$RUN_DIR/shipped.json"
jq -r '.[] | select(.issues_truncated) | "PR #\(.number) closes more than 100 issues — matches against it are unknown, not absent"' \
  "$RUN_DIR/shipped.json" >> "$RUN_DIR/warnings.txt"
if [ "$SHIPPED_TRUNCATED" = true ]; then
  echo "merged-PR sweep stopped after $SWEEP_PAGE page(s) — merged work since $SWEEP_SINCE may be unexamined" >> "$RUN_DIR/warnings.txt"
fi
```

Cost: one GraphQL call per 100 merged PRs in the window, capped at five pages (500 PRs);
the reference repo merges ~10–15 a day, so a 30-day window is four calls. Truncation comes
from pagination — `hasNextPage` still true at the page cap, or a failed page — never from
inspecting timestamps in a sample. A PR closing more than 100 issues is carried with
`issues_truncated: true`; §1h treats it as an **unknown** match for every issue it does not
list, and the prose says so. Both truncations produce `warnings[]` lines and block nothing;
the verdict vocabulary has no confidence grade in this version, so the prose carries the
caveat. This block is executed against scripted pages by the test file.

### §1d Comments and the marker (pass B)

Comments come from REST, not `gh issue view --json comments`, because editing in place
needs the **numeric** comment id and the view command returns node ids:

```bash
issue_gh api --hostname "$HOST" --paginate --slurp \
  "repos/$SLUG/issues/$ISSUE_NUM/comments?per_page=100" \
  > "$RUN_DIR/comments-${ISSUE_NUM}.raw" || ISSUE_FAILED=1
jq -c '[.[][] | {id, login: (.user.login // null), body, created_at, updated_at}]' \
  "$RUN_DIR/comments-${ISSUE_NUM}.raw" > "$RUN_DIR/comments-${ISSUE_NUM}.json" || ISSUE_FAILED=1
```

Then find this skill's own comment. Two filters, both mandatory: the comment's author is
`$ME` (another user's marker is theirs to edit, and a comment this token cannot edit must
never be targeted), and the body's **first line is exactly** the v1 marker — anchored at
both ends, tested on the first line alone, so a quoted marker further down, trailing text
after `-->`, or a future `v10` does not match:

```bash
MARKER_RE='^<!-- issue-details:v1 dev=[0-9a-f]{40} -->$'
MARKER_ID=$(jq -r --arg me "$ME" --arg re "$MARKER_RE" \
  '[.[] | select(.login == $me) | select(.body | split("\n")[0] | test($re))] | sort_by(.id) | .[0].id // empty' \
  "$RUN_DIR/comments-${ISSUE_NUM}.json")
MARKER_COUNT=$(jq --arg me "$ME" --arg re "$MARKER_RE" \
  '[.[] | select(.login == $me) | select(.body | split("\n")[0] | test($re))] | length' \
  "$RUN_DIR/comments-${ISSUE_NUM}.json")
COMMENT_IDS=$(jq -c '[.[].id] | sort' "$RUN_DIR/comments-${ISSUE_NUM}.json")
MARKER_UPDATED=""
if [ "$MARKER_COUNT" -gt 1 ]; then
  COMMENT_ACTION="refuse"
  echo "#${ISSUE_NUM}: $MARKER_COUNT issue-details marker comments by $ME — delete all but one by hand (deletion is outside this skill's write set); not writing" \
    | tee -a "$RUN_DIR/warnings.txt" >&2
elif [ -n "$MARKER_ID" ]; then
  MARKER_UPDATED=$(jq -r --argjson id "$MARKER_ID" '.[] | select(.id == $id) | .updated_at' \
    "$RUN_DIR/comments-${ISSUE_NUM}.json")
  COMMENT_ACTION="edit"
else
  COMMENT_ACTION="create"
fi
```

`MARKER_COUNT > 1` means an earlier run posted twice (a race, or a hand-pasted copy). This
skill never deletes a comment, and editing one while leaving the other standing keeps two
verdicts on the issue forever, so the action is `refuse`: the issue is evaluated and
reported, nothing is written, and the warning names the cleanup. `MARKER_UPDATED` and
`COMMENT_IDS` (every comment id, sorted) are the snapshot the gate re-checks before writing
(`execute.md` §3). This block is executed against fixtures by the test file.

### §1e Existing effort block

Read in §1b's load block (`EXISTING_EFFORT`), from the body file, never from anywhere
else. Detent reads effort from the fenced `detent-agent` block; this skill reads it and
never writes it.

### §1f Mechanical noise signal

Runs **here, before any search**, so a noise issue never spends the two search calls
(`triage.md` §1 row 1 is this block; the model does not get to override it). Two signals:
a `detent-intake` fingerprint in the body, or a path in the title or body under build
output (`.next/`, `dist/`, `build/`, `out/`), `node_modules/`, or `_generated/`:

```bash
NOISE_SIGNAL=""
if grep -q '<!-- detent-intake:' "$RUN_DIR/body-${ISSUE_NUM}.md"; then
  NOISE_SIGNAL="detent-intake fingerprint"
elif printf '%s\n' "$ISSUE_TITLE" | cat - "$RUN_DIR/body-${ISSUE_NUM}.md" \
     | grep -qE '(^|/|[[:space:]]|`)(\.next|dist|build|out|node_modules|_generated)/'; then
  NOISE_SIGNAL="path under build output / node_modules / _generated"
fi
if [ -n "$NOISE_SIGNAL" ]; then CLASSIFICATION="noise"; fi
```

Prose that merely mentions "the build" does not match — the signal needs a path segment.
This block is executed against fixtures by the test file.

### §1g Board state

The same Projects v2 query `lib/pr-facts.sh`'s `pr_facts_board` runs (verified live on
the reference repo), issued through `issue_gh` to a file so a 403 here stops the batch:

```bash
BOARD_GQL='query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){ issue(number:$num){
  projectItems(first:20){ nodes{ id project{ id title }
    fieldValues(first:30){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue { name field{ ... on ProjectV2FieldCommon { name } } } } } } } } } }'
issue_gh api --hostname "$HOST" graphql -f query="$BOARD_GQL" -f o="$OWNER" -f n="$NAME" -F num="$ISSUE_NUM" \
  > "$RUN_DIR/board-${ISSUE_NUM}.json" || ISSUE_FAILED=1
BOARD_STATUS=$(jq -r '[.data.repository.issue.projectItems.nodes[]?.fieldValues.nodes[]? | select(.field.name == "Status") | .name] | .[0] // "none"' \
  "$RUN_DIR/board-${ISSUE_NUM}.json" 2>/dev/null || echo none)
BOARD_PRIORITY=$(jq -r '[.data.repository.issue.projectItems.nodes[]?.fieldValues.nodes[]? | select(.field.name == "Priority") | .name] | .[0] // "none"' \
  "$RUN_DIR/board-${ISSUE_NUM}.json" 2>/dev/null || echo none)
```

Read for the report and for the priority-disagreement note only. Board `Status` and
`Priority` are never written by this skill, in any mode. When several project items exist,
prefer the one whose project id equals `detent.yaml`'s `tracker.project_slug`; verified on
the reference repo the issue carries exactly one item.

### §1h Dedupe candidates

Skipped when the issue is `noise` (§1f) or with `--no-dup-search`. The skip initialises
every result the verdict guard reads — a skipped search is an empty set, not a missing
file — and the term extraction and both searches sit inside the guard, so a literal
executor issues **zero** search calls on a noise issue:

```bash
if [ -n "${NOISE_SIGNAL:-}" ] || [ "${DO_DUP:-1}" = 0 ]; then
  DEDUPE_SKIPPED=1
else
  DEDUPE_SKIPPED=0
fi
TERMS=""; printf '[]' > "$RUN_DIR/dup-issues-${ISSUE_NUM}.json"; printf '[]' > "$RUN_DIR/dup-prs-${ISSUE_NUM}.json"
if [ "$DEDUPE_SKIPPED" != 1 ]; then
  # Title terms: lowercase tokens, stop-words and conventional-commit verbs dropped, tokens
  # under four characters dropped, the three longest kept (length is the cheap proxy for
  # distinctiveness; ties break alphabetically so the query is reproducible). The scope
  # word of a `scope: title` prefix is KEPT — `engagement:` and `ledger:` are the strongest
  # topical signal a title carries in the reference repo.
  TERMS=$(printf '%s' "$ISSUE_TITLE" \
    | tr -cs 'A-Za-z0-9_' '\n' | tr 'A-Z' 'a-z' \
    | grep -vxE 'a|an|the|and|or|of|to|in|on|for|with|from|by|is|are|be|not|no|when|because|never|ever|any|all|into|via|as|at|it|its|this|that|we|our|per|vs|use|uses|using|add|adds|fix|fixes|feat|docs|test|chore|refactor|perf|make|makes|support|allow|allows|should|can|does|do|after|before|instead|still|only|new|without|across|between|under|over|each|every' \
    | awk 'length($0) >= 4 && !seen[$0]++' \
    | awk '{print length($0) "\t" $0}' | sort -k1,1rn -k2,2 | head -3 | cut -f2 \
    | tr '\n' ' ' | sed 's/ $//')
  if [ "$(printf '%s' "$TERMS" | wc -w | tr -d ' ')" -ge 2 ]; then
    # GitHub ANDs the terms. `gh search issues` excludes PRs by default (verified);
    # `gh pr list --search` charges the search bucket as well as GraphQL. The issue itself
    # always matches its own terms and is dropped.
    issue_gh search issues --repo "$SLUG" --state open --limit 10 "$TERMS" \
      --json number,title,url,labels,updatedAt > "$RUN_DIR/dup-issues-${ISSUE_NUM}.raw" || ISSUE_FAILED=1
    jq -c --argjson me "$ISSUE_NUM" '[.[] | select(.number != $me)]' \
      "$RUN_DIR/dup-issues-${ISSUE_NUM}.raw" > "$RUN_DIR/dup-issues-${ISSUE_NUM}.json" || ISSUE_FAILED=1
    issue_gh pr list -R "$SLUG" --state open --limit 10 --search "$TERMS" \
      --json number,title,url,isDraft,closingIssuesReferences \
      > "$RUN_DIR/dup-prs-${ISSUE_NUM}.json" || ISSUE_FAILED=1
  else
    DEDUPE_SKIPPED=1   # title too generic to search → verdict `unclear` with that reason
  fi
fi
```

*Merged since filing, naming this issue* — from the run-wide sweep (§1c), no extra call.
`mergedAt` and `createdAt` are both Zulu-form, so the lexical compare is sound. A PR whose
closing list was truncated and does not name this issue is an **unknown** match, listed
separately and named in the prose, never counted as absent:

```bash
jq -c --arg since "$ISSUE_CREATED" --argjson me "$ISSUE_NUM" \
  '[.[] | select(.mergedAt >= $since) | select(.issues | index($me) != null)]' \
  "$RUN_DIR/shipped.json" > "$RUN_DIR/fixed-by-${ISSUE_NUM}.json"
jq -c --arg since "$ISSUE_CREATED" --argjson me "$ISSUE_NUM" \
  '[.[] | select(.mergedAt >= $since) | select(.issues_truncated) | select(.issues | index($me) == null) | .number]' \
  "$RUN_DIR/shipped.json" > "$RUN_DIR/fixed-by-unknown-${ISSUE_NUM}.json"
```

*Open PRs naming this issue* — from the run-wide list (§0e):

```bash
jq -c --argjson me "$ISSUE_NUM" '[.[] | select(.issues | index($me) != null)]' \
  "$RUN_DIR/open-prs.json" > "$RUN_DIR/in-flight-${ISSUE_NUM}.json"
```

The candidate sets the verdict guard reads (`triage.md` §3):

```bash
CANDIDATES_OPEN=$(jq -sc '[.[0][].number] + [.[1][].number] + [.[2][].number] | unique' \
  "$RUN_DIR/dup-issues-${ISSUE_NUM}.json" "$RUN_DIR/dup-prs-${ISSUE_NUM}.json" \
  "$RUN_DIR/in-flight-${ISSUE_NUM}.json")
CANDIDATES_SHIPPED=$(jq -c '[.[].number] | unique' "$RUN_DIR/fixed-by-${ISSUE_NUM}.json")
```

### §1i Goal references

Only when the issue carries no `goal:*` label of its own. Three reference shapes, from the
body and every comment: `part of #N`, `epic #N`, and `#N` inside a Markdown heading line.
Nothing else — `closes #N`, `split out of #N`, and bare mentions are not parentage. Order of
first appearance is kept (the first resolving reference wins in `triage.md` §4), duplicates
dropped, cap five:

```bash
GOAL_REFS=$(cat "$RUN_DIR/body-${ISSUE_NUM}.md" <(jq -r '.[].body' "$RUN_DIR/comments-${ISSUE_NUM}.json") \
  | grep -oiE '(part of #[0-9]+|epic #[0-9]+|^#{1,6} .*#[0-9]+)' \
  | grep -oE '#[0-9]+' | tr -d '#' | awk '!seen[$0]++' | head -5 | tr '\n' ' ' | sed 's/ $//')
```

Each referenced number is looked up in `goal-registry.tsv` (§0e) — no further API call. Two
hits naming **different** goal labels is a decision, not a first-wins (`triage.md` §4).
