# Review worktrees use a local `review-pr-<n>` branch, never the PR's own branch

`/review-worktree` checks a PR out for local review. The obvious implementation
checks out the PR's head branch; we deliberately do not.

## Why not the PR's branch

- **Double-checkout is refused.** Git allows a branch in exactly one worktree.
  On machines running an agent daemon (Detent), the PR branch is routinely
  already checked out in the daemon's own workpad; claiming it either fails or,
  worse, tramples an active lane.
- **A review worktree must be push-inert.** Reviewing on the real branch makes
  an accidental `git push` land on the PR. A local branch with tracking set to
  `origin/<headRef>` gives `git pull` (follow rework commits) without a
  symmetric safe `git push`.

## Why `review-pr-<n>` and not `review/pr-<n>`

Detent already owns the `review/pr-<n>` branch namespace for its own
auto-created review worktrees. Discovered during the first live test: the
slashed form collided with an existing daemon branch on the first repo tried.
The dash form keeps the namespaces disjoint on any machine running both.

## Consequences

- Reuse fast-forwards to the current head; divergence prints `WORKTREE_STALE`
  and refuses, because a review worktree holds no local commits by contract.
- Fixes discovered during review go through the normal issue/PR flow on the
  real branch, never committed in the review worktree.
