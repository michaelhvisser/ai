# Executing the plan — Phase 8 detail

Phase 8 turns the execution plan into motion. Everything before the user's selection is
read-only; everything after it runs under the mode the user picked. This file defines the
approval boundary, the one question, the two executor modes, and the stop conditions that
bound local execution.

---

## §1 The approval boundary

The report and every phase before the gate mutate nothing — that contract is unchanged. The
gate asks **once** (missing intent, `lib/decision-gates.md`) and the user's selection is the
authorization for everything that mode does. Two consequences:

- **No selection, no mutation.** `--no-gate`, `--json`, a non-interactive run with no answer,
  or an answer of Stop all leave the world exactly as the report found it.
- **A selection authorizes the mode, not everything.** Local execution still stops at every
  human-owned step, still honors each dispatched sibling's own gates and prompts, and still
  ends at the stop conditions in §6. Approval is "complete the plan's agent-executable
  steps", never "do whatever it takes".

The question is skipped entirely when `queue[0]` is a `QUEUE_TERMINAL` id — the report
already says who owns the move — and when the plan contains no agent-executable step.

## §2 The one question

One structured question, at most four options, asked through the driver's structured-input
capability (or as concise text in the final response when the driver has none — the user's
answer resumes this same gate):

1. **Execute the plan locally** — this session drives every agent-executable step in order,
   following the same process the Detent lane would run, per §4. Offered whenever at least
   one plan step is agent-executable.
2. **Hand to Detent** — move the linked issue to the contract lane and let the daemon drive
   the same plan, per §3. Offered only when the repo has a Detent contract (`detent.yaml`
   present on the base branch), the issue has an unambiguous board item, and the daemon
   would actually pick it up (`Rework` and `Merging` in `active_states`).
3. **First step only** — run just step 1 (dispatch its skill, or perform its recipe when it
   is agent-executable per §5), then re-run the fact phases and re-report. The classic
   one-step green light.
4. **Stop** — the report and the plan stand as printed; the recipes are in the plan for
   driving by hand.

Never present an option that cannot actually run: local execution needs at least one
executable step; the Detent option needs the contract facts above; a step whose mapped skill
is not invocable in this session (installed and model-invocable) is executed from its recipe
or, failing that, named as the reason the option is absent.

## §3 Hand to Detent

The handoff is one mutation: set the linked issue's board Status to the lane the plan calls
for, chosen from the contract, not hard-coded:

- Work remains in the plan (any fix, review, gate, or rebase step) → the contract's rework
  lane (`Rework` on the reference board).
- The plan is only promotion (`READY_VERIFIABLE`, verdict `ready` or `ready pending`) → the
  contract's merge lane (`Merging`), respecting its capacity note (`detent.yaml` caps
  `Merging` at 1 on the reference repo — when the lane is full, say so and stop instead of
  queueing a second item).

`pr_facts_board` already returned `item_id`, `project_id`, and the project **number** for the
issue's item; the Status field and option ids come from one lookup (verified live):

```bash
gh project field-list "$PROJ_NUM" --owner "$OWNER" --format json \
  --jq '.fields[] | select(.name=="Status") | {id, options: [.options[] | {id, name}]}'
gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
  --field-id "$FIELD_ID" --single-select-option-id "$OPT_ID"
```

After the move, verify it took (`pr_facts_board` again), print the lane and the daemon's
expected pickup, and stop — the plan now belongs to the daemon. Never also execute steps
locally after a handoff; two executors on one PR is the conflict Detent's lane caps exist to
prevent.

## §4 Local execution

Local mode is the Detent process run in this session: the same steps, the same contract
gates, the same evidence — with the user's own tools and the sibling skills doing the work.

**Bind to the PR's checkout first.** The report runs from any checkout — another branch,
detached HEAD, a dirty tree — but every dispatchable skill can reach a fixer that commits
and pushes from the ambient directory (`codex-ship` invokes `address-review`;
`antagonist-review` dispatches its own fixer), so code-mutating steps (rebase, fixes, the
contract gate) require a clean checkout at the PR head. When the ambient checkout is not
that, do not improvise in place: dispatch `/workflow:create-worktree <PR>` (review mode) and
run every subsequent step from the worktree it names. A dirty checkout at the right commit
stops with the dirt named — never stash it (`git stash` is shared, mutating state this skill
does not own).

**The loop.** Execute the plan's steps in order, but re-derive reality between every step —
the projection is a forecast, not a fact:

```
approved := the set of step ids in the printed plan
steps_run := 0
repeat:
    re-run the fact phases (--no-plan-check equivalent), carrying the original
      plan verdict (PLAN_COMBINED / PLAN_SPLIT from this run's facts.json) while
      the diff is materially unchanged; a fixer-changed diff drops the carry
    head := the fresh decision-table headline
    if head.id is QUEUE_TERMINAL or human-owned: stop — report what remains
    if head.id not in approved: stop — the plan no longer fits; re-ask (§6)
    if steps_run >= 8: stop — fuse (§6)
    execute head per §5;  steps_run += 1
    if execution failed or made no progress (§6): stop
```

The re-derivation is what makes interleaved `wait-ci` safe: every push projects CI to
pending, the loop watches it (`gh pr checks <n> -R <host>/<slug> --watch`, repo-qualified,
after polling the registration window — a freshly pushed head briefly reports *no checks*),
and a red landing routes to `address-review`, which is in the approved vocabulary whenever
the plan contained any push-projecting step.

**Every sibling dispatch passes the full PR URL, never a bare number.** Siblings resolve
their repository from the ambient checkout (`codex-ship` via `gh repo view`,
`antagonist-review` via unqualified `gh pr` calls), and a fork checkout can carry a
same-numbered PR — a bare number there addresses the wrong pull request; the URL pins host,
owner, and repo (`facts.md` §0a). A sibling that cannot accept a URL is dispatchable only
when the ambient checkout's repository **is** the resolved base repository. Every direct
`gh` call in the loop is repo-qualified (`-R <host>/<slug>`) for the same reason.

## §5 How each step executes locally

Dispatchable ids invoke their mapped skill exactly as the user would have —
`codex-ship` → `/workflow:codex-ship`, `antagonist-review` → `/workflow:antagonist-review`,
`address-review` → the language plugin's `address-review`, `ui-review` → the language
plugin's E2E verification skill (in `ts-workflow` that is `e2e-verify`; there is no skill
literally named `ui-review`) — every gate and prompt inside the sibling still applies.
Dispatchability is checked, not assumed: the mapped skill must be installed AND
model-invocable in this session. A
mapped skill that is not invocable here (a `disable-model-invocation` target) falls back to
the step's own recipe when one is mechanical, else stops with the exact slash command for
the user to type.

The recipe-owned ids are agent-executable in local mode — this is the sanctioned extension
beyond the old single-step gate, and each one is the `next-step.md` §6 recipe performed by
the orchestrator:

| id | executed as |
|---|---|
| `rebase` | the §6 recipe verbatim: fetch base, rebase, push with the lease pinned to the observed head SHA; a lease rejection or a conflict stops the loop (conflicts hand to `/workflow:resolve-conflicts` with the user, never auto-resolved). When no configured remote points at the head repository — the usual case for a fork checked out via `refs/pull/*` — the step is not executable: stop with the recipe |
| `wait-ci` | watch checks to completion, registration window first |
| `complete-gate` | run the contract gate (`gate.run`) at the head commit from the bound checkout; on green, post the evidence the contract names — workpad update, review comment, label. A red gate run routes to the fix step, not to a retry |
| `finish-draft` | `gh pr ready <n> -R <host>/<slug>` |
| `fix-plan` | apply the plan check's proposed issue edits — only when Phase 4 produced concrete replacement text this run; edit the issue body's Plan section to it and say so on the issue. No concrete text → stop and ask; the orchestrator never authors a plan itself |
| `move-to-human-review` | post the gate evidence, then the §3 board-move recipe with the `Human Review` option id |

`human-approval`, `hand-to-detent`, and every other `QUEUE_TERMINAL` id are never executed
locally — reaching one ends the loop with the report. Merge itself is always outside this
skill: local execution delivers a PR that is ready, and stops.

## §6 Stop conditions — the fuse

Local execution stops, with a fresh report of what happened and what remains, on the first
of:

- a `QUEUE_TERMINAL` or human-owned headline — the normal, successful exit;
- a headline whose id the approved plan never contained — the situation changed under the
  run (a human pushed, a review landed); re-ask rather than stretch the old approval;
- **no progress**: the same step id fires twice in a row with no new head SHA and no fact
  changed between them — executing it again would loop, exactly the churn Detent's fuses
  trip on;
- a step's execution fails (a lease rejection, a conflict, a sibling skill's own stop, a red
  contract gate after its fix step already ran this loop);
- the step budget (8 executions) — a plan needing more than that is not one approval's worth
  of work.

The completion criterion for a local run is therefore checkable: either the fresh headline is
`human-approval` / another terminal id with the ready ledger printed, or the stop names the
exact step that ended the loop and why. "Ran out of turns quietly" is not an outcome.
