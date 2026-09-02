# The approval gate — Phase 4, and `post`

Everything before the user's answer is read-only. The gate asks **once per run**, for every
evaluated issue together, and the answer authorizes exactly one subcommand:
`scripts/issue-details.sh post --run-dir "$RUN_DIR"`, whose write set is §2 — reached only
through its refresh (§3) and dispatcher (§4), in any mode.

---

## §1 The one question

Classify it per `lib/decision-gates.md`: consent to write to the issues is **missing
intent** — a request for triage does not imply posting it — so ask once, through the
driver's structured-input capability, and never loop. Three options:

1. **Post** — `post`: for each evaluated, still-open issue whose `comment_action` is
   `create` or `edit`, refresh, then dispatch. The script prints one line per issue.
2. **Print only** — `print`: every drafted comment to stdout after the report; nothing
   written. The drafts stay in the run dir.
3. **Stop** — the report stands; nothing else is printed or written.

**`--json`, `--no-gate`, and any non-interactive session mean print only** (for `--json`,
the drafts are in `facts.json` `issues[].comment.body_path`, not on stdout). A driver
without structured input does not skip the gate: per `driver-interaction.md`, ask the same
question as concise text in the final response and stop; the user's answer resumes here.
**Nothing is written before the answer**, and there is no flag that answers it.

Skip the question entirely when nothing could be posted: every evaluated issue is closed
or `refuse`, or the run evaluated nothing.

## §2 The write set

Three commands, and only these, each repo-qualified, each reachable **only** from
`id_dispatch`. Every other `gh` verb remains forbidden after the gate exactly as before it.

| Write | Command | When |
|---|---|---|
| create | `gh api --hostname "$HOST" -X POST "repos/$SLUG/issues/$n/comments" -F body=@comment-<n>.md` — **bare `gh`, no retry** | `comment_action: create` |
| edit in place | `pr_facts_gh api -X PATCH "repos/$SLUG/issues/comments/<marker_id>" -F body=@comment-<n>.md` | `comment_action: edit` |
| label | `pr_facts_gh issue edit <n> -R "$SLUG" --add-label "triage:needs-decision"` | the comment write succeeded **and** `needs_decision: true` |

`-F body=@<path>` reads the value from the file (`gh api --help`: "use @<path> … to read
value from file"). The label is added, never removed: clearing `triage:needs-decision` is
the human's signal that the decision landed, and this skill must not undo it on a re-run.

Never: `gh issue close`, `gh issue edit --body`, `--remove-label`, any other `--add-label`,
`gh project item-edit`, a comment on an issue whose action is `refuse`, or a second
comment when a marker already exists.

## §3 Refresh before write — `id_refresh`, fail closed

State moves between the read and the answer: a human replies or edits a reply, a label
lands, the issue closes, another run posts. Immediately before each issue's write the
script refetches the issue (`state`, `updatedAt`, `labels`) and its comments and compares
them with the snapshot **read back from `state-<n>.json`** — never from a shell variable.
Every failure path — an API error, a partial page, empty, malformed, or wrong-shaped JSON
(the comment pages are proven to be arrays of `{id, body, updated_at}` objects; `jq` on
empty input otherwise exits 0 and a create run would "see no marker" and post) — leaves
`write_ok: 0`; only a complete, well-formed, unchanged refresh sets it to 1. The compares,
in order, each with its note:

1. the issue is no longer `OPEN`;
2. `updatedAt` moved;
3. the sorted label set differs;
4. the **full comment fingerprint** `[{id, updated_at}]` differs — a comment added,
   removed, **or edited**, marker or not (an edited reply can change the goal references
   the draft was built from);
5. more than one owned marker exists now;
6. `create` but an owned marker appeared; `edit` but the marker's id or `updated_at`
   changed;
7. any action other than `create` / `edit`.

Board fields are not re-read: the draft never depends on a board field for anything but
a note, and a board move is not a reason to withhold a triage comment.

## §4 The dispatcher — `id_dispatch`

The only place a write command appears in executable form. Reads `write_ok`,
`comment_action`, `marker_id` from the state file and `needs_decision` from the result
file. Exactly one comment write, then the label only on success and only when a decision
is required.

**The create is a bare `gh api -X POST`, never the retry wrapper.** `pr_facts_gh` retries
5xx and connection resets, and a POST that GitHub accepted but whose response died in
transit would be posted again — the one-comment contract broken by the safety net. On any
failure the dispatcher instead refetches the comment list once and looks for its own
marker: found means the POST landed and is reported as `posted (confirmed after an
ambiguous response)` (the next run edits it); not found means the create failed and is
**not retried** — the user re-runs. `PATCH` and `--add-label` are idempotent and keep the
wrapper.

Per issue it prints `#<n> posted`, `#<n> edited #<id>`, `, label added` / `, label add
failed` when it applied, or `#<n> skipped — <note>`. A skipped issue does not abort the
rest, and a skipped write is reported, never retried silently.

## §5 After the writes

Stop. There is no "then run X" here: the design's hand-off to Detent, the plan, and the
close reasons are later versions' work (`SKILL.md` §"Scope"), and the decision view (the
board filtered on `triage:needs-decision`) is where a human picks the issue up.
