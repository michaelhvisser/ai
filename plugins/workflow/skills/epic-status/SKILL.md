---
name: epic-status
description: "Read-only status report for tracking issues (epics) and their children: sub-issue progress from GitHub's native sub-issue graph or a body checklist, which children are in flight and behind which PR, each open child's board column and agent lane, and — the part that earns the run — the concrete blocker class per child, separating a dependency from an unanswered decision from an issue body gone stale against the default branch. Verifies merge state rather than trusting a closed PR, and re-tests every stated dependency instead of repeating it. Use when asked where an epic stands, what is left on it, or which of its children could be worked next; or to sweep every open epic before planning a cycle. SKIP for one issue's triage — run issue-details — and SKIP for one PR's situation report — run pr-details."
argument-hint: "[<epic-number> ...] [--all] [--label <label>] [--repo <owner/repo>] [--brief]"
---

# Epic Status — read-only progress report for tracking issues

An epic's board column tells you nothing about whether it is moving. This skill
answers "where are we?" from evidence: what merged, what is open behind a PR,
and **what specifically is stopping each remaining child**.

It mutates nothing — no labels, no board moves, no comments, no issue edits. It
ends in a report. Acting on that report is the driver's call, so recommend and
stop.

## Vocabulary

- **Epic** — a tracking issue whose progress is the sum of its children. Children
  come from GitHub's native sub-issue graph, or, for older epics, a markdown
  checklist in the body.
- **Child** — an issue the epic tracks.
- **Lane** — the agent host or queue a child is routed to, encoded as a label
  (this marketplace's fleet uses `detent:<host>`; an absent label usually means a
  default lane). Lanes are discovered, never assumed — see step 5.

## Step 0 — bind the repository and board

Do not hardcode either. Everything downstream keys off these.

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=${REPO%%/*}
BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
printf 'repo=%s owner=%s base=%s\n' "$REPO" "$OWNER" "$BASE"
gh project list --owner "$OWNER" --format json \
  | jq -r '.projects[] | "\(.number)\t\(.title)"'
```

Pass `--repo` to override. If the owner has several projects, ask which board
tracks this work rather than guessing; if the repo uses no project board, skip
steps 5 and 7 and say the board column is unavailable.

**Completion criterion:** `REPO`, `OWNER`, `BASE` are bound, and either a project
number is chosen or the board is declared absent.

## Step 1 — find the epics

Epics are not reliably labelled. Cast a wide net, then narrow by reading:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh issue list --repo "$REPO" --state open --limit 100 --search "epic in:title" \
  --json number,title,labels \
  --jq '.[] | "#\(.number)\t\(.title)\t\(.labels | map(.name) | join(","))"'
```

Add a label sweep when the question is scoped to a goal or theme — pass the
label with `--label`:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
LABEL=goal:current-quarter
gh issue list --repo "$REPO" --state open --limit 100 --label "$LABEL" \
  --json number,title --jq '.[] | "#\(.number)\t\(.title)"'
```

Two failure modes to avoid:

- **Not every epic says "epic".** When the driver names one in prose ("the
  billing epic"), search for the words they used; do not map prose to a number
  by guessing.
- **Not every issue saying "epic" is one.** Some are tracking issues whose
  children all closed, or single issues that merely mention an epic. Read before
  reporting.

**Completion criterion:** every epic the driver asked about is resolved to a
number, or explicitly reported as not found.

## Step 2 — read sub-issue progress

The native sub-issue graph is the source of truth for membership. Batch the
epics into one query with aliases:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=${REPO%%/*}
NAME=${REPO##*/}
gh api graphql -F owner="$OWNER" -F name="$NAME" -F number=1 -f query='
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    issue(number:$number) {
      number title state
      subIssuesSummary { total completed percentCompleted }
      subIssues(first:100) { totalCount nodes { number title state } }
    }
  }
}' --jq '.data.repository.issue
  | "#\(.number) \(.title)  \(.subIssuesSummary.completed)/\(.subIssuesSummary.total)",
    "  returned=\(.subIssues.nodes | length) of totalCount=\(.subIssues.totalCount)",
    (.subIssues.nodes[] | select(.state=="OPEN") | "  OPEN #\(.number) \(.title)")'
