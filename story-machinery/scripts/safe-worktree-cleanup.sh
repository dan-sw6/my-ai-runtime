#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

# safe-worktree-cleanup.sh — спасает uncommitted работу из worktree перед удалением.
#
# Симптом ДО фикса: STORY-236 worker timed out (exit 124), оставил Phase 2 код
# uncommitted в worktree. Координатор сделал
# `git worktree remove --force` → весь код потерян. Retry с нуля стоил $6.
#
# Поведение:
# 1. Если в worktree есть uncommitted (staged + unstaged + untracked) — стэшить
#    с дескриптивным именем "rescued-STORY-${ID}-<ISO>", записать stash ref в
#    ${STATE_DIR}/story-${ID}/rescued.stash для retry preflight.
# 2. Удалить worktree через `git worktree remove --force`.
# 3. Удалить ветку worktree-STORY-${ID} (cleanup B.1.8 и так это делает).
#
# Usage:
#   bash scripts/safe-worktree-cleanup.sh STORY-ID [--dry-run]

STORY_ID="${1:?Usage: $0 STORY-ID [--dry-run]}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WORKTREE_ROOT="$(rcfg ao.worktree_root .claude/worktrees)"
WT_PATH="${REPO_ROOT}/${WORKTREE_ROOT}/STORY-${STORY_ID#STORY-}"
WORKER_DIR="${STATE_DIR}/story-${STORY_ID#STORY-}"
BRANCH="worktree-STORY-${STORY_ID#STORY-}"

if [[ ! -d "${WT_PATH}" ]]; then
  echo "[safe-cleanup] Worktree absent: ${WT_PATH} — nothing to do"
  exit 0
fi

# Step 1: Detect uncommitted work
porcelain="$(git -C "${WT_PATH}" status --porcelain 2>/dev/null || echo "")"
if [[ -n "${porcelain}" ]]; then
  diff_files="$(echo "${porcelain}" | wc -l | tr -d ' ')"
  echo "[safe-cleanup] ${diff_files} uncommitted change(s) detected in ${WT_PATH}"
  echo "${porcelain}" | head -10 | sed 's/^/  /'

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[safe-cleanup] DRY-RUN: would stash + remove worktree"
    exit 0
  fi

  ts="$(date -Is)"
  stash_msg="rescued-${STORY_ID}-${ts}"

  # `git stash push -u` for untracked, in worktree's git context
  if git -C "${WT_PATH}" stash push -u -m "${stash_msg}" >/dev/null 2>&1; then
    # Stash lives in REPO_ROOT/.git/refs/stash (shared object store with worktrees)
    stash_ref="$(git -C "${REPO_ROOT}" stash list | head -1 | awk -F: '{print $1}')"
    mkdir -p "${WORKER_DIR}"
    {
      echo "stash_ref=${stash_ref}"
      echo "stash_msg=${stash_msg}"
      echo "rescued_at=${ts}"
      echo "files_rescued=${diff_files}"
      echo "branch=${BRANCH}"
      echo ""
      echo "# To inspect: git stash show -p ${stash_ref}"
      echo "# To recover into a fresh worktree:"
      echo "#   git worktree add ${WT_PATH} ${BRANCH}"
      echo "#   git -C ${WT_PATH} stash apply ${stash_ref}"
    } > "${WORKER_DIR}/rescued.stash"
    echo "[safe-cleanup] Stashed as ${stash_ref} (${stash_msg})"
    echo "[safe-cleanup] Recovery instructions: ${WORKER_DIR}/rescued.stash"
  else
    echo "[safe-cleanup] WARN: git stash push failed — uncommitted work will be lost on remove" >&2
  fi
fi

# Step 2: Remove worktree
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[safe-cleanup] DRY-RUN: would run 'git worktree remove --force ${WT_PATH}'"
else
  git worktree remove --force "${WT_PATH}" 2>&1 | sed 's/^/  /'
  echo "[safe-cleanup] Removed worktree ${WT_PATH}"
fi

# Step 3: Delete branch (idempotent)
if git show-ref --quiet "refs/heads/${BRANCH}"; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[safe-cleanup] DRY-RUN: would delete branch ${BRANCH}"
  else
    git branch -D "${BRANCH}" 2>&1 | sed 's/^/  /'
  fi
fi

git worktree prune 2>/dev/null || true
echo "[safe-cleanup] Done for ${STORY_ID}"
