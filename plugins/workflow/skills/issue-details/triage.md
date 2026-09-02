# Triage — Phases 2–4

The judgement phases. The orchestrator applies each rule table below in order; the mechanical
blocks are the guards that keep a model's answer inside the closed vocabularies. Every block
is executed against fixtures by `plugins/workflow/tests/issue-details-triage.test.sh` —
the doc is the code under test; edit both together.

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
The mechanical noise check is `facts.md` §1h — it runs in Phase 1, **before** the searches,
and it is the only rule a model does not get to override: when `NOISE_SIGNAL` is set,
`CLASSIFICATION` is already `noise` by the time this table is read.

A `noise` classification skips dedupe (`facts.md` §1h) — the searches would cost two
bucket calls per issue for a verdict the class already settles — and the verdict is
`unclear` with reason `noise — dedupe not run`.

The classifier may also set `DECISION_REQUIRED=1` with a one-line reason when the issue
**itself** asks for a decision (a heading or sentence saying a design choice must be made
before work starts). That flag feeds §6; it never changes the class.

## §2 Dedupe is advisory, and names at most one canonical (Phase 3)

The candidate sets from `facts.md` §1h — open issues and PRs by title terms, open PRs naming
this issue, merged PRs since filing naming this issue — are **context**, not a verdict. The
orchestrator reads titles (and, for at most three, the bodies) and answers with exactly one
of the closed vocabulary:

| Verdict | Meaning | Requires |
|---|---|---|
| `needed` | no duplicate and no fixing PR found; the issue stands | a problem statement exists (`facts.md` §1a body non-empty), and the searches ran |
| `likely-duplicate-of #N` | #N is open and covers the same problem | #N appeared in `CANDIDATES_OPEN` |
| `already-fixed-by #N` | #N merged into the base branch after filing and names this issue | #N appeared in `CANDIDATES_SHIPPED` |
| `unclear` | searches skipped or degraded, no problem statement, several plausible canonicals, or a candidate the orchestrator cannot resolve from titles and bodies | the reason, in one line |

An open PR naming this issue (`in-flight-<n>.json`) does **not** change the verdict — the
issue is `needed` and the PR is the plan in motion; the prose says `in flight: #N`.

`canonical` in the YAML is `#N` for the two `#N` verdicts and `null` otherwise. Never two
numbers: when two candidates compete, the verdict is `unclear` and the prose lists both.

## §3 The verdict guard

The model may not invent numbers. Whatever it answered is passed through this block, which
downgrades anything outside the vocabulary — or naming a number that never appeared in a
search result — to `unclear` with a note the comment prints:

```bash
VERDICT_NOTE=""; CANONICAL="null"
# The whole string must be exactly `<verb> #<digits>` — a glob pattern would let
# `likely-duplicate-of #12 and #40` through and read the LAST number.
VD_VERB=$(printf '%s' "$VERDICT" | sed -nE 's/^(likely-duplicate-of|already-fixed-by) #[0-9]+$/\1/p')
VD_REF=$(printf '%s' "$VERDICT" | sed -nE 's/^(likely-duplicate-of|already-fixed-by) #([0-9]+)$/\2/p')
case "$VERDICT" in
  needed|unclear) ;;
  *)
    VD_SET=""; VD_WHERE=""
    if [ "$VD_VERB" = "likely-duplicate-of" ]; then
      VD_SET="$CANDIDATES_OPEN"; VD_WHERE="any open-issue or open-PR search result"
    elif [ "$VD_VERB" = "already-fixed-by" ]; then
      VD_SET="$CANDIDATES_SHIPPED"; VD_WHERE="the PRs merged into the base branch after filing that name this issue"
    else
      VERDICT_NOTE="'$VERDICT' is outside the verdict vocabulary; downgraded"; VERDICT="unclear"
    fi
    if [ -n "$VD_VERB" ]; then
      if jq -e --argjson n "$VD_REF" 'index($n) != null' <<<"$VD_SET" >/dev/null; then
        CANONICAL="#$VD_REF"
      else
        VERDICT_NOTE="#$VD_REF did not appear in $VD_WHERE; downgraded"; VERDICT="unclear"
      fi
    fi ;;
esac
```

## §4 Goal alignment, priority, and effort (Phase 4)

**Goal.** Resolved in this order; the first that applies wins, and `goal.source` records
which:

1. `own-label` — the issue already carries a `goal:*` label. Keep it; propose nothing.
2. `reference` — a `facts.md` §1f reference names an issue in the goal registry. Propose
   stamping that label on this issue (the proposal lives in the comment; this skill applies
   no label but `triage:needs-decision`). Two references resolving to **different** goal
   labels → `goal: null`, `DECISION_REQUIRED=1`, reason `two goal epics referenced: #A
   (<label>) and #B (<label>)`.
3. `none` — no label, no resolving reference. `goal: null`, with the reason (`no
   reference`, or `#N referenced but carries no goal:* label`, or `goal registry empty`).

The current quarter is mechanical, for the priority table's "current-quarter" test:

```bash
CUR_MONTH=$(date -u +%m); CUR_MONTH="${CUR_MONTH#0}"
CUR_QUARTER="q$(( (CUR_MONTH - 1) / 3 + 1 ))-$(date -u +%Y)"
```

