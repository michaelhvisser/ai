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
RC_STATE_FILE="$RC_GIT_DIR/resolve-conflicts.state"
# Load any previous run's state into PREV_* only — it is trusted further down
# strictly when its operation matches the one detected NOW. An --abort leaves
# this file behind, and a later, different operation must not inherit it.
RC_PREV_OP=""; RC_PREV_ONTO=""; RC_PREV_RUN_DIR=""
if [ -f "$RC_STATE_FILE" ]; then
  . "$RC_STATE_FILE"
  RC_PREV_OP="$RC_OP"; RC_PREV_ONTO="$RC_ONTO"; RC_PREV_RUN_DIR="$RC_RUN_DIR"
fi

RC_BASE=""
if [ -d "$RC_GIT_DIR/rebase-merge" ] || [ -d "$RC_GIT_DIR/rebase-apply" ]; then
  RC_OP=rebase
  RC_STATE_DIR="$RC_GIT_DIR/rebase-merge"
  [ -d "$RC_STATE_DIR" ] || RC_STATE_DIR="$RC_GIT_DIR/rebase-apply"
  RC_ONTO=$(cat "$RC_STATE_DIR/onto")            # the new base
  RC_ORIG_HEAD=$(cat "$RC_STATE_DIR/orig-head")  # the branch tip before the rebase began
  # Replay base = the first picked commit's parent. A plain rebase replays
  # merge-base..orig-head, but `git rebase --onto NEW UPSTREAM` replays only
  # UPSTREAM..orig-head — a merge-base three-dot diff would drag the commits
  # the command deliberately excluded into the baseline, and Step 6 would
  # then demand they survive. Merge backend: read the pick list. Apply
  # backend (`--apply`) has no pick list, but `last` counts the patch series
  # format-patch generated over UPSTREAM..orig-head, and that series is
  # linear, so orig-head~last is UPSTREAM. Merge-base is the last resort.
  RC_BASE=""
  if [ -f "$RC_STATE_DIR/git-rebase-todo" ] || [ -f "$RC_STATE_DIR/done" ]; then
    RC_FIRST_PICK=$(cat "$RC_STATE_DIR/done" "$RC_STATE_DIR/git-rebase-todo" 2>/dev/null \
      | grep -m1 -E '^(pick|edit|reword|fixup|squash) ' | awk '{print $2}')
    [ -n "$RC_FIRST_PICK" ] \
      && RC_BASE=$(git rev-parse -q --verify "${RC_FIRST_PICK}^" 2>/dev/null) \
      || RC_BASE=""
  elif [ -f "$RC_STATE_DIR/last" ]; then
    RC_LAST=$(cat "$RC_STATE_DIR/last")
    RC_BASE=$(git rev-parse -q --verify "${RC_ORIG_HEAD}~${RC_LAST}" 2>/dev/null) || RC_BASE=""
  fi
  [ -n "$RC_BASE" ] || RC_BASE=$(git merge-base "$RC_ONTO" "$RC_ORIG_HEAD")
elif [ -f "$RC_GIT_DIR/MERGE_HEAD" ]; then
  RC_OP=merge
  RC_ONTO=$(git rev-parse MERGE_HEAD)            # the incoming tip
  RC_ORIG_HEAD=$(git rev-parse HEAD)             # our tip
elif [ -f "$RC_GIT_DIR/CHERRY_PICK_HEAD" ]; then
  RC_OP=cherry-pick
  # HEAD at the FIRST stop of the sequence, restored from prior state only
  # when that state came from a cherry-pick too, so Step 6's after-diff spans
  # every picked commit — but a leftover file from an aborted rebase or merge
  # cannot smuggle its RC_ONTO in.
  if [ "$RC_PREV_OP" = cherry-pick ] && [ -n "$RC_PREV_ONTO" ]; then
    RC_ONTO="$RC_PREV_ONTO"
  else
    RC_ONTO=$(git rev-parse HEAD)
  fi
  RC_ORIG_HEAD=$(git rev-parse CHERRY_PICK_HEAD) # the commit being replayed
else
  RC_OP=none
  # No operation, but a state file exists: it is leftover from an aborted or
  # finished run — remove it so it cannot poison the next operation.
  rm -f "$RC_STATE_FILE"
fi

# Re-entrant: a rebase stopping on a later commit, or a multi-commit
# cherry-pick, re-runs this step — keep the same-operation run dir so the
# captured baselines accumulate in one place; a different operation starts
# fresh.
if [ "$RC_PREV_OP" = "$RC_OP" ] && [ -n "$RC_PREV_RUN_DIR" ] && [ -d "$RC_PREV_RUN_DIR" ]; then
  RC_RUN_DIR="$RC_PREV_RUN_DIR"
else
  RC_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/resolve-conflicts.XXXXXX")
fi

if [ "$RC_OP" = none ]; then
  echo "WORKFLOW_RESULT=INCOMPLETE"
  echo "WORKFLOW_REASON=no-operation-in-progress"
