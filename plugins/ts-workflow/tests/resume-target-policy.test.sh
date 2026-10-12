#!/bin/bash
set -euo pipefail

# Shell is intentional: execute the skill's Bash restoration blocks, then drive
# them in the order disclosed by the SKILL pointers. A policy-before-restore
# pointer regression selects the wrong real worktree policy and fails behavior.
# The pre-existing Zsh state-helper PATH issue is outside this test's scope.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
cleanup() {
  if [ -n "$RESUME_POLICY_EVIDENCE_DIR" ]; then
    mkdir -p "$RESUME_POLICY_EVIDENCE_DIR"
    cp -R "$SCRATCH/evidence/." "$RESUME_POLICY_EVIDENCE_DIR/"
  fi
  rm -rf "$SCRATCH"
}
RESUME_POLICY_EVIDENCE_DIR=$(printenv RESUME_POLICY_EVIDENCE_DIR || true)
mkdir -p "$SCRATCH/evidence" "$SCRATCH/blocks" "$SCRATCH/primary"
trap cleanup EXIT
PRIMARY="$SCRATCH/primary"
TARGET="$SCRATCH/target"
git -C "$PRIMARY" init -q -b feature/local
printf '.local/\n' > "$PRIMARY/.gitignore"
printf 'Local checks are authoritative; worker CI polling is prohibited.\n' > "$PRIMARY/AGENTS.md"
printf '{"scripts":{"test":"node --test check.test.ts"}}\n' > "$PRIMARY/package.json"
cat > "$PRIMARY/check.test.ts" <<'FIXTURE'
import { test } from 'node:test';
import assert from 'node:assert/strict';
test('fixture supports target-scoped local verification', () => assert.equal(2 + 2, 4));
FIXTURE
git -C "$PRIMARY" add .
git -C "$PRIMARY" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$PRIMARY" branch dev
git -C "$PRIMARY" worktree add -q -b feature/prci "$TARGET" dev
printf 'This repository requires current-head PR CI and npm run test locally.\n' > "$TARGET/AGENTS.md"
git -C "$TARGET" add AGENTS.md
git -C "$TARGET" -c user.name=Test -c user.email=test@example.invalid commit -qm 'require current-head PR CI'
PRIMARY=$(cd "$PRIMARY" && pwd -P)
TARGET=$(cd "$TARGET" && pwd -P)
mkdir -p "$PRIMARY/.local/state"
TARGET_HEAD=$(git -C "$TARGET" rev-parse HEAD)
git -C "$PRIMARY" worktree list --porcelain > "$SCRATCH/evidence/worktrees.txt"

extract() {
  local file="$1" section="$2" output="$3"
  awk -v section="$section" '
    BEGIN { fence=sprintf("%c%c%c",96,96,96) }
    $0 ~ section { active=1; next }
    active && $0 == fence "bash" { capture=1; next }
    capture && $0 == fence { exit }
    capture { print }
  ' "$ROOT/$file" | sed "s|<PLUGIN_ROOT>|$ROOT|g" > "$SCRATCH/blocks/$output"
  test -s "$SCRATCH/blocks/$output"
}
extract skills/address-review/loop-management.md '^### Restore and validate target' address-restore.sh
extract skills/address-review/loop-management.md '^### Phase routing' address-baseline.sh
extract skills/address-review/setup-and-discovery.md '^## Context' address-context.sh
extract skills/address-review/fetch-feedback.md '^## 2a.' address-feedback.sh
extract skills/address-review/fix-cycle.md '^## Step 7: Watch CI' address-step7.sh
extract skills/address-review/completion-check.md '^## Step 11:' address-step11-head.sh
extract skills/e2e-verify/loop-state.md '^## Bootstrap Block' e2e-bootstrap.sh
extract skills/e2e-verify/loop-state.md '^## Restore resume context' e2e-restore.sh
extract skills/e2e-verify/loop-state.md '^## Persist Arguments Block' e2e-persist.sh
extract skills/e2e-verify/loop-state.md '^## Re-entry Check' e2e-route.sh
extract skills/complete-issue/loop-state.md '^### Restore and validate target' owner-restore.sh

# Extract the completion watcher separately from Step 11's metadata block.
awk '
  BEGIN { fence=sprintf("%c%c%c",96,96,96) }
  $0 == fence "bash" { capture=1; block=""; next }
  $0 == fence { if (capture && block ~ /github_watch_pr_checks/) { printf "%s",block; exit } capture=0 }
  capture { block=block $0 "\n" }