A goal label `goal:q3-2026` is current-quarter when its suffix equals `CUR_QUARTER`,
next-quarter when it is the quarter after, and past otherwise (past goals align like
`none` for priority, and the prose says the epic's quarter has ended).

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

`max` is reserved for the operator and is **never proposed**. The guard clamps any answer
outside the three tiers, and reconciles it with the issue's own block (`facts.md` §1c),
which is reported beside the proposal and never overwritten:

```bash
EFFORT_NOTE=""
case "$PROPOSED_EFFORT" in
  medium|high|xhigh) ;;
  *) EFFORT_NOTE="proposed '$PROPOSED_EFFORT' is outside medium|high|xhigh (max is operator-only); clamped to xhigh"
     PROPOSED_EFFORT="xhigh" ;;
esac
if [ -n "${EXISTING_EFFORT:-}" ]; then
  if [ "$EXISTING_EFFORT" = "$PROPOSED_EFFORT" ]; then EFFORT_STANCE="agree"; else EFFORT_STANCE="disagree"; fi
else
  EFFORT_STANCE="propose"
fi
EFFORT="$PROPOSED_EFFORT"
```

`effort` in the YAML is always the proposal. The prose line reads `effort: xhigh —
proposed (no block on the issue)`, `… — agrees with the issue's block`, or `… — the issue's
block says high; left as is`. A block that says `max` is a `disagree` line, nothing more.

## §5 The social rule

The issue's author decides its fate. When the author is not the user running the skill:

- the comment **never proposes close or park**, whatever the verdict — a
  `likely-duplicate-of` or `already-fixed-by` verdict is stated as a finding addressed to
  the author, and `needs_decision` is set so it reaches the decision view;
- a priority that differs from the board's `Priority` is phrased as a note **for the
  author**, never as something to change — and this skill changes no board field in any
  mode anyway;
- nothing else changes: classification, effort, and goal are proposals either way.

```bash
if [ -n "${ISSUE_AUTHOR:-}" ] && [ "$ISSUE_AUTHOR" = "$ME" ]; then SELF_AUTHORED=1; else SELF_AUTHORED=0; fi
if [ -n "${ISSUE_AUTHOR:-}" ]; then AUTHOR_REF="@${ISSUE_AUTHOR}"; else AUTHOR_REF="the author (account deleted)"; fi
RECOMMENDATION=""; PRIORITY_NOTE=""
case "$VERDICT" in
  "likely-duplicate-of #"*)
    if [ "$SELF_AUTHORED" = 1 ]; then RECOMMENDATION="close as a duplicate of $CANONICAL"
    else RECOMMENDATION="for ${AUTHOR_REF}: this reads as a duplicate of $CANONICAL — your call"; fi ;;
  "already-fixed-by #"*)
    if [ "$SELF_AUTHORED" = 1 ]; then RECOMMENDATION="close — fixed by $CANONICAL"
    else RECOMMENDATION="for ${AUTHOR_REF}: $CANONICAL appears to have fixed this — your call"; fi ;;
esac
if [ "$SELF_AUTHORED" = 0 ] && [ "${BOARD_PRIORITY:-none}" != "none" ] && [ "$BOARD_PRIORITY" != "$PRIORITY" ]; then
  PRIORITY_NOTE="for ${AUTHOR_REF}: the table says $PRIORITY; the board says $BOARD_PRIORITY — left as is"
fi
```

An empty `ISSUE_AUTHOR` (deleted account) is not self-authored, and is addressed as "the
author (account deleted)" rather than a dangling `@`. `RECOMMENDATION` is the only
place the word "close" may appear in a comment, and only the self-authored branch writes it
as an instruction.

## §6 `needs_decision`

True when a human has to rule before the issue can move; it is also the only condition
under which the gate may add `triage:needs-decision`:

```bash
NEEDS_DECISION=false
if [ "$VERDICT" = "unclear" ]; then NEEDS_DECISION=true; fi
if [ "$CLASSIFICATION" = "question" ]; then NEEDS_DECISION=true; fi
if [ "${DECISION_REQUIRED:-0}" = 1 ]; then NEEDS_DECISION=true; fi
case "$VERDICT" in
  "likely-duplicate-of #"*|"already-fixed-by #"*)
    if [ "$SELF_AUTHORED" = 0 ]; then NEEDS_DECISION=true; fi ;;
esac
```

A `noise` issue always lands here (its verdict is `unclear`), which is deliberate: this
version closes nothing, so even mechanical noise is a human's click, and the label is how
it reaches the board view.

## §7 Still-needed hook — not in this version

The design's Phase-1 still-needed check (pinned `git show`/`git grep` reads at `$DEV_SHA`,
claim extraction, a researcher brief — `pr-details/still-needed.md` §1–§4) slots in
**between §2 and §3**: it would turn a `needed` verdict into evidence that the problem
still reproduces at the pinned tip, and a base-branch fix that no PR named into
`already-fixed-by`. This version does not run it: `STILL_NEEDED="not-run"`, the YAML has
no key for it, and the prose says `still-needed: not checked (v1)`. When it lands, extend
the vocabulary guard in §3 with the base-commit condition from `still-needed.md` §4 rather
than loosening the two `#N` checks here.
