# Facts — Phases 0–2

Every recipe here is read-only and was executed against a live repository before being written
down. Every `gh` call goes through `pr_facts_gh` (the retry wrapper) and is host- and
repo-explicit: there are no bare `gh api` calls.

**Transport rule: REST core and local reads; GraphQL only inside the two named fallbacks.**
`gh pr view`, `gh pr list`, `gh pr checks`, `gh pr diff`, `gh issue view`, `gh issue list`,
`gh repo view` and every `gh project` verb are GraphQL under the hood, and GraphQL carries a
secondary limit (points per minute, concurrency — shared by the Detent fleet and every review
session on the same token) that `rate_limit` never reports (§0b). A normal run therefore
issues **zero** GraphQL queries: identity comes from the git remote, the PR and issue records
from `repos/…` REST, the board from Detent's local snapshot, and the shipped sweep from local
git. GraphQL is reached only from §2c (thread resolution, when REST found ≥1 root thread) and
§2f (board, when the issue is absent from or stale in the snapshot), each guarded so a refusal
degrades to a stated unknown rather than a failed run.

---

## §0 Phase 0 — Preflight

Ordering is load-bearing: **identity before everything**. The base-branch ruleset needs
`$BASE`, the cache needs `headRefOid`, and the run directory needs the PR number — none of
which exist until step 0a has run.

### §0a Resolve identity (first, always)

Produce `{HOST, OWNER, NAME, SLUG, PR_NUM, BASE, HEAD_SHA, HEAD_REPO, HEAD_SLUG, IS_FORK}` before any
other call. Nothing downstream may use the current checkout's repo implicitly.

```bash
HOST="github.com"; SLUG=""
case "$PR_ARG" in
  https://*)   # full URL: host, owner, repo, and number all come from the URL
    HOST=$(printf '%s' "$PR_ARG" | sed -E 's#^https?://([^/]+)/.*#\1#')
    SLUG=$(printf '%s' "$PR_ARG" | sed -E 's#^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+.*#\1#')
    PR_ARG=$(printf '%s' "$PR_ARG" | sed -E 's#.*/pull/([0-9]+).*#\1#') ;;
esac
if [ -z "$SLUG" ]; then
  # Zero API calls: host and slug parsed from the origin remote (https, ssh://
  # and git@host:owner/name forms). `gh repo view` is GraphQL and is not used.
  IDENTITY=$(pr_facts_repo_identity origin) \
    || { echo "pr-details: origin remote missing or not owner/name" >&2; exit 4; }
  HOST=$(jq -r .host <<<"$IDENTITY")
  SLUG=$(jq -r .slug <<<"$IDENTITY")
fi
OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
```

Verified: `git@github.com:getparable/parable.git` and `https://github.com/getparable/parable`
both resolve to `{"host":"github.com","slug":"getparable/parable"}`.

**Mismatch rule.** If a URL resolved a `SLUG` or `HOST` different from the current checkout's,
stop with exit 4 and print both. Never silently report on repo A while the user is sitting in
repo B. `--json` callers get nothing on stdout.

**Auth is checked for the resolved host only.** Bare `gh auth status` walks every configured
host and can fail on an unrelated one:

```bash
gh auth status --hostname "$HOST" >/dev/null 2>&1 \
  || { echo "pr-details: not authenticated for $HOST" >&2; exit 3; }
```

Then the PR record the rest of the run depends on — one REST `pulls/{n}` call, normalised by
`pr_facts_pr_record` to the `gh pr view --json` field names, so this is also the §1a record
(`pr.json`); nothing fetches it twice:

```bash
pr_facts_pr_record "$HOST" "$SLUG" "$PR_ARG" > "$RUN_TMP/pr.json" || exit 4
PR_NUM=$(jq -r .number                    "$RUN_TMP/pr.json")
BASE=$(jq -r .baseRefName                 "$RUN_TMP/pr.json")
HEAD_SHA=$(jq -r .headRefOid              "$RUN_TMP/pr.json")
HEAD_REPO=$(jq -r .headRepositoryOwner.login "$RUN_TMP/pr.json")  # owner, for compare's owner:ref
# The FULL head slug, owner/name — remote-URL matching needs it, because the
# owner login alone is ambiguous (renamed forks, several repos per owner).
HEAD_SLUG=$(jq -r '.headRepositoryOwner.login + "/" + .headRepository.name' "$RUN_TMP/pr.json")
IS_FORK=$(jq -r .isCrossRepository        "$RUN_TMP/pr.json")
```

`PR_ARG` must be a number here. A branch-name argument resolves through `github_current_pr`
with that branch and its tip SHA (`git rev-parse <branch>`), which is REST
`commits/{sha}/pulls`. With no `PR_ARG` at all, resolve from the current branch the same way.
No resolution → exit 4. There is no `gh pr list --search` fallback: it is GraphQL, and a head
SHA that `commits/{sha}/pulls` does not know is not on any open PR.

Only now are the run directory (§0e), the git pins (§0c), and the ruleset lookup (§0d)
well-defined.

### §0b Rate gate

Run **once here and once immediately before Phase 4 dispatch**. All three buckets in one call,
because they are independent and duplicate search consumes more than one of them:

