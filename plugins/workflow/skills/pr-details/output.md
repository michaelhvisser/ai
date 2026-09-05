# Output — Phase 7

Stdout and stderr are strictly separated. With `--json`, **stdout carries the JSON object and
nothing else**; without it, stdout carries the terminal report and nothing else. Diagnostics,
progress, and warnings always go to stderr, and warnings that matter to a consumer are *also*
carried inside the JSON as `warnings[]`.

---

## §1 Terminal report

≤ 56 lines, fixed section order: header, `STATUS`, `PURPOSE` (one block per linked issue),
`PLAN CHECK`, `UI REVIEW`, `QUALITY`, `EXECUTION PLAN`.

```
=== PR #<n> · <title> ===
<slug> · <base> ← <head ref> @ <sha7> · <n> files +<add>/−<del> · <state>, <draft?>

STATUS
  CI        <state>  <per-required-check line: name ✓/✗/pending/missing, required?, integration id>
  Review    <given>/<required> approvals · <CHANGES_REQUESTED summary> · <extra approval rules>
  Threads   <n> unresolved (<h> human · <c> codex · <b> other) · <r> resolved
  Merge     <mergeable> · <mergeStateStatus> · <behind_by> behind <base> <(strict up-to-date required)>
  Board     #<issue> <status> · auto-promote: <on|off> · PR row: <status> (ignored)
  Local     <checkout relation> · <clean|dirty>

PURPOSE
  #<issue> <issue title>
  Needed?   <NEEDED|ALREADY FIXED|DUPLICATE|NO LONGER NEEDED|UNCLEAR> (<confidence>) — <one-line evidence>

PLAN CHECK  (<model> @ <effort> · <elapsed>)
  PLAN_ADEQUATE: <yes|partial|no>
  <Gn> <severity>  <gap text> — <path:line>

UI REVIEW   <warranted (severity) — routes … · shots: <shots_status>|not warranted — reason>

QUALITY     <codex-ship ✓ at head|✗|stale> · <antagonist …> · <deep review …> · <e2e …|n/a>
            still required before merge: <list, or "nothing — ladder satisfied at this head">

EXECUTION PLAN
  1 → <command or action>                             [row <n>]  <verdict qualifier>
      why:   <rationale naming the facts that fired the row>
      local: <the §6 recipe, one line>
  2 → <command or action>                             [row <n> · projected]
      why:   <one line>
      local: <the §6 recipe, one line>
  …
  then:  /workflow:pr-details <n>
  files: <run dir>
```

Rules:

- At most **5** unresolved threads inline, then `+n more`.
- Gaps capped at **5**, each with its severity.
- The plan prints every entry (cap 5, `next-step.md` §5); entry 1 carries the full `why:`
  and `local:` lines, later entries a one-line `why:`, a one-line `local:`, and the
  `projected` tag — the terminal is the only render, so the plan must be drivable by hand
  from it alone.
- `QUALITY` names each rung of the review ladder as **at head**, **stale** (evidence names an
  older SHA), or **not run**, then the second line derives "still required" from the same
  facts the table read — never from a separate judgment.
- The final `files:` line names `$RUN_DIR`.
- ASCII-safe except `✓` and `✗`.
- Rows 25–29 append the verdict qualifier:
  `1 → hand to Detent (Merging)  [row 25]  ready pending: local gate (pnpm lint && pnpm test && pnpm build)`.
- When thread resolution is unknown (`facts.md` §2c) the `Threads` line reads
  `≤ <n> unresolved (resolution unknown) (<h> human · <c> codex · <b> other)`, and the
  `Board` line names its source when it is not the snapshot:
  `#<issue> <status> (graphql)` or `#<issue> unknown (board unreadable)`.
- Warning lines (unavailable plan model, advisory ruleset, `h` is an upper bound, thread
  resolution unknown, board from stale snapshot, capped sweeps, degraded screenshots) go to
  **stderr**, never into this block.

## §2 `--json` schema, version 4

Stdout carries this object and nothing else. The same object is written to
`$RUN_DIR/facts.json` on every run, `--json` or not; the local-execution loop re-reads its
`plan_check` verdicts (`execute.md` §4). Version 4 is the REST-first transport: it adds
`pr.transport` (always `"rest"`), `status.threads.resolution_known` (false when the GraphQL
resolution read did not run or was refused — `facts.md` §2c), `issues[].board.source`
(`detent-snapshot|graphql|none`) and `issues[].board.snapshot_age_s` (null unless the
snapshot answered), widens `issues[].source` with `detent-snapshot`, and adds two
`warnings[]` lines — "thread resolution unknown …" and "board from stale snapshot …".
`pr.files_truncated` is now a constant `false` (REST paginates the file list). Version 3
removed `page`, widened `duplicates[].kind` with the supersession sweep (`shipped-pr`,
`closed-issue`, `backlog-issue` — `facts.md` §1e), and added `no-longer-needed` to the
still-needed verdict vocabulary; everything a version-3 consumer read is unchanged.

