---
name: resolve-conflicts
description: "Resolve an in-progress git merge, rebase, or cherry-pick conflict hunk by hunk on intent: research why each side changed, preserve both intents, verify with the repo's own checks, and prove afterwards that no reviewed change was silently dropped. Use when a merge or rebase stops on conflicts, or when pr-details says rebase and the rebase does not apply cleanly. SKIP when no operation is in progress — start the merge or rebase first, and come back only if it stops."
---

# Resolve Conflicts — finish the operation without losing either side

The failure mode this skill exists to prevent is not the unresolved conflict — git already
blocks on those. It is the silently mis-resolved hunk: a resolution that compiles, merges,
and deletes someone's reviewed change. Every rule below serves two ends: **preserve both
intents**, and **prove afterwards that both survived**.

Steps 1–5 are adapted from `resolving-merge-conflicts` in
[mattpocock/skills](https://github.com/mattpocock/skills) (MIT). The baseline capture
(Step 0) and the integrity check (Step 6) extend it.

Before requesting decisions, read `${CLAUDE_PLUGIN_ROOT}/lib/driver-interaction.md` and
follow its cross-platform capability-binding rules. Read
`${CLAUDE_PLUGIN_ROOT}/lib/decision-gates.md` before resolving any workflow choice.

## Usage

```
/workflow:resolve-conflicts     (Claude Code)
$workflow:resolve-conflicts     (Codex)
```

No arguments: the in-progress operation in the current repository is the target.

## Step 0 — Detect the operation and capture the baseline

```bash
RC_GIT_DIR=$(git rev-parse --git-dir)
RC_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/resolve-conflicts.XXXXXX")

if [ -d "$RC_GIT_DIR/rebase-merge" ] || [ -d "$RC_GIT_DIR/rebase-apply" ]; then
  RC_OP=rebase
  RC_STATE_DIR="$RC_GIT_DIR/rebase-merge"
  [ -d "$RC_STATE_DIR" ] || RC_STATE_DIR="$RC_GIT_DIR/rebase-apply"
  RC_ONTO=$(cat "$RC_STATE_DIR/onto")            # the new base
  RC_ORIG_HEAD=$(cat "$RC_STATE_DIR/orig-head")  # the branch tip before the rebase began
elif [ -f "$RC_GIT_DIR/MERGE_HEAD" ]; then
  RC_OP=merge
  RC_ONTO=$(git rev-parse MERGE_HEAD)            # the incoming tip
  RC_ORIG_HEAD=$(git rev-parse HEAD)             # our tip
elif [ -f "$RC_GIT_DIR/CHERRY_PICK_HEAD" ]; then
  RC_OP=cherry-pick
  RC_ONTO=$(git rev-parse HEAD)
  RC_ORIG_HEAD=$(git rev-parse CHERRY_PICK_HEAD) # the commit being replayed
else
  RC_OP=none
fi

if [ "$RC_OP" = none ]; then
  echo "WORKFLOW_RESULT=INCOMPLETE"
  echo "WORKFLOW_REASON=no-operation-in-progress"
else
  # Everything the branch (or replayed commit) changed relative to the incoming
  # side. This is the reviewed work that must survive resolution.
  git diff "$RC_ONTO...$RC_ORIG_HEAD" > "$RC_RUN_DIR/ours-before.diff"
fi
```

When `RC_OP=none`, stop: there is nothing to resolve. Do not start a merge or rebase on
the skill's own authority — which operation, onto what, is the caller's decision.

**Sides invert between merge and rebase.** Misreading this table is the most common cause
of silently-wrong resolutions, because during a rebase "ours" is *not* your branch:

| Operation | `HEAD` / `--ours` side | `--theirs` / incoming side |
|---|---|---|
| merge | your branch | the branch being merged in |
| rebase | the **new base** (`RC_ONTO`) | **your branch's commit** being replayed |
| cherry-pick | the checked-out branch | the commit being picked |

## Step 1 — Inventory the conflicts

```bash
git status --porcelain=v1 | grep -E '^(DD|AU|UD|UA|DU|AA|UU)'
git diff --name-only --diff-filter=U
```

Classify each file before resolving any:

- **Content conflict (`UU`)** — the normal case; Steps 2–3 apply per hunk.
- **Delete/modify (`DU`/`UD`)** — see the delete/modify rule in Step 3.
- **Both added (`AA`)** — usually two implementations of the same idea; pick by intent,
  never by concatenation.
- **Lockfiles and generated files** — never hand-merge. Resolve the source files first,
  then regenerate (the lockfile via its package manager's install command, generated code
  via its codegen command) and stage the regenerated result.

## Step 2 — Find the primary sources

For each conflicted file, learn why *each side* changed before touching a hunk:

```bash
git log --merge --oneline -- <file>                          # both sides' commits, one list
git log --oneline "$RC_ONTO" --not "$RC_ORIG_HEAD" -- <file> # incoming side only
git log --oneline "$RC_ORIG_HEAD" --not "$RC_ONTO" -- <file> # our side only
```

Read the commit messages. When a commit references a pull request or issue and `gh` is
available for this repo, read that too — the stated goal of each side is what Step 3's
tie-break rule keys on. Do not resolve a hunk whose two intents you cannot yet state.

## Step 3 — Resolve hunk by hunk

- **Preserve both intents where possible.** The usual correct resolution contains both
  changes, ordered so each still does its job — not a choice of one.
- **Where genuinely incompatible, pick by the operation's stated goal** and record the
  trade-off for the final report. A rebase exists to land your branch on the new base:
  the base wins on structure and refactors, the branch wins on the behaviour it was
  reviewed for.
- **Incompatible with no determining goal is a missing-intent gate** (`decision-gates.md`):
  stop and ask the driver. Never guess between two reviewed behaviours.
- **Never resolve a content conflict wholesale** with `git checkout --ours`/`--theirs` —
  per-hunk reading only. The sole exception is a generated file being regenerated.
- **Do not invent new behaviour.** A conflict is never the moment to improve either side;
  out-of-scope improvements go in the report, not the resolution.
- **Delete/modify:** the deletion wins only when the deleting side's commits show the
  functionality moved or became obsolete, *and* the modifying side's change is re-applied
  at the new location. Otherwise the modification wins and the report says why.
- **Never `--abort` because resolution is hard.** Abort only when the driver cancels the
  operation itself.

After resolving each file, confirm no markers remain — run both, since resolved files may
already be staged:

```bash
git diff --check
git diff --cached --check
```

## Step 4 — Verify with the repo's own checks

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/detect-checks.sh"
detect_checks
```

Run the non-empty ones, in order: `CHECK_TYPECHECK`, `CHECK_TEST`, `CHECK_LINT`,
`CHECK_BUILD`. An empty string means the project does not have that check — skip it, it is
not an error. Fix what the *resolution* broke; a failure that exists on either parent
independently of the merge is pre-existing — record it in the report, do not fix it here.

## Step 5 — Finish the operation

```bash
git add <resolved files>
GIT_EDITOR=true git rebase --continue      # rebase
git commit --no-edit                       # merge
GIT_EDITOR=true git cherry-pick --continue # cherry-pick
```

A rebase replays commits one at a time, so a later commit may stop on new conflicts:
loop back to Step 1 for each stop (the Step 0 baseline stays valid — `RC_ONTO` and
`RC_ORIG_HEAD` do not change mid-rebase). During a rebase always use `--continue`, never a
plain `git commit`.

## Step 6 — Integrity check

Only after the operation fully completes:

```bash
git diff "$RC_ONTO"..HEAD > "$RC_RUN_DIR/ours-after.diff"
```

Compare `ours-before.diff` against `ours-after.diff`. Every hunk present before and absent
after must be one of:

1. **An identical change already on the incoming side** — confirm with
   `git log -S'<vanished text>' --oneline "$RC_ONTO"` or by reading the incoming commit.
2. **A deliberate drop recorded in Step 3's trade-offs.**

Anything else is a lost reviewed change: reopen the resolution and restore it before
declaring done. This check is the completion criterion for the whole skill — "the rebase
continued to the end" is not.

## Step 7 — Report and hand back

Report to the driver: files resolved; the intent-vs-intent rationale for every non-trivial
hunk; recorded trade-offs and deliberate drops; checks run with results; the integrity
verdict. Then, only if the branch already exists on the remote and the operation rewrote
history:

```bash
git fetch origin <branch>
git push --force-with-lease origin <branch>
```

Never plain `--force` — `--force-with-lease` after a fetch is what refuses to overwrite a
reviewer's push. This skill does not merge, open PRs, or move board items; hand those to
the calling workflow.
