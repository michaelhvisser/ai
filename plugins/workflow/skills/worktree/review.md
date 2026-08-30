# Worktree — Review

Create (or refresh) a review worktree checked out at a PR's **head commit**,
install its dependencies, and open it in an editor. Loaded by `SKILL.md` when
the user wants to review one or more PRs locally.

This is deliberately different from `create.md`: that flow is issue-oriented
and branches from the default branch (no PR code). A review needs the head ref
so `git diff origin/<default>...HEAD` is the actual change set.

## Usage

User-facing slash command: `/review-worktree <pr-number> [<pr-number>...]`.
Skill invocation: `$workflow:worktree review`.

## Steps

### Step 1: Capture Input

Collect one or more PR numbers. If none is available from the request, follow
the shared **missing-intent gate**: request the PR number(s) and stop.

Bare numbers only — extract the number from a pasted PR URL.

### Step 2: Check for Environment Files (once)

```bash
SOURCE_DIR="$(pwd)"
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-create.sh" env-files --source-dir "$SOURCE_DIR"
```

If the output starts with `ENV_FILES_FOUND=true`, follow the shared
**missing-intent gate**: ask once — "Found environment files that may contain
secrets. Copy them to the review worktree(s)?" — and apply the answer to every
PR in this invocation. Never infer consent. If the user has already granted
env-copy consent for review worktrees earlier in the same session, reuse it.

### Step 3: Create or Refresh Each Review Worktree

For each PR number:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-create.sh" review "<pr-number>" --source-dir "$SOURCE_DIR" --copy-env   # or --no-copy-env
```

The script:

- force-fetches `refs/pull/<num>/head` into a local `refs/pr-review/<num>`
  ref — this works for cross-repository (fork) PRs and PRs whose head branch
  was deleted, where `origin/<headRef>` does not exist
- creates `../<reponame>-review-pr-<num>-<title-slug>/` on a **local**
  branch `review-pr-<num>` started from that ref — it never checks out the
  PR's own branch, which may already be claimed by an agent daemon's workpad
  or another worktree
- on reuse (keyed on the stable `review-pr-<num>` branch, so a changed PR
  title still finds it), re-fetches and follows the PR head — a clean tree
  sitting exactly at the previously fetched head moves even across a
  force-push; re-run the skill to pick up rework commits, there is no
  `git pull` upstream; anything else prints `WORKTREE_STALE` (local or
  diverged commits) or `WORKTREE_DIRTY` (uncommitted changes) and is left
  untouched — surface that to the user instead of resetting
- prints `PR_STATE_WARNING` when the PR is merged or closed — still usable,
  but tell the user

Read `Worktree absolute path:` from the output for each PR.

**A `WORKTREE_STALE` or `WORKTREE_DIRTY` line stops the flow for that PR
here.** The tree holds local commits, uncommitted changes, or diverged history
the script refused to touch, so do not install dependencies into it or open it
in an editor as if it showed the PR head. Report the line and follow the
missing-intent gate: review the tree anyway, reset it by hand, or skip this
PR. (A clean worktree sitting exactly at the previously fetched head is moved
automatically, force-pushes included.)

### Step 4: Install Dependencies

**Trust gate first.** The worktree now contains code the PR author controls, and
installing dependencies executes that PR's lifecycle scripts with your local
permissions — in a directory where Step 2 may just have copied secret-bearing
env files. Classify before installing:

```bash
gh pr view "<pr-number>" --json isCrossRepository,author --jq '{fork: .isCrossRepository, author: .author.login}'
```

- **Same-repository PR** (`fork: false`) — the author has push access to this
  repo already; install normally.
- **Fork PR** (`fork: true`) — untrusted by default. This is missing intent
  (`lib/decision-gates.md`): ask whether to install with lifecycle scripts
  disabled (`npm install --ignore-scripts`, `pnpm install --ignore-scripts`,
  `yarn install --mode=skip-build` on Yarn Berry / `--ignore-scripts` on
  classic v1, `bun install --ignore-scripts`), install
  normally because the user vouches for this author, or skip installation.
  When scripts were skipped, say so in the report — packages needing a build
  step may not work until the user opts in.

Then detect the package manager from the worktree's lockfile and install.
**Run every install from inside the worktree** — the shell is still sitting in
the source checkout, so an unscoped install lands in the wrong repository:

```bash
( cd "<worktree-path>" && <install command> )
```

| Lockfile present | Command |
|---|---|
| `pnpm-lock.yaml` | `pnpm install` |
| `package-lock.json` | `npm install` |
| `yarn.lock` | `yarn install` |
| `bun.lockb` / `bun.lock` | `bun install` |
| `go.mod` (no JS lockfile) | nothing — Go resolves on build |

If the repo's agent guidance (`CLAUDE.md`/`AGENTS.md`) prescribes a specific
worktree setup command, prefer it — but never run a setup script that would
overwrite env files the user chose to copy (or not copy) in Step 2.

### Step 5: Open in Editor

If the user asked for an editor (or invoked `/review-worktree`, whose default
is Cursor), launch it with the Claude session markers stripped — a
CLI-launched Electron editor inherits them and every integrated terminal
inside it then treats `claude` as a nested session and disables transcript
saving:

```bash
CURSOR_BIN="$(command -v cursor || echo /Applications/Cursor.app/Contents/Resources/app/bin/cursor)"
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID "$CURSOR_BIN" --new-window "<worktree-path>"
```

If no Cursor binary exists, fall back to `open -a "Cursor" <path>` (macOS,
drops inherited env by re-parenting through launchd), then to skipping the
step with a note. Never fail the whole flow over the editor.

### Step 6: Report

For each PR, report: worktree path, branch, head commit, and the diff stat
against the PR's **freshly fetched** base — the creation script fetches only
`refs/pull/<n>/head`, so `origin/<base>` is whatever the user last fetched and
can misreport the change set. Every command is scoped to the worktree with
`git -C`: the shell is still sitting in the source checkout, and with several
PRs there are several worktrees to report on.

```bash
RV_WT="<worktree-path>"   # the script's "Worktree absolute path:" line
RV_BASE=$(gh pr view "<pr-number>" --json baseRefName --jq .baseRefName)
git -C "$RV_WT" fetch --no-tags origin "$RV_BASE"
git -C "$RV_WT" log --oneline -1
git -C "$RV_WT" diff --stat "origin/${RV_BASE}...HEAD" | tail -1
```

Note any `PR_STATE_WARNING` or `WORKTREE_STALE` lines.

## Contract

- A review worktree holds **no local commits**; never commit or push from
  `review-pr-<num>`. Fixes belong on the PR's real branch via the normal flow.
- Cleanup: `/remove-worktree` or `/prune-worktree` handle
  `<reponame>-review-pr-*` like any other worktree.