```json
{
  "schema": 4,
  "generated_at": "2026-08-20T12:00:00Z",
  "host": "github.com",
  "repo": "threefold-solutions/client-portals",
  "pr": {"number":161,"title":"…","url":"…","state":"OPEN","is_draft":false,"is_fork":false,
         "base":"dev","base_tip":"<sha>","head_ref":"…","head_sha":"…","merge_base":"<sha>",
         "author":"michaelhvisser","additions":727,"deletions":68,"changed_files":9,
         "files":["…"],"files_truncated":false,"diff_lines":979,"transport":"rest"},
  "issues": [{"number":92,"title":"…","state":"OPEN","source":"body-keyword","labels":["detent:mac-mini-1"],
              "board":{"project_id":"client-portals","status":"Human Review","priority":null,"ambiguous":false,
                       "source":"detent-snapshot","snapshot_age_s":20}}],
  "status": {
    "ci": {"state":"green",
           "required":[{"context":"Lint, typecheck, test","integration_id":15368,"state":"pass"},
                       {"context":"Vercel","integration_id":null,"state":"pass"}],
           "missing":[],
           "observed":[{"name":"Vercel Preview Comments","kind":"check-run","state":"success","required":false}]},
    "review_decision":"", "approvals_given":0,
    "changes_requested_by":{"human":[],"bot":[]},
    "threads": {"total":0,"unresolved":{"human":0,"codex":0,"other_bot":0,"needs_resolve_only":0},
                "resolved":0,"paginated_complete":true,"resolution_known":true,
                "items":[{"path":"…","line":1,"origin":"codex-bot","last_by":"human/codex-ship",
                          "resolved":true,"age_h":12}]},
    "mergeable":"MERGEABLE","merge_state":"BEHIND","behind_by":4,"ahead_by":1,
    "rules": {"source":"ruleset","advisory":false,"ruleset_ids":[20898153],
              "threads_required":true,"strict_up_to_date":true,
              "required_checks":[{"context":"Lint, typecheck, test","integration_id":15368},
                                 {"context":"Vercel","integration_id":null}],
              "merge_methods":["squash"],"approvals_required":0,
              "code_owner_review":false,"last_push_approval":false,
              "extra_approval_unattributed":true,"dismiss_stale_on_push":false,
              "ignored":["deletion","non_fast_forward"],"unknown":[]},
    "contract": {"auto_promote":false,"gate_run":"pnpm lint && pnpm test && pnpm build",
                 "require_automated_review":true,"merge_method":"squash",
                 "active_states":["Todo","In Progress","Rework","Merging"],
                 "observed_states":["Human Review","Blocked"],
                 "terminal_states":["Done","Cancelled"]},
    "local": {"checked_out":false,"detached":false,"dirty":false,"relation":"other-commit"},
    "prior": {"antagonist":{"ran":false,"at_head":false,"evidence":""},
              "codex_ship":{},"address_review":{},"e2e":{},"review_deep":{},"detent_gate":{}}
  },
  "duplicates": [{"kind":"issue","number":143,"title":"…","signals":["shared-files"],
                  "confidence":"possible","board_status":"Todo"},
                 {"kind":"shipped-pr","number":151,"title":"…","signals":["shared-files","recent-merge"],
                  "confidence":"possible","closed_issues":[144],"merged_at":"2026-08-19T09:00:00Z"},
                 {"kind":"backlog-issue","number":150,"title":"…","signals":["direction"],
                  "confidence":"possible","board_status":"Backlog"}],
  "still_needed": {"92":{"verdict":"needed","confidence":"high",
                         "evidence":["convex/http.ts:212 @ <base_tip> still matches on label"]}},
  "plan_check": {"per_issue":{"92":{"combined":"yes","split":false,
                   "models":[{"name":"fable","requested_model":null,"effort":"xhigh",
                              "seconds":40,"usable":true,"adequate":"yes","confidence":"high",
                              "gaps":[],"diff_vs_plan":"…","proposed_issue_edits":"— none —",
                              "verify_by":"…","raw_path":"…/plan-fable.md"}]}},
                 "combined":"yes","split":false},
  "ui": {"warranted":false,"severity":null,"files":[],"routes":[],"evidence_present":false,
         "reason":"no UI paths changed",
         "preview_url":null,"shots_status":"not-warranted",
         "screenshots":[],"visual_summary":null},
  "quality": {
    "codex_ship":{"ran":false,"at_head":false,"clean":null,"evidence":null},
    "antagonist":{"ran":false,"at_head":false,"evidence":null},
    "deep_review":{"ran":false,"at_head":false,"evidence":null},
    "e2e":{"ran":false,"at_head":false,"applicable":false},
    "still_required":["antagonist-review"]},
  "queue": [
    {"pos":1,"id":"rebase","row":10,"projected":false,
     "command":"rebase onto dev","why":"4 commits behind dev under a strict ruleset",
     "local":"git fetch <base-remote> && git rebase <base-remote>/dev, then git push --force-with-lease=refs/heads/<headRefName>:<observed-head-sha> <head-remote> HEAD:refs/heads/<headRefName>",
     "cost":"local, minutes"},
    {"pos":2,"id":"wait-ci","row":17,"projected":true,
     "command":"wait for CI on the new head","why":"the rebase resets every at-head fact",
     "local":"source lib/github-rest.sh && github_watch_pr_checks 161 <new-head-sha>  (REST check-runs poll; gh pr checks --watch is GraphQL)","cost":"wall time only"},
    {"pos":3,"id":"antagonist-review","row":19,"projected":true,
     "command":"/workflow:antagonist-review https://github.com/threefold-solutions/client-portals/pull/161","why":"no review evidence can survive the rebase; diff 979 ≥ 150",
     "local":"review the diff yourself (gh api -H 'Accept: application/vnd.github.diff' repos/threefold-solutions/client-portals/pulls/161), or run the language plugin's review-deep",
     "cost":"tokens: high · wall: 10–30 min"}],
  "ready": {"verifiable":false,
            "conjuncts":[{"id":"C1","grade":"verified","state":"true","text":"required checks pass"},
                         {"id":"C3","grade":"verified","state":"false","text":"behind_by == 0 under strict"},
                         {"id":"C13","grade":"self-report","state":"unknown","text":"pnpm lint && pnpm test && pnpm build"}],
            "observably_false":["C3"],"unverifiable":["C13"]},
  "next_step": {"id":"rebase","row":10,"verdict":null,
                "command":"rebase onto dev","rationale":"4 commits behind dev under a strict ruleset",
                "then":["/workflow:pr-details 161"],"pending":[],
                "notes":[]},
  "facts_incomplete": false,
  "warnings": ["thread resolution unknown — GraphQL refused; 1 root thread counted as open (upper bound); threads not required by the dev ruleset",
               "board from stale snapshot (5120 s) — GraphQL refused; state Human Review is the last daemon reading"],
  "files": {"run_dir":"…/run/161-e04cd91db728-83c00c","cache_dir":"…/cache/<head_sha>",
            "diff":"diff.patch","plan_fable":"plan-fable.md"}
}
```

