# Facts — Phases 0–1

Every recipe here is read-only and was executed against `getparable/parable` before being
written down. Every `gh` call goes through `pr_facts_gh` (the retry wrapper from
`lib/pr-facts.sh`) and is host- and repo-explicit.

---

## §0 Phase 0 — Preflight

Ordering is load-bearing: **identity first**, then auth for that host, then the rate gate,
then the run-wide fetches that every issue shares.

### §0a Resolve identity

```bash
HOST="github.com"
SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 4
HOST=$(gh repo view --json url --jq '.url | sub("^https?://";"") | split("/")[0]')
OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
gh auth status --hostname "$HOST" >/dev/null 2>&1 \
  || { echo "issue-details: not authenticated for $HOST" >&2; exit 3; }
ME=$(pr_facts_gh api --hostname "$HOST" user --jq .login) \
  || { echo "issue-details: cannot resolve the running user" >&2; exit 3; }
```

`gh repo view` takes the repository as a **positional** argument — no `-R` flag. An issue
argument given as a full URL sets `HOST` and `SLUG` from the URL; when that differs from
the checkout's repository, stop with exit 4 and print both — never report on repo A while
sitting in repo B.

`ME` is the login the social rule compares issue authors against (`triage.md` §5). It is a
run-wide fact: one call, whatever the issue count.

### §0b Rate gate

Same helper and the same reserves as `pr-details`: `detent.yaml`'s
`tracker.github_graphql_min_remaining_reserve` / `github_rest_min_remaining_reserve` when
present, else 1000 each; the search bucket reserves 5 of its 30/min.

```bash
VIOLATIONS=$(pr_facts_rate_gate "$HOST" "$GRAPHQL_RESERVE" "$REST_RESERVE" "$SEARCH_RESERVE")
case $? in
  0) : ;;
  1) printf 'issue-details: rate limit below reserve:\n%s\n' "$VIOLATIONS" >&2; exit 3 ;;
  2) echo "issue-details: rate_limit unreadable" >&2; exit 3 ;;
esac
```

**Below the core or GraphQL reserve: stop, exit 3, no report.** The quota is shared by every
agent on the account, and a triage comment is never worth starving a merge lane.

