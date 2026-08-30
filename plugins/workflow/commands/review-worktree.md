---
argument-hint: "<pr-number> [<pr-number>...]"
description: "Check out one or more PRs at their head commits in review worktrees, install deps, and open them in Cursor"
allowed-tools: ["Bash(*worktree-create.sh*)", "Bash(pwd:*)", "Bash(git:*)", "Bash(gh:*)", "Bash(pnpm:*)", "Bash(npm:*)", "Bash(yarn:*)", "Bash(bun:*)", "Bash(env:*)", "Bash(command:*)", "Bash(open:*)", "Read", "AskUserQuestion"]
---

# Review Worktrees for PRs

**If `$ARGUMENTS` is empty or not provided:**

This command checks out one or more PRs at their **head commits** in isolated
review worktrees, installs dependencies, and opens each in Cursor.

**Usage:** `/review-worktree <pr-number> [<pr-number>...]`

Ask the user: "Which PR number(s) would you like to review?"

---

**If `$ARGUMENTS` is provided:**

Read `${CLAUDE_PLUGIN_ROOT}/skills/worktree/review.md` and follow its
procedure for every PR number in `$ARGUMENTS`, with these defaults:

- **Editor**: open each worktree in Cursor (Step 5) unless the user said not
  to. Always launch through the env-stripped wrapper in the procedure.
- **Env files**: ask once (Step 2) and apply the answer to all PRs in this
  invocation.
- **Deps**: install per Step 4 before opening the editor.

Finish with the Step 6 report — one line per PR: path, branch, head commit,
diff stat vs base.

Cleanup later is `/remove-worktree` or `/prune-worktree`.