```bash
VIOLATIONS=$(pr_facts_rate_gate "$HOST" "$GRAPHQL_RESERVE" "$REST_RESERVE" "$SEARCH_RESERVE")
case $? in
  0) : ;;
  1) printf 'pr-details: rate limit below reserve:\n%s\n' "$VIOLATIONS" >&2; exit 3 ;;
  2) echo "pr-details: rate_limit unreadable" >&2; exit 3 ;;
esac
```

**Reserves come from the repo's `detent.yaml` when present**, because that file is the fleet's
declared floor and this skill must not undercut it:

| Reserve | Source key | Default when absent |
|---|---|---|
| `GRAPHQL_RESERVE` | `tracker.github_graphql_min_remaining_reserve` | `1000` |
| `REST_RESERVE` | `tracker.github_rest_min_remaining_reserve` | `1000` |
| `SEARCH_RESERVE` | *(no key exists upstream)* | `5` (of a 30/min bucket) |

`tracker.github_graphql_warn_remaining`, when present, produces a stderr warning line without
stopping.

**On any bucket below its reserve: stop and report — exit 3.** Never degrade silently. A
report whose sections are quietly missing is worse than a refusal, especially for a `--json`
consumer. If the user wants a cheaper run they pass `--no-dup-search` themselves; the skill
does not decide that for them.

**Search charges GraphQL too.** `gh` routes advanced issue search through GraphQL, so a full
`search` bucket does not guarantee a search will succeed. Budget duplicate search against
**both** buckets, and note in the report that the 30/min search bucket is small enough that
back-to-back runs can trip it on its own.

**The gate cannot see GraphQL's secondary limit.** `rate_limit` reports the hourly point
budget only. GraphQL also enforces a per-minute point rate and a concurrency cap, and a
breach returns `API rate limit already exceeded` while `rate_limit` still shows thousands
remaining — observed on 2026-09-02 with 4805 of 5000 GraphQL points left. The limit is
shared across every process on the token (the Detent fleet polls the board through it), so
no reserve this skill picks can protect a run. That is why the design target is **zero
GraphQL calls on a normal run**: the gate guards the buckets it can read, and the two GraphQL
fallbacks (§2c, §2f) each tolerate a refusal by degrading to a stated unknown.

### §0c Pin the git objects

The still-needed probe and every source read are pinned to two SHAs recorded here. Both
objects must exist locally before Phase 3, and a fork head is frequently absent:

```bash
BASE_TIP=$(git ls-remote origin "refs/heads/$BASE" | cut -f1)
git fetch --no-tags --quiet origin "+refs/heads/${BASE}:refs/pr-details/base-${PR_NUM}"
git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null \
  || git fetch --no-tags --quiet origin "+refs/pull/$PR_NUM/head:refs/pr-details/head-$PR_NUM"
git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null \
  || { echo "pr-details: head object $HEAD_SHA unavailable" >&2; FACTS_INCOMPLETE=1; }
MERGE_BASE=$(git merge-base "$BASE_TIP" "$HEAD_SHA") || FACTS_INCOMPLETE=1
```

**Brace every variable that is followed by a colon** — `${BASE}:refs/…`, `${BASE_TIP}:path`,
`${HEAD_REPO}:${HEAD_REF}`. Under zsh, `$BASE:r` is the history modifier *remove extension* and
`$BASE_TIP:A` is *absolute path*; an unbraced `"$BASE:refs/…"` silently becomes `devefs/…` and
the fetch fails. Observed on the first live run of this skill.

`refs/pull/<N>/head` is the reliable route to a fork head. The fetch writes only into
`refs/pr-details/*` — a namespace this skill owns — and touches no branch, no index, and no
working tree. If either object cannot be obtained, set `FACTS_INCOMPLETE` and let row 3 fire;
Phase 3 does not run against a guess.

**The base-branch history probe uses the range, not a count.** `git log -n 5 origin/$BASE`
is not "since the merge-base" and silently omits relevant commits:

```bash
git log --format='%H %s' "${MERGE_BASE}..${BASE_TIP}" -- "$PATH_UNDER_TEST"
```

### §0d Contract and ruleset discovery

Contract text (all optional, read-only): `WORKFLOW.md`, `AGENTS.md`, `CLAUDE.md` at the repo
root — first ~6k chars plus any section whose heading matches `/Gate|Review|Merg|Promot|State/i`.

From `detent.yaml`: `tracker.project_slug`, `active_states`, `observed_states`,
`terminal_states`, the three rate reserves, `deliverable.merge_method`, `gate.run`,
`gate.require_automated_review`, and `agent.auto_promote.*` when present.

**`AUTO_PROMOTE` is an explicit fact, read from the base branch, defaulting to false.** The
Detent daemon runs against the base branch's configuration, not the PR's — a PR that *enables*
auto-promotion has not enabled it yet:

```bash
AUTO_PROMOTE=$(git show "${BASE_TIP}:detent.yaml" 2>/dev/null \
  | awk '/^ *auto_promote:/{f=1} f&&/^ *enabled:/{print $2; exit}')
AUTO_PROMOTE="${AUTO_PROMOTE:-false}"
```

Read the ruleset with `pr_facts_rules "$HOST" "$SLUG" "$BASE"`. Several rulesets can
contribute rules to one branch, so every aggregate is explicit:

