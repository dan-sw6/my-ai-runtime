#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

# What: post-merge hygiene helper for local git worktrees and feature branches.
# Why: provide deterministic cleanup of stale story worktree branches after
# merge without ad-hoc destructive commands.
# Invariants:
# - default mode is `--dry-run` and does not mutate git state;
# - apply mode requires explicit `--apply`;
# - never delete the base branch, current branch/worktree, unmerged branches,
#   or dirty worktrees.

SCRIPT_NAME="$(basename "$0")"
BASE_BRANCH="$(rcfg ao.base_ref main)"
# TODO(coordinator): ao.worktree_branch_pattern isn't in the runtime.config
# schema yet (config/runtime.config.example.yaml only documents ao.worktree_root).
# Default below matches the branch naming safe-worktree-cleanup.sh uses
# (worktree-STORY-<id>) — add the key to the ao: block if products need to
# override it, or fold it into worktree_root if that's a cleaner home.
BRANCH_PATTERN="$(rcfg ao.worktree_branch_pattern "worktree-STORY-*")"
MODE="dry-run"

REPO_ROOT=""
CURRENT_BRANCH=""
CURRENT_WORKTREE=""

SCANNED=0
CANDIDATES=0
APPLIED=0

declare -A BRANCH_TO_WORKTREE=()
declare -a PLAN_BRANCHES=()
declare -a PLAN_WORKTREES=()
declare -a SKIPS=()

