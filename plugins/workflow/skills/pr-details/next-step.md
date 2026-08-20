# Next step — Phase 6

The decision table itself lives in `SKILL.md` §"Phase 6". This file defines the facts it reads,
why the rows sit in that order, how the ready predicate is built, and the regression the
ordering has to keep passing.

---

## §1 Fact definitions

| Fact | Definition |
|---|---|
| `CI_STATE` | `green\|red\|pending\|none\|partial-red` per `facts.md` §2a, with **absent required checks counted as pending** |
| `HUMAN_CR` | some `human/person` author's latest review is `CHANGES_REQUESTED` |
| `CODEX_CR` | the **Codex connector's** latest review is `CHANGES_REQUESTED` (`login startswith "chatgpt-codex-connector"`) |
| `BOT_CR` | any bot's latest review is `CHANGES_REQUESTED` — retained for reporting only; **no row keys on it** |
| `UNRES_H` | unresolved threads whose origin class is `human/person` |
| `UNRES_CODEX` | unresolved threads whose origin class is `codex-bot` |
| `UNRES_B` | unresolved threads whose origin is any bot **other than** `codex-bot` |
| `BEHIND` / `STRICT` | `behind_by > 0` / ruleset `strict_up_to_date` |
| `THREADS_REQ` | ruleset `threads_required` |
| `APPROVALS_GIVEN` / `APPROVALS_REQUIRED` | distinct latest-`APPROVED` authors excluding the PR author / ruleset `approvals_required` |
| `AUTO_PROMOTE` | `agent.auto_promote.enabled` read from `detent.yaml` **on the base branch**, default `false` |
| `REQ_LABEL` | the issue carries the auto-promote opt-out label; meaningful only when `AUTO_PROMOTE` |
| `AR_AT_HEAD` / `CS_AT_HEAD` / `E2E_AT_HEAD` / `RD_AT_HEAD` | prior-skill evidence (`facts.md` §2g) dated at or after `HEAD_SHA` |
| `DIFF_LINES` | `wc -l` of the cached `diff.patch` |
| `IS_DRAFT` | `pr.json .isDraft` |
| `BOARD_STATUS` / `BOARD_AMBIGUOUS` | least-advanced linked issue's board Status (`still-needed.md` §5) / several project items matched |
| `PLAN_COMBINED` / `PLAN_SPLIT` | `plan-check.md` §4, reduced across issues by worst verdict |
| `FACTS_INCOMPLETE` | any load-bearing fact is `unknown` (`facts.md` §0f) |
| `READY_VERIFIABLE` | §3 below |

## §2 Ordering rationale

The groups run cheapest-and-most-terminal first, then hard blockers, then spend.

1. **Terminal / unreadable (rows 1–3) before everything.** If the PR is finished, or the facts
   cannot be trusted, no other row's premise holds. Row 3 exists because a partially-fetched
   fact set can otherwise manufacture a green: `threads.unresolved: 0` from a failed query
   looks identical to genuinely zero.
2. **Board state (rows 4–6) before any review or plan spend.** A `Blocked` or `Backlog` issue
   is work the contract says not to do. Evaluating board state late means a `Blocked` issue
   with a 200-line diff and green CI reaches the review-spend rows and gets an expensive pass
   recommended on work that is explicitly parked. `Done`/`Cancelled` get their own row (4)
   rather than no row at all.
3. **Supersession (rows 7–8) before mechanical fixes.** No point rebasing a PR that should be
   closed. Both rows require *every* linked issue to qualify (`still-needed.md` §5).
4. **Mechanical blockers (rows 9–11) before draft.** A draft with merge conflicts, or a draft
   with red CI, must not be told "finish the draft" while the actual work goes unnamed. Draft
   is an annotation and a readiness prohibition, not a blocker in its own right; it drops to
   row 22, where it fires only if nothing else is wrong.
5. **Feedback (rows 12–14) before plan spend**, and Codex feedback keys on `CODEX_CR` /
   `UNRES_CODEX`, never on `BOT_CR`. Reading row 13 as "any bot requested changes" sends a
   sole CodeRabbit `CHANGES_REQUESTED` to `codex-ship`, contradicting the very next row. Row 13
   matches only the Codex connector; every other bot falls to row 14.
6. **Plan verdicts (rows 15–16) before waiting, UI, and review spend.** The plan verdict is
   already computed by the time the table runs, so acting on it costs nothing further, and a
   wrong plan invalidates the value of any review spend beneath it. Row 15 keys on the
   **combined** verdict, not "no from any model": under an any-model reading a single
   dissenting model fires the hard-blocker row and steals the split case from the row designed
   for it. A split routes to row 16 (`antagonist-review`) — the adjudicating skill — and does
   so *before* UI review, so the split verdict is never masked.