| Aggregate | Rule type | Semantics |
|---|---|---|
| `required_checks[]` | `required_status_checks` | **union of `(context, integration_id)` pairs**, `integration_id` null-preserving. Never key on `context` alone. |
| `strict_up_to_date` | `required_status_checks` | `ANY(strict_required_status_checks_policy)` |
| `threads_required` | `pull_request` | `ANY(required_review_thread_resolution)` |
| `approvals_required` | `pull_request` | `MAX(required_approving_review_count)` |
| `code_owner_review` | `pull_request` | `ANY(require_code_owner_review)` |
| `last_push_approval` | `pull_request` | `ANY(require_last_push_approval)` |
| `extra_approval_unattributed` | `pull_request` | `ANY(require_extra_approval_for_unattributed_changes)` |
| `dismiss_stale_on_push` | `pull_request` | `ANY(dismiss_stale_reviews_on_push)` |
| `allowed_merge_methods[]` | `pull_request` | **intersection** across contributing rulesets |
| `ignored[]` | `creation`, `deletion`, `update`, `non_fast_forward` | recorded, never blocking — these restrict branch mutation, not merging an open PR |
| `unknown[]` | any other `type` | preserved verbatim; **treated as a blocker** — the ready rows cannot fire while `unknown[]` is non-empty, and the rationale names the rule types |

Verified on `threefold-solutions/client-portals` `dev`: required
`("Lint, typecheck, test", 15368)` and `("Vercel", null)`; strict = true; threads required =
true; approvals required = 0; extra-approval-for-unattributed = true; merge methods
`["squash"]`; `ignored: ["deletion","non_fast_forward"]`; `unknown: []`. The `null`
`integration_id` on `Vercel` is exactly why the pair must tolerate null rather than drop the
entry — and `deletion`/`non_fast_forward` are exactly why they must not land in `unknown[]`,
or the ready rows could never fire on this repo.

**Fallbacks are keyed on emptiness, not on a 404.** `repos/<slug>/rules/branches/<branch>`
returns an **empty array with exit 0** when no ruleset applies — verified against a
non-existent branch. `pr_facts_rules` therefore falls through to
`repos/<slug>/branches/<base>/protection`, and then to `{"source":"none","advisory":true}`,
in which case the `threads_required` and `strict_up_to_date` conjuncts become **advisory** and
the rationale says so.

### §0e Run directory, cache, concurrency

Two directories, with different lifetimes:

```
$SCRATCH_DIR/pr-details/
  cache/<HEAD_SHA>/                     # SHA-immutable only; survives runs
    diff.patch  files.json  merge-base
  run/<PR>-<HEAD_SHA[0:12]>-<rand6>/    # everything else; unique per invocation
    pr.json  issue-<N>.json  facts.json  plan-prompt.md  plan-codex.md  plan-fable.md
```

Create it with `RUN_DIR=$(pr_facts_run_dir "$SCRATCH_DIR" "$PR_NUM" "$HEAD_SHA")`.

**Only SHA-immutable data is cached**: the diff, the changed-file list, and the merge-base.
Everything else — CI, reviews, threads, labels, issue bodies, board state, rate limits — is
**always fetched fresh**, on every run, regardless of `--refresh`. A blanket ten-minute cache
turns a status command into a stale one: reviews land, checks finish, and board items move
while `headRefOid` never changes, so a cached run can report "ready" after new feedback has
arrived. `--refresh` therefore busts only the immutable cache — useful after a force-push
reused a SHA, or after a corrupted download.

Cache writes are write-to-temp plus `mv` (an atomic rename within one filesystem). Since cache
entries are content-addressed by SHA, two concurrent runs write identical bytes and the rename
is idempotent.

**Concurrency needs no locking.** `RUN_DIR` carries the PR number, the head SHA, and a random
suffix, so two simultaneous invocations — even on the same PR at the same SHA — never share a
mutable path. There is no lock file, no `facts.json` in a shared location, and no `.done` file
that outlives its run.

`pr-details` **emits** `$RUN_DIR/facts.json` (the `--json` object of `output.md` §2) on every
run, whether or not `--json` was passed. Nothing consumes it yet; siblings may later.

### §0f Retries and partial data

`pr_facts_gh` implements the wrapper: **3 attempts**, exponential backoff `2s → 4s → 8s` with
±20% jitter, retrying HTTP `5xx`, a `403` whose body names a `secondary rate limit` or carries
`Retry-After`, and connection resets. It does **not** retry `401`, `404`, or a primary
rate-limit `403` — those go straight to exit 3 or 4.

**Partial GraphQL data is a failure of the fact it was fetching.** A response carrying both
`data` and a non-empty `errors[]` — the common shape when one node is inaccessible — must not
be treated as success. Guard every GraphQL call with `pr_facts_graphql_ok`. The affected fact
is recorded as `unknown`, never as a green or zero value; `warnings[]` names it; and if it is
load-bearing (CI, threads, mergeability, board) set `FACTS_INCOMPLETE` and let row 3 fire. A
`threads.unresolved: 0` derived from a partial response is precisely how a "ready" verdict
gets manufactured out of an error.

