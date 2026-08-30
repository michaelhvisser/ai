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
RC_PREV_OP=""; RC_PREV_ONTO=""; RC_PREV_RUN_DIR=""; RC_PREV_BRANCH=""; RC_PREV_EXPECT=""
if [ -f "$RC_STATE_FILE" ]; then
  . "$RC_STATE_FILE"
  RC_PREV_OP="$RC_OP"; RC_PREV_ONTO="$RC_ONTO"; RC_PREV_RUN_DIR="$RC_RUN_DIR"
  RC_PREV_BRANCH="${RC_BRANCH:-}"; RC_PREV_EXPECT="${RC_EXPECT:-}"
fi

RC_PICKS=""
if [ -d "$RC_GIT_DIR/rebase-merge" ] || [ -d "$RC_GIT_DIR/rebase-apply" ]; then
  RC_OP=rebase
  RC_STATE_DIR="$RC_GIT_DIR/rebase-merge"
  [ -d "$RC_STATE_DIR" ] || RC_STATE_DIR="$RC_GIT_DIR/rebase-apply"
  RC_ONTO=$(cat "$RC_STATE_DIR/onto")            # the new base
  RC_ORIG_HEAD=$(cat "$RC_STATE_DIR/orig-head")  # the branch tip before the rebase began
  # The commits being replayed, read from the rebase's own state. Merge
  # backend: pick lines from done + git-rebase-todo. Apply backend: each
  # generated patch opens with "From <sha>". No single "replay base" range
  # can substitute for this list — --onto excludes commits a merge-base
  # range would include, a reordered interactive todo breaks
  # first-pick-parent arithmetic, and merged side-branch history breaks
  # patch counting.
  if [ -f "$RC_STATE_DIR/git-rebase-todo" ] || [ -f "$RC_STATE_DIR/done" ]; then
    RC_PICKS=$(cat "$RC_STATE_DIR/done" "$RC_STATE_DIR/git-rebase-todo" 2>/dev/null \
      | awk '/^(pick|edit|reword|fixup|squash) /{print $2}')
  else
    RC_PICKS=$(awk '/^From [0-9a-f]{40}/{print $2}' "$RC_STATE_DIR"/[0-9]* 2>/dev/null)
  fi
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
elif [ "$RC_OP" = merge ]; then
  # Everything the branch changed relative to the incoming side. This is the
  # reviewed work that must survive resolution.
  git diff "$RC_ONTO...$RC_ORIG_HEAD" > "$RC_RUN_DIR/ours-before.diff"
else
  # rebase and cherry-pick: ONE BASELINE PER REPLAYED COMMIT, all captured at
  # the first stop. Later commits may apply cleanly and never re-enter this
  # step, and Step 6's supersession proof needs their baselines too. For a
  # cherry-pick the set is the current commit plus every pick still in the
  # sequencer (picks completed before the first stop landed before RC_ONTO
  # and are outside the integrity check's scope).
  if [ "$RC_OP" = cherry-pick ]; then
    RC_PICKS="$RC_ORIG_HEAD $(awk '/^pick /{print $2}' "$RC_GIT_DIR/sequencer/todo" 2>/dev/null)"
  fi
  if [ -z "$RC_PICKS" ]; then
    # No readable pick state — last resort for a rebase: the merge-base range.
    git diff "$(git merge-base "$RC_ONTO" "$RC_ORIG_HEAD")" "$RC_ORIG_HEAD" \
      > "$RC_RUN_DIR/ours-before.diff"
  fi
  # while-read, not `for x in $VAR`: zsh does not word-split an unquoted
  # variable, and these blocks run under the user's shell.
  printf '%s\n' "$RC_PICKS" | while IFS= read -r RC_P; do
    [ -n "$RC_P" ] || continue
    RC_P=$(git rev-parse "$RC_P")
    RC_OUT="$RC_RUN_DIR/ours-before-$(git rev-parse --short "$RC_P").diff"
    if git rev-parse -q --verify "${RC_P}^2" >/dev/null 2>&1; then
      # A merge commit being picked: ^1 is NOT automatically the right base —
      # the pick was started with -m <n>, and for a single pick git records
      # <n> nowhere. Determine it from the command the caller actually ran
      # (missing intent if unknowable) and write the baseline by hand:
      # git diff "<sha>^<n>" "<sha>" > "$RC_OUT"
      echo "MAINLINE_NEEDED: $RC_P — baseline requires the -m parent number"
    elif git rev-parse -q --verify "${RC_P}~1" >/dev/null 2>&1; then
      git diff "${RC_P}~1" "$RC_P" > "$RC_OUT"
    else
      # Root commit: no parent; a failed ~1 lookup would leave an EMPTY
      # baseline that Step 6 vacuously passes. Its entire content is the change.
      git show --format= "$RC_P" > "$RC_OUT"
    fi
  done
fi

