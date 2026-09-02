# Issue Intake Pipeline

Research and design, 2026-09-01; revised 2026-09-02 after a Codex review and an independent Fable review (see the last two sections). For Michael and Cory. Repo getparable/parable, board project 1.

How to take an issue from filed to merged on staging with no human in the loop except where a human is actually the decision, without two people clobbering each other, and without the queue rotting. Built on what OpenClaw learned at a thousand items a day, sized for a two-person team at ten.

## The answer

Build two skills on the pieces you already own, and fix the intake leak first.

1. **Fix the leak.** The 513-issue flood on 24 Aug was Detent's own Monday `stale-todos` scan walking the untracked `.next/` build output. Scope that scan to tracked source before anything else. The biggest noise source is the fleet, not the humans.
2. **`/issue-details`.** The issue-side twin of `/pr-details`: classify, dedupe, check the problem still exists on `dev`, score against quarter goals, propose priority and effort, research and write the plan into the issue, have a second model attack the plan, then one approval gate that hands it to Detent.
3. **`/triage-queue`.** The batch sweep over Backlog and stale Todo: cluster duplicates, propose closes from an enumerated reason list with evidence gates, re-rank against goals, and leave one edited-in-place decision comment per issue. Proposes by default. Applies only mechanical reasons, and only after a three-day silent-consent window.
4. **Extract, don't copy.** The supersession sweep, the pinned-read still-needed check, the verdict vocabulary, and the board hand-off in `pr-details` 0.5.0 (merged, PR #15) become a shared library both skills and the PR skill import.
5. **Prioritise through a goal tag on the epic.** Label the quarter-goal epics, link issues as native sub-issues, and score alignment by parent chain. The board already exposes Parent issue, Cory can see it, Detent can read it.

Steal from OpenClaw the discipline, not the throughput machinery: propose and apply as separate steps that re-read live state before every write; the model never holds a write token; inactivity never closes a bug; every close reason is enumerated with its own evidence gate; one comment per item, edited in place. Skip their 128-worker scheduler, their 353 labels, and the lanes they later deleted for having zero successful runs.

## Where the queue is today

Live survey, 2026-09-01. The one-day flood is excluded from the rate figures.

| Measure | Value |
|---|---|
| Open issues | 300 |
| Untouched 30+ days | 142 |
| Filed in the last 7 days | 49 |
| Filed by the two of you | ~10/day, peaks in the mid-20s |
| Open PRs | 26 (24 Michael, 2 Cory) |
| Merge lanes | 1 (`Merging: 1`) plus a host-wide gate lock |

**The 24 August flood was self-inflicted.** 513 issues were filed at 11:20Z under Cory's token, every one labelled `maintenance` and carrying a `<!-- detent-intake:… -->` fingerprint. That is the `weekly-todos` source in `detent.yaml` (`cron: "0 6 * * 1"`, `scan: stale-todos`). Titles like `TODO in apps/frontend/.next/dev/server/chunks/ssr/…mermaid_core….js:2812` show it walked gitignored build output. 492 were closed as not-planned by hand five hours later. The scanner has no visible include or exclude scope in the config, so this is a Detent-side fix: scan tracked files only, or disable the source until it can be scoped.

### What already exists, and what it does not do

| Piece | What it does | Gap |
|---|---|---|
| `detent.yaml backlog_admission` | Every 15 min, scores Backlog issues against the Admission Criteria in `WORKFLOW.md`; auto-admits to Todo at 0.9 confidence, max 3 proposals a run, 10 open. | Judges readiness only. No dedupe, no goal alignment, no still-needed check against `dev`, never closes anything. |
| `WORKFLOW.md` Admission Criteria | Alignment, Readiness, Size, Safety Gates. One in-repo text Detent and humans both read. | No prioritisation rubric next to it. |
| `/pr-details` 0.5.0 | PR-anchored situation report: pinned-read still-needed check per linked issue, supersession sweep over merged PRs and backlog, closed verdict vocabulary, 30-row decision table, approval gate with a "hand to Detent" board move, 8-step fuse. | Anchored on a PR. Everything from Phase 1 onward is reusable for an issue once the anchor is swapped. |
| `/triage-slack` | Slack message to researched issue; files through a deterministic script that refuses Todo without confirmation and refuses to run under 1000 GraphQL calls remaining. | Slack only. But its filer script is the "deterministic apply, model has no token" shape the new skills should share. |
| Board (project 1) | Status: Backlog, Todo, In Progress, Blocked, Human Review, Rework, Merging, Done, Cancelled. Priority: Urgent, High, Medium, Low, No priority. Parent issue, Sub-issues progress, Milestone fields present. | No Effort field. Effort lives in the `detent-agent` body block. |
| Routing labels | `detent:cory`, `detent:mac-mini-1`, `detent:local`. Exclude-only on the Air; fails open when unlabelled. | Assigned by hand at pickup, which is how two hosts collide. Should be assigned at triage. |
| Issue templates, issue-triggered Actions | None. | Nothing enforces the body shape the admission scanner needs. |
| Goal cascade | `~/Development/michaelhvisser/goals/GOALS.md`: Someday, Year, Quarter (Q3 ends 30 Sept), Month, Week. Read by `/today`. | Private and off-repo. Neither Cory's host nor Detent can read it. |