elif [ "$RC_OP" = cherry-pick ]; then
  # Only the picked commit's own change. A three-dot diff would reach back to
  # the merge base and drag every unselected branch-only ancestor into the
  # baseline, which Step 6 would then report as "lost". Per-commit filename so
  # a multi-commit pick accumulates one baseline per stop, idempotently.
  git diff "${RC_ORIG_HEAD}~1" "$RC_ORIG_HEAD" \
    > "$RC_RUN_DIR/ours-before-$(git rev-parse --short "$RC_ORIG_HEAD").diff"
elif [ "$RC_OP" = rebase ]; then
  # Only the commits actually being replayed (RC_BASE handles --onto, where
  # the merge base and the replay base differ).
  git diff "$RC_BASE" "$RC_ORIG_HEAD" > "$RC_RUN_DIR/ours-before.diff"
else
  # merge: everything the branch changed relative to the incoming side. This
  # is the reviewed work that must survive resolution.
  git diff "$RC_ONTO...$RC_ORIG_HEAD" > "$RC_RUN_DIR/ours-before.diff"
fi

# Fenced blocks may execute as separate shell calls and inherit nothing, and
# by Step 6 the operation state dirs are gone — persist what later steps need.
[ "$RC_OP" = none ] || printf 'RC_OP=%s\nRC_ONTO=%s\nRC_ORIG_HEAD=%s\nRC_RUN_DIR=%s\n' \
  "$RC_OP" "$RC_ONTO" "$RC_ORIG_HEAD" "$RC_RUN_DIR" > "$RC_STATE_FILE"
```

When `RC_OP=none`, stop: there is nothing to resolve. Do not start a merge or rebase on
the skill's own authority — which operation, onto what, is the caller's decision.

**Every later block that uses an `RC_*` variable begins with this loader** — repeat it
rather than assuming shell state survived from Step 0:

```bash
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
[ -f "$RC_STATE_FILE" ] && . "$RC_STATE_FILE"
```

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
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
[ -f "$RC_STATE_FILE" ] && . "$RC_STATE_FILE"

# --merge needs MERGE_HEAD: it fails during a rebase or cherry-pick, where the
# two --not commands below cover both sides on their own.
[ "$RC_OP" = merge ] && git log --merge --oneline -- <file>  # both sides, merge only
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
  operation itself — and then also remove
  `$(git rev-parse --git-dir)/resolve-conflicts.state`, so the abandoned run's facts
  cannot leak into a later operation (Step 0 additionally refuses mismatched state on
  load).

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
`RC_ORIG_HEAD` do not change mid-rebase). A multi-commit cherry-pick also stops per
commit, but there `CHERRY_PICK_HEAD` moves: loop back to **Step 0** at each stop, so the
per-commit baseline tracks the commit actually being replayed (the shared run dir
accumulates them). During a rebase always use `--continue`, never a plain `git commit`.

## Step 6 — Integrity check

Only after the operation fully completes:

```bash
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
[ -f "$RC_STATE_FILE" ] && . "$RC_STATE_FILE"

git diff "$RC_ONTO"..HEAD > "$RC_RUN_DIR/ours-after.diff"
```

Compare every `ours-before*.diff` (one file for a merge or rebase; one per picked commit
for a cherry-pick) against `ours-after.diff`. Every hunk present before and absent
after must be one of:

1. **An identical change already on the incoming side** — confirm with
   `git log -S'<vanished text>' --oneline "$RC_ONTO"` or by reading the incoming commit.
2. **A deliberate drop recorded in Step 3's trade-offs.**
3. **Cherry-pick only: superseded inside the picked series itself** — a later picked
   commit modified or removed what an earlier one introduced, so the transient hunk is
   rightly absent from the net result. Prove it by pointing at the later
   `ours-before-<sha>.diff` that touches the same lines; the series' **net** effect is
   what must survive, not each intermediate state.

Anything else is a lost reviewed change: reopen the resolution and restore it before
declaring done. This check is the completion criterion for the whole skill — "the rebase
continued to the end" is not.

## Step 7 — Report and hand back

Report to the driver: files resolved; the intent-vs-intent rationale for every non-trivial
hunk; recorded trade-offs and deliberate drops; checks run with results; the integrity
verdict. Then, only if the branch already exists on the remote and the operation rewrote
history:

```bash
RC_EXPECT=$(git rev-parse -q --verify "refs/remotes/origin/<branch>") || RC_EXPECT=""
git push --force-with-lease="<branch>:${RC_EXPECT}" origin <branch>
```

Never plain `--force`, and never `git fetch` before this push: fetching refreshes the
remote-tracking ref, and a bare `--force-with-lease` then uses that just-fetched value as
its expectation — a contributor's push made during the resolution would be silently
overwritten. The explicit `<branch>:<expected>` lease pins the expectation to what this
repository last saw **before** the operation. A rejected push means the remote really did
move: stop and surface it to the driver; re-fetching and retrying on the skill's own
authority is exactly the overwrite the lease exists to prevent. This skill does not
merge, open PRs, or move board items; hand those to the calling workflow.

Finally, remove the state file so a future run cannot inherit a finished operation's
facts: `rm -f "$(git rev-parse --git-dir)/resolve-conflicts.state"`.