7. **Wait (row 17) after plan, before spend.** Waiting is the least actionable outcome, so it
   must not preempt anything actionable; but it must preempt spending tokens on a tree whose
   CI has not reported.
8. **Review spend (rows 18–21).** UI review is cheapest and most specific, then the cross-model
   ladder. Row 21 (Codex-clear but no second family) yields `antagonist-review` outright rather
   than "optional", which has no representation in a closed `next_step.id` vocabulary. Its
   optionality lives in
   `next_step.notes[] = ["second-family review is discretionary here — codex-ship was clean at head"]`.
9. **Draft (22), gate (23), approval (24), ready (25–29).** These are the promotion ladder, and
   they run last because each presupposes everything above is clean.

## §3 The ready predicate

Not a hand-written conjunction — a **ledger** built from the repo's own contract, with each
conjunct carrying a verifiability grade:

- **verified** — GitHub state proves it directly.
- **evidenced** — a GitHub artifact dated at or after `HEAD_SHA` asserts it (a comment, a
  label). Presence of evidence, not proof of the underlying run.
- **self-report** — nothing on GitHub can establish it; only a local run or a human can.

| # | Conjunct | Source | Grade |
|---|---|---|---|
| C1 | every required `(context, integration_id)` check is `pass` | ruleset + check matrix | verified |
| C2 | zero unresolved review threads (when `THREADS_REQ`) | ruleset + threads | verified |
| C3 | `behind_by == 0` (when `STRICT`) | ruleset + compare | verified |
| C4 | `APPROVALS_GIVEN >= APPROVALS_REQUIRED`; code-owner, last-push, and unattributed-changes approval requirements satisfied | ruleset + reviews + `mergeStateStatus` | verified |
| C5 | no outstanding `CHANGES_REQUESTED` | reviews | verified |
| C6 | `mergeable == MERGEABLE`, `mergeStateStatus ∉ {BLOCKED, DIRTY, BEHIND, DRAFT}`, `!IS_DRAFT` | PR record | verified |
| C7 | `rules.unknown[]` is empty (`rules.ignored[]` does not count — `facts.md` §0d) | ruleset | verified |
| C8 | the deploy-preview build is green on the PR head, where the contract calls a failed preview build a gate failure even without a required-check marker | check matrix | verified |
| C9 | an automated deep review ran at head and its findings were addressed (`WORKFLOW.md` gate; `detent.yaml gate.require_automated_review: true`) | `RD_AT_HEAD` | evidenced |
| C10 | E2E verification ran at head **when the change is user-facing / browser-affecting** | `E2E_AT_HEAD` + `ui.warranted` | evidenced |
| C11 | unresolved PR review comments re-checked | threads refreshed this run | verified |
| C12 | the issue workpad updated after the latest push, with changed files, checks, evidence, PR link, risk | workpad comment date vs `HEAD_SHA` date | evidenced |
| C13 | the repo's local gate passes at head (`detent.yaml gate.run`, e.g. `pnpm lint && pnpm test && pnpm build`) | — | **self-report** |
| C14 | backend schema/function validation accepted the change, when the relevant paths are touched | — | **self-report** |

C8–C14 are **read from the contract at run time, not hard-coded**: `gate.run` supplies C13's
command string, `require_automated_review` gates C9, and the `WORKFLOW.md` gate section
supplies C8/C10/C12/C14. A repo with no such contract drops them, and the rationale says so.

Then:

```
observably_false := { C in C1..C12 : C evaluates false on fetched GitHub state }
unverifiable     := { C in C13..C14 that apply to this change }

READY_VERIFIABLE := observably_false is empty
verdict          := "ready"                                  if unverifiable is empty
                 := "ready pending: " + names(unverifiable)  otherwise
```

- `observably_false` non-empty → **row 23 (`complete-gate`)**, not a ready row. A deep review
  that did not run at head and a stale workpad are *observably false* mandatory conjuncts, so
  the answer is "finish the pre-review gate", never "ready".
- `unverifiable` non-empty → the ready rows still fire, but the verdict is qualified. C13/C14
  are always unverifiable, so in practice a Detent-contract PR reports
  `ready pending: local gate (pnpm lint && pnpm test && pnpm build)` — and, when `convex/` is
  touched, `+ convex dev schema validation`. That is the honest answer, and more useful than a
  bare "ready" that quietly assumes an unrun gate.

**Board routing after the predicate.** Rows 25–29 exist because "ready" and "who acts next"
are different questions, and the answer depends on `AUTO_PROMOTE`:

- `Merging` → `hand-to-detent`: the merge lane runs the repo's ship skill, and `detent.yaml`
  caps `Merging` at 1.
- `Human Review` with `AUTO_PROMOTE == false` → **`human-approval`**. On the verified repo,
  `Human Review` sits in `observed_states`, not `active_states`, and `WORKFLOW.md` states
  plainly that every issue waits there for a human decision. Handing it to Detent would hand
  it to a daemon that will not pick it up.