## What OpenClaw actually does

Volume is real: 441 issues and 433 PRs opened on the peak day in February 2026; still 244 issues and 665 PRs on 2026-08-31. Three layered bots, with the intelligence in a separate repo so the model never runs with write credentials against the main one.

- **Barnacle** (deterministic, in-repo). Runs on every issue and PR event. Canned label-to-comment-to-close rules (`r: support`, `r: no-ci-pr`, `r: too-many-prs` with a 20-open-PR cap per author). Structural checks produce *candidate* labels; the close fires only when a human re-applies the label. `bad-barnacle` switches it off per item.
- **ClawSweeper** (Codex, out-of-repo). Every event forwarded as `repository_dispatch` with a sha256 ingress fingerprint of head, body and label so stale reviews are dropped. Lanes: *review* writes one report per item with a snapshot hash; *apply* wakes every 15 minutes and closes only unchanged high-confidence proposals, capped at 20 closes per token lifetime; *repair* is maintainer-command-gated autofix and automerge. One marker-backed comment per item, edited in place, with hidden verdict markers.
- **Clownfish.** Bulk cluster resolver fed by an offline embedding crawl. 4,178 clusters by June; 65% clean, 28% needs-human, 72 closes. Its fix lane attempted 316 automatic fixes and executed 2.

Rules worth keeping:

- Close reasons are an enumerated list, each with an evidence gate and age floor. "A main commit alone is never sufficient to propose `implemented_on_main`. Require a GitHub-verified, merged fixing PR." Stale needs 60 days and no human comment.
- Inactivity never closes a bug. `bug` and `enhancement` are exempt from the stale bot; a stale bug triggers a verification review, and a self-audit fails the workflow if a bot closes a bug as not-planned.
- Dedupe is advisory context, never a verdict: explicit links, closing-PR references, title-term search, optional embedding clusters, fed into a prompt that still requires a canonical-search pass and names at most one canonical.
- Bulk filers are flagged (`clawsweeper:bulk-filed`) and routed away from automated fix dispatch.
- Auto-implementation is strict-bug only, must establish a failing regression first, never automerges, and re-fetches the branch head 90 seconds before pushing.
- Rate limits are the ceiling. They cut the review feed from 600 to 450 items an hour when the shared App token hit 403s.

What they turned off: the commit-review lane (zero successes in its last 20 runs), the crawl-remote deployment system (three runs ever), the proof-nudge lane, the Claude CLI runtime. The one-time purge closed about 4,000 issues in a day; steady state afterward proposed 4 closes out of 3,478 reviewed in a week. Expect the same shape: one big sweep, then a trickle.

Elsewhere: Anthropic's claude-code repo comments a duplicate candidate, waits three days, closes only if no comments follow and the author did not thumbs-down. GitHub Agentic Workflows "safe outputs": the agent runs read-only and emits structured requests; a separate job with write permission applies them under per-type caps.

## The pipeline

Stages 0 to 4 and 7 are new; 5 and 6 exist.