# The push lease is captured at the FIRST stop, before any resolution work:
# a background fetch during a long resolution (an IDE, a daemon) advances the
# remote-tracking ref, and a lease value read later would rubber-stamp
# exactly the push the lease exists to refuse. On re-entry the first stop's
# captured value wins — never re-read it.
if [ "$RC_PREV_OP" = "$RC_OP" ] && [ -n "$RC_PREV_BRANCH" ]; then
  RC_BRANCH="$RC_PREV_BRANCH"; RC_EXPECT="$RC_PREV_EXPECT"
else
  if [ "$RC_OP" = rebase ] && [ -f "$RC_STATE_DIR/head-name" ]; then
    RC_BRANCH=$(sed 's#^refs/heads/##' "$RC_STATE_DIR/head-name")
  else
    RC_BRANCH=$(git symbolic-ref --quiet --short HEAD) || RC_BRANCH=""
  fi
  RC_EXPECT=""
  [ -n "$RC_BRANCH" ] \
    && { RC_EXPECT=$(git rev-parse -q --verify "refs/remotes/origin/${RC_BRANCH}") || RC_EXPECT=""; }
fi

# Fenced blocks may execute as separate shell calls and inherit nothing, and
# by Step 6 the operation state dirs are gone — persist what later steps need.
[ "$RC_OP" = none ] || printf 'RC_OP=%s\nRC_ONTO=%s\nRC_ORIG_HEAD=%s\nRC_RUN_DIR=%s\nRC_BRANCH=%s\nRC_EXPECT=%s\n' \
  "$RC_OP" "$RC_ONTO" "$RC_ORIG_HEAD" "$RC_RUN_DIR" "$RC_BRANCH" "$RC_EXPECT" > "$RC_STATE_FILE"
```

When `RC_OP=none`, stop: there is nothing to resolve. Do not start a merge or rebase on
the skill's own authority — which operation, onto what, is the caller's decision.

A `MAINLINE_NEEDED` line means a replayed **merge commit**'s baseline could not be derived
mechanically: recover the `-m <n>` parent number from the command the caller actually ran
(`sequencer/opts` may record it for a multi-pick sequence; otherwise it is a missing-intent
question), then write `git diff "<sha>^<n>" "<sha>"` to the named baseline file before
continuing past Step 0.

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

Only after the operation fully completes. **First, run Step 4's checks once more against
the finished tree**: when commits after the resolved stop applied cleanly, the earlier
check run saw only an intermediate state, and a cleanly-applied later commit can still
break the build against the resolution. Then:

```bash
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
[ -f "$RC_STATE_FILE" ] && . "$RC_STATE_FILE"

git diff "$RC_ONTO"..HEAD > "$RC_RUN_DIR/ours-after.diff"
```

Compare every `ours-before*.diff` (one file for a merge; one per replayed commit for a
rebase or cherry-pick) against `ours-after.diff`. Every hunk present before and absent
after must be one of:

1. **An identical change already on the incoming side** — confirm with
   `git log -S'<vanished text>' --oneline "$RC_ONTO"` or by reading the incoming commit.
2. **A deliberate drop recorded in Step 3's trade-offs.**
3. **Superseded inside the replayed series itself** — a later replayed commit (in the
   cherry-pick sequence or the rebase todo) modified or removed what an earlier one
   introduced, so the transient hunk is rightly absent from the net result. Prove it by
   pointing at the later `ours-before-<sha>.diff` that touches the same lines; the
   series' **net** effect is what must survive, not each intermediate state.

Anything else is a lost reviewed change: reopen the resolution and restore it before
declaring done. This check is the completion criterion for the whole skill — "the rebase
continued to the end" is not.

## Step 7 — Report and hand back

Report to the driver: files resolved; the intent-vs-intent rationale for every non-trivial
hunk; recorded trade-offs and deliberate drops; checks run with results; the integrity
verdict. Then, only if the branch already exists on the remote and the operation rewrote
history:

```bash
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
[ -f "$RC_STATE_FILE" ] && . "$RC_STATE_FILE"
git push --force-with-lease="${RC_BRANCH}:${RC_EXPECT}" origin "$RC_BRANCH"
```

Never plain `--force`, and never `git fetch` before this push. The lease value comes from
the state file, captured at the **first stop of the operation** (Step 0): a bare
`--force-with-lease`, or a lease read at push time, uses whatever the remote-tracking ref
holds *now* — and any fetch in between (this skill's, an IDE's, a daemon's) refreshes it
into a rubber stamp. The pinned `<branch>:<expected>` lease means: overwrite only what
this repository had seen before resolution began. A rejected push means the remote really
did move: stop and surface it to the driver; re-fetching and retrying on the skill's own
authority is exactly the overwrite the lease exists to prevent. This skill does not
merge, open PRs, or move board items; hand those to the calling workflow.

Finally, remove the state file so a future run cannot inherit a finished operation's
facts: `rm -f "$(git rev-parse --git-dir)/resolve-conflicts.state"`.
