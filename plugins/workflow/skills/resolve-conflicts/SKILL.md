---
name: resolve-conflicts
description: "Resolve an in-progress git merge, rebase, or cherry-pick conflict hunk by hunk on intent: research why each side changed, preserve both intents, verify with the repo's own checks, and prove afterwards that no reviewed change was silently dropped. Use when a merge, rebase, or cherry-pick stops on conflicts, or when pr-details says rebase and the rebase does not apply cleanly. SKIP when no operation is in progress — start the operation first, and come back only if it stops."
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
# The state file is DATA and is parsed, never sourced: a branch name may
# legally contain shell metacharacters (`git check-ref-format` accepts
# `refs/heads/a;rm -rf ~`), so sourcing the file would execute them.
rc_get() { sed -n "s/^${1}=//p" "$RC_STATE_FILE" 2>/dev/null | head -1; }
# Previous run's state, trusted further down strictly when both the operation
# KIND and the operation IDENTITY match what is detected now — an --abort
# leaves this file behind, and a later operation (even of the same kind) must
# not inherit it.
RC_PREV_OP=""; RC_PREV_ID=""; RC_PREV_ONTO=""; RC_PREV_RUN_DIR=""
if [ -f "$RC_STATE_FILE" ]; then
  RC_PREV_OP=$(rc_get RC_OP); RC_PREV_ID=$(rc_get RC_ID)
  RC_PREV_ONTO=$(rc_get RC_ONTO); RC_PREV_RUN_DIR=$(rc_get RC_RUN_DIR)
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
    # Todo grammar: commands have one-letter aliases (`p`, `f`, …), fixup
    # takes an optional -C/-c before its commit, and `merge -C <sha> <label>`
    # appears under --rebase-merges (that original merge's own content — an
    # evil merge, an embedded resolution — needs a baseline like any pick).
    # `drop`/`d` is deliberately absent: a dropped commit is an intent, not a
    # loss. Skip a leading option, then keep only hex.
    RC_PICKS=$(cat "$RC_STATE_DIR/done" "$RC_STATE_DIR/git-rebase-todo" 2>/dev/null \
      | awk '{
          cmd=$1; sha=""
          if (cmd ~ /^(pick|p|edit|e|reword|r|fixup|f|squash|s)$/) {
            sha=$2; if (sha ~ /^-/) sha=$3
          } else if (cmd ~ /^(merge|m)$/ && $2 ~ /^-[Cc]$/) {
            sha=$3
          }
          if (sha ~ /^[0-9a-f]+$/) print sha
        }')
  else
    RC_PICKS=$(awk '/^From [0-9a-f]{40}/{print $2}' "$RC_STATE_DIR"/[0-9]* 2>/dev/null)
  fi
elif [ -f "$RC_GIT_DIR/MERGE_HEAD" ]; then
  RC_OP=merge
  RC_ONTO=$(git rev-parse MERGE_HEAD)            # the incoming tip
  RC_ORIG_HEAD=$(git rev-parse HEAD)             # our tip
elif [ -f "$RC_GIT_DIR/CHERRY_PICK_HEAD" ]; then
  RC_OP=cherry-pick
  RC_ORIG_HEAD=$(git rev-parse CHERRY_PICK_HEAD) # the commit being replayed
else
  RC_OP=none
  # No operation, but a state file exists: it is leftover from an aborted or
  # finished run — remove it so it cannot poison the next operation.
  rm -f "$RC_STATE_FILE"
fi

