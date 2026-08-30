#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'USAGE'
Usage:
  worktree-create.sh env-files [--source-dir <path>]
  worktree-create.sh create <issue-or-pr-number> [--source-dir <path>] [--copy-env|--no-copy-env] [--metadata-file <path>] [--register-state|--no-register-state]
  worktree-create.sh review <pr-number> [--source-dir <path>] [--copy-env|--no-copy-env]
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not installed"
}

slugify() {
  printf '%s\n' "$1" \
    | sed 's/[^a-zA-Z0-9-]/-/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/--*/-/g; s/^-//; s/-$//'
}

main_repo_root() {
  local source_dir="$1"
  local git_common_dir
  git_common_dir=$(git -C "$source_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "Not inside a git repository"
  case "$git_common_dir" in
    */.git) printf '%s\n' "${git_common_dir%/.git}" ;;
    *) git -C "$source_dir" rev-parse --show-toplevel ;;
  esac
}

default_branch() {
  local repo_root="$1"
  local branch
  branch=$(git -C "$repo_root" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | tr -cd '[:alnum:]-._/' | head -1)
  [ -n "$branch" ] || die "Could not determine default branch"
  printf '%s\n' "$branch"
}

find_env_files() {
  local source_dir="$1"
  local file rel_path
  find "$source_dir" \( -name "node_modules" -o -name ".git" -o -name "vendor" \) -prune -o \
    \( -name ".env" -o -name ".env.local" -o -name ".envrc" \) -type f -print 2>/dev/null \
    | while IFS= read -r file; do
        case "$file" in
          "$source_dir"/*) rel_path="${file#"$source_dir"/}" ;;
          *) rel_path="$file" ;;
        esac
        case "$rel_path" in
          -*) ;;
          *) printf '%s\n' "$rel_path" ;;
        esac
      done \
    | sort
}

copy_env_files() {
  local source_dir="$1"
  local worktree_path="$2"
  local copied=0
  local wt_real
  wt_real=$(cd "$worktree_path" && pwd -P)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    local dir dest dest_dir_real
    dir=$(dirname "$file")
    if [ "$dir" != "." ]; then
      mkdir -p "$worktree_path/$dir"
    fi
    dest="$worktree_path/$file"
    # The worktree content is under the PR author's control: a tracked
    # symlink at the destination (or a symlinked parent directory) would
    # make this copy write the reviewer's secrets to an arbitrary path
    # outside the worktree. cp -P protects only the SOURCE side, so resolve
    # the destination and refuse anything that escapes or is a symlink.
    dest_dir_real=$(cd "$worktree_path/$dir" 2>/dev/null && pwd -P) || dest_dir_real=""
    case "${dest_dir_real}/" in
      "${wt_real}/"*) : ;;
      *) echo "ENV_COPY_REFUSED: $file (destination resolves outside the worktree)"; continue ;;
    esac
    if [ -L "$dest" ]; then
      echo "ENV_COPY_REFUSED: $file (destination is a symlink)"
      continue
    fi
    cp -P "$source_dir/$file" "$dest"
    echo "Copied $file"
    copied=$((copied + 1))
  done
  echo "Copied env files: $copied"
}

existing_worktree_path() {
  local repo_root="$1"
  local branch_name="$2"
  local target_path="$3"
  git -C "$repo_root" worktree list --porcelain \
    | awk -v target_branch="refs/heads/${branch_name}" -v target_path="$target_path" '
      /^worktree / { path = substr($0, 10) }
      /^branch / {
        branch = substr($0, 8)
        if (path == target_path && branch == target_branch) {
          print path
          exit
        }
      }'
}

branch_checked_out_path() {
  local repo_root="$1"
  local branch_name="$2"
  git -C "$repo_root" worktree list --porcelain \
    | awk -v target="refs/heads/${branch_name}" '
      /^worktree / { path = substr($0, 10) }
      /^branch / {
        branch = substr($0, 8)
        if (branch == target) {
          print path
          exit
        }
      }'
}

extract_issue_from_pr() {
  local pr_json="$1"
  local head_ref body
  head_ref=$(printf '%s\n' "$pr_json" | jq -r '.headRefName // ""')
  body=$(printf '%s\n' "$pr_json" | jq -r '.body // ""')
  if [[ "$head_ref" =~ issue-([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$body" =~ ([Ff]ixes|[Cc]loses|[Rr]esolves)[[:space:]]+#([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

resolve_item() {
  local number="$1"
  local pr_json issue_json pr_title linked_issue
  # gh resolves the repository from its cwd; with --source-dir that is not
  # necessarily the shell's cwd, so every lookup runs from the source repo.
  pr_json=$(cd "$SOURCE_DIR" && gh pr view "$number" --json number,title,headRefName,body 2>/dev/null || true)
  if [ -n "$pr_json" ]; then
    pr_title=$(printf '%s\n' "$pr_json" | jq -r '.title // empty')
    if linked_issue=$(extract_issue_from_pr "$pr_json"); then
      issue_json=$(cd "$SOURCE_DIR" && gh issue view "$linked_issue" --json number,title,state 2>/dev/null || true)
      if [ -n "$issue_json" ]; then
        ITEM_NUMBER="$linked_issue"
        ITEM_TITLE=$(printf '%s\n' "$issue_json" | jq -r '.title')
        ITEM_KIND="issue"
        return 0
      fi
    fi
    ITEM_NUMBER="$number"
    ITEM_TITLE="$pr_title"
    ITEM_KIND="pr"
    return 0
  fi

  issue_json=$(cd "$SOURCE_DIR" && gh issue view "$number" --json number,title,state 2>/dev/null || true)
  [ -n "$issue_json" ] || die "Issue or PR #$number not found"
  ITEM_NUMBER=$(printf '%s\n' "$issue_json" | jq -r '.number')
  ITEM_TITLE=$(printf '%s\n' "$issue_json" | jq -r '.title')
  ITEM_KIND="issue"
}

write_metadata() {
  local metadata_file="$1"
  [ -n "$metadata_file" ] || return 0
  {
    printf 'ITEM_KIND\t%s\n' "$ITEM_KIND"
    printf 'ISSUE_NUM\t%s\n' "$ITEM_NUMBER"
    printf 'ITEM_TITLE\t%s\n' "$ITEM_TITLE"
    printf 'TITLE_SLUG\t%s\n' "$TITLE_SLUG"
    printf 'REPO_NAME\t%s\n' "$REPO_NAME"
    printf 'MAIN_REPO_ROOT\t%s\n' "$MAIN_REPO_ROOT"
    printf 'SOURCE_DIR\t%s\n' "$SOURCE_DIR"
    printf 'WORKTREE_NAME\t%s\n' "$WORKTREE_NAME"
    printf 'WORKTREE_PATH\t%s\n' "$WORKTREE_PATH"
    printf 'WORKTREE_ABS_PATH\t%s\n' "$WORKTREE_ABS_PATH"
    printf 'BRANCH_NAME\t%s\n' "$BRANCH_NAME"
    printf 'DEFAULT_BRANCH\t%s\n' "$DEFAULT_BRANCH"
    printf 'WORKTREE_CREATED\t%s\n' "$WORKTREE_CREATED"
    printf 'ENV_FILES_COUNT\t%s\n' "$ENV_FILES_COUNT"
  } > "$metadata_file"
}

run_env_files() {
  local source_dir
  source_dir=$(pwd)
  while [ $# -gt 0 ]; do
    case "$1" in
      --source-dir)
        source_dir="${2:-}"
        [ -n "$source_dir" ] || die "--source-dir requires a path"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown env-files option: $1"
        ;;
    esac
  done
  [ -d "$source_dir" ] || die "Source directory not found: $source_dir"

  local env_files
  env_files=$(find_env_files "$source_dir")
  if [ -z "$env_files" ]; then
    echo "ENV_FILES_FOUND=false"
    return 0
  fi

  echo "ENV_FILES_FOUND=true"
  echo "$env_files"
}

run_create() {
  local number="${1:-}"
  [ -n "$number" ] || die "create requires an issue or PR number"
  shift
  echo "$number" | grep -qE '^[0-9]+$' || die "Issue or PR number must be numeric"

  local copy_env="false"
  local register_state="true"
  local metadata_file=""
  SOURCE_DIR=$(pwd)

  while [ $# -gt 0 ]; do
    case "$1" in
      --source-dir)
        SOURCE_DIR="${2:-}"
        [ -n "$SOURCE_DIR" ] || die "--source-dir requires a path"
        shift 2
        ;;
      --copy-env)
        copy_env="true"
        shift
        ;;
      --no-copy-env)
        copy_env="false"
        shift
        ;;
      --metadata-file)
        metadata_file="${2:-}"
        [ -n "$metadata_file" ] || die "--metadata-file requires a path"
        shift 2
        ;;
      --register-state)
        register_state="true"
        shift
        ;;
      --no-register-state)
        register_state="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown create option: $1"
        ;;
    esac
  done

  require_tool gh
  require_tool git
  require_tool jq
  gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
  [ -d "$SOURCE_DIR" ] || die "Source directory not found: $SOURCE_DIR"

  MAIN_REPO_ROOT=$(main_repo_root "$SOURCE_DIR")
  DEFAULT_BRANCH=$(default_branch "$MAIN_REPO_ROOT")
  resolve_item "$number"

  REPO_NAME=$(basename "$MAIN_REPO_ROOT")
  TITLE_SLUG=$(slugify "$ITEM_TITLE")
  [ -n "$TITLE_SLUG" ] || TITLE_SLUG="$ITEM_NUMBER"
  WORKTREE_NAME="${REPO_NAME}-issue-${ITEM_NUMBER}-${TITLE_SLUG}"
  WORKTREE_PATH="$(cd "$MAIN_REPO_ROOT/.." && pwd -P)/${WORKTREE_NAME}"
  BRANCH_NAME="issue-${ITEM_NUMBER}-${TITLE_SLUG}"
  WORKTREE_CREATED="false"

  local existing_path
  existing_path=$(existing_worktree_path "$MAIN_REPO_ROOT" "$BRANCH_NAME" "$WORKTREE_PATH")
  if [ -n "$existing_path" ]; then
    WORKTREE_ABS_PATH=$(cd "$existing_path" && pwd)
    echo "WORKTREE_EXISTS: $WORKTREE_ABS_PATH"
  else
    local checked_out_path
    checked_out_path=$(branch_checked_out_path "$MAIN_REPO_ROOT" "$BRANCH_NAME")
    if [ -n "$checked_out_path" ]; then
      die "Branch $BRANCH_NAME is checked out at $checked_out_path"
    fi
    if [ -e "$WORKTREE_PATH" ] || [ -L "$WORKTREE_PATH" ]; then
      die "Target path already exists: $WORKTREE_PATH"
    fi
    if git -C "$MAIN_REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
      git -C "$MAIN_REPO_ROOT" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
    else
      git -C "$MAIN_REPO_ROOT" fetch origin "$DEFAULT_BRANCH"
      git -C "$MAIN_REPO_ROOT" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$DEFAULT_BRANCH"
    fi
    WORKTREE_ABS_PATH=$(cd "$WORKTREE_PATH" && pwd)
    WORKTREE_CREATED="true"
    echo "WORKTREE_CREATED: $WORKTREE_ABS_PATH"
  fi

  local env_files
  env_files=$(find_env_files "$SOURCE_DIR")
  if [ -n "$env_files" ]; then
    ENV_FILES_COUNT=$(printf '%s\n' "$env_files" | awk 'NF { count++ } END { print count + 0 }')
    echo "ENV_FILES_FOUND: $ENV_FILES_COUNT"
    echo "$env_files"
    if [ "$copy_env" = "true" ]; then
      printf '%s\n' "$env_files" | copy_env_files "$SOURCE_DIR" "$WORKTREE_ABS_PATH"
    else
      echo "ENV_FILES_SKIPPED"
    fi
  else
    ENV_FILES_COUNT=0
    echo "ENV_FILES_FOUND: 0"
  fi

  if [ "$register_state" = "true" ]; then
    "$SCRIPT_DIR/worktree-state.sh" save "$WORKTREE_ABS_PATH" "$MAIN_REPO_ROOT" "$ITEM_NUMBER"
  fi

  write_metadata "$metadata_file"

  echo "Worktree absolute path: $WORKTREE_ABS_PATH"
  echo "Branch: $BRANCH_NAME"
}

run_review() {
  local number="${1:-}"
  [ -n "$number" ] || die "review requires a PR number"
  shift
  echo "$number" | grep -qE '^[0-9]+$' || die "PR number must be numeric"

  local copy_env="false"
  SOURCE_DIR=$(pwd)

  while [ $# -gt 0 ]; do
    case "$1" in
      --source-dir)
        SOURCE_DIR="${2:-}"
        [ -n "$SOURCE_DIR" ] || die "--source-dir requires a path"
        shift 2
        ;;
      --copy-env)
        copy_env="true"
        shift
        ;;
      --no-copy-env)
        copy_env="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown review option: $1"
        ;;
    esac
  done

  require_tool gh
  require_tool git
  require_tool jq
  gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
  [ -d "$SOURCE_DIR" ] || die "Source directory not found: $SOURCE_DIR"

  MAIN_REPO_ROOT=$(main_repo_root "$SOURCE_DIR")

  local pr_json head_ref pr_state pr_title
  # Resolve against the source repository, not the shell's cwd — with
  # --source-dir they can differ, and the fetch below targets this repo's
  # origin, so the metadata must come from the same place.
  pr_json=$(cd "$MAIN_REPO_ROOT" && gh pr view "$number" --json number,title,headRefName,state 2>/dev/null || true)
  [ -n "$pr_json" ] || die "PR #$number not found"
  head_ref=$(printf '%s\n' "$pr_json" | jq -r '.headRefName // ""')
  pr_state=$(printf '%s\n' "$pr_json" | jq -r '.state // ""')
  pr_title=$(printf '%s\n' "$pr_json" | jq -r '.title // ""')
  [ -n "$head_ref" ] || die "PR #$number has no head ref"
  if [ "$pr_state" != "OPEN" ]; then
    echo "PR_STATE_WARNING: PR #$number is $pr_state"
  fi

  REPO_NAME=$(basename "$MAIN_REPO_ROOT")
  TITLE_SLUG=$(slugify "$pr_title")
  [ -n "$TITLE_SLUG" ] || TITLE_SLUG="pr-$number"
  WORKTREE_NAME="${REPO_NAME}-review-pr-${number}-${TITLE_SLUG}"
  WORKTREE_PATH="$(cd "$MAIN_REPO_ROOT/.." && pwd -P)/${WORKTREE_NAME}"
  BRANCH_NAME="review-pr-${number}"
  WORKTREE_CREATED="false"

  # The PR head branch may live on a fork (cross-repository PR) or be deleted
  # once the PR merges, so origin/<headRefName> is not a reliable fetch source.
  # GitHub serves refs/pull/<n>/head on the base repository for every PR —
  # open, closed, merged, or cross-repo. Force-fetch it into a local review
  # ref (shared across worktrees) so force-pushed heads track too. The head
  # branch itself may be checked out in another worktree — never claim it; the
  # dedicated review branch carries identical content and cannot collide.
  local pr_head_ref="refs/pr-review/${number}"
  # The previous fetched head, captured before the force-fetch moves the ref:
  # it is what lets reuse tell "the PR was force-pushed" apart from "someone
  # committed locally".
  local prev_pr_head=""
  prev_pr_head=$(git -C "$MAIN_REPO_ROOT" rev-parse -q --verify "${pr_head_ref}^{commit}" 2>/dev/null) || prev_pr_head=""
  git -C "$MAIN_REPO_ROOT" fetch --force origin "refs/pull/${number}/head:${pr_head_ref}"

  # Reuse is keyed on the stable review-pr-<n> branch, never the title-derived
  # path: PR titles change between invocations, the branch name does not.
  local existing_path
  existing_path=$(branch_checked_out_path "$MAIN_REPO_ROOT" "$BRANCH_NAME")
  if [ -n "$existing_path" ]; then
    WORKTREE_ABS_PATH=$(cd "$existing_path" && pwd)
    WORKTREE_PATH="$WORKTREE_ABS_PATH"
    WORKTREE_NAME=$(basename "$WORKTREE_ABS_PATH")
    echo "WORKTREE_EXISTS: $WORKTREE_ABS_PATH"
    # Reuse ladder. The review contract says the branch holds no local
    # commits and no uncommitted changes; only a tree that provably kept the
    # contract may be moved, and nothing is ever discarded silently.
    local wt_head wt_dirty
    wt_head=$(git -C "$WORKTREE_ABS_PATH" rev-parse HEAD)
    wt_dirty=$(git -C "$WORKTREE_ABS_PATH" status --porcelain)
    if [ -n "$wt_dirty" ]; then
      # "Already up to date" from --ff-only would vouch for a dirty tree.
      echo "WORKTREE_DIRTY: uncommitted changes; not touching it"
    elif [ -n "$prev_pr_head" ] && [ "$wt_head" = "$prev_pr_head" ]; then
      # Clean and exactly at the previously fetched PR head: safe to follow
      # the PR wherever it went — including a force-push, which --ff-only
      # alone could never track.
      git -C "$WORKTREE_ABS_PATH" reset --hard "$pr_head_ref" >/dev/null
      echo "WORKTREE_UPDATED: $pr_head_ref"
    elif [ "$(git -C "$WORKTREE_ABS_PATH" rev-list --count "${pr_head_ref}..HEAD")" -gt 0 ]; then
      # A stray local commit makes HEAD ahead of the fetched PR head, and
      # --ff-only would report "Already up to date" while keeping it.
      echo "WORKTREE_STALE: local commits beyond $pr_head_ref; not touching it"
    elif git -C "$WORKTREE_ABS_PATH" merge --ff-only "$pr_head_ref" >/dev/null 2>&1; then
      echo "WORKTREE_UPDATED: $pr_head_ref"
    else
      echo "WORKTREE_STALE: local branch has diverged from $pr_head_ref; not touching it"
    fi
  else
    if [ -e "$WORKTREE_PATH" ] || [ -L "$WORKTREE_PATH" ]; then
      die "Target path already exists: $WORKTREE_PATH"
    fi
    if git -C "$MAIN_REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
      die "Branch $BRANCH_NAME already exists but is not a registered worktree; remove or rename it first"
    fi
    git -C "$MAIN_REPO_ROOT" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$pr_head_ref"
    WORKTREE_ABS_PATH=$(cd "$WORKTREE_PATH" && pwd)
    WORKTREE_CREATED="true"
    echo "WORKTREE_CREATED: $WORKTREE_ABS_PATH"
  fi

  local env_files
  env_files=$(find_env_files "$SOURCE_DIR")
  if [ -n "$env_files" ]; then
    ENV_FILES_COUNT=$(printf '%s\n' "$env_files" | awk 'NF { count++ } END { print count + 0 }')
    echo "ENV_FILES_FOUND: $ENV_FILES_COUNT"
    echo "$env_files"
    if [ "$copy_env" = "true" ]; then
      printf '%s\n' "$env_files" | copy_env_files "$SOURCE_DIR" "$WORKTREE_ABS_PATH"
    else
      echo "ENV_FILES_SKIPPED"
    fi
  else
    ENV_FILES_COUNT=0
    echo "ENV_FILES_FOUND: 0"
  fi

  echo "Worktree absolute path: $WORKTREE_ABS_PATH"
  echo "Branch: $BRANCH_NAME"
  echo "PR head ref: $pr_head_ref (refs/pull/${number}/head, branch: $head_ref)"
  echo "PR state: $pr_state"
}

COMMAND="${1:-}"
case "$COMMAND" in
  env-files)
    shift
    run_env_files "$@"
    ;;
  create)
    shift
    run_create "$@"
    ;;
  review)
    shift
    run_review "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