0. **Intake shape** (templates, `detent.yaml`). Issue templates for bug, goal work, and idea, each pre-filling Summary, Evidence, Impact, Proposed fix, Verification, and the `detent-agent` block. `stale-todos` scoped to tracked files. Bulk-filer guard: more than 25 issues from one author in an hour parks the batch in Backlog with `triage:bulk`.
1. **Triage** (`/issue-details` Phases 1 to 3, propose-only). Classify (bug, goal, idea, question, noise). Dedupe against open issues, open PRs, merged PRs since filing. Still-needed check with pinned reads at the `dev` tip. Goal alignment via parent epic. Proposed Priority, effort tier, routing label. Conflict check against every open PR's touched paths and every In Progress issue's plan.
2. **Research and plan** (Phase 4). One read-only Explore subagent pinned to the same commit writes the plan: implicated `file:line`, files the fix will touch, acceptance criteria checkable by `make check`, verification recipe, effort tier from the AGENTS.md rubric. Written into the issue body under `## Plan`, which the Detent lane and the admission scanner already read.
3. **Plan review by a different model** (Phase 5). The `antagonist-review` pattern applied to the plan: Codex attacks it, a third model breaks ties, at most two revise loops. Anything needing a product decision stops here with a decision packet.
4. **Hand-off gate** (Phase 6). One question: admit to Todo with Priority, epic, routing label set; leave in Backlog for the scanner; park; close with a named reason; stop. Board writes go through one deterministic script that refetches the item and aborts if it changed.
5. **Implement** (Detent lanes). Claims from Todo (2 lanes), Codex at the issue's effort tier, opens the PR, UI changes to Human Review. `/pr-details` is the PR-side check-in; `/codex-ship` hardens.
6. **Merge to staging** (Detent merge lane). `make check` under the gate lock, Full CI, automated review, squash to `dev`, Railway deploys staging. Serial by design.
7. **Sweep** (`/triage-queue`, local launchd on the Air, hourly). After each merge, re-checks open issues referencing the merged PR's paths for already-fixed. Weekly, walks Backlog and stale Todo: clusters duplicates, re-ranks against goals, proposes closes and parks. One decision comment per issue, edited in place. Sends a notification only when something needs Michael: a short email listing new decision packets, stuck Detent items (Blocked, Rework over the limit, Human Review waiting), and any close it applied. Quiet runs send nothing. The morning `/today` digest carries the same list as a backstop.

### Converting `pr-details`

Do not fork it. Split into anchor-specific and shared halves; move the shared half into a library directory in the workflow plugin and import from three places.

| pr-details file | Shared or anchored | Reuse |
|---|---|---|
| `facts.md` §0 preflight | Shared | Unchanged. |
| `facts.md` §1e supersession sweep | Shared | Window starts at the issue's `createdAt` instead of the merge base. Keep `SHIPPED_TRUNCATED`. |
| `still-needed.md` | Shared | Pinned reads, claim extraction, researcher brief, verdict vocabulary apply as-is to one issue. |
| `plan-check.md` | Shared | Becomes stage 3, plus the antagonist loop. |
| `next-step.md` | Anchored | New ~12-row table: noise, duplicate, superseded, already-fixed, needs-decision, not-ready, ready-admit, conflicts-with, ui-park, stop. |
| `execute.md` §3 hand to Detent, §6 fuse | Shared | Add Priority, epic, routing label writes to the same script. |
| `screenshots.md`, §2 status snapshot | Anchored | Not needed. |

The live test `pr-details-supersession-sweep.test.sh` treats the doc as the code under test. Keep that pattern for the library.

## Triage rules

Belong in `WORKFLOW.md` as `## Prioritisation Criteria` next to Admission Criteria, so Detent's scanner, the skills, and a human read one text.

**Classification.** An item is a `bug` only when it reports broken existing behaviour and the expected behaviour is already defined by docs, tests, the API contract, or established behaviour. A request for a new capability is a `goal` item if it hangs off a goal-tagged epic and an `idea` if it does not. Anything needing a product decision is neither until you rule.

**Priority.**

| Board Priority | Rule | Queue behaviour |
|---|---|---|
| Urgent | Data exposure, cross-tenant leakage, auth bypass, sync stopped for a paying org, unusable app. Or label `Blocker`. | Admit immediately, routed to whichever host is idle. |
| High | A `bug` with no workaround, or any child of a current-quarter goal epic. | Admit when the plan passes review. Bugs before goal work at equal priority. |
| Medium | A `bug` with a workaround; child of a next-quarter goal epic. | Admit only when Todo has fewer than 4 items. |
| Low | An `idea` with no goal parent. Cosmetic. | Stays in Backlog. Never auto-admitted. Weekly sweep decides park or close. |

