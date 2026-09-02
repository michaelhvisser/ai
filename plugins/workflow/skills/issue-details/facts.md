# Facts — what `collect` does

`scripts/issue-details.sh collect` is the whole of Phases 0–1. This file is the map of the
script, section by function, with the live-verified facts each one encodes. Every recipe
was executed against `getparable/parable` before it was written into the script; where a
`gh` shape was surprising, the surprise is recorded here so the next author does not
re-discover it.

Two rules hold throughout, by construction:

- **Per-issue state lives in `$RUN_DIR/state-<n>.json`, never in a shell variable across
  steps.** `id_state_set` / `id_state_get` are the only accessors; pass A, pass B,
  `finalize`, the refresh, and the dispatcher each read the file. The only shell-level
  facts are run-wide constants (`HOST`, `SLUG`, `ME`, `BASE`, `BASE_SHA`, `PROJECT_SLUG`,
  the reserves), persisted to `run.json` so later subcommands reload them.
- **Every GitHub read goes through `id_gh <file> …`** — `pr_facts_gh` (the lib's retry
  wrapper) writing to a file, never on the left of a pipe, never inside `$( )` (both fork a
  subshell, where `STOP_BATCH` would die). A terminal rate-limit 403 sets `STOP_BATCH`;
  any failure sets `ISSUE_FAILED` / `ISSUE_ERROR`. GraphQL responses additionally pass
  `id_graphql_ok` — `pr_facts_graphql_ok` plus a `data != null` check — so an `errors[]`
  body is a fetch failure (and a `RATE_LIMITED` type a batch stop), never an empty fact.

---

## §0 Preflight — `id_preflight`

**Identity first.** `gh repo view --json nameWithOwner` and `--json url` (positional
repository — `gh repo view` has no `-R`). An issue URL argument sets `URL_HOST`/`URL_SLUG`;
a mismatch with the checkout's repository is exit 4 — never report on repo A while sitting
in repo B. Then `gh auth status --hostname "$HOST"` (exit 3), and `ME` from `gh api user`
— the login the marker lookup and the social rule compare against.

**Reserves**, from the checkout's `detent.yaml` when present
(`tracker.github_graphql_min_remaining_reserve`, `github_rest_min_remaining_reserve`) else
1000 each; the search bucket reserves 5 of its 30/min. `tracker.project_slug` is read here
too, for the board query. **The gate** (`id_gate preflight`, §1a) runs before anything
else; below reserve is exit 3 with no report — the quota is shared by every agent on the
account, and a triage comment is never worth starving a merge lane.

**The base tip**: `git ls-remote origin refs/heads/<base>` — no fetch, no object. `dev` by
default, falling back to the repository's default branch **only when no `--base` was
given**; an explicit branch that does not resolve is exit 3, never a silent substitution.
`BASE_SHA` goes into every marker (`<!-- issue-details:v1 dev=<sha> -->`) and the YAML's
`dev_sha`, so a later reader knows which tip the verdict was judged against.

**Run-wide fetches**, each proven with `jq -e 'type == "array"'` — a failure is exit 3,
never an empty fact:

- *Open PRs* (`gh pr list --state open --limit 100 --json …closingIssuesReferences`) for
  in-flight detection; the cap is warned, not hidden.
- *The goal registry*: every `goal:*` label (`gh label list`), then the issues carrying
  each (`gh issue list --label <l> --state all`). Epics in the reference repo are body-text
  lists, not native sub-issues, so the registry is the whole mechanism. An empty registry
  is a fact with a warning (verified 2026-09-02: `goal:q3-2026` exists, no issue carries it).

## §0f Selection — `id_select`

Both modes **materialise `selected.txt`**; nothing downstream reads the argv. Explicit
numbers are deduplicated in order. `--since <n>d` computes the boundary with BSD
`date -v` then GNU `date -d` (both verified), stops with exit 3 when neither works, lists
open issues with `--limit 500` (newest-created first — a smaller limit would drop the
window's oldest members before the cap applied; 300 open, 137 created in 30 days at the
time of writing), sorts by `createdAt, number`, and keeps the **oldest 50** with a warning
on stderr and in `warnings[]`. Each issue costs two search calls, and the 30/min search
bucket makes 50 issues roughly four minutes of sleeping; the cap keeps one run inside one
person's patience.

## §1 Per issue — the driver in `id_collect`

Two passes over `selected.txt`, so the merged-PR sweep can start its window at the
earliest selected filing date with one paginated query for the whole run. **Every call
that can set `STOP_BATCH` or `ISSUE_FAILED` is followed by its check** — the gate, then
each fetch — so a failed gate is followed by no fetch in the same iteration:

```
pass A:  per issue — if STOP_BATCH: record unevaluated; else gate → fetch, each `|| record; continue`
sweep:   gate → sweep, unless STOP_BATCH
pass B:  per issue — skip if in failed.txt or unevaluated.tsv; if STOP_BATCH: record;
         else gate → comments → noise → board → dedupe → goal refs, each `|| record; continue`;
         then self_authored and evaluated: true
```

A pass-A failure is persisted to `failed.txt`; pass B never guesses at a missing record.
An issue that fails for its own reason (a 404, a malformed response) is recorded and the
batch continues; a rate-limit 403 or a gate stop records that issue **and every issue
after it** as `batch stopped: <reason>`. Exit 4 only when explicit numbers were given and
none was found; exit 3 when nothing at all was evaluated for any other reason.

