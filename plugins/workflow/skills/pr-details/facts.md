# Facts — Phases 0–2

Every recipe here is read-only and was executed against a live repository before being written
down. Every `gh` call goes through `pr_facts_gh` (the retry wrapper) and is host- and
repo-explicit: there are no bare `gh api` calls.

---

## §0 Phase 0 — Preflight

Ordering is load-bearing: **identity before everything**. The base-branch ruleset needs
`$BASE`, the cache needs `headRefOid`, and the run directory needs the PR number — none of
which exist until step 0a has run.

### §0a Resolve identity (first, always)

Produce `{HOST, OWNER, NAME, SLUG, PR_NUM, BASE, HEAD_SHA, HEAD_REPO, IS_FORK}` before any
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
  SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 4
  HOST=$(gh repo view --json url --jq '.url | sub("^https?://";"") | split("/")[0]')
fi
OWNER="${SLUG%%/*}"; NAME="${SLUG##*/}"
```

`gh repo view` takes the repository as a **positional** argument — it has no `-R` flag
(verified: `unknown shorthand flag: 'R'`). Every *other* command in this skill does take `-R`.

**Mismatch rule.** If a URL resolved a `SLUG` or `HOST` different from the current checkout's,
stop with exit 4 and print both. Never silently report on repo A while the user is sitting in
repo B. `--json` callers get nothing on stdout.

**Auth is checked for the resolved host only.** Bare `gh auth status` walks every configured
host and can fail on an unrelated one:

```bash
gh auth status --hostname "$HOST" >/dev/null 2>&1 \
  || { echo "pr-details: not authenticated for $HOST" >&2; exit 3; }
```

Then the minimal PR record the rest of Phase 0 depends on:

```bash
pr_facts_gh pr view "$PR_ARG" -R "$SLUG" \
  --json number,baseRefName,headRefOid,headRepositoryOwner,isCrossRepository,state \
  > "$RUN_TMP/pr-min.json" || exit 4