### `next_step.id` — closed vocabulary

`merged`, `closed`, `facts-incomplete`, `board-terminal`, `blocked`, `no-active-issue`,
`close-superseded`, `close-duplicate`, `rebase`, `address-review`, `codex-ship`, `fix-plan`,
`antagonist-review`, `wait-ci`, `ui-review`, `finish-draft`, `complete-gate`,
`human-approval`, `move-to-human-review`, `hand-to-detent`, `needs-human`.

Twenty-one values, one per distinct outcome of the thirty rows. `next_step.verdict` is `null`
except on rows 25–29, where it is `"ready"` or `"ready pending: …"`, and `next_step.pending[]`
carries the conjunct ids in that case. **There is no "optional" value anywhere in the schema** —
a weaker secondary suggestion lives in `then[]` or `notes[]`.

`queue[]` uses the same vocabulary. `queue[0]` is `next_step` restated (same `id`, same `row`)
with the `command`, `local`, and `cost` render fields added; entries with `projected: true`
are path, not fact (`next-step.md` §5). A version-1 consumer that only reads `next_step`
loses nothing.

The two version-4 `warnings[]` lines are fixed-prefix so a consumer can match them:
`thread resolution unknown — …` accompanies `status.threads.resolution_known: false` and a
non-zero thread count; `board from stale snapshot (<age> s) — …` accompanies
`issues[].board.source: "detent-snapshot"` with `facts_incomplete: true` (the snapshot was
stale and GraphQL could not refresh it). An issue absent from the snapshot whose GraphQL read
also failed carries `board.source: "none"` and `board.status: "unknown"` with no warning line
— `next_step.id` is already `facts-incomplete` and says so.

## §3 Exit codes

| Exit | Meaning |
|---|---|
| `0` | A report was produced — **including `next_step.id == "blocked"`**. Callers branch on `next_step.id`, never on the exit code. |
| `2` | Usage error. |
| `3` | Auth or rate-limit refusal. No partial report on stdout. |
| `4` | PR not found, or resolved to a repository the caller did not intend. |
| `1` | Reserved for unexpected internal failure. Never used deliberately. |

## §4 Scratch hygiene

Scratch files live under the session scratchpad only; never commit or post them, and do not
paste secrets into model prompts. The screenshots are scratch files like any other:
`shots/*.png` may show authenticated preview content, so they never leave the run directory —
not committed, not posted, not uploaded, not served.