' "$ROOT/skills/address-review/completion-check.md" > "$SCRATCH/blocks/address-step11-watch.sh"
test -s "$SCRATCH/blocks/address-step11-watch.sh"

# Interpret pointer ordering, rather than comparing an exact paragraph.
# Each emitted action executes a real block and produces target/policy evidence.
pointers() {
  local kind="$1" file="$2"
  awk -v kind="$kind" '
    /^## / {
      if ((kind=="address" && $0=="## Entry and Durable State") ||
          (kind=="e2e" && $0=="## Setup and Durable State") ||
          (kind=="owner" && $0=="## Arguments and Owner State")) active=1
      else if (active && ((kind=="address" && $0=="## Step 2: Fetch Feedback") ||
                          (kind=="e2e" && $0=="## Standalone and Embedded Ownership") ||
                          (kind=="owner" && $0=="## Phase 1: Implementation"))) active=0
    }
    active { text=text " " $0 }
    END {
      if (kind=="address") {
        names[1]="restore"; patterns[1]="Restore and validate target"
        names[2]="context"; patterns[2]="setup-and-discovery.md"
        names[3]="policy"; patterns[3]="lib/validation-policy.md"
        names[4]="route"; patterns[4]="Phase routing"; count=4
      } else if (kind=="e2e") {
        names[1]="bootstrap"; patterns[1]="Bootstrap Block"
        names[2]="restore"; patterns[2]="Restore resume context"
        names[3]="persist"; patterns[3]="Persist Arguments Block"
        names[4]="policy"; patterns[4]="lib/validation-policy.md"
        names[5]="route"; patterns[5]="Re-entry Check"; count=5
      } else {
        names[1]="restore"; patterns[1]="Restore and validate[[:space:]]+target"
        names[2]="policy"; patterns[2]="lib/validation-policy.md"
        names[3]="route"; patterns[3]="Phase routing"; count=3
      }
      for (i=1;i<=count;i++) {
        positions[i]=match(text,patterns[i])
        if (!positions[i]) { print "Missing execution pointer: " names[i] > "/dev/stderr"; exit 1 }
      }
      for (n=1;n<=count;n++) {
        next_index=0
        for (i=1;i<=count;i++) if (positions[i] && (!next_index || positions[i]<positions[next_index])) next_index=i
        print names[next_index]; positions[next_index]=0
      }
    }
  ' "$ROOT/$file"
}
pointers address skills/address-review/SKILL.md > "$SCRATCH/evidence/address-actions.txt"
pointers e2e skills/e2e-verify/SKILL.md > "$SCRATCH/evidence/e2e-actions.txt"
pointers owner skills/complete-issue/SKILL.md > "$SCRATCH/evidence/owner-actions.txt"

source "$ROOT/lib/loop-state.sh"
github_pr() {
  printf 'metadata:%s:%s\n' "$PWD" "$1" >> "$EVENTS"
  printf '{"number":%s,"head":{"sha":"%s","ref":"feature/prci","repo":{"full_name":"test/resume"}},"base":{"ref":"dev","repo":{"full_name":"test/resume","name":"resume","owner":{"login":"test"}}}}' "$1" "$TARGET_HEAD"
}
gh() {
  test "$1" = api
  if [ "$2" = graphql ]; then
    if [ "$FEEDBACK" = new ] && [ "$THREAD_RESOLVED" = false ]; then
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread-new","isResolved":false,"path":"check.test.ts","line":3,"comments":{"nodes":[{"body":"New actionable fixture feedback","author":{"login":"test-bot"}}]}}]}}}}}'
    else
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
    fi
  else
    printf 'test/resume'
  fi
}
github_watch_pr_checks() {
  printf 'watch:%s:%s\n' "$PWD" "$2" >> "$EVENTS"
  test "$PWD" = "$TARGET"
  test "$2" = "$TARGET_HEAD"
  printf '{"items":[{"name":"fixture-check","state":"success","terminal":true,"successful":true}]}'
  return "$WATCH_STATUS"
}
resolve_policy() {
  printf 'policy:%s\n' "$WORKTREE_PATH" >> "$EVENTS"
  if grep -q 'requires current-head PR CI' "$WORKTREE_PATH/AGENTS.md"; then VALIDATION_MODE=pr-ci; else VALIDATION_MODE=local; fi
  set_loop_field "$STATE_FILE" validation_mode "$VALIDATION_MODE" "$WORKFLOW_STATE_PATH"
}
locators() {
  CURRENT_CHECKOUT_ROOT="$PRIMARY"
  RESOLVED_ORIGINAL_REPO_ROOT="$PRIMARY"
  ORIGINAL_REPO_ROOT="$PRIMARY"
  CURRENT_REPO_SLUG=test/resume
  REPO_SLUG=test/resume
  WORKTREE_PATH="$PRIMARY"
  WORKFLOW_STATE_PATH='[]'
  EMBEDDED_WORKFLOW=false
  WORKFLOW_RESULT=''
  WORKFLOW_REASON=''
}
seed() {
  local name="$1" owner="$2" phase="$3" promise="$4"
  jq -n --arg name "$name" --arg owner "$owner" --arg phase "$phase" --arg promise "$promise" --arg primary "$PRIMARY" --arg target "$TARGET" '
    {schema_version:2,owner_workflow:$owner,loop_name:$name,completion_promise:$promise,
     terminal_promises:[$promise,"INCOMPLETE"],phase:$phase,components:{},
     original_repo_root:$primary,worktree_path:$target,repo_slug:"test/resume",
     validation_mode:"local",has_ci:"false",ci_skip_reason:"repository-local-validation-policy",
     bot_review_baseline:"2026-10-01T00:00:00Z"}
  ' > "$STATE_FILE"
}

