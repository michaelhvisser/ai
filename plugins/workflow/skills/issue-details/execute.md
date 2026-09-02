# The approval gate — Phase 6

Everything before the user's answer is read-only. The gate asks **once per run**, for every
evaluated issue together, and the answer authorizes exactly the closed write set in §2 —
reached only through the dispatcher in §4, in any mode.

---

## §1 The one question

Classify it per `lib/decision-gates.md`: consent to write to the issues is **missing
intent** — a request for triage does not imply posting it — so ask once, through the
driver's structured-input capability, and never loop. Three options:

1. **Post** — for each evaluated, still-open issue whose `COMMENT_ACTION` is `create` or
   `edit`: refresh (§3), then run the dispatcher (§4). The report prints what was written,
   per issue.
2. **Print only** — render every drafted comment to stdout after the report, write
   nothing. The drafts stay in the run dir.
3. **Stop** — the report stands; nothing else is printed or written.

**`--json`, `--no-gate`, and any non-interactive session mean print only** (for `--json`,
the drafts are in `issues[].comment.body_path`, not on stdout). A driver without
structured input does not skip the gate: per `driver-interaction.md`, ask the same question
as concise text in the final response and stop; the user's answer resumes here. **Nothing
is written before the answer**, and there is no flag that answers it.

Skip the question entirely when nothing could be posted: every evaluated issue is closed
or `refuse`, or the run evaluated nothing.

## §2 The write set

Three commands, and only these, each repo-qualified, each reachable **only** from the §4
dispatcher. Every other `gh` verb remains forbidden after the gate exactly as before it.

| Write | Command | When |
|---|---|---|
| create | `gh api --hostname "$HOST" -X POST "repos/$SLUG/issues/$ISSUE_NUM/comments" -F body=@"$RUN_DIR/comment-${ISSUE_NUM}.md"` — bare `gh`, no retry (§4) | `COMMENT_ACTION=create` |
| edit in place | `pr_facts_gh api --hostname "$HOST" -X PATCH "repos/$SLUG/issues/comments/$MARKER_ID" -F body=@"$RUN_DIR/comment-${ISSUE_NUM}.md"` | `COMMENT_ACTION=edit` |
| label | `pr_facts_gh issue edit "$ISSUE_NUM" -R "$SLUG" --add-label "triage:needs-decision"` | the comment write succeeded **and** `NEEDS_DECISION=true` |

