#!/usr/bin/env bash
set -euo pipefail

# What: print canonical scope diff for current HEAD against origin/<base-ref>.
# Why: keep scope checks deterministic and immune to stale local <base_ref> branches.
# Invariants:
# - compare base is always refs/remotes/origin/<base-ref>;
# - script is read-only and never fetches or mutates git refs/worktree state;
# - missing origin compare ref returns deterministic [scope-diff][error] message.

SCRIPT_NAME="$(basename "$0")"
base_ref=""
output_mode="name-status"

print_help() {
  cat <<HELP
Usage:
  bash scripts/${SCRIPT_NAME} --base-ref <ref> [--name-status|--name-only]
  bash scripts/${SCRIPT_NAME} --help

Description:
  Outputs git diff for canonical scope checks via:
    git diff --name-status "origin/<base-ref>...HEAD"

Options:
  --base-ref <ref>   Base branch name without local fallback (required).
  --name-status      Output name-status diff (default).
  --name-only        Output names only.
  --help             Show this help and exit.

Exit codes:
  0  Success.
  1  Runtime/preflight failure.
  2  Invalid CLI arguments.
HELP
}

die_arg() {
  echo "[scope-diff][error] $*" >&2
  echo "[scope-diff][hint] use --help for usage" >&2
  exit 2
}

normalize_base_ref() {
  local raw="$1"
  raw="${raw#refs/heads/}"
  raw="${raw#refs/remotes/}"
  raw="${raw#origin/}"
  printf '%s\n' "${raw}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --base-ref)
      if [[ $# -lt 2 ]]; then
        die_arg "--base-ref requires value"
      fi
      base_ref="$2"
      shift 2
      ;;
    --base-ref=*)
      base_ref="${1#--base-ref=}"
      shift
      ;;
    --name-status)
      output_mode="name-status"
      shift
      ;;
    --name-only)
      output_mode="name-only"
      shift
      ;;
    *)
      die_arg "unsupported argument: $1"
      ;;
  esac
done

if [[ -z "${base_ref}" ]]; then
  die_arg "--base-ref must not be empty"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
  echo "[scope-diff][error] not inside a git repository" >&2
  exit 1
fi
cd "${repo_root}"

normalized_base_ref="$(normalize_base_ref "${base_ref}")"
if [[ -z "${normalized_base_ref}" ]]; then
  die_arg "normalized --base-ref is empty"
fi

compare_ref="origin/${normalized_base_ref}"
compare_ref_path="refs/remotes/${compare_ref}"
if ! git show-ref --verify --quiet "${compare_ref_path}"; then
  echo "[scope-diff][error] compare_ref_missing ref=${compare_ref}" >&2
  echo "[scope-diff][hint] run: git fetch -p origin ${normalized_base_ref}" >&2
  exit 1
fi

case "${output_mode}" in
  name-status)
    git diff --name-status "${compare_ref}...HEAD"
    ;;
  name-only)
    git diff --name-only "${compare_ref}...HEAD"
    ;;
  *)
    die_arg "unsupported output mode: ${output_mode}"
    ;;
esac
