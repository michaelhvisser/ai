# E2E Verify — Mode-Specific Finish Actions

Loaded by `SKILL.md` Step 7. Contains the **E2E gate** (must run before any
finish action), maps `MODE` to the closing action, and contains the
`fix-and-ship` CI-watch loop and user-only ship workflow handoff rules.

## Step 7.0: E2E Gate (applies to every mode before any finish action)

Before any mode action, check persisted browser cleanup. A recorded session
must be stopped, including on re-entry into the posting or shipping phase:

```bash
E2E_BROWSER_STATE=$(get_loop_field "$STATE_FILE" "e2e_browser_state" "$WORKFLOW_STATE_PATH")
if [ -n "$E2E_BROWSER_STATE" ]; then
  if ! bash "<PLUGIN_ROOT>/scripts/e2e-browser.sh" stop "$E2E_BROWSER_STATE"; then
    set_loop_field "$STATE_FILE" "e2e_browser_cleanup" "failed" "$WORKFLOW_STATE_PATH"
    WORKFLOW_REASON=browser-cleanup-failed
    if [ "$EMBEDDED_WORKFLOW" = "true" ]; then
      set_workflow_result "$STATE_FILE" "$WORKFLOW_STATE_PATH" "e2e-fail" "$WORKFLOW_REASON" "e2e-failed"
      echo "E2E_VERIFY_RESULT=e2e-fail"
      echo "E2E_VERIFY_REASON=$WORKFLOW_REASON"
    else
      set_loop_terminal_result "$STATE_FILE" "e2e-fail" "$WORKFLOW_REASON" "e2e-failed" "E2E_FAIL"
      echo "<done>E2E_FAIL</done>"
    fi
    exit 0
  fi
  set_loop_field "$STATE_FILE" "e2e_browser_cleanup" "stopped" "$WORKFLOW_STATE_PATH"
fi
```

Then evaluate `E2E_RESULT`:

- **UI-visible diff** (`WEB_CHANGES`, `HANDLER_CHANGES`, or layout-sensitive
  keywords detected — see `e2e-test-execution.md` §5a.1):
  - `E2E_RESULT=pass` → continue to the per-mode finish action below.
  - `E2E_RESULT` is anything else (`fail`, `partial`, `skipped-server-failed`,
    `missing-browser-tooling`, `uninspected-screenshots`) → **stop**. Do NOT
    add `run-full-ci`. Do NOT add `e2e-verified`. Do NOT invoke
    `$ts-workflow:ship`. The Step 6 comment already records the failure with
    findings. Persist the terminal result before exiting:

    ```bash
    WORKFLOW_RESULT=e2e-fail
    WORKFLOW_REASON="$E2E_RESULT"
    if [ "$EMBEDDED_WORKFLOW" = "true" ]; then
      set_workflow_result "$STATE_FILE" "$WORKFLOW_STATE_PATH" "e2e-fail" "$WORKFLOW_REASON" "e2e-failed"
    else
      set_loop_terminal_result "$STATE_FILE" "e2e-fail" "$WORKFLOW_REASON" "e2e-failed" "E2E_FAIL"
    fi
    echo "WORKFLOW_RESULT=$WORKFLOW_RESULT"
    echo "WORKFLOW_REASON=$WORKFLOW_REASON"
    if [ "$EMBEDDED_WORKFLOW" = "true" ]; then
      echo "E2E_VERIFY_RESULT=e2e-fail"
      echo "E2E_VERIFY_REASON=$WORKFLOW_REASON"
    else
      echo "<done>E2E_FAIL</done>"
    fi
    exit 0
    ```
- **Non-UI diff** (no web indicators, no UI-facing files changed):
  - `E2E_RESULT=skipped` → continue to the per-mode finish action below
    (treated as the success path).
  - Any non-`skipped` value on a non-UI diff is a logic error — investigate
    before continuing.

## Step 7.1: Resolve policy and authorized triggers

Only after Step 7.0 passes, resolve `<PLUGIN_ROOT>/lib/validation-policy.md`.
Run any explicitly configured, authorized repository trigger helper required
by that policy now, before watching checks. Do not return to Step 6 to trigger
it. The mode/task must authorize the mutation; helper existence or a
conventional label name is not authority. Investigate remains read-only.
Failed or unavailable required triggering is incomplete, not a CI exemption.
Report mutations only after confirmed success. This skill has no built-in
label POST recipe.
On resume, reuse confirmed triggering for the same head and inspect an existing
run before invoking its helper again. Never launch a duplicate full suite while
the configured run is pending; follow the helper's repository-owned contract.

Local mode skips automatic trigger/readiness handling and executes the shared
local-validation path, including required checks and published-head equality.

## Step 7.2: Completion validation gate (every mode)

Execute this before any action table row, `verified` result, or ship handoff.
Explicit pr-ci policy watches the exact head in every mode, even with no rebase.
Auto retains the earlier post-rebase watcher and final fix-and-ship watcher;
ship also validates through its own workflow. Local mode uses the required
local proof above and never calls this CI watcher.
The watcher waits for check registration, pins every
poll to the exact PR head, and rejects API failures or a head shift.

