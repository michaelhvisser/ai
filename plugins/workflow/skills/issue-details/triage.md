# Triage — the judgement tables (Phase 2) and the guards `finalize` applies

The orchestrator reads `state-<n>.json` for every evaluated issue, applies the tables
below, and writes `judgement-<n>.json` (`SKILL.md` §"Phase 2"). The mechanical guards —
the closed verdict vocabulary, never-`max`, the social rule, `needs_decision`, goal
resolution — live in `scripts/issue-details.sh` (`id_verdict_guard`, `id_effort_guard`,
`id_finalize_issue`) and run in `finalize`; the tests drive them directly. A judgement that
strays outside a table is corrected there, with a note the comment prints — never
silently adopted.

---

## §1 Classification (Phase 2)

Exactly one of `bug | goal | idea | question | noise`, decided in this order; first match
wins.

| # | Class | Condition | Evidence the comment must carry |
|---|---|---|---|
| 1 | `noise` | a **mechanical** signal: the body carries a `<!-- detent-intake:` fingerprint, or a path in the title or body sits under build output (`.next/`, `dist/`, `build/`, `out/`), `node_modules/`, or `_generated/` | the signal, quoted |
| 2 | `bug` | the issue reports **broken existing behaviour**, and the expected behaviour is **already defined** — by docs, a test, the API contract (`openapi.yaml`), or established behaviour the issue can point at | `expected-by: <path or #N>` — the place that defines the expected behaviour |
| 3 | `goal` | a request for new capability that hangs off a goal-labelled epic (§4 resolves to a label) | the epic number |
| 4 | `idea` | a request for new capability with no goal parent | — |
| 5 | `question` | anything whose next step is a product ruling, not code — including a "bug" whose expected behaviour nobody has defined | the question, in one line |

Judgement without a citation is not a `bug`. When the classifier cannot name where the
expected behaviour is defined, the class is `question`, and `needs_decision` follows (§6).
The mechanical noise check is `collect`'s (`facts.md` §1e): when `noise_signal` is set in
the state, `finalize` forces `classification: noise` and `verdict: unclear` whatever the
judgement says, and no search was run for it. The judgement may set
`decision_required: true` with a `decision_reason` when the issue **itself** asks for a
ruling (a heading or sentence saying a design choice must be made before work starts);
that feeds §6 and never changes the class.

## §2 Dedupe is advisory, and names at most one canonical (Phase 3)

The candidate sets in the state (`facts.md` §1h — `dup_issues`, `dup_prs`, `in_flight` by
title terms and closing references; `candidates_shipped`, merged PRs since filing naming
this issue; `fixed_by_unknown`, merged PRs whose closing list was truncated) are
**context**, not a verdict. The orchestrator reads the titles and answers with exactly one
of the closed vocabulary:

| Verdict | Meaning | Requires |
|---|---|---|
| `needed` | no duplicate and no fixing PR found; the issue stands | a problem statement exists (`body-<n>.md` non-empty), and `dedupe_skipped` is 0 |
| `likely-duplicate-of #N` | #N is open and covers the same problem | #N appeared in `CANDIDATES_OPEN` |
| `already-fixed-by #N` | #N merged into the base branch after filing and names this issue | #N appeared in `CANDIDATES_SHIPPED` |
| `unclear` | searches skipped or degraded, no problem statement, several plausible canonicals, or a candidate the orchestrator cannot resolve from titles and bodies | the reason, in one line |

An open PR naming this issue (`in-flight-<n>.json`) does **not** change the verdict — the
issue is `needed` and the PR is the plan in motion; the prose says `in flight: #N`.

`canonical` in the YAML is `#N` for the two `#N` verdicts and `null` otherwise. Never two
numbers: when two candidates compete, the verdict is `unclear` and the prose lists both.

## §3 The verdict guard — `id_verdict_guard`

The model may not invent numbers. `finalize` passes the judged verdict through the guard:
the whole string must be exactly `<verb> #<digits>` (a glob would let
`likely-duplicate-of #12 and #40` through and read the last number); a
`likely-duplicate-of` number must appear in `candidates_open`, an `already-fixed-by`
number in `candidates_shipped`; anything else — a foreign wording, a number that never
appeared in a search result — is downgraded to `unclear` with a `verdict_note` the comment
prints. `dedupe_skipped: 1` with a verdict other than `unclear` is downgraded the same way.

## §4 Goal alignment, priority, and effort (Phase 4)

**Goal.** Resolved in this order; the first that applies wins, and `goal.source` records
which:

1. `own-label` — the issue already carries a `goal:*` label. Keep it; propose nothing.
2. `reference` — a `facts.md` §1i reference names an issue in the goal registry. Propose
   stamping that label on this issue (the proposal lives in the comment; this skill applies
   no label but `triage:needs-decision`). Two references resolving to **different** goal
   labels → `goal: null`, `DECISION_REQUIRED=1`, reason `two goal epics referenced: #A
   (<label>) and #B (<label>)`.
