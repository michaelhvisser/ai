# Worktree — Prune

Batch cleanup of all git worktrees whose work is done: issue worktrees for closed issues with merged branches, and review worktrees for merged or closed PRs. Loaded by `SKILL.md` when the user wants to clean up multiple worktrees at once.

## Usage

User-facing slash command: `/prune-worktree` (no args). Skill invocation: `$workflow:worktree prune`.

## Steps

### Step 1: List All Candidate Worktrees

```bash
git worktree list | grep -E "issue-|review-pr-" || echo "No issue or review worktrees found"
```

If none found, inform the user and stop.

### Step 2: Check Default Branch

```bash
DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | sed 's/.*: //')
git fetch origin "$DEFAULT_BRANCH"
```

### Step 3: Evaluate Each Worktree

Classify each worktree by its **checked-out branch**, not its path — a repo
name, ancestor directory, or PR title slug can itself contain `review-pr-<n>`
or `issue-`, so path matching can mis-derive the number:

```bash
WT_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current)
```

A branch matching `review-pr-<digits>` exactly is a review worktree; otherwise
treat a `*-issue-*` path as an issue worktree.

For each **issue worktree**:

1. Extract the issue number from the path:
   ```bash
   ISSUE_NUM=$(echo "$WORKTREE_PATH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
   ```

2. Check if the issue is closed:
   ```bash
   STATE=$(gh issue view "$ISSUE_NUM" --json state --jq '.state' 2>/dev/null)
   ```

3. Check if the branch is merged:
   ```bash
   BRANCH=$(cd "$WORKTREE_PATH" && git branch --show-current)
   MERGED=$(git branch -r --merged "origin/$DEFAULT_BRANCH" | grep -q "origin/$BRANCH" && echo "true" || echo "false")
   ```

4. Classify as:
   - **Pruneable**: Issue is closed (`STATE` = `CLOSED`) AND branch is merged (`MERGED` = `true`)
   - **Keep**: Issue is open OR branch is not merged

For each **review worktree** (`review-pr-<n>` branches are local-only and never
merge, so the merged check does not apply):

1. Take the PR number from the branch (exact, unlike the path) and check the
   PR state:
   ```bash
   PR_NUM=${WT_BRANCH#review-pr-}
   STATE=$(gh pr view "$PR_NUM" --json state --jq '.state' 2>/dev/null)
   ```

2. Check the review contract held — no local commits beyond the PR head and no
   uncommitted changes:
   ```bash
   LOCAL_COMMITS=$(git -C "$WORKTREE_PATH" rev-list --count "refs/pr-review/${PR_NUM}..HEAD" 2>/dev/null || echo "unknown")
   DIRTY=$(git -C "$WORKTREE_PATH" status --porcelain)
   ```

3. Classify as:
   - **Pruneable**: `STATE` is `MERGED` or `CLOSED` AND `LOCAL_COMMITS` = `0` AND `DIRTY` is empty
   - **Keep**: anything else (an open PR, local commits, or uncommitted changes)

### Step 4: Report and Resolve Cleanup Scope

Display a summary:
- Worktrees to prune (with issue number and status)
- Worktrees to keep (with reason)

The prune request authorizes removal of every worktree classified as
pruneable. State `Decision`, `Evidence`, and `Rationale`, then proceed without a
redundant confirmation.

Deleting the associated branches is optional and therefore a
**missing-intent gate** unless the original request specified it. Request one
branch-cleanup decision for the reported pruneable set. If structured input is
unavailable, ask in the final response and stop before any removal.

### Step 5: Remove Pruneable Worktrees

For each pruneable worktree:

```bash
git worktree remove "$WORKTREE_PATH"
```

Delete a branch with `git branch -d "$BRANCH"` only when branch cleanup was
explicitly authorized. The merge check makes forced deletion unnecessary for
issue branches. A `review-pr-<n>` branch never merges, so `-d` refuses it —
use `git branch -D "review-pr-${PR_NUM}"` (safe: Step 3 proved zero local
commits) and drop its fetch ref with
`git update-ref -d "refs/pr-review/${PR_NUM}"`.

### Step 6: Clean Up Stale Entries

```bash
git worktree prune
```

Report what was removed and what remains.
