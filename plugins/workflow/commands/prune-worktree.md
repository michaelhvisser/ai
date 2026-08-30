---
description: "Batch cleanup of all completed issue and PR-review worktrees"
allowed-tools: ["Bash(git:*)", "Bash(gh:*)", "Bash(echo:*)", "Bash(basename:*)", "Bash(grep:*)", "Bash(*worktree-state*)", "Read", "AskUserQuestion"]
---

# Prune Worktrees

This command safely removes worktrees whose work is done: issue worktrees for
completed GitHub issues, and review worktrees for merged or closed PRs.

**What it does:**

1. Scans for worktrees matching `{reponame}-issue-*` and `{reponame}-review-pr-*`
2. Issue worktrees: checks the issue status and that the branch merged
3. Review worktrees: checks the PR state and the no-local-commits contract
4. Removes worktrees that pass, cleans up local branches

**Safety checks:**

- Only removes closed issues with merged PRs
- Warns about uncommitted changes
- Provides manual commands for edge cases

**Usage:** `/prune-worktree` (no arguments needed)

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

## Scan and Cleanup

**CRITICAL: When executing bash commands below, use backticks (\`) for command substitution, NOT $(). Claude Code has a bug that mangles $() syntax into broken commands.**

**CRITICAL: Before removing any worktree, first cd to the main repository directory.** This prevents CWD invalidation errors if running from a worktree that will be removed:

!cd `git worktree list | head -1 | awk '{print $1}'`

First, get the repository name:

!REPO_NAME=`basename \`git rev-parse --show-toplevel\``
!echo "Repository: $REPO_NAME"

List all worktrees:

!git worktree list

Classify each candidate worktree by its **checked-out branch**
(`git -C "$WORKTREE_PATH" branch --show-current`) — a repo name or title slug
can itself contain `review-pr-` or `issue-`. A branch matching
`review-pr-<digits>` exactly is a review worktree; otherwise treat a
`{REPO_NAME}-issue-*` path as an issue worktree.

For each **issue worktree**:

1. Extract issue number from directory name using: `grep -oE '[0-9]+'`
2. **Validate issue number is numeric** (security: prevent command injection)
3. Check GitHub issue status: `gh issue view "$ISSUE_NUM" --json state`
4. Check if branch is merged: `git branch --merged "$DEFAULT_BRANCH" | grep -F "$BRANCH_NAME"`
5. If issue is closed AND branch is merged, offer to remove

For each **review worktree** (the branch never merges, so the merged check
does not apply):

1. Take the PR number from the branch: `PR_NUM` is `review-pr-<n>` minus the prefix (validate numeric)
2. Check PR state: `gh pr view "$PR_NUM" --json state` — `MERGED` or `CLOSED` = done
3. Check the review contract held: `git -C "$WORKTREE_PATH" rev-list --count "refs/pr-review/${PR_NUM}..HEAD"` is `0` and `git -C "$WORKTREE_PATH" status --porcelain` is empty
4. If all pass, offer to remove; cleanup uses `git branch -D "review-pr-${PR_NUM}"` (never merges, proven empty) and `git update-ref -d "refs/pr-review/${PR_NUM}"`

**Security note:** Always validate extracted issue/PR numbers are numeric before using in gh commands, and quote all variables in shell commands.

## Safety Features

- **Changes to main repo before removing worktrees** (prevents CWD errors if running from a worktree being removed)
- Only processes worktrees following issue naming convention
- Verifies GitHub issue exists and is closed
- Confirms branch is merged into dev branch
- Checks for uncommitted changes
- Requires user confirmation before deletion
- Offers optional branch cleanup

## Manual Cleanup Commands

**IMPORTANT**: When showing cleanup for closed but unmerged issues, display these commands:

```bash
git worktree remove "/path/to/worktree"
git branch -D "branch-name"
```

## Worktree State Cleanup

After removing worktrees, clear the active worktree state so the pre-tool-use hook stops enforcing path prefixes:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-state.sh" clear
```

## Manual Override

If you need to force remove a worktree:

```bash
git worktree remove <path> --force
git branch -D <branch-name>  # if needed
```