`-F body=@<path>` reads the value from the file (`gh api --help`: "use @<path> … to read
value from file"). The label is added, never removed: clearing `triage:needs-decision` is
the human's signal that the decision landed, and this skill must not undo it on a re-run.

Never: `gh issue close`, `gh issue edit --body`, `--remove-label`, any other `--add-label`,
`gh project item-edit`, a comment on an issue whose `COMMENT_ACTION` is `refuse`, or a
second comment when a marker already exists.

## §3 Refresh before write — fail closed

State moves between the read and the answer: a human replies, a label lands, the issue
closes, another run posts. Immediately before each issue's write, refetch the issue and
its comments and compare with the evaluation snapshot (`facts.md` §1b `ISSUE_UPDATED`,
`ISSUE_LABELS`; §1d `MARKER_ID`, `MARKER_UPDATED`, `COMMENT_IDS`). Every failure path — an
API error, a partial page, empty, malformed, or wrong-shaped JSON — leaves `WRITE_OK=0`;
only a complete, well-formed, unchanged refresh sets it to 1. The fetches go to files and
`jq -e` proves each file holds the exact shape expected, because `jq` on empty input
exits 0 and a create run would otherwise "see no marker" and post; a comment list that
parses as an array but is not a list of comment objects is refused the same way.

```bash
WRITE_OK=0; WRITE_NOTE=""
MARKER_RE='^<!-- issue-details:v1 dev=[0-9a-f]{40} -->$'
RF="$RUN_DIR/refresh-${ISSUE_NUM}"
if pr_facts_gh issue view "$ISSUE_NUM" -R "$SLUG" --json state,updatedAt,labels > "$RF.issue" 2>/dev/null \
   && jq -e '(.state | type == "string") and (.updatedAt | type == "string") and (.labels | type == "array")' "$RF.issue" >/dev/null 2>&1 \
   && pr_facts_gh api --hostname "$HOST" --paginate --slurp \
        "repos/$SLUG/issues/$ISSUE_NUM/comments?per_page=100" > "$RF.raw" 2>/dev/null \
   && jq -e 'type == "array" and all(.[]; type == "array" and all(.[]; type == "object"
             and (.id | type == "number") and (.body | type == "string") and (.updated_at | type == "string")))' \
        "$RF.raw" >/dev/null 2>&1; then
  NOW_STATE=$(jq -r .state "$RF.issue"); NOW_UPDATED=$(jq -r .updatedAt "$RF.issue")
  NOW_LABELS=$(jq -c '[.labels[].name] | sort' "$RF.issue")
  NOW_IDS=$(jq -c '[.[][].id] | sort' "$RF.raw")
  jq -c --arg me "$ME" --arg re "$MARKER_RE" \
    '[.[][] | select((.user.login // null) == $me) | select(.body | split("\n")[0] | test($re)) | {id, updated_at}] | sort_by(.id)' \
    "$RF.raw" > "$RF.markers" 2>/dev/null || printf 'x' > "$RF.markers"
  NOW_MARKER_COUNT=$(jq 'length' "$RF.markers" 2>/dev/null || true)
  NOW_MARKER_ID=$(jq -r '.[0].id // empty' "$RF.markers" 2>/dev/null || true)
  NOW_MARKER_UPDATED=$(jq -r '.[0].updated_at // empty' "$RF.markers" 2>/dev/null || true)
  case "$NOW_MARKER_COUNT" in ''|*[!0-9]*) NOW_MARKER_COUNT=-1 ;; esac
  if [ "$NOW_MARKER_COUNT" -lt 0 ]; then
    WRITE_NOTE="refresh returned unreadable comments — not writing"
  elif [ "$NOW_STATE" != "OPEN" ]; then
    WRITE_NOTE="issue is $NOW_STATE — not writing"
  elif [ "$NOW_UPDATED" != "$ISSUE_UPDATED" ]; then
    WRITE_NOTE="issue changed since evaluation (updatedAt $ISSUE_UPDATED -> $NOW_UPDATED) — re-run"
  elif [ "$NOW_LABELS" != "$ISSUE_LABELS" ]; then
    WRITE_NOTE="labels changed since evaluation ($ISSUE_LABELS -> $NOW_LABELS) — re-run"
  elif [ "$NOW_IDS" != "$COMMENT_IDS" ]; then
    WRITE_NOTE="comments changed since evaluation — re-run"
  elif [ "$NOW_MARKER_COUNT" -gt 1 ]; then
    WRITE_NOTE="$NOW_MARKER_COUNT owned marker comments — delete all but one by hand; not writing"
  elif [ "$COMMENT_ACTION" = "create" ] && [ -n "$NOW_MARKER_ID" ]; then
    WRITE_NOTE="a marker comment appeared since the read (#$NOW_MARKER_ID) — not posting a second"
  elif [ "$COMMENT_ACTION" = "edit" ] && [ "$NOW_MARKER_ID" != "$MARKER_ID" ]; then
    WRITE_NOTE="the marker comment changed since the read — re-run"
  elif [ "$COMMENT_ACTION" = "edit" ] && [ "$NOW_MARKER_UPDATED" != "$MARKER_UPDATED" ]; then
    WRITE_NOTE="marker comment $MARKER_ID was edited since the read — re-run"
  elif [ "$COMMENT_ACTION" = "create" ] || [ "$COMMENT_ACTION" = "edit" ]; then
    WRITE_OK=1
  else
    WRITE_NOTE="no write action for this issue ($COMMENT_ACTION)"
  fi
else
  WRITE_NOTE="pre-write refresh failed (API or JSON error) — not writing"
fi
```

`updatedAt` moves on a body edit, a label change, a state change, and a new comment;
labels and the full comment-id set are compared explicitly as well, so the check does not
rest on one timestamp. The marker's own `updated_at` covers an edit to the comment itself,
which does not bump the issue. Board fields are not re-read: the draft never depends on a
board field for anything but a note, and a board move is not a reason to withhold a
triage comment. This block is executed against fixtures by
`plugins/workflow/tests/issue-details-triage.test.sh` — the doc is the code under test;
edit both together.

## §4 The dispatcher

The only place a write command appears in executable form. Exactly one comment write,
then the label only on success and only when a decision is required.

**The create is a bare `gh api -X POST`, never the retry wrapper.** `pr_facts_gh` retries
5xx and connection resets, and a POST that GitHub accepted but whose response died in
transit would be posted again — the one-comment contract broken by the safety net. On
any failure the dispatcher instead refetches the comment list once and looks for its own
marker: found means the POST landed and is reported as such (the next run edits it);
not found means the create failed and is **not retried** — the user re-runs. PATCH and
`--add-label` are idempotent and keep the wrapper.

```bash
WROTE=""; RF="$RUN_DIR/refresh-${ISSUE_NUM}"; MARKER_RE='^<!-- issue-details:v1 dev=[0-9a-f]{40} -->$'
if [ "${WRITE_OK:-0}" = 1 ]; then
  case "$COMMENT_ACTION" in
    create)
      if gh api --hostname "$HOST" -X POST "repos/$SLUG/issues/$ISSUE_NUM/comments" \
           -F body=@"$RUN_DIR/comment-${ISSUE_NUM}.md" > "$RF.post" 2>/dev/null; then
        WROTE="posted"
      elif gh api --hostname "$HOST" --paginate --slurp \
             "repos/$SLUG/issues/$ISSUE_NUM/comments?per_page=100" > "$RF.after" 2>/dev/null \
           && jq -e --arg me "$ME" --arg re "$MARKER_RE" \
                '[.[][] | select((.user.login // null) == $me) | select(.body | split("\n")[0] | test($re))] | length > 0' \
                "$RF.after" >/dev/null 2>&1; then
        WROTE="posted (confirmed after an ambiguous response)"
      else
        WRITE_NOTE="comment create failed — not retried (a POST is not idempotent); re-run, which edits it if it landed"
      fi ;;
    edit)
      if pr_facts_gh api --hostname "$HOST" -X PATCH "repos/$SLUG/issues/comments/$MARKER_ID" \
           -F body=@"$RUN_DIR/comment-${ISSUE_NUM}.md" >/dev/null; then
        WROTE="edited #$MARKER_ID"
      else WRITE_NOTE="comment edit failed"; fi ;;
    *) WRITE_NOTE="no write action for this issue ($COMMENT_ACTION)" ;;
  esac
  if [ -n "$WROTE" ] && [ "${NEEDS_DECISION:-false}" = true ]; then
    if pr_facts_gh issue edit "$ISSUE_NUM" -R "$SLUG" --add-label "triage:needs-decision" >/dev/null; then
      WROTE="$WROTE, label added"
    else WROTE="$WROTE, label add failed"; fi
  fi
fi
if [ -n "$WROTE" ]; then echo "#${ISSUE_NUM} $WROTE"; else echo "#${ISSUE_NUM} skipped — ${WRITE_NOTE:-no write}"; fi
```

A skipped issue is printed with its note and the batch continues — one stale issue does
not abort the rest, and a skipped write is reported, never retried silently. A failed
label add after a successful comment is reported as such; the comment stands. This block
is executed against a stubbed `gh` / `pr_facts_gh` by the test file.

## §5 After the writes

Print, per issue: `posted`, `edited #<comment id>`, `label added` when it was, `skipped —
<note>` otherwise. Then stop. There is no "then run X" here: the design's hand-off to
Detent, the plan, and the close reasons are later versions' work (`SKILL.md` §"Scope"),
and the decision view (the board filtered on `triage:needs-decision`) is where a human
picks the issue up.
