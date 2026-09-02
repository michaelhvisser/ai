# The approval gate — Phase 6

Everything before the user's answer is read-only. The gate asks **once per run**, for every
evaluated issue together, and the answer authorizes exactly the closed write set in §2 —
nothing else, in any mode.

---

## §1 The one question

Classify it per `lib/decision-gates.md`: consent to write to the issues is **missing
intent** — a request for triage does not imply posting it — so ask once, through the
driver's structured-input capability, and never loop. Three options:

1. **Post** — for each evaluated open issue, create or edit-in-place the marker comment
   (§2), and add `triage:needs-decision` where `needs_decision: true`. The report prints
   what was written, per issue.
2. **Print only** — render every drafted comment to stdout after the report, write
   nothing. The drafts stay in the run dir.
3. **Stop** — the report stands; nothing else is printed or written.

**`--json`, `--no-gate`, and any non-interactive session mean print only** (for `--json`,
the drafts are in `issues[].comment.body_path`, not on stdout). A driver without
structured input does not skip the gate: per `driver-interaction.md`, ask the same question
as concise text in the final response and stop; the user's answer resumes here. **Nothing
is written before the answer**, and there is no flag that answers it.

Skip the question entirely when nothing could be posted: every evaluated issue is closed,
or the run evaluated nothing.

## §2 The write set

Three commands, and only these, each repo-qualified. Every other `gh` verb remains
forbidden after the gate exactly as before it.

```bash
# create, when no marker comment exists
pr_facts_gh issue comment "$ISSUE_NUM" -R "$SLUG" --body-file "$RUN_DIR/comment-${ISSUE_NUM}.md"
# edit in place, when facts.md §1b found one
pr_facts_gh api --hostname "$HOST" -X PATCH "repos/$SLUG/issues/comments/$MARKER_ID" \
  -F body=@"$RUN_DIR/comment-${ISSUE_NUM}.md"
# the only label this skill may add, and only when needs_decision is true
pr_facts_gh issue edit "$ISSUE_NUM" -R "$SLUG" --add-label "triage:needs-decision"
```

`-F body=@<path>` reads the value from the file (`gh api --help`: "use @<path> … to read
value from file"). The label is added, never removed: clearing `triage:needs-decision` is
the human's signal that the decision landed, and this skill must not undo it on a re-run.

Never: `gh issue close`, `gh issue edit --body`, `--remove-label`, any other `--add-label`,
`gh project item-edit`, or a second comment when a marker already exists.

## §3 Snapshot before write

State moves between the read and the answer — a human replies, another run posts. Refetch
the comment list immediately before each issue's write and compare:

```bash
pr_facts_gh api --hostname "$HOST" --paginate --slurp \
  "repos/$SLUG/issues/$ISSUE_NUM/comments?per_page=100" \
  | jq -c '[.[][] | {id, body, updated_at}]' > "$RUN_DIR/comments-${ISSUE_NUM}.now.json"
NOW_MARKER_ID=$(jq -r '[.[] | select(.body | startswith("<!-- issue-details:v1"))]
  | sort_by(.id) | .[0].id // empty' "$RUN_DIR/comments-${ISSUE_NUM}.now.json")
NOW_MARKER_UPDATED=""
if [ -n "$NOW_MARKER_ID" ]; then
  NOW_MARKER_UPDATED=$(jq -r --argjson id "$NOW_MARKER_ID" '.[] | select(.id == $id) | .updated_at' \
    "$RUN_DIR/comments-${ISSUE_NUM}.now.json")
fi
WRITE_OK=1
if [ "$COMMENT_ACTION" = "create" ] && [ -n "$NOW_MARKER_ID" ]; then
  WRITE_OK=0; WRITE_NOTE="a marker comment appeared since the read (#$NOW_MARKER_ID) — not posting a second"
elif [ "$COMMENT_ACTION" = "edit" ] && [ "$NOW_MARKER_ID" != "$MARKER_ID" ]; then
  WRITE_OK=0; WRITE_NOTE="the oldest marker comment changed since the read — re-run"
elif [ "$COMMENT_ACTION" = "edit" ] && [ "$NOW_MARKER_UPDATED" != "$MARKER_UPDATED" ]; then
  WRITE_OK=0; WRITE_NOTE="marker comment $MARKER_ID was edited since the read — re-run"
fi
```

`WRITE_OK=0` skips that issue's writes (comment **and** label), prints the note, and
continues with the next issue — one stale issue does not abort a batch, and a skipped write
is reported, never retried silently.

## §4 After the writes

Print, per issue: `posted #<comment id>` or `edited #<comment id>`, `label added` when it
was, `skipped — <note>` otherwise. Then stop. There is no "then run X" here: the design's
hand-off to Detent, the plan, and the close reasons are later versions' work
(`SKILL.md` §"Scope"), and the decision view (the board filtered on
`triage:needs-decision`) is where a human picks the issue up.