```bash
COMPLETION_CI_REQUIRED=false
case "${VALIDATION_MODE:-auto}" in
  pr-ci) COMPLETION_CI_REQUIRED=true ;;
  auto) if [ "$MODE" = "fix-and-ship" ]; then COMPLETION_CI_REQUIRED=true; fi ;;
  local) ;;
  *) WORKFLOW_RESULT=INCOMPLETE; WORKFLOW_REASON=invalid-validation-policy; exit 1 ;;
esac
if [ "$COMPLETION_CI_REQUIRED" = "true" ]; then
PR_JSON=$(cd "$WORKTREE_PATH" && github_pr "$PR_NUM") || {
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON=ci-api-failed
}
if [ "${WORKFLOW_RESULT:-}" != "INCOMPLETE" ]; then
  HEAD_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
  PUBLISHED_COMPLETION_HEAD=$(jq -er '.head.sha' <<< "$PR_JSON")
  if [ "$PUBLISHED_COMPLETION_HEAD" != "$HEAD_SHA" ]; then
    WORKFLOW_RESULT=INCOMPLETE
    WORKFLOW_REASON=pr-head-shift
  fi
fi
if [ "${WORKFLOW_RESULT:-}" != "INCOMPLETE" ]; then
  CHECKS_STATUS=0
  CHECKS_SNAPSHOT=$(cd "$WORKTREE_PATH" && github_watch_pr_checks "$PR_NUM" "$HEAD_SHA") || CHECKS_STATUS=$?
  if [ "$CHECKS_STATUS" -ne 0 ]; then
    case "$CHECKS_STATUS" in
      "$GITHUB_CHECKS_FAILED") WORKFLOW_REASON=ci-checks-failed ;;
      "$GITHUB_CHECKS_REGISTRATION_TIMEOUT") WORKFLOW_REASON=ci-registration-timeout ;;
      "$GITHUB_CHECKS_API_ERROR") WORKFLOW_REASON=ci-api-failed ;;
      "$GITHUB_CHECKS_HEAD_SHIFT") WORKFLOW_REASON=pr-head-shift ;;
      *) WORKFLOW_REASON=ci-watch-failed ;;
    esac
    WORKFLOW_RESULT=INCOMPLETE
  fi
fi

if [ "${WORKFLOW_RESULT:-}" = "INCOMPLETE" ]; then
  echo "WORKFLOW_RESULT=$WORKFLOW_RESULT"
  echo "WORKFLOW_REASON=$WORKFLOW_REASON"
  exit 1
fi
jq -r '.items[] | "\(.name): \(.state)"' <<< "$CHECKS_SNAPSHOT"
fi
```

Every non-success watcher result follows the top-level **Hard Invariant
Failure** procedure. Do not continue to the ship workflow.

## Step 7.3: Mode → Action Table (only after both gates pass)

| Mode | Action |
|------|--------|
| `verify` | Finish with a verified result |
| `fix-and-verify` | Finish with a verified result |
| `investigate` | Finish with a verified result for the reported findings |
| `ship-prep` | Finish with a verified result |
| `ship` | Set phase to `shipping`. Execute the ship workflow |
| `fix-and-ship` | Set phase to `shipping`. Execute the full ship workflow |

## Ship Workflow Handoff

The ship skill is user-only. Do not call it with the Skill tool. Read
`<PLUGIN_ROOT>/skills/ship/SKILL.md` and execute its instructions
directly.

- **`ship` mode** → Treat an empty string as the ship workflow's `SKILL_ARGS`
  so it runs the full coverage and E2E gates.
- **`fix-and-ship` mode** → Treat an empty string as the ship workflow's
  `SKILL_ARGS`. Ship must run its changed-source coverage gate; the earlier
  browser result may be reused only through ship's explicit verified-result
  path.

For either ship mode, initialize ship under the current E2E workflow and set
its explicit caller contract before executing the loaded skill:

```bash
SHIP_STATE_PATH=$(child_workflow_path "$WORKFLOW_STATE_PATH" "ship")
initialize_workflow_state "$STATE_FILE" "$SHIP_STATE_PATH"
CALLER_LOOP_STATE_FILE="$STATE_FILE"
CALLER_WORKFLOW_STATE_PATH="$WORKFLOW_STATE_PATH"
```

After ship returns, clear both caller variables and route its structured result:

```bash
WORKFLOW_STATE_PATH="$CALLER_WORKFLOW_STATE_PATH"
unset CALLER_LOOP_STATE_FILE CALLER_WORKFLOW_STATE_PATH
SHIP_RESULT=$(get_loop_field "$STATE_FILE" "result" "$SHIP_STATE_PATH")
SHIP_REASON=$(get_loop_field "$STATE_FILE" "reason" "$SHIP_STATE_PATH")
if [ "$SHIP_RESULT" != "shipped" ]; then
  WORKFLOW_RESULT=INCOMPLETE
  WORKFLOW_REASON="${SHIP_REASON:-ship-incomplete}"
fi
```

Any non-shipped result follows the top-level **Hard Invariant Failure**
procedure. A shipped result continues to the finish block below.

## Finish Result

After the selected mode action completes, persist E2E's result and either
return it to the caller or emit the standalone promise:

```bash
if [ "$EMBEDDED_WORKFLOW" = "true" ]; then
  set_workflow_result "$STATE_FILE" "$WORKFLOW_STATE_PATH" "verified" "" "completed"
  echo "E2E_VERIFY_RESULT=verified"
else
  set_loop_terminal_result "$STATE_FILE" "verified" "" "completed" "VERIFIED"
  echo "<done>VERIFIED</done>"
fi
```