**Null authors.** `author` is null for deleted accounts. Every classifier treats
`author == null` as `human/unknown` and never dereferences `.login`.

---

## §1 Phase 1 — PR record, issues, duplicates, diff

### §1a Full PR record

The §0a record **is** the full record — `pr_facts_pr_record` returns every field the report
reads, so copy it into the run directory and fetch the file list beside it:

```bash
cp "$RUN_TMP/pr.json" "$RUN_DIR/pr.json"
pr_facts_pr_files "$HOST" "$SLUG" "$PR_NUM" > "$RUN_DIR/files.json"
```

Shapes (REST, normalised): `state ∈ OPEN|CLOSED|MERGED` (REST reports `closed` plus
`merged_at`; the helper folds that to `MERGED`); `mergeable ∈ MERGEABLE|CONFLICTING|UNKNOWN`
(REST `true|false|null`); `mergeStateStatus ∈ CLEAN|BEHIND|BLOCKED|DIRTY|UNSTABLE|HAS_HOOKS|
UNKNOWN|DRAFT` (REST `mergeable_state`, upper-cased); `labels[{name}]`; `autoMergeRequest`
(`null` or the auto-merge object); `reviewRequests[{__typename, login|name}]`; `additions`,
`deletions`, `changedFiles`, `commits` (a count); `transport: "rest"`. Verified on
getparable/parable PR 3053 (`OPEN`, `MERGEABLE`, `BLOCKED`) and PR 2899 (`MERGED`).

Fields the old GraphQL record carried that REST does not, and where each now comes from:
`reviewDecision` and `reviews` → §2b (`pr_facts_pr_reviews` + `pr_facts_review_decision`);
`closingIssuesReferences` and `projectItems` → §1b and §2f (timeline cross-references, the
Detent snapshot); `statusCheckRollup` → §2a (`pr_facts_check_matrix`, which was already the
authority because the rollup carries no app id); `comments` → §2g; `files` → `files.json`.

`files.json` is `[{path, status, additions, deletions, previous_filename}]`, paginated at 100,
so there is no `gh`-side cap and no `files_truncated` case: `(length)` equals `.changedFiles`
by construction (verified: 10/10 on PR 3053). `files_truncated` stays in the schema as a
constant `false` for consumers that read it.

### §1b Linked issues

REST has no `closingIssuesReferences`. Gather candidates from three zero-GraphQL sources,
then confirm the body ones against the issue's timeline:

1. **Body keyword** — `(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#(\d+)` over the PR body
   and commit messages. Confirmed by a `cross-referenced` timeline event from this PR →
   `source: body-keyword`, **linked**. Unconfirmed (the event has not been written yet, or the
   number is a typo) → `candidate`.
2. **Detent's own authority** — the branch convention `_(\d+)-[0-9a-f]{12}$` on `headRefName`,
   or a snapshot pipeline row whose `pull_request.number` is this PR
   (`pr_facts_snapshot_pr_issue "$SLUG" "$PR_NUM"`). Either → `source: branch-name` or
   `source: detent-snapshot`, **linked**: the daemon created the branch for exactly that issue.
3. **Bare mention** — `#(\d+)` anywhere else in the body → `source: body-mention`,
   `candidate`.

```bash
pr_facts_issue "$HOST" "$SLUG" "$N" > "$RUN_DIR/issue-$N.json"
LINKS=$(pr_facts_issue_links "$HOST" "$SLUG" "$N" "$PR_NUM")
CROSS_REF=$(jq -r .cross_referenced_by_pr <<<"$LINKS")      # true → body-keyword confirmed
BOARD_CHANGED_AT=$(jq -r '.last_board_change_at // empty' <<<"$LINKS")  # feeds §2f freshness
```

`pr_facts_issue` returns the `gh issue view --json` shape (`state ∈ OPEN|CLOSED`,
`labels[{name}]`, `url`) plus `isPullRequest`, because REST serves PRs from the same endpoint
and a candidate number can be one. Verified: issue #1763 ↔ PR 3053 and issue #2889 ↔ PR 2899
both report `cross_referenced_by_pr: true`.

**Sidebar-only links are not visible on REST.** A link made only through the PR's
"Development" panel writes no `cross-referenced` event and no `connected` event that this
endpoint returns (verified: #2889 auto-closed from `Fixes #2889` in the body and the timeline
still shows only the cross-reference). Such a PR reaches this skill with no linked issue unless
Detent's branch or snapshot names one, and the report says so rather than guessing.

### §1c Duplicate discovery

Skipped with `--no-dup-search`. Three signals; ≥2 → `likely`, 1 → `possible`.

*Signal 1 — title similarity.* Drop stop-words and conventional-commit prefixes; keep the 4–6
most distinctive tokens.

