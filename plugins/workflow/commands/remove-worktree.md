---
description: "Interactively select and remove a git worktree"
allowed-tools: ["Bash(git:*)", "Bash(gh:*)", "Bash(echo:*)", "Bash(cd:*)", "Bash(grep:*)", "Bash(cat:*)", "Bash(*worktree-state*)", "Read", "AskUserQuestion"]
---

# Remove Worktree

This command interactively removes a single git worktree. Unlike `/prune-worktree` which auto-removes all safe worktrees, this command lets you select a specific worktree and handles cases where the issue isn't closed or branch isn't merged.

**Usage:** `/remove-worktree` (no arguments - interactive selection)

## Clear Worktree State

Clear any active worktree state so the pre-tool-use hook doesn't block cleanup commands:
!`"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-state.sh" clear 2>/dev/null || true`

## Context

- Repository name: !`basename \`git rev-parse --show-toplevel 2>/dev/null\` 2>/dev/null || echo "unknown"`
- Default branch: !`git remote show origin 2>/dev/null | grep 'HEAD branch' | sed 's/.*: //' || echo "main"`
- All worktrees: !`git worktree list 2>&1 || echo "No worktrees found"`
- Issue worktrees: !`git worktree list 2>/dev/null | grep -E "issue-[0-9]+" || echo "No issue worktrees found"`
- Review worktrees: !`git worktree list 2>/dev/null | grep -E "review-pr-[0-9]+" || echo "No review worktrees found"`

---

## Steps

