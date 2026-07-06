#!/usr/bin/env bash
# worker-mark-waiting.sh — PreToolUse hook handler для AskUserQuestion.
#
# Пишет marker-файл `${WORKER_DIR}/blocked-waiting.json` когда worker в interactive
# mode вызывает AskUserQuestion. Coordinator (watch-waiting-workers.sh) ловит
# появление файла через inotifywait и шлёт notify-send.
#
# Активируется только если CLAUDE_WORKER_MODE=interactive (чтобы не шуметь в
# обычных coordinator-сессиях). Также требует CLAUDE_STORY_ID — иначе exit 0.
#
# Stdin: JSON от Claude Code hook (см. https://code.claude.com/docs/en/hooks).
# Stdout: должен быть тихим (иначе влияет на TUI).
# Exit 0 всегда (non-blocking hook).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

# Гейт по env — скрипт безопасно no-op если запущен вне worker-контекста.
[[ "${CLAUDE_WORKER_MODE:-}" == "interactive" ]] || exit 0
[[ -n "${CLAUDE_STORY_ID:-}" ]] || exit 0

STORY_ID="${CLAUDE_STORY_ID}"
WORKER_DIR="${STATE_DIR}/${STORY_ID,,}"  # lowercase story-NNN
MARKER="${WORKER_DIR}/blocked-waiting.json"

mkdir -p "${WORKER_DIR}" 2>/dev/null

# Читаем JSON из stdin и вытаскиваем превью первого вопроса (до 200 символов).
INPUT="$(cat 2>/dev/null || true)"
QUESTION_PREVIEW=""
if command -v jq >/dev/null 2>&1 && [[ -n "${INPUT}" ]]; then
  QUESTION_PREVIEW="$(printf '%s' "${INPUT}" | jq -r '.tool_input.questions[0].question // ""' 2>/dev/null | cut -c1-200)"
fi

TS="$(date -Iseconds)"
PANE="${TMUX_PANE:-}"
WAVE="${CLAUDE_WAVE_ID:-}"

jq -n \
  --arg ts "${TS}" \
  --arg story "${STORY_ID}" \
  --arg pane "${PANE}" \
  --arg wave "${WAVE}" \
  --arg preview "${QUESTION_PREVIEW}" \
  '{ts: $ts, story: $story, pane: $pane, wave: $wave, question_preview: $preview}' \
  > "${MARKER}.tmp" 2>/dev/null \
  && mv "${MARKER}.tmp" "${MARKER}"

exit 0