### §1a The gate — `id_gate <label>`

One `rate_limit` read to a file. Core or GraphQL below reserve → `STOP_BATCH`. An
unreadable response, a `{}`, a null bucket, or a non-numeric `remaining` → `STOP_BATCH`
(every operand is shape-checked before any comparison — fail closed). The search bucket
below reserve → sleep to its `reset` (it refills every minute; a batch two issues in
should not abort over it). Runs before pass A's fetch of each issue, before the sweep, and
before pass B's work on each issue.

### §1b The record — `id_fetch`

`gh issue view <n> --json number,title,body,author,createdAt,updatedAt,labels,state,url,milestone`,
proven to carry `number == <n>`. Into the state: title, author (empty for a deleted
account — treated as **not** self-authored, the conservative side), `created_at`,
`updated_at` (the evaluation snapshot the refresh compares), `state`, sorted `labels`,
the body to `body-<n>.md`, and `existing_effort` — the `effort:` inside a fenced
`detent-agent` block, read and never written (`max` included: reported as-is beside the
proposal). A closed issue is still evaluated; `post` writes nothing to it.

### §1c The merged-PR sweep — `id_sweep`

The "already fixed" candidates: a paginated GraphQL `search` with
`repo:<slug> is:pr is:merged base:<base> merged:>=<earliest selected createdAt>` returning
`closingIssuesReferences(first:100){ pageInfo{hasNextPage} nodes{number} }`. Not
`gh pr list --state merged` — that list is ordered by *creation* date with no sort flag
(cli/cli#10244), so an old PR merged recently can fall outside any cap. Verified live: the
qualifier, the closing references, `issueCount`, and `pageInfo` come back, and the query
charges the **GraphQL** bucket only (the search bucket read 30 before and after). Five
pages (500 PRs) cap the run; truncation comes from pagination — `hasNextPage` at the cap,
a failed page, or an `errors[]` response — never from timestamps. A PR closing more than
100 issues is carried `issues_truncated: true`; §1h treats it as an **unknown** match for
every issue it does not list, named in the prose, never counted as absent.

### §1d Comments and the marker — `id_comments`

REST (`repos/<slug>/issues/<n>/comments`, paginated, slurped), because editing in place
needs the **numeric** comment id and `gh issue view --json comments` returns node ids.
The pages are proven to be arrays of `{id:number, body:string, updated_at:string}`
objects — anything else is a fetch failure. Then the owned marker: author `== $ME`
(another user's marker is theirs) **and** the body's first line exactly
`^<!-- issue-details:v1 dev=[0-9a-f]{40} -->$` — tested on the first line alone, so a
quoted marker further down, trailing text after `-->`, or a future `v10` does not match.
One owned marker → `comment_action: edit` with its id and `updated_at`; none → `create`;
more than one → `refuse` with a warning naming the manual cleanup (deletion is outside the
write set, and editing one while leaving the other keeps two verdicts on the issue). The
state also stores `comments_fingerprint`: `[{id, updated_at}]` for **every** comment,
which the refresh compares whole.

### §1e Noise — `id_noise`

Mechanical, before any search, and not for the model to override: a `<!-- detent-intake:`
fingerprint in the body, or a path in the title or body under `.next/`, `dist/`, `build/`,
`out/`, `node_modules/`, or `_generated/` (a path segment — prose that says "the build" does
not match). `noise_signal` in the state forces `classification: noise` and
`verdict: unclear` in `finalize`, and skips the searches.

### §1f Board — `id_board`

The same Projects v2 query `lib/pr-facts.sh`'s `pr_facts_board` runs, through `id_gh` and
`id_graphql_ok`. The item whose `project.id` equals `detent.yaml`'s `tracker.project_slug`
is read; only when no item matches does the first item stand in. `Status` and `Priority`
are read for the report and the priority-disagreement note only — never written, in any
mode.

### §1h Dedupe candidates — `id_dedupe`

Skipped — with every result initialised to an empty set and **zero search calls** — for a
noise issue, with `--no-dup-search`, or when the title yields fewer than two terms.
Otherwise the terms are the three longest lower-cased tokens of the title after dropping
stop-words and conventional-commit verbs (length is the cheap proxy for distinctiveness;
ties alphabetical; the scope word of a `scope: title` prefix is **kept** — `engagement:`
and `ledger:` are the strongest topical signal a title carries in the reference repo).
GitHub ANDs the terms; `gh search issues` excludes PRs by default (verified);
`gh pr list --search` charges the search bucket as well as GraphQL; the issue itself
always matches and is dropped. Then, from the run-wide lists with no further call: merged
PRs since filing naming this issue (`candidates_shipped`), truncated-list PRs not naming
it (`fixed_by_unknown`), and open PRs naming it (`in_flight`). `candidates_open` is the
union of the two searches and the in-flight set — the only numbers the verdict guard
accepts.

### §1i Goal references — `id_goalrefs`

From the body and every comment: `part of #N`, `epic #N`, and `#N` inside a Markdown
heading line — nothing else (`closes #N`, `split out of #N`, and bare mentions are not
parentage). First-appearance order, duplicates dropped, cap five; `grep`'s no-match status
is neutralised so an issue with no reference does not abort a strict shell. The issue's
own `goal:*` label, when present, is recorded as `goal_own_label`. Resolution against the
registry happens in `finalize` (`triage.md` §4) — no further API call.