PR_NUM=$(jq -r .number                    "$RUN_TMP/pr-min.json")
BASE=$(jq -r .baseRefName                 "$RUN_TMP/pr-min.json")
HEAD_SHA=$(jq -r .headRefOid              "$RUN_TMP/pr-min.json")
HEAD_REPO=$(jq -r .headRepositoryOwner.login "$RUN_TMP/pr-min.json")
IS_FORK=$(jq -r .isCrossRepository        "$RUN_TMP/pr-min.json")
```

With no `PR_ARG` at all, resolve from the branch first (`github_current_pr`), then from the
head SHA (`gh pr list -R "$SLUG" --search "$HEAD_SHA"`). No resolution → exit 4.

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

One `gh pr view`, repo-explicit:

```bash
pr_facts_gh pr view "$PR_NUM" -R "$SLUG" --json number,title,body,url,state,isDraft,author,\
createdAt,updatedAt,baseRefName,headRefName,headRefOid,headRepositoryOwner,isCrossRepository,\
mergeable,mergeStateStatus,reviewDecision,reviewRequests,reviews,labels,closingIssuesReferences,\
statusCheckRollup,projectItems,autoMergeRequest,additions,deletions,changedFiles,files,comments,\
commits > "$RUN_DIR/pr.json"
```

Shapes: `mergeable ∈ MERGEABLE|CONFLICTING|UNKNOWN`;
`mergeStateStatus ∈ CLEAN|BEHIND|BLOCKED|DIRTY|UNSTABLE|HAS_HOOKS|UNKNOWN|DRAFT`;
`reviewDecision ∈ ""|APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED` (**empty string**, not null,
when no review is required); `statusCheckRollup[]` mixes
`CheckRun{name,status,conclusion,workflowName}` and `StatusContext{context,state}` — Vercel is
a legacy status (`state:"SUCCESS"`, `conclusion:null`).

**The rollup carries no app id.** Verified: neither `statusCheckRollup` nor
`github_check_snapshot` exposes one, so the `(context, integration_id)` match cannot be made
from either. Use `pr_facts_check_matrix` (§2a), which reads `check-runs` and the combined
status directly and preserves `app.id`.

`files` is capped by `gh`. Compare `(.files | length)` against `.changedFiles`; when they
differ, take the authoritative list from `gh pr diff --name-only` and set
`files_truncated: true`.

### §1b Linked issues

When `closingIssuesReferences` is empty, fall back in order: the keyword regex
`(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#(\d+)` over the PR body and commit messages;
then bare `#(\d+)` in the body; then the Detent branch convention `_(\d+)-[0-9a-f]{12}$`.
Record `source: sidebar|body-keyword|body-mention|branch-name`. Only `sidebar` and
`body-keyword` count as *linked*; the rest are *candidate*, and the report says so.

Fetch each with `gh issue view "$N" -R "$SLUG" --json number,title,body,state,labels,url`.

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

# Hydrate only the PR candidates that survive scoring — one gh pr view each, capped at 5.
pr_facts_gh pr view "$CAND" -R "$SLUG" --json number,headRefName,headRefOid,statusCheckRollup,projectItems
```

*Signal 2 — shared file paths.* `gh` has no `--argjson` flag and `--jq` takes exactly one
expression, so this must pipe into standalone `jq`; `pr_facts_shared_files` does that and
already drops lockfiles, `**/_generated/**`, and snapshots:

```bash
MINE=$(jq -c '[.files[].path]' "$RUN_DIR/pr.json")
pr_facts_shared_files "$HOST" "$SLUG" "$PR_NUM" "$MINE"
```

Overlap on ≥2 semantic files, or on any file that is >50% of this PR's diff → candidate. The
50-PR cap is recorded as `truncated: true`.

*Signal 3 — labels and board neighbourhood.* Open issues sharing a non-generic label (skip
`bug`, `enhancement`, `detent:*`, `slack-triage`), max 3 label queries, then each candidate's
board Status via `pr_facts_board`. Two active board items for one problem is the duplicate
case this skill exists to catch.

### §1d Diff

`pr_facts_gh pr diff "$PR_NUM" -R "$SLUG"` → the SHA-keyed cache. `DIFF_LINES=$(wc -l)`. Over
4000 lines → `HUGE_DIFF=true`, and Phase 4 receives a per-file stat plus full hunks for the top
10 files with an explicit `DIFF TRUNCATED: n of m files shown` marker in the prompt.

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

From `pr.json`: `reviewDecision`, plus `reviews[]` reduced to the latest state per author.
Fall back to `github_pr_reviews`. **Bot login suffixes differ between transports** — REST
returns `chatgpt-codex-connector[bot]`, GraphQL returns `chatgpt-codex-connector` (both
verified on the same PR) — so always match with `startswith`. Record `APPROVALS_GIVEN`
(distinct latest-`APPROVED` authors, excluding the PR author) and CHANGES_REQUESTED authors
split human vs bot.

Note that a Codex connector verdict may arrive as an **issue comment** rather than a formal
review — on one verified PR the reviews array was empty while the connector's verdict sat in
the comment stream. Read both.

### §2c Review threads

```bash
THREADS=$(pr_facts_review_threads "$HOST" "$OWNER" "$NAME" "$PR_NUM")
[ "$(jq -r .paginated_complete <<<"$THREADS")" = "true" ] || FACTS_INCOMPLETE=1
```

The helper passes **no cursor** on the first page (`-F after=null`; `gh` converts the literal
to JSON null — `-f after=""` sends an empty string, which is not a valid cursor), and fetches
comments as `first:1` (origin) plus `last:1` (latest) rather than `first:50`, because only the
origin author and the latest author are needed and `first:50` silently reports the wrong "last
commenter" on any thread past 50 comments. Verified live: one PR in this repo has **79**
review threads, so pagination is not hypothetical. **Every** paginated collection follows this
shape — threads, timeline items, project items, project fields, labels, comments, commits.

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

`mergeable` / `mergeStateStatus` from `pr.json`; if `UNKNOWN`, re-poll after 3s and again
after 10s, then set `FACTS_INCOMPLETE`. Behind-count:

```bash
pr_facts_compare "$HOST" "$SLUG" "$BASE" "$HEAD_SHA"     # {status, ahead_by, behind_by}
```

For a fork, the head side is `${HEAD_REPO}:${HEAD_REF}`. **`behind_by > 0` under a strict ruleset
is *rebase required*, not advisory** — the server refuses the merge regardless of CI.

### §2e Local state

Surface only: `git rev-parse HEAD` vs `HEAD_SHA`, `git status --porcelain`,
`git symbolic-ref -q HEAD`. Never acted upon, never mutated.

### §2f Board state — from the issue, not the PR

Detent's board item is the **issue**:

```bash
pr_facts_board "$HOST" "$OWNER" "$NAME" issue       "$ISSUE_NUM"
pr_facts_board "$HOST" "$OWNER" "$NAME" pullRequest "$PR_NUM"
```

Select the item whose `project_id` equals `detent.yaml`'s `tracker.project_slug`; if that is
unknown and exactly one item exists, use it; if several, set `BOARD_AMBIGUOUS=true` (row 6).
No linked issue → `BOARD_STATUS=none`. The PR's *own* board row is read separately and, when
it differs, printed once as an ignored line. Verified on this repo: issue #92 reads
`Human Review` while its PR #161's row reads `Backlog` — reading the PR row as the issue's
state would misroute the entire promotion ladder.

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