- `Human Review` with `AUTO_PROMOTE == true` → `hand-to-detent`, unless `REQ_LABEL`, which is
  the opt-out and routes to `human-approval`.
- Active states → `move-to-human-review`, with the rationale naming the gate evidence that
  must be posted first.

## §4 Fact-vector regression

Each vector, and the row it must hit. Re-check this list after any change to the table.

| # | Fact vector | The failure being prevented | Row | Outcome |
|---|---|---|---|---|
| **F12** | ruleset requires `Lint, typecheck, test` + `Vercel`; the head SHA's checks contain only a successful `Lint, typecheck, test` | required set built from observations only → "all required pass" vacuously true → "ready" | **17** (`wait-ci`) | the required set is materialized first; `Vercel` is `missing` → `CI_STATE = pending`. C1 is false, so the ready rows cannot fire even if reached. Report names `Vercel — required, not reported on this SHA`. |
| **F13** | `approvals_required = 1`, 0 approvals, `reviewDecision = REVIEW_REQUIRED`, CI green, clean, board `Human Review`, small non-UI diff | no row tested approval sufficiency → "ready" | **24** (`human-approval`) | C4 false → `observably_false` non-empty. Row 23 is checked first, but C4 is a ruleset conjunct, so row 24's dedicated approval condition gives the specific action ("1 approval required, 0 given"). |
| **F14** | AR and Codex evidence at head, CI green, board `Human Review`, `RD_AT_HEAD == false`, workpad stale | "ready" — the contract gates were gathered but unused | **23** (`complete-gate`) | C9 and C12 observably false → rationale: "pre-review gate incomplete at `<sha>`: deep review not run at head; workpad last updated before the latest push". |
| **F15** | otherwise-ready facts, board `Human Review`, no `auto_promote` block in `detent.yaml` | "hand to Detent" — a daemon that will never promote it | **26** (`human-approval`) | `AUTO_PROMOTE=false` (read from base-branch `detent.yaml`, default false) → human approval, rationale quoting the contract: "there is no automatic promotion in this project". |
| **F16** | board `Blocked`, diff 200 lines, no AR/CS evidence, CI green | a review-spend row fired before any board row could stop the work | **5** (`blocked`) | board gates sit at rows 4–6, ahead of all spend. `Backlog` → row 6; `Done`/`Cancelled` → row 4. |
| **F17** | Fable `yes`, Codex `no` → combined `partial` + split; UI warranted; no E2E evidence | UI review fired before the split row; and an any-model reading of "no" fired the wrong row | **16** (`antagonist-review`) | row 15 keys on `PLAN_COMBINED == no` (combined, not any-model), so it does not fire; row 16 matches `PLAN_SPLIT` and sits above UI review at row 18. |
| **F18** | issue A already-fixed with high confidence; issue B still needed | a scalar `still_needed` could recommend closing the PR and "the issue" | **none of 7–8** | rows 7–8 require *every* linked issue to qualify. A mixture emits the split annotation and the table continues on B's facts. Board state = least advanced issue. |
| **F19** | sole CodeRabbit `CHANGES_REQUESTED`, no Codex thread | `BOT_CR` meaning "any bot" satisfied the Codex row → `codex-ship` | **14** (`address-review`) | row 13 keys on `CODEX_CR`/`UNRES_CODEX` only; `BOT_CR` is reporting-only and keys no row. |
| **F20a** | `isDraft = true` **and** `mergeable = CONFLICTING` | "finish the draft" masked the conflict | **9** (`rebase`) | draft demoted to row 22; annotation "draft — the blocker above outranks promoting it". |
| **F20b** | draft + red CI | same masking | **11** (`address-review`) | same mechanism. |
| **F20c** | draft + `PLAN_COMBINED == no` | same masking | **15** (`fix-plan`) | same mechanism. Draft also sets C6 false, so no ready row can fire while the PR is a draft. |
| **F21** | base branch has `deletion` and `non_fast_forward` rules alongside the modelled two | treating *every* unmodelled rule type as unknown makes `unknown[]` permanently non-empty, so C7 is always false and no ready row can ever fire | **unchanged** | branch-mutation rule types land in `rules.ignored[]`, not `unknown[]` (`facts.md` §0d). Verified: the reference repo's `dev` carries exactly these two. |
| **F22** | the issue's board row reads `Human Review`; the PR's own board row reads `Backlog` | reading the PR row as the issue's state fires row 6 (`no-active-issue`) and abandons the promotion ladder | **per issue row** | `BOARD_STATUS` comes from the **issue's** project item; the PR's row is printed once as an ignored line (`facts.md` §2f). Verified live on this repo. |