# Operation identity: the same KIND is not the same OPERATION — an aborted
# rebase followed by a new rebase must not share baselines. The identity is
# derived from state git itself keeps per operation.
# Identity gates state reuse; the baseline PRUNE further down is what makes a
# false identity match harmless, so no filesystem trivia (inodes recycle on
# APFS) is part of it.
case "$RC_OP" in
  rebase)      RC_ID="${RC_ORIG_HEAD}:${RC_ONTO}" ;;
  merge)       RC_ID="$RC_ONTO" ;;
  cherry-pick)
    if [ -d "$RC_GIT_DIR/sequencer" ]; then
      RC_ID=$(cat "$RC_GIT_DIR/sequencer/head" 2>/dev/null)
    else
      # Single pick: include the target HEAD — the same commit retried after
      # the branch advanced is a different operation with a different RC_ONTO.
      RC_ID="$(git rev-parse CHERRY_PICK_HEAD):$(git rev-parse HEAD)"
    fi ;;
  *)           RC_ID="" ;;
esac

if [ "$RC_OP" = cherry-pick ]; then
  # HEAD at the FIRST stop of the sequence, restored from prior state only
  # when it belongs to THIS sequence, so Step 6's after-diff spans every
  # picked commit — while an aborted earlier operation's RC_ONTO cannot
  # smuggle in.
  if [ "$RC_PREV_OP" = cherry-pick ] && [ "$RC_PREV_ID" = "$RC_ID" ] && [ -n "$RC_PREV_ONTO" ]; then
    RC_ONTO="$RC_PREV_ONTO"
  else
    RC_ONTO=$(git rev-parse HEAD)
  fi
fi

# Re-entrant: a rebase stopping on a later commit, or a multi-commit
# cherry-pick, re-runs this step — keep the run dir only for the SAME
# operation (kind and identity), so baselines accumulate in one place and an
# abandoned operation's baselines are never compared against this one.
if [ "$RC_PREV_OP" = "$RC_OP" ] && [ "$RC_PREV_ID" = "$RC_ID" ] \
  && [ -n "$RC_PREV_RUN_DIR" ] && [ -d "$RC_PREV_RUN_DIR" ]; then
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
  # And the mirror: the INCOMING side's changes, which a resolve-to-ours can
  # silently discard while every ours-before hunk still survives. Step 6
  # checks both directions.
  git diff "$RC_ORIG_HEAD...$RC_ONTO" > "$RC_RUN_DIR/theirs-before.diff"
else
  # rebase and cherry-pick: ONE BASELINE PER REPLAYED COMMIT, all captured at
  # the first stop. Later commits may apply cleanly and never re-enter this
  # step, and Step 6's supersession proof needs their baselines too. For a
  # cherry-pick the set is the current commit plus every pick still in the
  # sequencer (picks completed before the first stop landed before RC_ONTO
  # and are outside the integrity check's scope).
  if [ "$RC_OP" = cherry-pick ]; then
    # One revision PER LINE: the todo still lists the currently conflicting
    # pick, and joining with a space would weld two SHAs into one while-read
    # record, failing rev-parse into an empty baseline. Duplicates are
    # harmless — the per-commit filename makes the write idempotent.
    RC_PICKS=$( { printf '%s\n' "$RC_ORIG_HEAD"; \
      awk '/^pick /{print $2}' "$RC_GIT_DIR/sequencer/todo" 2>/dev/null; } )
  fi
  # `--onto` can target history UNRELATED to the original tip; merge-base
  # then fails and an unguarded substitution would leave EMPTY baseline
  # files that Step 6 vacuously passes. The empty tree is the correct base
  # for unrelated history — everything on each side is its own change.
  RC_MB=$(git merge-base "$RC_ONTO" "$RC_ORIG_HEAD" 2>/dev/null) \
    || RC_MB=$(git hash-object -t tree /dev/null)
  if [ -z "$RC_PICKS" ]; then
    # No readable pick state — last resort for a rebase: the base range.
    git diff "$RC_MB" "$RC_ORIG_HEAD" > "$RC_RUN_DIR/ours-before.diff"
  fi
  if [ "$RC_OP" = rebase ]; then
    # The incoming side for a rebase: what the new base changed since the
    # (possibly empty-tree) base. A conflict resolved to the replayed version
    # can overwrite these hunks in the final tree even though every onto
    # commit stays an ancestor; Step 6 checks this direction too.
    git diff "$RC_MB" "$RC_ONTO" > "$RC_RUN_DIR/theirs-before.diff"
  fi
  # while-read, not `for x in $VAR`: zsh does not word-split an unquoted
  # variable, and these blocks run under the user's shell.
  printf '%s\n' "$RC_PICKS" | while IFS= read -r RC_P; do
    [ -n "$RC_P" ] || continue
    RC_P=$(git rev-parse "$RC_P")
    RC_OUT="$RC_RUN_DIR/ours-before-$(git rev-parse --short "$RC_P").diff"
    if git rev-parse -q --verify "${RC_P}^2" >/dev/null 2>&1; then
      if [ "$RC_OP" = rebase ]; then
        # --rebase-merges replays merges along the first-parent line, so the
        # original merge's own content baselines against parent 1.
        git diff "${RC_P}^1" "$RC_P" > "$RC_OUT"
      else
        # A merge commit being cherry-picked: ^1 is NOT automatically the
        # right base — the pick was started with -m <n>, and for a single
        # pick git records <n> nowhere. Determine it from the command the
        # caller actually ran (missing intent if unknowable) and write the
        # baseline by hand: git diff "<sha>^<n>" "<sha>" > "$RC_OUT"
        echo "MAINLINE_NEEDED: $RC_P — baseline requires the -m parent number"
      fi
    elif git rev-parse -q --verify "${RC_P}~1" >/dev/null 2>&1; then
      git diff "${RC_P}~1" "$RC_P" > "$RC_OUT"
    else
      # Root commit: no parent; a failed ~1 lookup would leave an EMPTY
      # baseline that Step 6 vacuously passes. Its entire content is the change.
      git show --format= "$RC_P" > "$RC_OUT"
    fi
  done