```bash
# gh search issues EXCLUDES pull requests by default (verified: a bare query returns issues
# only; --include-prs is the only way to get PRs, and we do not want them here).
pr_facts_gh search issues --repo "$SLUG" --state open  --limit 10 "$Q" \
  --json number,title,labels,updatedAt,state,url
pr_facts_gh search issues --repo "$SLUG" --state closed --limit 5 "$Q" \
  --json number,title,closedAt,url                    # "already fixed" candidates

# gh search prs has NO headRefName JSON field (verified: "Unknown JSON field").
# Available: assignees author authorAssociation body closedAt commentsCount createdAt id
#            isDraft isLocked isPullRequest labels number repository state title updatedAt url
pr_facts_gh search prs --repo "$SLUG" --state open --limit 10 "$Q" \
  --json number,title,isDraft,state,updatedAt,url,author

# Hydrate only the PR candidates that survive scoring — one REST pulls/{n} each, capped at 5.
pr_facts_pr_record "$HOST" "$SLUG" "$CAND" | jq -c '{number, headRefName, headRefOid, state, isDraft}'
```

A candidate's CI comes from `pr_facts_check_matrix` on its `headRefOid` when the comparison
needs it, and its board row from the snapshot (signal 3) — never from `projectItems`.

*Signal 2 — shared file paths.* `pr_facts_shared_files` is REST only: one
`pulls?state=open&per_page=50` call, then `pulls/{n}/files` for each other open PR (≤ 51 core
calls, verified: 25 open PRs on getparable/parable → 26 calls, one overlap found). It drops
lockfiles, `**/_generated/**`, and snapshots before comparing:

```bash
MINE=$(jq -c '[.[].path]' "$RUN_DIR/files.json")
SHARED=$(pr_facts_shared_files "$HOST" "$SLUG" "$PR_NUM" "$MINE")
SHARED_TRUNCATED=$(jq -r .truncated <<<"$SHARED")      # true when the open-PR page hit 50
jq -c '.prs' <<<"$SHARED"                               # [{number,title,headRefName,shared[]}]
```

Overlap on ≥2 semantic files, or on any file that is >50% of this PR's diff → candidate.
`truncated: true` (50 open PRs fetched — older ones unexamined) becomes a `warnings[]` line.

*Signal 3 — labels and board neighbourhood.* Open issues sharing a non-generic label (skip
`bug`, `enhancement`, `detent:*`, `slack-triage`), max 3 label queries, then each candidate's
board Status from **the snapshot only** — `pr_facts_board_local "$SLUG" "$CAND"` — with
`board_status: "unknown"` when the candidate is absent from it. Never spend GraphQL on a
candidate: the §2f fallback exists for the linked issue whose lane decides the plan, and a
duplicate check with an unknown lane is still a duplicate check. Two active board items for
one problem is the duplicate case this skill exists to catch.

### §1d Diff

`pr_facts_pr_diff "$HOST" "$SLUG" "$PR_NUM"` (REST `pulls/{n}` with the
`application/vnd.github.diff` media type — `gh pr diff` resolves the PR through GraphQL) → the
SHA-keyed cache. `DIFF_LINES=$(wc -l)` (verified: 483 lines on PR 3053). Over 4000 lines →
`HUGE_DIFF=true`, and Phase 4 receives a per-file stat plus full hunks for the top 10 files
with an explicit `DIFF TRUNCATED: n of m files shown` marker in the prompt.

### §1e Supersession sweep — recently shipped and backlog

Answers the half of "should this PR be closed instead of finished" that §1c's
similarity scoring misses: what **shipped** since this PR's merge-base, and what the
**backlog** plans for the same area. Skipped with `--no-dup-search` (same question, same
budget decision). The shipped half runs from **local git** with zero API calls; the
closed-issue half is one paginated REST list. Neither touches GraphQL or the 30/min search
bucket. Verified live, including the UTC normalization: REST `closed_at` is Zulu-form ISO
8601, and a `git` date printed with a local offset breaks the lexical comparison, so the
window boundary is forced to UTC.

