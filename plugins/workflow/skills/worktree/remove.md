# Worktree — Remove

Interactively select and safely remove a single git worktree. Loaded by `SKILL.md` when the user wants to delete a specific worktree.

## Usage

User-facing slash command: `/remove-worktree` (interactive, no args). Skill invocation: `$workflow:worktree remove`.

## Steps

### Step 1: List Worktrees

```bash
git worktree list
```

Filter for issue worktrees (matching `*-issue-*`) and review worktrees
(matching `*-review-pr-*`). If none found, inform the user and stop.

### Step 2: Select Worktree

If the request, current path, or issue/PR context identifies exactly one
worktree, select it. If multiple worktrees remain equally valid, follow the
shared **missing-intent gate**: list them, request the target, and stop before
removal.

### Step 3: Safety Checks

The checks differ by worktree kind — classify from the path first.

**Issue worktree** (`*-issue-*`):

1. **Issue status**: Is the linked issue closed?
   ```bash
   ISSUE_NUM=$(echo "$WORKTREE_PATH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
   gh issue view "$ISSUE_NUM" --json state --jq '.state'
   ```

2. **Merge status**: Is the branch merged into the default branch?
   ```bash
   DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | sed 's/.*: //')
   BRANCH_NAME=$(cd "$WORKTREE_PATH" && git branch --show-current)
   git branch --merged "$DEFAULT_BRANCH" | grep -q "$BRANCH_NAME"
   ```

3. **Uncommitted changes**: Are there any pending changes?
   ```bash
   cd "$WORKTREE_PATH" && git status --porcelain
   ```

**Review worktree** (`*-review-pr-*`): the branch `review-pr-<n>` is local-only
and never merges, so the merge check does not apply. Instead:

1. **PR status**: Is the reviewed PR merged or closed?
   ```bash
   PR_NUM=$(echo "$WORKTREE_PATH" | grep -oE 'review-pr-([0-9]+)' | grep -oE '[0-9]+')
   gh pr view "$PR_NUM" --json state --jq '.state'   # MERGED or CLOSED = done
   ```

2. **No local commits**: the review contract says the branch holds none beyond
   the fetched PR head; a nonzero count means the contract was broken — stop.
   ```bash
   git -C "$WORKTREE_PATH" rev-list --count "refs/pr-review/${PR_NUM}..HEAD"
   ```

3. **Uncommitted changes**: same as above — `git status --porcelain` must be
   empty.

### Step 4: Confirm and Remove

**Safe removal** (issue worktree: issue closed + branch merged + no uncommitted
changes; review worktree: PR merged/closed + zero local commits + no
uncommitted changes):

Treat the original removal request as authorization for this safe target. State
`Decision`, `Evidence`, and `Rationale`, including the closed issue, merged
branch, and clean status, then remove it without a redundant confirmation.

```bash
git worktree remove "$WORKTREE_PATH"
```

**Unsafe removal** (issue open, branch unmerged, or uncommitted changes):

```
WORKFLOW_RESULT=INCOMPLETE
WORKFLOW_REASON=unsafe-worktree
```

Stop without removing the worktree or deleting either branch. A driver cannot
override unmerged commits, an open issue, or uncommitted changes. Make the
worktree safe first, then rerun the workflow.

### Step 5: Optional Branch Cleanup

Branch deletion is a **missing-intent gate** unless the original request
explicitly included branch cleanup. Request: "Also delete the local and remote
branch `$BRANCH_NAME`?" If structured input is unavailable, ask in the final
response and stop without deleting either branch or claiming branch cleanup.

```bash
git branch -d "$BRANCH_NAME"
git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
```

For a review worktree the branch is local-only (nothing to delete on the
remote) and never merges, so `-d` refuses it; use `-D` — safe here because the
Step 3 checks proved it holds no commits beyond the PR head:

```bash
git branch -D "review-pr-${PR_NUM}"
git update-ref -d "refs/pr-review/${PR_NUM}"
```