The gate runs **again before each issue's dedupe searches** (§1e). A shortfall in the
**search** bucket alone is handled differently there: it is a 30/min bucket, so the run
sleeps until its `reset` timestamp rather than aborting a batch two issues in. A core or
GraphQL shortfall mid-batch stops evaluation; the issues already fully evaluated still
reach the gate, and `warnings[]` names the ones that were not (`SKILL.md` §"Output
contract").

### §0c Pin the base branch

```bash
BASE="${BASE_ARG:-dev}"
DEV_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
if [ -z "$DEV_SHA" ]; then
  BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  DEV_SHA=$(git ls-remote origin "refs/heads/${BASE}" | cut -f1)
fi
[ -n "$DEV_SHA" ] || { echo "issue-details: cannot resolve the tip of $BASE" >&2; exit 3; }
```

`DEV_SHA` is stamped into every marker comment (`<!-- issue-details:v1 dev=<sha> -->`) and
into the YAML block as `dev_sha`, so a later reader — a human, or `pr-details` — knows which
tip the verdict was judged against. No object is fetched: this version reads no source
(`triage.md` §7), so a `ls-remote` is the whole pin. Brace the variable before the colon
(`${BASE}:`) if you ever extend this into a `git show` — under zsh `$BASE:r` is a history
modifier.

### §0d Run directory

```bash
ID_RAND=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
RUN_DIR="$SCRATCH_DIR/issue-details/run/$(date -u +%Y%m%dT%H%M%SZ)-${ID_RAND}"
mkdir -p "$RUN_DIR"
```

Per invocation, never shared: `issue-<n>.json`, `comments-<n>.json`, `board-<n>.json`,
`comment-<n>.md` (the drafted marker comment), `facts.json`. Nothing here is cached across
runs — labels, comments, board state, and the base tip all move between runs.

### §0e Run-wide fetches (once, shared by every issue)

Three list endpoints charge the GraphQL bucket but not the 30/min search bucket, so they run
once per run regardless of how many issues follow.

*Merged PRs into the base branch* — the "already fixed" candidates. Newest first, capped at
100 (verified: `closingIssuesReferences` is populated on this endpoint):

```bash
pr_facts_gh pr list -R "$SLUG" --base "$BASE" --state merged --limit 100 \
  --json number,title,mergedAt,closingIssuesReferences \
  | jq -c '[.[] | {number, title, mergedAt, issues: [.closingIssuesReferences[].number]}]' \
  > "$RUN_DIR/shipped.json"
```

*Open PRs* — a PR already in flight for the issue changes the advice from "start" to
"watch #N":

```bash
pr_facts_gh pr list -R "$SLUG" --state open --limit 100 \
  --json number,title,isDraft,closingIssuesReferences \
  | jq -c '[.[] | {number, title, isDraft, issues: [.closingIssuesReferences[].number]}]' \
  > "$RUN_DIR/open-prs.json"
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

```bash
SINCE_DAYS="${SINCE_ARG%d}"
SINCE=$(date -u -v-"${SINCE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${SINCE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
pr_facts_gh issue list -R "$SLUG" --state open --limit 100 --json number,createdAt \
  | jq -r --arg since "$SINCE" '[.[] | select(.createdAt >= $since)] | sort_by(.number) | .[].number' \
  > "$RUN_DIR/selected.txt"
```

Both `date` forms were verified (`-v` is BSD/macOS, `-d` is GNU). The selection is capped
at **50 issues per run** — beyond that, the first 50 by number plus a warning. Each issue
costs two search calls (§1e), and the 30/min search bucket makes 50 issues roughly four
minutes of sleeping even when nothing else is running; the cap keeps one run inside one
person's patience. Explicit numbers on the command line are never capped.

---

## §1 Phase 1 — Per-issue record

### §1a The issue

```bash
pr_facts_gh issue view "$ISSUE_NUM" -R "$SLUG" \
  --json number,title,body,author,createdAt,updatedAt,labels,state,url,milestone \
  > "$RUN_DIR/issue-${ISSUE_NUM}.json" || exit 4
ISSUE_TITLE=$(jq -r .title "$RUN_DIR/issue-${ISSUE_NUM}.json")
ISSUE_AUTHOR=$(jq -r '.author.login // ""' "$RUN_DIR/issue-${ISSUE_NUM}.json")
ISSUE_CREATED=$(jq -r .createdAt "$RUN_DIR/issue-${ISSUE_NUM}.json")
ISSUE_STATE=$(jq -r .state "$RUN_DIR/issue-${ISSUE_NUM}.json")
ISSUE_LABELS=$(jq -c '[.labels[].name]' "$RUN_DIR/issue-${ISSUE_NUM}.json")
jq -r .body "$RUN_DIR/issue-${ISSUE_NUM}.json" > "$RUN_DIR/body-${ISSUE_NUM}.md"
```

`author` is null for deleted accounts; `ISSUE_AUTHOR` is then empty and the social rule
treats the issue as **not** self-authored (the conservative side). A closed issue is still
evaluated — the report says `state: CLOSED` and the gate offers nothing to post for it.

### §1b Comments and the marker

Comments come from REST, not `gh issue view --json comments`, because editing in place
needs the **numeric** comment id and the view command returns node ids:

```bash
pr_facts_gh api --hostname "$HOST" --paginate --slurp \
  "repos/$SLUG/issues/$ISSUE_NUM/comments?per_page=100" \
  | jq -c '[.[][] | {id, login: (.user.login // null), body, created_at, updated_at}]' \
  > "$RUN_DIR/comments-${ISSUE_NUM}.json"
```

Then find this skill's own comment. The marker is the **first line** of the body, so
`startswith` — a marker quoted inside someone's reply must not match:

```bash
MARKER_ID=$(jq -r '[.[] | select(.body | startswith("<!-- issue-details:v1"))]
  | sort_by(.id) | .[0].id // empty' "$RUN_DIR/comments-${ISSUE_NUM}.json")
MARKER_COUNT=$(jq '[.[] | select(.body | startswith("<!-- issue-details:v1"))] | length' \
  "$RUN_DIR/comments-${ISSUE_NUM}.json")
MARKER_UPDATED=""
if [ -n "$MARKER_ID" ]; then
  MARKER_UPDATED=$(jq -r --argjson id "$MARKER_ID" '.[] | select(.id == $id) | .updated_at' \
    "$RUN_DIR/comments-${ISSUE_NUM}.json")
  COMMENT_ACTION="edit"
else
  COMMENT_ACTION="create"
fi
```

`MARKER_COUNT > 1` means an earlier run posted twice (a race, or a hand-pasted copy); the
oldest is the one edited, and a warning names the others — this skill never deletes a
comment. `MARKER_UPDATED` is the snapshot the gate re-checks before writing
(`execute.md` §3). This block is executed against fixtures by
`plugins/workflow/tests/issue-details-triage.test.sh` — the doc is the code under test;
edit both together.

### §1c Existing effort block

Detent reads effort from a fenced `detent-agent` block in the body. Read it; never write it:

```bash
EXISTING_EFFORT=$(awk '
  /^```detent-agent[[:space:]]*$/ {inb=1; next}
  /^```/ {inb=0}
  inb && $1 == "effort:" {print $2; exit}
' "$RUN_DIR/body-${ISSUE_NUM}.md")
```

Empty means no block. Whatever value is there — including `max`, which only the operator may
set — is reported as-is beside the proposal (`triage.md` §4); the issue body is never edited.

### §1d Board state

```bash
pr_facts_board "$HOST" "$OWNER" "$NAME" issue "$ISSUE_NUM" > "$RUN_DIR/board-${ISSUE_NUM}.json"
BOARD_STATUS=$(jq -r '[.items[] | select(.fields.Status != null)] | .[0].fields.Status // "none"' \
  "$RUN_DIR/board-${ISSUE_NUM}.json")
BOARD_PRIORITY=$(jq -r '[.items[] | select(.fields.Priority != null)] | .[0].fields.Priority // "none"' \
  "$RUN_DIR/board-${ISSUE_NUM}.json")
```

Read for the report and for the priority-disagreement note only. Board `Status` and
`Priority` are never written by this skill, in any mode. Select the item whose project
matches `detent.yaml`'s `tracker.project_slug` when several exist; verified on the reference
repo the issue carries exactly one item.

### §1e Dedupe candidates (skipped for `noise` and with `--no-dup-search`)

Re-run the rate gate first (§0b); on a search-bucket shortfall, sleep to its reset:

```bash
SEARCH_RESET=$(pr_facts_gh api --hostname "$HOST" rate_limit \
  --jq 'if .resources.search.remaining < 5 then .resources.search.reset else empty end')
if [ -n "$SEARCH_RESET" ]; then
  NOW_TS=$(date -u +%s)
  if [ "$SEARCH_RESET" -gt "$NOW_TS" ]; then sleep $(( SEARCH_RESET - NOW_TS + 1 )); fi
fi
```

*Title terms.* Mechanical: lowercase tokens of the title, stop-words and conventional-commit
verbs dropped, tokens shorter than four characters dropped, the three longest kept (length
is the cheap proxy for distinctiveness; ties break alphabetically so the query is
reproducible). The scope word of a `scope: title` prefix is **kept** — in the reference
repo `engagement:` and `ledger:` are the strongest topical signal a title carries.

```bash
TERMS=$(printf '%s' "$ISSUE_TITLE" \
  | tr -cs 'A-Za-z0-9_' '\n' | tr 'A-Z' 'a-z' \
  | grep -vxE 'a|an|the|and|or|of|to|in|on|for|with|from|by|is|are|be|not|no|when|because|never|ever|any|all|into|via|as|at|it|its|this|that|we|our|per|vs|use|uses|using|add|adds|fix|fixes|feat|docs|test|chore|refactor|perf|make|makes|support|allow|allows|should|can|does|do|after|before|instead|still|only|new|without|across|between|under|over|each|every' \
  | awk 'length($0) >= 4 && !seen[$0]++' \
  | awk '{print length($0) "\t" $0}' | sort -k1,1rn -k2,2 | head -3 | cut -f2 \
  | tr '\n' ' ' | sed 's/ $//')
```

Fewer than two terms → the searches are skipped and the verdict is `unclear` with reason
`title too generic to search`.

*The two searches.* GitHub ANDs the terms. `gh search issues` excludes PRs by default
(verified), and `gh pr list --search` charges the search bucket as well as GraphQL. The
issue itself always matches its own terms and is dropped:

```bash
pr_facts_gh search issues --repo "$SLUG" --state open --limit 10 "$TERMS" \
  --json number,title,url,labels,updatedAt \
  | jq -c --argjson me "$ISSUE_NUM" '[.[] | select(.number != $me)]' \
  > "$RUN_DIR/dup-issues-${ISSUE_NUM}.json"
pr_facts_gh pr list -R "$SLUG" --state open --limit 10 --search "$TERMS" \
  --json number,title,url,isDraft,closingIssuesReferences \
  > "$RUN_DIR/dup-prs-${ISSUE_NUM}.json"
```

*Merged since filing, naming this issue* — from the run-wide list, no extra call. The window
starts at the issue's `createdAt`; `mergedAt` and `createdAt` are both Zulu-form, so the
lexical compare is sound:

```bash
jq -c --arg since "$ISSUE_CREATED" --argjson me "$ISSUE_NUM" \
  '[.[] | select(.mergedAt >= $since) | select(.issues | index($me) != null)]' \
  "$RUN_DIR/shipped.json" > "$RUN_DIR/fixed-by-${ISSUE_NUM}.json"
SHIPPED_TRUNCATED=false
if [ "$(jq length "$RUN_DIR/shipped.json")" -eq 100 ] \
   && [ "$(jq -r 'min_by(.mergedAt) | .mergedAt' "$RUN_DIR/shipped.json")" \> "$ISSUE_CREATED" ]; then
  SHIPPED_TRUNCATED=true
fi
```

`SHIPPED_TRUNCATED=true` means the 100-PR cap ended the sweep before reaching the issue's
filing date — merged work may exist unseen. It produces a `warnings[]` line and blocks
nothing; the verdict vocabulary has no confidence grade in this version, so the prose
carries the caveat instead.

*Open PRs naming this issue* — also from the run-wide list:

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

### §1f Goal references

Only when the issue carries no `goal:*` label of its own. Three reference shapes, from the
body and every comment: `part of #N`, `epic #N`, and `#N` inside a Markdown heading line.
Nothing else — `closes #N`, `split out of #N`, and bare mentions are not parentage.

```bash
GOAL_REFS=$(cat "$RUN_DIR/body-${ISSUE_NUM}.md" <(jq -r '.[].body' "$RUN_DIR/comments-${ISSUE_NUM}.json") \
  | grep -oiE '(part of #[0-9]+|epic #[0-9]+|^#{1,6} .*#[0-9]+)' \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -un | head -5 | tr '\n' ' ' | sed 's/ $//')
```

Each referenced number is looked up in `goal-registry.tsv` (§0e) — no further API call. The
first hit, by reference order, becomes the proposed goal; two hits naming **different**
goal labels is a decision, not a first-wins (`triage.md` §4).