**Goal projection.** Label each quarter-goal epic `goal:q3-2026` (one label per quarter). Issues attach as native sub-issues. The skill walks `issue.parent` up to two levels and scores alignment by the first goal-labelled ancestor, recording which one. An unparented issue that reads as goal work gets a proposed "adopt into epic #N" in its triage comment. The "This quarter" section of GOALS.md lists the epic numbers so `/today` and the sweep agree.

**Close reasons.** The model may only propose from this list. Each has a mechanical evidence gate the apply script checks itself.

| Reason | Evidence gate | Apply |
|---|---|---|
| `already-fixed-by #PR` | A PR merged to `dev` after the issue's `createdAt` that references the issue in `closingIssuesReferences` or touches the implicated paths, and a pinned read at the `dev` tip shows the claimed behaviour is gone. | 3-day grace comment, then close if no reply and no thumbs-down from the author. |
| `duplicate-of #N` | #N open and further along, or closed as completed. One canonical only. Close comment links the satellite's unique evidence into the canonical. | 3-day grace. |
| `superseded-by #N` | #N shipped or In Progress or later. A bare Backlog idea never supersedes. | Decision packet. |
| `generated-noise` | Author filed >25 issues in the hour; body carries an intake fingerprint; path under build output, `node_modules`, or `_generated`. | Immediate, batch listed in one comment. |
| `out-of-scope` | Fails Admission Alignment. | Decision packet. |
| `stale-idea` | `idea`, no goal parent, untouched 90 days, no reactions, no comments from anyone but the author. | Park first (`parked` label + comment). Close 30 days after parking if still silent. |
| `needs-verification` | A `bug` untouched 60 days. Not a close reason. | Immediate re-review, never a close. |

Absolute: a bug is never closed for inactivity; an issue with an open PR referencing it in closing syntax stays open until that PR merges or closes. The apply script fails closed on any GitHub read error.

**Decision packets.** One comment with a hidden marker, the exact question, options, recommendation, evidence; label `triage:needs-decision`. The morning digest lists them. You answer in the thread; the next sweep reads your comment as an authoritative routing instruction.

## Parallel without clobbering

Parallelism lives in research and implementation, not in merging. The merge lane is serial and the gate lock serialises `make check` per host.

- **Route at triage, not at pickup.** The triage skill sets exactly one of `detent:cory`, `detent:mac-mini-1`, `detent:local`, or none (Air default) when it admits.
- **File overlap becomes a native dependency.** Every plan lists the files it will touch. On overlap with an open PR or an In Progress or Todo plan, set GitHub `blocked_by` on the later issue and move it to Blocked; Detent's `dependency_auto_unblock` returns it to Todo when the blocker merges. Migration-carrying issues always serialise.
- **One writer for the board.** The scheduled sweep runs locally on the Air as a launchd agent, gated on the same Detent schedule-ownership lease that already gates `backlog_admission`, so the fleet has one board writer. A human running `/issue-details` locally writes only to the issue in hand.
- **Snapshot before write.** Record `updatedAt` at read, refetch immediately before writing, abort on change.
- **Humans keep a one-click veto.** Thumbs-down on the grace comment, a reply, or the `detent:local` label stops any automated action.
- **Budget the API.** Tonight's survey alone exhausted the shared 5,000-call hour twice. Read the whole board in one paginated query into a cache file, walk from the cache, refuse to start under a 1,000-call reserve. All of a user's tokens share one quota, so a cloud routine on your account does not buy a second budget; a dedicated bot account or GitHub App does.

**Throughput to expect.** Full CI ~10 minutes, gate lock up to 2 hours, one Merging lane: a ceiling in the low tens of merges a day across the fleet, fewer on migration days. Watch merge-lane queue depth, not agent count.

## Rollout and gates

| Phase | Build | Run against | Gate to next |
|---|---|---|---|
| A, this week | Scope `stale-todos`. Issue templates. Extract the shared library from `pr-details` 0.5.0. `/issue-details` propose-only. Label the Q3 epics. | The 49 issues filed in the last 7 days. | You accept the proposed priority and plan on 8 of 10 without editing. |
| B, next week | `/triage-queue` report-only. Apply script exists, invoked by hand with an approved list. | The 142 issues untouched 30+ days. | Under 10% of proposed closes rejected across two sweeps. |
| C | Install the launchd sweep with notification-on-change. Enable 3-day grace auto-apply for `already-fixed-by` and `duplicate-of` only. Wire the digest into `/today`. | Steady state. | Two weeks with no reverted close. |
| D | Auto-plan: `bug` or goal-child issues run stages 1 to 3 unattended and admit themselves on a passed plan review. Ideas still wait. | New issues only. | Detent no-progress fuse trips on auto-planned issues no higher than hand-planned. |