address_case() (
  locators
  WATCH_STATUS="$1"
  FEEDBACK="$2"
  THREAD_RESOLVED=false
  TARGET_HEAD=$(git -C "$TARGET" rev-parse HEAD)
  EXPECTED_REVIEW_HEAD="$TARGET_HEAD"
  EVENTS="$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.events"
  STATE_FILE="$PRIMARY/.local/state/address-review-7.loop.local.json"
  LOOP_STATE_FILE="$STATE_FILE"
  seed address-review-7 address-review watching COMPLETE
  RESOLVED_PR=7
  WATCH_MODE=true
  while IFS= read -r action; do
    case "$action" in
      restore) source "$SCRATCH/blocks/address-restore.sh" ;;
      context) source "$SCRATCH/blocks/address-context.sh" ;;
      policy) resolve_policy ;;
      route)
        test "$WORKTREE_PATH" = "$TARGET"
        test "$VALIDATION_MODE" = pr-ci
        source "$SCRATCH/blocks/address-baseline.sh"
        test "$BOT_REVIEW_BASELINE" = 2026-10-01T00:00:00Z
        printf 'step2:feedback\n' >> "$EVENTS"
        source "$SCRATCH/blocks/address-feedback.sh" > "$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.feedback.json"
        if [ "$FEEDBACK" = new ]; then
          jq -e '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved == false' "$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.feedback.json" >/dev/null
          printf 'fix:actionable\n' >> "$EVENTS"
          # A synthetic workflow-owned fix commit advances HEAD without touching
          # the fixture product. Completion must use that new head, not resume's.
          git -C "$TARGET" -c user.name=Test -c user.email=test@example.invalid commit -qm 'fixture review fix' --allow-empty
          TARGET_HEAD=$(git -C "$TARGET" rev-parse HEAD)
          THREAD_RESOLVED=true
        fi
        printf 'step5:%s\n' "$WORKTREE_PATH" >> "$EVENTS"
        (cd "$WORKTREE_PATH" && npm run test) > "$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.local.log" 2>&1
        source "$SCRATCH/blocks/address-step7.sh"
        if [ "$CHECK_STATUS" -ne 0 ]; then
          printf 'stopped:step7\n' >> "$EVENTS"
          cp "$STATE_FILE" "$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.state.json"
          return 0
        fi
        printf 'step11\n' >> "$EVENTS"
        source "$SCRATCH/blocks/address-step11-head.sh"
        test -z "$WORKFLOW_REASON"
        source "$SCRATCH/blocks/address-step11-watch.sh"
        test "$CHECK_STATUS" = 0
        printf 'bot-watch\n' >> "$EVENTS"
        ;;
    esac
  done < "$SCRATCH/evidence/address-actions.txt"
  cp "$STATE_FILE" "$SCRATCH/evidence/address-$WATCH_STATUS-$FEEDBACK.state.json"
)
address_case 0 clean > "$SCRATCH/evidence/address-success.log"
address_case 1 clean > "$SCRATCH/evidence/address-failure.log"
address_case 0 new > "$SCRATCH/evidence/address-new-feedback.log"
TARGET_HEAD=$(git -C "$TARGET" rev-parse HEAD)
grep -q '^bot-watch$' "$SCRATCH/evidence/address-0-clean.events"
test "$(grep -c '^watch:' "$SCRATCH/evidence/address-0-clean.events")" = 2
grep -q '^stopped:step7$' "$SCRATCH/evidence/address-1-clean.events"
test "$(grep -c '^watch:' "$SCRATCH/evidence/address-1-clean.events")" = 1
! grep -q '^bot-watch$' "$SCRATCH/evidence/address-1-clean.events"
awk '/^step2:/ { feedback=NR } /^fix:/ { fix=NR } /^step11$/ { completion=NR } END { exit !(feedback>0 && fix>feedback && completion>fix) }' "$SCRATCH/evidence/address-0-new.events"