**CRITICAL: When executing bash commands below, use backticks (\`) for command substitution, NOT $(). Claude Code has a bug that mangles $() syntax into broken commands. Copy the commands exactly as written.**

### 1. Get Repository Info

!REPO_NAME=`basename \`git rev-parse --show-toplevel\``
!echo "Repository: $REPO_NAME"

### 2. List Candidate Worktrees

!echo "Scanning for issue and review worktrees..."
!git worktree list

Filter for worktrees matching `{REPO_NAME}-issue-*` or `{REPO_NAME}-review-pr-*` and display them as one numbered list.

!git worktree list | grep -E "/${REPO_NAME}-(issue|review-pr)-[0-9]+" | cat -n

If none are found, inform the user and stop:
"No issue or review worktrees found"

### 3. Ask User to Select Worktree

Use AskUserQuestion to ask: "Which worktree would you like to remove? Enter the number from the list above, or the full path."

Store the selected worktree path and extract:
- `WORKTREE_PATH`: The full path to the worktree
- `BRANCH_NAME`: The branch associated with the worktree

To get branch name:
!BRANCH_NAME=`git worktree list --porcelain | grep -A2 "worktree $WORKTREE_PATH" | grep "branch" | sed 's/branch refs\/heads\///'`
!echo "Branch: $BRANCH_NAME"

**Classify by the branch, not the path** (a repo name or title slug can itself
contain `review-pr-` or `issue-`): a branch matching `review-pr-<digits>`
exactly is a **review worktree** — take `PR_NUM` from it and follow the review
variant in Steps 4–5; anything else is an **issue worktree** — extract
`ISSUE_NUM`:

!ISSUE_NUM=`echo "$WORKTREE_PATH" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'`
!echo "Issue number: $ISSUE_NUM"

For a review worktree:

!PR_NUM=`echo "$BRANCH_NAME" | grep -oE '^review-pr-[0-9]+$' | grep -oE '[0-9]+'`
!echo "PR number: $PR_NUM"

### 4. Check Worktree Status

#### Check for uncommitted changes
!cd "$WORKTREE_PATH" && git status --porcelain

If there are uncommitted changes, warn the user immediately.

#### Validate issue number is numeric (security check)
!if ! echo "$ISSUE_NUM" | grep -qE '^[0-9]+$'; then echo "Error: Could not extract valid issue number"; exit 1; fi

#### Check GitHub issue status
!gh issue view "$ISSUE_NUM" --json state,title --jq '"\(.state): \(.title)"'

#### Detect default branch and check if merged
!DEFAULT_BRANCH=`git remote show origin | grep 'HEAD branch' | sed 's/.*: //' | tr -cd '[:alnum:]-._/'`
!if [ -z "$DEFAULT_BRANCH" ]; then echo "Error: Could not determine default branch"; exit 1; fi
!echo "Default branch: $DEFAULT_BRANCH"
!git fetch origin "$DEFAULT_BRANCH" --quiet
!MERGED=`git branch --merged "origin/$DEFAULT_BRANCH" | grep -F "$BRANCH_NAME" || echo ""`

#### Review worktree variant (branch `review-pr-<n>`)

The branch is local-only and never merges, so the issue/merge checks above do
not apply. Instead check the PR state and the review contract (no local
commits beyond the fetched PR head, no uncommitted changes):

!gh pr view "$PR_NUM" --json state --jq '.state'
!LOCAL_COMMITS=`git -C "$WORKTREE_PATH" rev-list --count "refs/pr-review/${PR_NUM}..HEAD" 2>/dev/null || echo "unknown"`
!echo "Local commits beyond PR head: $LOCAL_COMMITS"

### 5. Determine Safety and Proceed

Evaluate the status:
- `ISSUE_CLOSED`: true if GitHub issue state is "CLOSED"
- `BRANCH_MERGED`: true if branch appears in merged branches
- `HAS_CHANGES`: true if uncommitted changes exist

#### If SAFE (issue closed AND branch merged AND no uncommitted changes):

Display: "This worktree is safe to remove:"
- Issue #$ISSUE_NUM is closed
- Branch '$BRANCH_NAME' is merged into $DEFAULT_BRANCH
- No uncommitted changes

Use AskUserQuestion: "Remove this worktree?"
- Options: "Yes, remove it" / "No, cancel"

If confirmed:
!git worktree remove "$WORKTREE_PATH"
!echo "Worktree removed: $WORKTREE_PATH"

Ask: "Also delete the local branch '$BRANCH_NAME'?"
- Options: "Yes, delete branch" / "No, keep branch"

If confirmed:
!git branch -d "$BRANCH_NAME"

#### Review worktree: safe removal

Safe when the PR state is `MERGED` or `CLOSED`, `LOCAL_COMMITS` is `0`, and
there are no uncommitted changes. Confirm as above, then:

!git worktree remove "$WORKTREE_PATH"
!git branch -D "$BRANCH_NAME"
!git update-ref -d "refs/pr-review/${PR_NUM}"

`-D` is correct here: a `review-pr-<n>` branch never merges, and the zero
local-commit check proved it holds nothing of its own. Anything else (open PR,
local commits, uncommitted changes) follows the NOT SAFE path below.

#### If NOT SAFE (issue open OR branch not merged OR has uncommitted changes):

Display a prominent warning:

```
⚠️  WARNING: This worktree may contain unfinished work!

Status:
- Issue #$ISSUE_NUM: [OPEN/CLOSED]
- Branch merged: [YES/NO]
- Uncommitted changes: [YES/NO]

Removing this worktree could result in PERMANENT DATA LOSS.
This action cannot be undone.
```

Use AskUserQuestion with a serious tone:
"Are you SURE you want to force-remove this worktree? This may delete unfinished work."
- Options:
  - "Yes, I understand the consequences - force remove"
  - "No, cancel and keep the worktree"

**Only if user explicitly confirms force removal:**

!git worktree remove "$WORKTREE_PATH" --force
!echo "Worktree force-removed: $WORKTREE_PATH"

Ask: "Also delete the local branch '$BRANCH_NAME'? (Use -D to force delete unmerged branch)"
- Options: "Yes, force delete branch" / "No, keep branch"

If confirmed:
!git branch -D "$BRANCH_NAME"

### 6. Clear Worktree State

Clear the active worktree state so the pre-tool-use hook stops enforcing path prefixes:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-state.sh" clear
```

### 7. Completion

Display final status:
!echo "Done."
!git worktree list

---

## Why Use This vs /prune-worktree?

| Command | Use Case |
|---------|----------|
| `/prune-worktree` | Batch cleanup of all completed (closed + merged) worktrees |
| `/remove-worktree` | Remove a specific worktree, including abandoned/unfinished ones |

Use `/remove-worktree` when:
- You abandoned work on an issue and want to clean up
- The issue was closed without merging (won't fix, duplicate, etc.)
- You need to remove a specific worktree without affecting others
