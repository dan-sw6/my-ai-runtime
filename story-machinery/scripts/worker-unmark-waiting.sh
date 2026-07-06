#!/usr/bin/env bash
# worker-unmark-waiting.sh — PostToolUse hook handler для AskUserQuestion.
#
# Удаляет marker-файл после того как пользователь ответил на AskUserQuestion.
# Парный к worker-mark-waiting.sh. Exit 0 всегда.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

[[ "${CLAUDE_WORKER_MODE:-}" == "interactive" ]] || exit 0
[[ -n "${CLAUDE_STORY_ID:-}" ]] || exit 0

STORY_ID="${CLAUDE_STORY_ID}"
WORKER_DIR="${STATE_DIR}/${STORY_ID,,}"
MARKER="${WORKER_DIR}/blocked-waiting.json"

rm -f "${MARKER}" 2>/dev/null

exit 0