```

Two traps, both silent:

- **`subIssues(first:N)` truncates without error** while `totalCount` reports the
  truth. The recipe prints both — if they differ, page with `after:` before
  reporting, or you will under-count open children.
- **An epic with zero sub-issues is not an empty epic.** Older ones track work in
  a body checklist. Read the body and follow the issue references:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh issue view 1 --repo "$REPO" --json body --jq .body | grep -oE '#[0-9]+' | sort -u
```

**Completion criterion:** every open child is enumerated — `nodes | length`
equals `totalCount`, or the body checklist has been read.

## Step 3 — map in-flight PRs to children

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,isDraft,updatedAt,labels \
  --jq '.[] | "#\(.number)\t\(if .isDraft then "DRAFT" else "open" end)\t\(.title)\t\(.updatedAt[:10])"'
```

Resolve each PR to the child it closes from its **body**, not its title:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh pr list --repo "$REPO" --state open --limit 100 --json number,body \
  --jq '.[] | . as $PR | (.body // "")
    | [scan("(?i)(?:closes|fixes|resolves)\\s+#([0-9]+)")]
    | flatten | .[] | "PR #\($PR.number) -> closes #\(.)"'
```

**A closed PR is not a merged PR.** Check both fields — a PR can be green,
cleanly reviewed, and still never have landed:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh pr view 1 --repo "$REPO" --json number,state,mergedAt,closedAt \
  --jq '"#\(.number) state=\(.state) mergedAt=\(.mergedAt // "null")"'
```

`state=CLOSED` with `mergedAt=null` means the work did not land. This also
decides unblocking: automated dependency-unblock rules typically require a
blocker to be terminal **or merged**, so a closed-unmerged PR frees nothing.
Confirm what actually reached the default branch:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git fetch origin "$BASE" --quiet
git log "origin/$BASE" --oneline -20
```

**Completion criterion:** every open PR touching this epic is linked to a child,
and every PR claimed as landed has been checked for a non-null `mergedAt`.