e2e_case() (
  locators
  local fresh="$1"
  EVENTS="$SCRATCH/evidence/e2e-$fresh.events"
  STATE_FILE="$PRIMARY/.local/state/e2e-test-$fresh.json"
  MODE=verify
  PR_NUM=99
  BUILD_RESULT=''
  E2E_RESULT=''
  PAGES_TESTED=0
  BASE_BRANCH=ambient
  if [ "$fresh" = fresh ]; then
    seed complete-issue-7 complete-issue verifying COMPLETE
    EMBEDDED_WORKFLOW=true
    WORKFLOW_STATE_PATH='["components","e2e_verify"]'
    initialize_workflow_state "$STATE_FILE" "$WORKFLOW_STATE_PATH"
    MODE=fix-and-ship
    PR_NUM=88
  else
    seed e2e-verify-7 e2e-verify shipping VERIFIED
    set_loop_field "$STATE_FILE" mode fix-and-ship '[]'
    set_loop_field "$STATE_FILE" pr_number 7 '[]'
    set_loop_field "$STATE_FILE" build_result pass '[]'
    set_loop_field "$STATE_FILE" e2e_result pass '[]'
    set_loop_json_field "$STATE_FILE" pages_tested 3 '[]'
    set_loop_field "$STATE_FILE" base_branch dev '[]'
  fi
  while IFS= read -r action; do
    case "$action" in
      bootstrap) source "$SCRATCH/blocks/e2e-bootstrap.sh" ;;
      restore) source "$SCRATCH/blocks/e2e-restore.sh" ;;
      persist) source "$SCRATCH/blocks/e2e-persist.sh" ;;
      policy) resolve_policy ;;
      route)
        test "$WORKTREE_PATH" = "$TARGET"
        test "$VALIDATION_MODE" = pr-ci
        source "$SCRATCH/blocks/e2e-route.sh"
        test "$MODE" = fix-and-ship
        if [ "$fresh" = fresh ]; then
          test "$PR_NUM" = 88
          test -z "$PHASE"
          ! grep -q '^metadata:' "$EVENTS"
        else
          test "$PR_NUM" = 7
          test "$BUILD_RESULT" = pass
          test "$E2E_RESULT" = pass
          test "$PAGES_TESTED" = 3
          test "$BASE_BRANCH" = dev
          test "$PHASE" = shipping
          test "$(jq -r '.head.sha' <<< "$PR_JSON")" = "$TARGET_HEAD"
          grep -q "^metadata:$TARGET:7$" "$EVENTS"
        fi
        printf 'route:%s\n' "$PHASE" >> "$EVENTS"
        ;;
    esac
  done < "$SCRATCH/evidence/e2e-actions.txt"
  cp "$STATE_FILE" "$SCRATCH/evidence/e2e-$fresh.state.json"
)
e2e_case resumed > "$SCRATCH/evidence/e2e-resumed.log"
e2e_case fresh > "$SCRATCH/evidence/e2e-fresh.log"

(
  locators
  EVENTS="$SCRATCH/evidence/owner.events"
  STATE_FILE="$PRIMARY/.local/state/owner-test.json"
  seed complete-issue-7 complete-issue verifying COMPLETE
  while IFS= read -r action; do
    case "$action" in
      restore) source "$SCRATCH/blocks/owner-restore.sh" ;;
      policy) resolve_policy ;;
      route)
        test "$WORKTREE_PATH" = "$TARGET"
        test "$VALIDATION_MODE" = pr-ci
        test "$PHASE" = verifying
        printf 'route:verifying\n' >> "$EVENTS"
        ;;
    esac
  done < "$SCRATCH/evidence/owner-actions.txt"
  cp "$STATE_FILE" "$SCRATCH/evidence/owner.state.json"
) > "$SCRATCH/evidence/owner.log"
echo 'resume-target-policy: restored registered target governs policy and routing; resumed gates reject failed CI; E2E restores saved context and preserves fresh embedded arguments'