3. `none` — no label, no resolving reference. `goal: null`, with the reason (`no
   reference`, or `#N referenced but carries no goal:* label`, or `goal registry empty`).

The current quarter is mechanical (`id_quarter`: `q<1-4>-<year>` from the UTC date), for
the priority table's "current-quarter" test: a goal label `goal:q3-2026` is current-quarter
when its suffix equals it, next-quarter when it is the quarter after, and past otherwise
(past goals align like `none` for priority, and the prose says the epic's quarter has
ended). Resolution runs in `finalize` against `goal-registry.tsv` — `goal_own_label`
first, else the first `goal_refs` entry found in the registry (`source: reference`, the
proposal being to stamp that label; this skill applies no label but
`triage:needs-decision`), else `null` with the reason (`no part-of/epic reference`,
`referenced issues carry no goal:* label`, `goal registry empty`). Two references
resolving to **different** labels → `null`, `decision_required`, reason naming both.

**Priority** — the design's table, applied to the class and the goal:

| Priority | Rule |
|---|---|
| `Urgent` | data exposure, cross-tenant leakage, auth bypass, sync stopped for a paying org, unusable app — or the issue carries the `Blocker` label |
| `High` | a `bug` with no workaround, or any issue whose goal is a current-quarter epic |
| `Medium` | a `bug` with a workaround, or an issue whose goal is a next-quarter epic |
| `Low` | an `idea` with no goal, or cosmetic |
| `none` | `noise` and `question` — nothing to rank until the decision lands |

"No workaround" is a claim the prose must support from the body (`workaround: none stated`
is acceptable when the body is silent, and the comment says so). The `Urgent` row's
conditions are each named in the prose when they fire.

**Effort** — the repo's `AGENTS.md` §"Issue Effort Selection" rubric, verbatim:

| Tier | Rubric |
|---|---|
| `medium` | Mechanical, tightly specified work: copy changes, renames, adding a field to an existing endpoint with regenerated types |
| `high` | Standard feature or fix with some ambiguity or cross-cutting reach: a new endpoint plus its frontend consumption, a non-trivial bug with a known repro |
| `xhigh` | New subsystem or tricky state: Temporal workflows, concurrency/retry/recovery logic, migration-heavy or webhook-ordering work |

`max` is reserved for the operator and is **never proposed**. `id_effort_guard` clamps any
`proposed_effort` outside the three tiers to `xhigh` with an `effort_note`, and reconciles
it with the issue's own block (`existing_effort`, `facts.md` §1b): `effort` in the YAML is
always the proposal; `effort_stance` is `propose` (no block), `agree`, or `disagree` — a
block that says `max` is a `disagree` line, nothing more, and the body is never edited.

## §5 The social rule

The issue's author decides its fate. When the author is not the user running the skill:

- the comment **never proposes close or park**, whatever the verdict — a
  `likely-duplicate-of` or `already-fixed-by` verdict is stated as a finding addressed to
  the author, and `needs_decision` is set so it reaches the decision view;
- a priority that differs from the board's `Priority` is phrased as a note **for the
  author**, never as something to change — and this skill changes no board field in any
  mode anyway;
- nothing else changes: classification, effort, and goal are proposals either way.

`finalize` derives `recommendation` and `priority_note` from `self_authored` (the state's
author equals the running user, and is non-empty), the guarded verdict, and the board's
`Priority`: a `likely-duplicate-of` / `already-fixed-by` verdict on your own issue reads
`close as a duplicate of #N` / `close — fixed by #N`; on another author's it reads
`for @author: … — your call`; a board Priority that differs from the proposal on another
author's issue reads `for @author: the table says X; the board says Y — left as is`.

An empty author (deleted account) is not self-authored, and is addressed as "the author
(account deleted)" rather than a dangling `@`. `recommendation` is the only place the word
"close" may appear in a comment, and only the self-authored branch writes it as an
instruction.

## §6 `needs_decision`

True when a human has to rule before the issue can move; it is also the only condition
under which the gate may add `triage:needs-decision`:

`needs_decision` is true when the guarded verdict is `unclear`, the class is `question`,
the judgement set `decision_required`, or a duplicate/fixed verdict landed on another
author's issue (their call).

A `noise` issue always lands here (its verdict is `unclear`), which is deliberate: this
version closes nothing, so even mechanical noise is a human's click, and the label is how
it reaches the board view.

## §7 Still-needed hook — not in this version

The design's Phase-1 still-needed check (pinned `git show`/`git grep` reads at `$DEV_SHA`,
claim extraction, a researcher brief — `pr-details/still-needed.md` §1–§4) slots in
**between §2 and §3**: it would turn a `needed` verdict into evidence that the problem
still reproduces at the pinned tip, and a base-branch fix that no PR named into
`already-fixed-by`. This version does not run it: the YAML has no key for it, and the
prose says `still-needed: not checked (v1)`. When it lands, extend `id_verdict_guard` with
the base-commit condition from `still-needed.md` §4 rather than loosening the two `#N`
checks.