## Step 4 — pull the board

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=${REPO%%/*}
PROJECT=1
gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 3000 > /tmp/epic-board.json
jq -r '.items | length | "board items: \(.)"' /tmp/epic-board.json
```

**`gh project item-list` truncates at `--limit` and says nothing.** The default
is far below a mature board's item count, and the items lost are the newest —
exactly the children you are asking about. Pass a limit above the board size and
sanity-check the printed count.

Join the board against the epic's children:

```bash
jq -r --argjson CHILDREN '[1,2,3]' '
  .items[]
  | select(.content.number as $N | $CHILDREN | index($N))
  | [ "#\(.content.number)",
      (.status // "no-column"),
      ((.labels // []) | join(",")),
      (.title[:52])
    ] | @tsv' /tmp/epic-board.json
```

**Completion criterion:** every open child has a board column, or is reported as
not on the board.

## Step 5 — discover lanes, then read lane depth

Lane labels are repo-local. Discover them instead of assuming a naming scheme:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh label list --repo "$REPO" --limit 200 --json name \
  --jq '.[].name | select(test("^(agent|detent|lane):"))'
```

Then read queue depth per lane, treating "no lane label" as its own bucket:

```bash
jq -r '
  [ .items[]
    | select(.status == "Todo")
    | ((.labels // []) | map(select(test("^(agent|detent|lane):"))) | first) // "«default lane»"
  ] | group_by(.) | map({lane: .[0], queued: length})
    | sort_by(-.queued)[] | "\(.queued)\t\(.lane)"' /tmp/epic-board.json
```

Read the number against the fleet's own limits, not intuition. Queue depth, not
host capacity, is what decides whether new work starts: if the dispatcher caps
concurrent agents per column and orders columns by priority, a deep queue in the
lowest-priority column will not drain soon. Read the repo's dispatcher config
(commonly `detent.yaml` at the repo root) for `max_concurrent_agents_by_state`
and the column priority order before claiming anything about timing.

Only run this step when the driver is deciding what to work next; skip it for a
pure status question.

## Step 6 — classify every blocker

This is the step that earns the run. A child sitting in a blocked column tells
you nothing; the reason does. Read the latest comment:

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api "repos/$REPO/issues/1/comments" --jq '.[-1].body' | head -c 800
```

Classify into exactly one of these. They demand different actions, and conflating
them is the failure this step exists to prevent:

| Class | How it presents | Action |
|---|---|---|
| **Preserved work** | Runner stopped mid-run with the workspace kept (`workspace_preserved`, "unpushed commits retained") | Recover that host's workspace before re-dispatching — otherwise the work is paid for twice |
| **Discarded work** | Same stop, nothing kept (`output_discarded`) | Safe to re-dispatch as-is |
| **Dispatch loop** | Repeated attempts with no diff, commit, or PR advancement (`dispatch_loop_detected`) | Re-dispatching unchanged will loop again — the issue needs re-scoping, not another attempt |
| **Spurious bump** | Column changed during completion (`tracker_lane_transition`) | Usually noise; the child is ready |
| **Unanswered decision** | The **body** carries "open decisions", "decide before building", or a needs-decision label | A human owes an answer; never let an agent default into it |
| **Dependency** | "after #N", "blocked by #N" | Re-test it — see below |
| **Stale body** | Cited files, schemas, or symbols no longer exist | Not dispatchable at any column until rewritten |

### Re-test every stated dependency

Issues go stale, and a dependency written months ago is a claim, not a fact. A
child that says "must wait for #N to establish the pattern" may be waiting on a
pattern that landed through some other PR. Check the default branch:

```bash
BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git fetch origin "$BASE" --quiet
git grep -l "SomeSymbol" "origin/$BASE" -- '*.go'
git log "origin/$BASE" --oneline -20 --grep="keyword" -i
```

Label each dependency **REAL**, **STALE**, or **SOFT** (the dependency exists but
the child can adopt what already shipped) and report which.

### Check the body against the branch

Before calling any child ready, spot-check its key references. Renames are the
worst case: one schema or module rename invalidates every table, path, and
symbol name across several open issues at once, and an agent dispatched at such a
body burns a run discovering that.

```bash
BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git show "origin/$BASE:README.md" | head -5
```

**Completion criterion:** every open child carries exactly one blocker class, and
every dependency is marked REAL, STALE, or SOFT with the evidence that decided it.

## Report

Per epic, in this order:

1. **Verdict line** — done / close / mid-flight / stalled, with the child
   fraction (`67/78`) and the date of the last merge that advanced it.
2. **Shipped recently** — merged PRs, with dates.
3. **In flight** — open PRs, the child each closes, and any blocker stated in the
   PR body (pending approval, blocked verification, incomplete review).
4. **Open children** grouped by theme, each with column, lane, and blocker class.
5. **Where the human is the bottleneck** — only the decisions the driver must
   make. Keep it short and put it last; it is the part that gets acted on.

`--brief` collapses to items 1 and 5.

## Rate limits

Fleets that share one token exhaust the GraphQL quota through board polling, and
this skill's own board read is expensive. Exhaustion is partial, not total, and
the partiality is the useful part:

- **The search API has its own tighter budget.** `gh issue list --search` can
  fail with `API rate limit already exceeded` while a raw `gh api graphql` query
  in the same second succeeds. A failed epic search does not mean the whole token
  is spent — retry the searches, and use step 2's direct query meanwhile.
- **Probe with a real read**, `gh api graphql -f query='{viewer{login}}'`. A
  `{rateLimit{remaining}}` query is itself exempt and will report health during
  exhaustion; `gh api rate_limit` may report a different token's budget entirely.
- **REST keeps working when GraphQL is out.** `gh api repos/OWNER/REPO/issues/N`
  for state, `.../issues/N/comments` for blocker reasons, and
  `.../pulls/N` for merge state (`merged_at`, snake_case on REST).
- **Projects v2 has no REST equivalent.** If the board read fails, report
  everything else and say the column is unavailable — never infer it.
- Exhaustion is bursty; a retry after 20–40s usually gets a window.

## Rules

- **Never report a status you did not read.** A child is not done because a
  sibling merged.
- **Never call a PR landed without a non-null `mergedAt`.**
- **Never repeat a dependency you did not re-test**, and never repeat a body's
  file or symbol reference you did not confirm on the default branch.
- Keep the three stuck-shapes distinct: a dependency, an unanswered decision, and
  a stale body need different actions.
- If an earlier claim in the session turns out wrong, correct it in one line and
  continue.
- Mutating anything — a column, a label, an issue body — is out of scope. Say
  what should change and let the driver decide.