print_help() {
  cat <<HELP
Usage:
  ./scripts/git-worktree-hygiene.sh [--dry-run] [--apply] [--help]

Modes:
  --dry-run   Preview mode (default). Print cleanup plan only.
  --apply     Execute cleanup plan for merge-safe candidates.
  --help      Show this help.

Safety policy:
  - Candidates are local branches matching refs/heads/${BRANCH_PATTERN} only.
  - Branch must be merged into ${BASE_BRANCH} (\`merge-base --is-ancestor\`).
  - ${BASE_BRANCH} and current branch/worktree are always protected.
  - Dirty or missing worktrees are skipped (no forced removal).
  - Unmerged branches are skipped.

Behavior:
  - dry-run prints plan and shell commands without mutations.
  - apply removes candidate worktree (if attached/clean), then deletes branch.

Reason codes:
  success
  no_merge_safe_candidates
  not_in_git_repository
  base_branch_missing
  unknown_option
  conflicting_mode_flags
  worktree_remove_failed
  branch_delete_failed
HELP
}

error() {
  echo "[${SCRIPT_NAME}][error] $*" >&2
}

emit_summary() {
  local verdict="$1"
  local reason="$2"
  local skipped_count="${#SKIPS[@]}"
  echo "summary verdict=${verdict} reason=${reason} mode=${MODE} base_branch=${BASE_BRANCH} scanned=${SCANNED} candidates=${CANDIDATES} applied=${APPLIED} skipped=${skipped_count}"
}

fail_with_reason() {
  local reason="$1"
  error "$reason"
  emit_summary "fail" "$reason"
  exit 1
}

print_cmd() {
  local rendered=""
  local arg
  for arg in "$@"; do
    rendered+=" $(printf '%q' "$arg")"
  done
  # shellcheck disable=SC2001
  echo "$(echo "$rendered" | sed -e 's/^ //')"
}

parse_args() {
  local dry_run_flag=0
  local apply_flag=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        print_help
        exit 0
        ;;
      --dry-run)
        dry_run_flag=1
        shift
        ;;
      --apply)
        apply_flag=1
        shift
        ;;
      *)
        error "unknown option: $1"
        fail_with_reason "unknown_option"
        ;;
    esac
  done

  if [[ "$dry_run_flag" -eq 1 && "$apply_flag" -eq 1 ]]; then
    fail_with_reason "conflicting_mode_flags"
  fi

  if [[ "$apply_flag" -eq 1 ]]; then
    MODE="apply"
  else
    MODE="dry-run"
  fi
}

ensure_git_context() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail_with_reason "not_in_git_repository"
  fi

  REPO_ROOT="$(git rev-parse --show-toplevel)"
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  CURRENT_WORKTREE="$REPO_ROOT"

  if ! git show-ref --verify --quiet "refs/heads/${BASE_BRANCH}"; then
    fail_with_reason "base_branch_missing"
  fi
}

collect_worktree_map() {
  local line=""
  local current_path=""
  local branch_ref=""

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ refs/heads/*)
        branch_ref="${line#branch refs/heads/}"
        BRANCH_TO_WORKTREE["$branch_ref"]="$current_path"
        ;;
    esac
  done < <(git worktree list --porcelain)
}

worktree_is_clean() {
  local path="$1"
  local status_output=""
  status_output="$(git -C "$path" status --porcelain 2>/dev/null || true)"
  [[ -z "$status_output" ]]
}

register_skip() {
  local branch="$1"
  local reason="$2"
  SKIPS+=("skip branch=${branch} reason=${reason}")
}

build_plan() {
  local branch=""
  local worktree_path=""
  mapfile -t local_branches < <(git for-each-ref --format='%(refname:short)' "refs/heads/${BRANCH_PATTERN}" | LC_ALL=C sort)
  SCANNED="${#local_branches[@]}"

  for branch in "${local_branches[@]}"; do
    if [[ "$branch" == "$BASE_BRANCH" ]]; then
      register_skip "$branch" "protected_base_branch"
      continue
    fi

    if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
      register_skip "$branch" "protected_current_branch"
      continue
    fi

    if ! git merge-base --is-ancestor "$branch" "$BASE_BRANCH"; then
      register_skip "$branch" "not_merged_into_base"
      continue
    fi

    worktree_path="${BRANCH_TO_WORKTREE[$branch]:-}"
    if [[ -n "$worktree_path" ]]; then
      if [[ "$worktree_path" == "$CURRENT_WORKTREE" ]]; then
        register_skip "$branch" "protected_current_worktree"
        continue
      fi
      if [[ ! -d "$worktree_path" ]]; then
        register_skip "$branch" "worktree_path_missing"
        continue
      fi
      if ! worktree_is_clean "$worktree_path"; then
        register_skip "$branch" "worktree_dirty"
        continue
      fi
    fi

    PLAN_BRANCHES+=("$branch")
    PLAN_WORKTREES+=("$worktree_path")
  done

  CANDIDATES="${#PLAN_BRANCHES[@]}"
}

print_plan() {
  local idx=0
  local branch=""
  local worktree_path=""

  echo "mode=${MODE} base_branch=${BASE_BRANCH} current_branch=${CURRENT_BRANCH} current_worktree=${CURRENT_WORKTREE}"

  if [[ "$CANDIDATES" -eq 0 ]]; then
    echo "plan none reason=no_merge_safe_candidates"
  fi

  for idx in "${!PLAN_BRANCHES[@]}"; do
    branch="${PLAN_BRANCHES[$idx]}"
    worktree_path="${PLAN_WORKTREES[$idx]}"
    if [[ -n "$worktree_path" ]]; then
      echo "plan branch=${branch} worktree=${worktree_path} action=remove_worktree+delete_branch"
    else
      echo "plan branch=${branch} worktree=- action=delete_branch"
    fi
  done

  for idx in "${!SKIPS[@]}"; do
    echo "${SKIPS[$idx]}"
  done
}

apply_plan() {
  local idx=0
  local branch=""
  local worktree_path=""

  for idx in "${!PLAN_BRANCHES[@]}"; do
    branch="${PLAN_BRANCHES[$idx]}"
    worktree_path="${PLAN_WORKTREES[$idx]}"

    if [[ -n "$worktree_path" ]]; then
      echo "apply branch=${branch} action=remove_worktree path=${worktree_path}"
      if ! git worktree remove "$worktree_path"; then
        fail_with_reason "worktree_remove_failed"
      fi
    fi

    echo "apply branch=${branch} action=delete_branch"
    if ! git branch -D "$branch" >/dev/null; then
      fail_with_reason "branch_delete_failed"
    fi
    APPLIED=$((APPLIED + 1))
  done
}

preview_plan() {
  local idx=0
  local branch=""
  local worktree_path=""

  for idx in "${!PLAN_BRANCHES[@]}"; do
    branch="${PLAN_BRANCHES[$idx]}"
    worktree_path="${PLAN_WORKTREES[$idx]}"
    if [[ -n "$worktree_path" ]]; then
      echo "dry-run: $(print_cmd git worktree remove "$worktree_path")"
    fi
    echo "dry-run: $(print_cmd git branch -D "$branch")"
  done
}

main() {
  parse_args "$@"
  ensure_git_context
  collect_worktree_map
  build_plan
  print_plan

  if [[ "$MODE" == "apply" ]]; then
    apply_plan
  else
    preview_plan
  fi

  if [[ "$CANDIDATES" -eq 0 ]]; then
    emit_summary "pass" "no_merge_safe_candidates"
  else
    emit_summary "pass" "success"
  fi
}

main "$@"