*Recently shipped PRs*, with the issues they closed and their file lists. Squash merges land
on the base branch as first-parent commits carrying `(#N)` in the subject and the closing
keywords in the body, so the range `MERGE_BASE..BASE_TIP` **is** the window, in merge order —
which `gh pr list` could never give (it lists by creation date with no sort flag, so an old
PR merged recently fell outside its 30-row cap; michaelhvisser/ai#17):

```bash
SINCE=$(TZ=UTC git show -s --format=%cd \
  --date=format-local:%Y-%m-%dT%H:%M:%SZ "$MERGE_BASE")
SHIPPED_CAP="${SHIPPED_CAP:-200}"
pr_facts_shipped_local "$MERGE_BASE" "$BASE_TIP" "$SHIPPED_CAP" > "$RUN_DIR/shipped.json"
# The range bounds the window exactly; only the cap can cut it short. Truncation
# is therefore a count, not a guess from the sample's timestamps.
SHIPPED_TOTAL=$(git rev-list --count --first-parent "${MERGE_BASE}..${BASE_TIP}")
SHIPPED_TRUNCATED=false
if [ "$SHIPPED_TOTAL" -gt "$SHIPPED_CAP" ]; then
  SHIPPED_TRUNCATED=true
fi
```

`shipped.json` is `[{number, title, mergedAt, sha, issues[], files[]}]`, newest first;
`mergedAt` is the committer date in UTC (`format-local` under `TZ=UTC`). A first-parent
commit with no PR number in its subject (a direct push) is kept with `number: null` so its
files still count toward overlap. Merge commits diff against their first parent. Verified on
getparable/parable `dev`: 12 first-parent commits → 12 rows, PR 2899 carrying `issues:
[2889]`. An issue closed only through the sidebar has no keyword in the squash body and shows
up in the closed-issue sweep below instead (verified: #2343, closed by PR 2887 the same
second, appears there and not in `issues[]`).

`SHIPPED_TRUNCATED=true` mirrors signal 2's cap handling: it produces a `warnings[]` line
("shipped sweep capped at 200 merged commits inside the window — older shipped work
unexamined"), and the researcher brief says so, so an `unclear`-leaning verdict is never
laundered into confidence by a sweep that silently stopped early. This block is executed
against scripted repos by `plugins/workflow/tests/pr-details-supersession-sweep.test.sh` —
the doc is the code under test; edit both together.

Score file overlap with the same rules as signal 2 (drop lockfiles, `**/_generated/**`,
snapshots). A shipped PR overlapping this one's files, or closing an issue whose title
matches signal 1's tokens, is an `already-fixed` candidate **even when §3's per-file log
probe missed it** — a replacement can land in entirely new files. The closed issues ride
along as the "recently shipped issues" the researcher weighs.

*Recently closed issues* in the same window (catches issues closed as wontfix/superseded
with no merged PR):

```bash
pr_facts_closed_issues "$HOST" "$SLUG" "$SINCE" > "$RUN_DIR/closed-issues.json"
```

REST `issues?state=closed&since=` filters on `updated_at` and lists PRs as issues, so the
helper re-applies `closed_at >= SINCE` and drops rows carrying `pull_request`; output is
`[{number, title, closedAt, labels[{name}]}]`, paginated (verified: 13 issues in a 14-hour
window on getparable/parable).

*Backlog direction.* The open-issue candidates from §1c signals 1 and 3 already carry board
status; the question here is different — not "is this a duplicate" but "does **planned**
work make this PR moot" (a rework, replacement, or removal of the area it patches). Label
every open candidate whose board status is a planning state (`Backlog`, `Todo`) as a
`direction` candidate rather than dropping it for being dissimilar.

Everything lands in `duplicates[]` with `kind ∈ {issue, pr, shipped-pr, closed-issue,
backlog-issue}` plus its signal list. The sweep only gathers — the Phase 3 researcher is the
judge (`still-needed.md` §4), and no candidate is ever closed, commented on, or edited here.

---

## §2 Phase 2 — Status snapshot

### §2a CI

```bash
MATRIX=$(pr_facts_check_matrix "$HOST" "$SLUG" "$HEAD_SHA")
CI=$(pr_facts_ci_state "$RULES" "$MATRIX")
CI_STATE=$(jq -r .state <<<"$CI")
```

`pr_facts_ci_state` **materializes the required set first, then matches observations into
it.** This is the vacuous-green guard: building the required set from what was *observed*
makes "all required pass" trivially true whenever a required context is simply absent from the
rollup.

```
required := the (context, integration_id) union from §0d
for each r in required:
    obs := the matrix entry whose name == r.context
           and (r.integration_id is null or the entry's app_id == r.integration_id)
    if obs is absent          -> state[r] = "missing"
    elif obs not terminal     -> state[r] = "pending"
    elif obs successful       -> state[r] = "pass"
    else                      -> state[r] = "fail"

CI_STATE = red         if any state[r] == "fail"
         = pending     if any state[r] in {"pending","missing"}
         = partial-red if all required pass but a non-required check failed
         = green       if required is non-empty and all state[r] == "pass"
         = green       if required is empty and every observed terminal check succeeded
         = none        if required is empty and the matrix is empty
```

`missing` is deliberately folded into `pending`, never into green, and the report names the
missing context explicitly (`Vercel — required, not reported on this SHA`). Non-required
failures are `partial-red` and never block.

### §2b Reviews

REST has no `reviewDecision`; it is **derived**, the way GitHub derives it, from the review
list and the ruleset:

```bash
REVIEWS=$(pr_facts_pr_reviews "$HOST" "$SLUG" "$PR_NUM")
DECISION=$(pr_facts_review_decision "$REVIEWS" "$RULES" "$(jq -r .author.login "$RUN_DIR/pr.json")")
REVIEW_DECISION=$(jq -r .reviewDecision <<<"$DECISION")
APPROVALS_GIVEN=$(jq -r .approvals_given <<<"$DECISION")
```

The derivation: keep the latest non-`COMMENTED` review per author, PR author excluded (a
`DISMISSED` review supersedes that author's earlier approval); any latest
`CHANGES_REQUESTED` → `CHANGES_REQUESTED`; fewer distinct latest-`APPROVED` authors than the
ruleset's `approvals_required` → `REVIEW_REQUIRED`; at least one approval → `APPROVED`;
otherwise `""` — the same empty-string convention `gh pr view` used when nothing is required.
`APPROVALS_GIVEN` is that distinct-approver count. The object also carries
`changes_requested_by[]` and `latest[]` (login, type, state, commit) for the human/bot split.
**Bot login suffixes differ between transports** — REST returns
`chatgpt-codex-connector[bot]`, GraphQL returns `chatgpt-codex-connector` (both verified on
the same PR) — so always match with `startswith`. Verified on PR 3053: zero reviews,
`approvals_required: 0` → `""`.

Note that a Codex connector verdict may arrive as an **issue comment** rather than a formal
review — on one verified PR the reviews array was empty while the connector's verdict sat in
the comment stream. Read both.

### §2c Review threads

REST first, always; GraphQL only when there is a thread whose resolution matters:

```bash
THREADS=$(pr_facts_review_threads_rest "$HOST" "$SLUG" "$PR_NUM")
THREADS_REQ=$(jq -r .threads_required <<<"$RULES")
RESOLUTION_KNOWN=false
if [ "$(jq -r .total <<<"$THREADS")" -gt 0 ]; then
  # The one fact REST lacks is isResolved. Spend the GraphQL call only now,
  # and keep the REST result when it is refused or partial.
  if GQL=$(pr_facts_review_threads "$HOST" "$OWNER" "$NAME" "$PR_NUM") \
     && [ "$(jq -r .paginated_complete <<<"$GQL")" = "true" ]; then
    THREADS="$GQL"; RESOLUTION_KNOWN=true
  fi
fi
if [ "$RESOLUTION_KNOWN" = false ] && [ "$THREADS_REQ" = true ] \
   && [ "$(jq -r .total <<<"$THREADS")" -gt 0 ]; then
  FACTS_INCOMPLETE=1      # resolution is a merge gate here and cannot be read
fi
```

`pr_facts_review_threads_rest` groups `pulls/{n}/comments` by root (`in_reply_to_id ==
null`) into the same node shape (`id`, `path`, `line`, `origin`, `latest`, `isOutdated` from
a root whose `line` is null) with `isResolved: null` on every node and `resolution_known:
false` on the envelope — REST carries no resolution state anywhere. Verified on PR 2899: REST
2 comments → 1 root thread, origin `chatgpt-codex-connector[bot]`, latest by the PR author
starting `Fixed in`; GraphQL reports that same thread resolved.

**Counting when resolution is unknown.** A root thread counts as **open** unless its latest
comment is by the PR author or carries a skill marker (`Fixed in`, `Addressed in`,
`Dismissed (`) — those are the replies this workflow leaves when it resolves. The report
prints the count as `≤ n (resolution unknown)` and `status.threads.resolution_known: false`
with a `warnings[]` line. `FACTS_INCOMPLETE` is set **only when the ruleset's
`threads_required` is true**, because only then is resolution a merge gate; on a repo like
getparable/parable (`threads_required: false`) the upper bound feeds rows 12–14 as-is and
the plan says so. A PR with zero root threads never touches GraphQL.

The GraphQL helper passes **no cursor** on the first page (`-F after=null`; `gh` converts
the literal to JSON null — `-f after=""` sends an empty string, which is not a valid
cursor), and fetches comments as `first:1` (origin) plus `last:1` (latest) rather than
`first:50`, because only the origin author and the latest author are needed and `first:50`
silently reports the wrong "last commenter" on any thread past 50 comments. Verified live:
one PR in this repo has **79** review threads, so pagination is not hypothetical. **Every**
paginated collection follows this shape — threads, timeline items, project items, project
fields, labels, comments, commits.

Author classification: `origin` decides the thread's origin class, `latest` decides who spoke
last. Classify per
`${CLAUDE_PLUGIN_ROOT}/lib/bot-logins.md` (logins → class, with the `__typename` fallback:
`Bot` → `other-bot`, `User` → `human`, `null` → `human/unknown`). Any login matching
`startswith("chatgpt-codex-connector")` is `codex-bot`. Plugins cannot read each other's
files (`${CLAUDE_PLUGIN_ROOT}` is per-plugin), so this table is deliberately local.

**Automation under a human login.** Detent and `codex-ship` act with the user's own token, so
`human` is subdivided by body markers: `human/detent` (body starts with `## Workpad`,
`Detent recovered`, `Detent stopped retrying`, `Routed this issue to`), `human/codex-ship`
(`Dismissed (slop):`, `Dismissed (`), `human/skill-reply` (`Fixed in <sha>`, `Addressed in`),
else `human/person`. Only `human/person` origins count toward `UNRES_H`; the report states
that `h` is an upper bound when markers are absent. A bot-origin thread whose latest comment
is a `human/person` dismissal, still unresolved, is flagged `needs-resolve-only` — the fix is
a click, not code.

### §2d Mergeability

`mergeable` / `mergeStateStatus` from `pr.json`; if `UNKNOWN`, re-fetch with
`pr_facts_pr_record` after 3s and again after 10s (GitHub computes mergeability lazily on the
first read), then set `FACTS_INCOMPLETE`. A merged or closed PR reads `UNKNOWN` permanently
(verified on PR 2899) — rows 1–2 fire before this matters. Behind-count:

```bash
pr_facts_compare "$HOST" "$SLUG" "$BASE" "$HEAD_SHA"     # {status, ahead_by, behind_by}
```

For a fork, the head side is `${HEAD_REPO}:${HEAD_REF}`. **`behind_by > 0` under a strict ruleset
is *rebase required*, not advisory** — the server refuses the merge regardless of CI.

### §2e Local state

Surface only: `git rev-parse HEAD` vs `HEAD_SHA`, `git status --porcelain`,
`git symbolic-ref -q HEAD`. Never acted upon, never mutated.

### §2f Board state — from the issue, not the PR

Detent's board item is the **issue**, and Detent already holds the board locally: the daemon
writes `detent-board-snapshot.json` beside its `global.yaml` every poll (path from
`detent --format json config path`, override with `DETENT_BOARD_SNAPSHOT`). Read that first —
zero auth, zero API — and reach GitHub's Projects v2 GraphQL only when the snapshot cannot
answer:

```bash
BOARD=$(pr_facts_board_local "$SLUG" "$ISSUE_NUM" "$BOARD_CHANGED_AT")
BOARD_SOURCE="detent-snapshot"
if [ "$(jq -r .fresh <<<"$BOARD")" != "true" ]; then
  # Absent (not in an active or observed lane, or another project's issue) or
  # stale (older than refresh.stale_after_seconds, or a board change after
  # saved_at). One GraphQL call, and a refusal is an unknown, not a crash.
  if GQL=$(pr_facts_board "$HOST" "$OWNER" "$NAME" issue "$ISSUE_NUM"); then
    BOARD="$GQL"; BOARD_SOURCE="graphql"
  else
    BOARD_SOURCE="none"; BOARD_STATUS="unknown"; FACTS_INCOMPLETE=1
  fi
fi
```

Snapshot rows: `identifier` is `owner/repo#N`; `pipeline[]` covers the active and observed
lanes and carries `pull_request{number, branch_name, state, mergeable_state, head_sha,
ci_status}`; `board_issues[]` covers every lane the daemon has seen (Backlog included on the
verified snapshot; coverage follows the daemon's configured states, so absence means "ask
GraphQL", never "no board row"). `pr_facts_board_local` returns `{found, fresh, saved_at,
age_seconds, stale_after_seconds, state, priority_name, labels, blocked_by, pull_request,
matched_in, source}`; `state` **is** `BOARD_STATUS`. `fresh` requires age ≤
`refresh.stale_after_seconds` (600 when the file does not say; the verified daemon writes
4786) **and** no `project_v2_item_status_changed` event after `saved_at` (§1b's
`BOARD_CHANGED_AT` — REST carries no status name on that event, so it is only a tripwire).
Verified: issue #1763 → `Human Review`, `matched_in: pipeline`, `fresh: true` at age 20 s.

When the GraphQL path runs: select the item whose `project_id` equals `detent.yaml`'s
`tracker.project_slug`; if that is unknown and exactly one item exists, use it; if several,
set `BOARD_AMBIGUOUS=true` (row 6). No linked issue → `BOARD_STATUS=none`. **The PR's own
board row is no longer read** — it was only ever printed as an ignored line, and the snapshot
keys on the issue by construction. (History: on the reference repo issue #92 read `Human
Review` while its PR #161's row read `Backlog`; reading the PR row as the issue's state would
misroute the entire promotion ladder, which is why the issue row was always the fact.)
Record `board.source ∈ detent-snapshot|graphql|none` and `board.snapshot_age_s` in the output
(`output.md` §2); a stale snapshot that GraphQL could not refresh produces the `warnings[]`
line "board from stale snapshot (<age> s)" and keeps the snapshot's state as the best
available reading with `FACTS_INCOMPLETE` set.

### §2g Prior-skill evidence

GitHub first (durable), disk second (session-local).

| Skill | GitHub evidence | Disk evidence |
|---|---|---|
| `codex-ship` | `@codex review` PR comments by the user; Codex reviews naming `**Reviewed commit:** \`<HEAD_SHA[0:10]>\``; thread replies starting `Dismissed (slop):` | — |
| `antagonist-review` | commits `fix(review): address antagonist review round` | `$SCRATCH_DIR/**/antagonist-ledger.json` with `pr == PR_NUM` |
| `address-review` | thread replies and resolutions by the user after bot comments | `<repo>/.local/state/address-review-$PR_NUM.loop.local.json` |
| `e2e-verify` | `e2e-verified` label; a `## E2E Verification Results` comment | `<repo>/.local/state/e2e-verify-$PR_NUM.loop.local.json` |
| `review-deep --post` | a PR comment by the user with a `## Deep Review` / review-findings heading | — |
| Detent gate | the issue workpad comment (`## Workpad`) whose **`updated_at`** (not `created_at` — Detent edits the same comment in place) is after the `HEAD_SHA` commit date, mentioning the PR | — |

All six GitHub markers were confirmed live on this repo: `@codex review`,
`**Reviewed commit:** \`8872519c0d\`` (a 10-char SHA), `## Deep Review Results`, and
`## Workpad` on the issue.

Read the comment streams with `--paginate --slurp` piped into standalone `jq`. **`--slurp`
cannot be combined with `--jq` or `--template`** (verified: `gh` rejects the combination):

```bash
pr_facts_gh api --hostname "$HOST" --paginate --slurp \
  "repos/$SLUG/issues/$PR_NUM/comments?per_page=100" \
  | jq -c '[.[][] | {login: (.user.login // null), body, created_at, updated_at}]'
```

Each source records `{ran, at_head, evidence}`. `at_head` means the evidence post-dates or
names the current `HEAD_SHA`; evidence against an older SHA is **stale** and satisfies
nothing.