fi

# PRUNE stale baselines. Identity can falsely match a restarted operation
# with the same endpoints but an edited pick list (Codex reproduced inode
# recycling on APFS, so no directory fingerprint is trusted). The keep-set is
# derived only from LIVE facts — never from remembered state, which a false
# match would poison. Deletion is the dangerous direction (a deleted
# legitimate baseline turns Step 6 into a false PASS), so a file is removed
# only when every proof of belonging fails: not in the current replay set,
# its change never landed by patch-id, and no landed commit carries its
# subject (a conflict-RESOLVED earlier pick lands with a different patch-id
# but keeps its message). A stale file that slips through all three surfaces
# in Step 6 as a visible false alarm — the safe failure.
printf '%s\n' "$RC_PICKS" \
  | while IFS= read -r RC_P; do
      [ -n "$RC_P" ] && git rev-parse --short "$RC_P" 2>/dev/null
    done | sort -u > "$RC_RUN_DIR/.keep"
git rev-list "$RC_ONTO"..HEAD 2>/dev/null \
  | while IFS= read -r RC_C; do
      git show --format= "$RC_C" | git patch-id --stable
    done | awk '{print $1}' | sort -u > "$RC_RUN_DIR/.landed"
git log --format=%s "$RC_ONTO"..HEAD 2>/dev/null > "$RC_RUN_DIR/.landed-subjects"
for RC_F in $(ls "$RC_RUN_DIR"/ours-before-*.diff 2>/dev/null); do
  RC_S=${RC_F##*ours-before-}; RC_S=${RC_S%.diff}
  grep -qx "$RC_S" "$RC_RUN_DIR/.keep" && continue
  RC_PID=$(git show --format= "$RC_S" 2>/dev/null | git patch-id --stable | awk '{print $1}')
  [ -n "$RC_PID" ] && grep -qx "$RC_PID" "$RC_RUN_DIR/.landed" && continue
  RC_SUBJ=$(git log -1 --format=%s "$RC_S" 2>/dev/null)
  [ -n "$RC_SUBJ" ] && grep -qxF "$RC_SUBJ" "$RC_RUN_DIR/.landed-subjects" && continue
  rm -f "$RC_F"
done

# Push lease for Step 7. Only a rebase rewrites published history, and for a
# rebase the correct expectation is not any remote-tracking snapshot — every
# snapshot is raceable (a fetch by an IDE before or after the first stop
# refreshes it) — but RC_ORIG_HEAD itself: the tip this rewrite replaces. If
# the remote holds anything else, the push MUST fail, because either someone
# pushed meanwhile or the rewrite was against a stale branch.
if [ "$RC_OP" = rebase ] && grep -q '^refs/heads/' "$RC_STATE_DIR/head-name" 2>/dev/null; then
  # grep, not a bare -f test: a rebase started from detached HEAD writes the
  # literal "detached HEAD" into head-name, which must record no lease.
  RC_BRANCH=$(sed 's#^refs/heads/##' "$RC_STATE_DIR/head-name")
  RC_EXPECT="$RC_ORIG_HEAD"
  # The branch's CONFIGURED push destination, not a hardcoded origin/<name> —
  # pushRemote / remote.pushDefault / a push refspec can all redirect it.
  RC_PUSH=$(git rev-parse --abbrev-ref "${RC_BRANCH}@{push}" 2>/dev/null) \
    || RC_PUSH="origin/${RC_BRANCH}"
  RC_REMOTE=${RC_PUSH%%/*}; RC_DEST=${RC_PUSH#*/}
else
  RC_BRANCH=$(git symbolic-ref --quiet --short HEAD) || RC_BRANCH=""
  RC_EXPECT=""; RC_REMOTE=""; RC_DEST=""  # no rewrite → no force-push at all
fi

# Fenced blocks may execute as separate shell calls and inherit nothing, and
# by Step 6 the operation state dirs are gone — persist what later steps need.
# Written as key=value DATA; loaders parse with rc_get, never source.
[ "$RC_OP" = none ] || printf 'RC_OP=%s\nRC_ID=%s\nRC_ONTO=%s\nRC_ORIG_HEAD=%s\nRC_RUN_DIR=%s\nRC_BRANCH=%s\nRC_EXPECT=%s\nRC_REMOTE=%s\nRC_DEST=%s\n' \
  "$RC_OP" "$RC_ID" "$RC_ONTO" "$RC_ORIG_HEAD" "$RC_RUN_DIR" "$RC_BRANCH" "$RC_EXPECT" "$RC_REMOTE" "$RC_DEST" > "$RC_STATE_FILE"
```

When `RC_OP=none`, stop: there is nothing to resolve. Do not start a merge or rebase on
the skill's own authority — which operation, onto what, is the caller's decision.

A `MAINLINE_NEEDED` line means a replayed **merge commit**'s baseline could not be derived
mechanically: recover the `-m <n>` parent number from the command the caller actually ran
(`sequencer/opts` may record it for a multi-pick sequence; otherwise it is a missing-intent
question), then write `git diff "<sha>^<n>" "<sha>"` to the named baseline file before
continuing past Step 0.

**Every later block that uses an `RC_*` variable begins with this loader** — repeat it
rather than assuming shell state survived from Step 0, and always parse, never source
(the file can carry a branch name, and git permits shell metacharacters in refs):

```bash
RC_STATE_FILE="$(git rev-parse --git-dir)/resolve-conflicts.state"
rc_get() { sed -n "s/^${1}=//p" "$RC_STATE_FILE" 2>/dev/null | head -1; }
RC_OP=$(rc_get RC_OP); RC_ONTO=$(rc_get RC_ONTO); RC_ORIG_HEAD=$(rc_get RC_ORIG_HEAD)
RC_RUN_DIR=$(rc_get RC_RUN_DIR)
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
rc_get() { sed -n "s/^${1}=//p" "$RC_STATE_FILE" 2>/dev/null | head -1; }  # data — never source it
RC_OP=$(rc_get RC_OP); RC_ONTO=$(rc_get RC_ONTO); RC_ORIG_HEAD=$(rc_get RC_ORIG_HEAD)

# --merge needs MERGE_HEAD: it fails during a rebase or cherry-pick, where the
# two --not commands below cover both sides on their own.
[ "$RC_OP" = merge ] && git log --merge --oneline -- <file>  # both sides, merge only
git log --oneline "$RC_ONTO" --not "$RC_ORIG_HEAD" -- <file> # commits only on the RC_ONTO side
git log --oneline "$RC_ORIG_HEAD" --not "$RC_ONTO" -- <file> # commits only on the RC_ORIG_HEAD side
```

Which of those two is "ours" and which is "incoming" depends on the operation — map them
through the sides table in Step 0. For a cherry-pick in particular, `RC_ONTO` is **your
checked-out branch** and `RC_ORIG_HEAD` is the **picked commit**, the reverse of what the
same variables mean during a merge.

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
rc_get() { sed -n "s/^${1}=//p" "$RC_STATE_FILE" 2>/dev/null | head -1; }  # data — never source it
RC_ONTO=$(rc_get RC_ONTO); RC_ORIG_HEAD=$(rc_get RC_ORIG_HEAD); RC_RUN_DIR=$(rc_get RC_RUN_DIR)

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

**Then the mirror.** `theirs-before.diff` (captured for merge and rebase) carries the
incoming side's changes, and a resolution that kept the replayed version can overwrite
them while every ours-hunk still survives. Every theirs-before hunk the final tree no
longer contains needs the same justification with the sides swapped: an identical change
already on our side, or a deliberate drop recorded in Step 3. For a cherry-pick the
incoming side is the branch itself — for each conflicted file, compare
`git show "$RC_ONTO:<file>"` against the final tree the same way. A one-sided check
proves only that our intent survived; the skill's claim is that **both** did.

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
rc_get() { sed -n "s/^${1}=//p" "$RC_STATE_FILE" 2>/dev/null | head -1; }  # data — never source it
RC_BRANCH=$(rc_get RC_BRANCH); RC_EXPECT=$(rc_get RC_EXPECT)
RC_REMOTE=$(rc_get RC_REMOTE); RC_DEST=$(rc_get RC_DEST)
if [ -z "$RC_BRANCH" ] || [ -z "$RC_EXPECT" ] || [ -z "$RC_REMOTE" ] || [ -z "$RC_DEST" ]; then
  # No recorded rewrite: merge and cherry-pick land by plain push, which
  # belongs to the caller — and a detached-HEAD rebase records no lease.
  # Pushing here anyway would be worse than a no-op: an EMPTY expect
  # ("branch:") means "require the ref to be absent" and can CREATE the
  # remote branch.
  echo "no rewrite lease recorded — skipping the push entirely"
else
  # The configured push destination captured at Step 0 — not a hardcoded
  # origin/<name>, which pushRemote or a push refspec could silently bypass.
  git push --force-with-lease="${RC_DEST}:${RC_EXPECT}" "$RC_REMOTE" "${RC_BRANCH}:${RC_DEST}"
fi
```

Never plain `--force`, and never any fetch-then-lease dance. The expectation is
`RC_ORIG_HEAD` — **the tip this rewrite replaced** — not a remote-tracking snapshot:
every snapshot is raceable, because a fetch by anything (this skill, an IDE, a daemon)
before or after the first stop refreshes the ref, and a rebase may replay clean commits
before it ever stops. "The remote must still hold the commit I rewrote away" is the only
expectation that is correct by construction. A rejected push means the remote holds
something else — someone pushed meanwhile, or the rebase started from a stale branch:
stop and surface it to the driver; retrying with a refreshed lease on the skill's own
authority is exactly the overwrite the lease exists to prevent. This skill does not
merge, open PRs, or move board items; hand those to the calling workflow.

Finally, remove the state file so a future run cannot inherit a finished operation's
facts: `rm -f "$(git rev-parse --git-dir)/resolve-conflicts.state"`.