Metrics: issues filed per day by human and by intake source; admitted per day and median Backlog age; closes proposed, accepted, rejected, reverted; merges per day and merge-lane depth at 09:00; fuse trips per admitted issue; GitHub API calls per hour by skill.

## Decisions for Michael

1. Goal tag on the epic (recommended) versus milestones.
2. Sweep runs locally on the Air (decided 2026-09-01): launchd agent invoking `claude -p`, same pattern as the dev-tidy agent in michaelhvisser/config. Local has Codex, a real `git fetch`, and the `gh` auth the other skills already use. Cloud was rejected: checkout freshness unclear, no Codex, and it would share the same GitHub API quota anyway.
3. Whether `stale-todos` survives at all. If it cannot be scoped, turn it off; the weekly `repository-maintenance` routine already files scoped findings.

## Sources

- OpenClaw workflows: `auto-response.yml`, `clawsweeper-dispatch.yml`, `stale.yml`, `duplicate-after-merge.yml`, `scripts/github/barnacle-auto-response.mjs` (github.com/openclaw/openclaw, fetched 2026-09-02).
- ClawSweeper README, `prompts/review-item.md`, `docs/related-issue-discovery.md`, CHANGELOG.md (github.com/openclaw/clawsweeper). Clownfish and gitcrawl repos.
- Volume: GitHub search `created:2026-02-01` and `created:2026-08-31`; greptile.com/blog/prs-on-openclaw; openclaw issues #69167, #38283.
- Steinberger on X 2026-02-15, 2026-04-25, 2026-05-03. GitHub blog maintainer interview 2026-08-27.
- Anthropic claude-code `.github/workflows` and `scripts/auto-close-duplicates.ts`. GitHub Agentic Workflows safe-outputs. Sentry Seer docs. steipete/agent-scripts `github-project-triage`.
- Local: `detent.yaml`, `detent.local.yaml`, `WORKFLOW.md`, `AGENTS.md`, the `workflow` 0.5.0 and `slack-triage` plugins in michaelhvisser/ai, live `gh` queries 2026-09-01.

## Revisions after the Codex second opinion (2026-09-02)

Codex (session 01a05f9e) reviewed this document against `detent.yaml`, `WORKFLOW.md`, and `AGENTS.md`. Verdict: "Do not build this as written: the triage ideas are useful, but the current design automates closure and coordination before it has a trustworthy authority, concurrency, and failure-recovery model." Accepted changes, in the order they change the build:

1. **Disable `weekly-todos` now, prove the flood later.** The marker, label, timing, and config match is strong but not proof at the version deployed on 24 Aug. Disable the source before re-enabling it with tracked-files-only input, a dry-run fixture containing `.next/`, and a per-run cap. The `intake` source has no `max_findings_per_run` today; fingerprint dedupe does nothing against hundreds of unique paths.
2. **One admission authority.** `backlog_admission` reads only the section named `criteria_section: Admission Criteria`, so a separate "Prioritisation Criteria" section is invisible to Detent. Worse, writing a polished plan into the issue body makes it pass Readiness and Detent can admit it to Todo at 0.9 before plan review or the hand-off gate finishes. Fix: until approval, the plan lives in the marker comment, not the body; the hand-off gate writes body and Todo in one step. Then choose one owner of Backlog to Todo: either `auto_admit: false` with the triage actor owning the move, or admission restricted to issues carrying an approved `triage:ready` result. Never three classifiers of readiness.
3. **One evaluator, two interfaces.** `/issue-details` evaluates one issue; `/triage-queue` is a thin batch wrapper over the same evaluator and the same deterministic apply script. Not two skills.
4. **No silent consent for semantic closes.** Grace-period auto-close survives only for predicates a script proves completely: `generated-noise` under a capped scanner, and `already-fixed-by` where the merged PR names the issue in `closingIssuesReferences` (GitHub would have closed it on a merge to the default branch; `dev` is not the default). `duplicate-of`, `superseded-by`, and path-overlap already-fixed are proposal-only until an authorised maintainer applies a machine-readable approval. Split `out-of-scope` into `agent-ineligible` (needs a human lane) and `out-of-product-scope` (close). Add human-only reason codes: works-as-designed, question, withdrawn, cannot-reproduce, malformed.
5. **Decision packets get a contract.** Authorised responders are OWNER and MEMBER, matching `backlog_admission.authors`. Replies use `/triage <verb> [#N]`; free prose is not a routing instruction. Packets expire after 14 days into Backlog, and conflicting answers escalate rather than last-writer-wins.
6. **Goal alignment is frozen at triage.** Keep the epic tag (Michael's call), but the evaluator copies the resolved `goal:*` label onto the issue when it triages, so reparenting or relabelling an epic later does not silently reprioritise history. Two goal-labelled ancestors is a decision packet, not "first wins". The list of active goal epics lives in the repo (`WORKFLOW.md`), not in the private cascade.
7. **There is no single board writer.** The schedule-ownership lease gates only the three cron loops; Detent workers, auto-unblock, and humans all write. So: full-state fingerprints (issue `updatedAt` plus project-item `updatedAt` plus labels, since project field edits do not bump the issue), per-run journal with idempotency keys, and reconcile after write. File overlap becomes advisory in the triage comment; only migrations and proven dependencies get `blocked_by`. Routing labels at triage express affinity only where it matters (UI work to the host with browser tooling); everything else stays unlabelled and the Air default carries it.
8. **Scheduler moves to the always-on host.** A sleeping laptop is not a control plane. Run the sweep on mac-mini-1 (always on, has Codex), two to four times a day rather than hourly, with a non-overlap lock, a durable run ID, a last-success heartbeat, and an alert on missed success. Notify-on-change alone cannot tell a quiet queue from a crashed sweep.
9. **Gates get denominators.** Each phase gate needs a stratified sample across bug, goal, idea, and legacy issues, a minimum count before progression, per-reason precision, and a documented kill switch. Semantic close proposals target near-zero false positives, not "under 10%". Phase D uses first-turn Blocked rate, material plan amendments, and rework rate normalised by effort tier, not raw fuse trips.
10. **Trust boundary.** Issue bodies and comments are untrusted input. The apply script validates a narrow schema, allowed actors, and allowed transitions independently of whatever the model emitted. An unattended planner never assigns effort `max`; malformed effort blocks are rejected, not defaulted.
11. **Tier the plan review by effort.** Deterministic checks for `medium`, one independent review for `high`, the full antagonist loop only for `xhigh`.
12. **Do not refactor `pr-details` in Phase A.** Prove the evaluator standalone, then extract the shared primitives once they are stable.
13. **One notification path.** The sweep email. Drop the separate after-merge sweep and the `/today` duplicate until the sweep has a track record.
14. **Backpressure.** Admission to Todo across all priorities is capped by merge-lane depth, not only for Medium.

Not accepted: milestones over the epic tag (Michael's decision; mitigated by item 6), and cloud scheduling (Michael's decision; item 8 moves it to the always-on host instead). Flagged for Michael, outside this design: `WORKFLOW.md` §Isolation Contract still names one implementation lane as the safe baseline while `detent.yaml` sets `Todo: 2` and `In Progress: 2`.

Revised MVP: disable `weekly-todos`; report-only evaluator with the single-issue interface; admission gating so Detent cannot admit around the gate. Nothing closes automatically until Phase C, and then only the two script-provable reasons.

## Second review by an independent Fable agent (2026-09-02)

Brief: adjudicate Codex, verify its claims against the repo, name what both missed. Seven GitHub calls. Findings, with the author's verification where a claim was checked afterwards.

**Codex was right on** admission authority (verified: `criteria_section: Admission Criteria` at `detent.yaml:220`, `auto_admit: true` at 0.9 at `:230-231`; Readiness at `WORKFLOW.md:301-304` is the design's `## Plan` section verbatim), the non-existent single writer (`detent.yaml:259-261` scopes the lease to the three cron loops; `dependency_auto_unblock` at `:73-78` and workers are ungated), the laptop scheduler, and killing silent consent for semantic closes.

**Codex overreached on** coordination machinery and gates. For ten issues a day, write-domain partitioning beats fingerprints and journals: the sweep writes only to Backlog items, Detent never touches Backlog once admission is off (`WORKFLOW.md:23`), and a human running the evaluator writes only to the issue in hand. Stratified samples with minimum denominators take weeks per stratum at this volume; two people can read every proposal, so 100% review replaces statistics. Keep the kill switch and "no reverted close". The `/triage <verb>` syntax and five human-only reason codes are too much ceremony: prose from OWNER or MEMBER can route, only an explicit verb or a manual close closes.

**Both the author and Codex were wrong at the foundation of goal alignment.** Epics #2267, #2896, #3082 have zero native sub-issues and no parent; epics here are body-text lists and "part of #N" references. The parent walk, its two-level limit, and the ancestor-conflict rules describe a chain with no links. The fix the revision section stumbled into is the whole mechanism: stamp `goal:*` on the issue at triage. The epic label is the registry (`gh issue list --label goal:q3-2026`); no `WORKFLOW.md` section, which is the per-issue Codex prompt and would feed the registry to every lane.

**No admission label hook exists.** `backlog_admission` has only `authors.allow_association` (`detent.yaml:221-225`); `allowed_issue_labels` lives on `auto_promote` (`:164`); tracker `authorization.labels.exclude` gates dispatch, exclude-only. Gating admission on `triage:ready` is a Detent change. Until then: `backlog_admission.enabled: false` (`:214`), not just `auto_admit: false`, because a proposal-only scanner still comments on the same issues the evaluator does.

**Verified against the repo by the author after the review:**
- Flood timing. The reviewer flagged 11:20Z against a `0 6 * * 1` cron as unexplained. Checked: the first flood issue (#2348) was created at 11:00:12Z, which is 06:00 America/Chicago; the last (#2860) at 11:20:24Z is the tail of a 20-minute filing run. The cron fired on schedule. Attribution stands, and there is no missed-cron replay to investigate.
- The Air's no-progress fuse. `detent.yaml:168-175` says `metered` is required for enforcement and subscription mode "never refuses dispatch or parks an issue". `detent.local.yaml:38` sets `billing_mode: subscription` on the Air, with a comment that `agent.no_progress_token_limit` stays armed. That key is set in none of `detent.yaml`, `detent.local.yaml`, or `~/Library/Application Support/detent/global.yaml`. Unless Detent ships a built-in default, the Air has no no-progress brake. Unverified: whether a default exists.
- Isolation contradiction. `WORKFLOW.md:258-260` and `:271-273` say one implementation lane; `detent.yaml:139-140` sets Todo 2 and In Progress 2; the Air overlay allows 3 agents; `global.yaml:30` allows 12 machine-wide. AGENTS.md's "assume `make dev` is already running" on shared ports makes the contract the honest one.

**What both missed:**
1. Intake shape is mostly solved for new issues: 52 of the 60 most recent open issues carry a `detent-agent` block. Templates are low value. The migration problem is the 142 old issues, and the answer is the sweep proposing close or park, not retrofitting blocks.
2. A third inbox. Packet comments join `/today` and the Detent dashboard while 24 open PRs already wait on Michael. Decisions live in one board view filtered on `triage:needs-decision`; no email in Phase A.
3. Double triage with `/pr-details`. Still-needed and the supersession sweep would run three times per issue and PR pair at different `dev` tips and can disagree. Write the verdict plus the `dev` SHA into the marker comment; `pr-details` trusts a verdict newer than its merge base.
4. Cory's issues. 11 of the last 60 are his; every unparented one scores Low and his stale ones draw close proposals. Rule: the evaluator never proposes close or park on the other human's issue without that human's reaction, and priority on someone else's filing is a comment, not a field write.
5. The revised MVP is still five phases. Planning at intake duplicates what the Detent lane already does at `xhigh`. And 21 of 52 recent effort blocks are `xhigh`, so "antagonist only for xhigh" is 40% of issues unless triage actively downgrades.

**Reviewer's verdict:** Codex was right on authority, closes, and the laptop, wrong in scale on coordination and gates; the author accepted too literally, and both built prioritisation on a sub-issue hierarchy that does not exist.

**First deliverable, this week:**
- `detent.yaml`: comment out `intake` (`:244-256`); set `backlog_admission.enabled: false` (`:214`). One PR.
- Label the four or five Q3 epics `goal:q3-2026`.
- `/issue-details <n>`, read-only: classify (bug, goal, idea, noise); search open issues and PRs by title terms for duplicates; propose a `goal:*` label and board Priority per the table; propose effort, never `max`; post one marker comment. No plan, no still-needed, no antagonist. Run it on last week's 49 issues; Michael and Cory each read every comment.
- A board view filtered on `triage:needs-decision`.
