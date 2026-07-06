#!/usr/bin/env bash
# watch-waiting-workers.sh — background watcher для interactive workers.
#
# Поллит ${WATCH_ROOT}/story-*/blocked-waiting.json каждые POLL_INTERVAL
# секунд. При появлении нового marker'а — шлёт notify-send с инструкцией
# `tmux attach -t wave-N:story-NNN`. Помнит уже уведомлённые маркеры (по inode)
# чтобы не повторять notify при долгом ожидании.
#
# Использование (обычно вызывается run-stories orchestrator'ом):
#   bash scripts/watch-waiting-workers.sh &
#   WATCHER_PID=$!
#   # ... wave running ...
#   kill "${WATCHER_PID}" 2>/dev/null
#
# Env:
#   POLL_INTERVAL=2  — интервал опроса в секундах
#   WATCH_ROOT=${STATE_DIR}  — где искать маркеры (по умолчанию state_dir из runtime.config.yaml)
#   NOTIFY_URGENCY=critical  — `low|normal|critical`

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

POLL_INTERVAL="${POLL_INTERVAL:-2}"
WATCH_ROOT="${WATCH_ROOT:-$(rcfg state_dir /tmp/claude-workers)}"
NOTIFY_URGENCY="${NOTIFY_URGENCY:-critical}"

if ! command -v notify-send >/dev/null 2>&1; then
  echo "[watch-waiting-workers] notify-send not installed — watcher is a no-op." >&2
  # Не exit — оставляем цикл чтобы coordinator мог kill его без ошибки.
fi

mkdir -p "${WATCH_ROOT}" 2>/dev/null

# Запомненные inode'ы маркеров — чтобы не нотифаить повторно о том же событии.
declare -A SEEN

send_notify() {
  local marker="$1"
  local story pane wave preview body title

  if ! command -v jq >/dev/null 2>&1; then
    story="$(basename "$(dirname "${marker}")")"
    pane=""
    wave=""
    preview=""
  else
    story="$(jq -r '.story // ""' "${marker}" 2>/dev/null || echo "")"
    pane="$(jq -r '.pane // ""' "${marker}" 2>/dev/null || echo "")"
    wave="$(jq -r '.wave // ""' "${marker}" 2>/dev/null || echo "")"
    preview="$(jq -r '.question_preview // ""' "${marker}" 2>/dev/null || echo "")"
  fi

  [[ -z "${story}" ]] && story="$(basename "$(dirname "${marker}")")"

  title="⏸ ${story} waiting for input"
  if [[ -n "${wave}" ]]; then
    body="tmux attach -t ${wave}"
    [[ -n "${preview}" ]] && body="${body}

${preview}"
  else
    body="Worker paused on AskUserQuestion"
    [[ -n "${preview}" ]] && body="${body}: ${preview}"
  fi

  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u "${NOTIFY_URGENCY}" -a "run-stories" "${title}" "${body}" 2>/dev/null || true
  fi
  echo "[watch-waiting-workers] ${title} · ${body//$'\n'/ | }" >&2
}

cleanup_seen() {
  # Убираем inode'ы маркеров, которые уже исчезли — чтобы не накапливалось.
  local key
  for key in "${!SEEN[@]}"; do
    [[ -f "${SEEN[$key]}" ]] || unset 'SEEN[$key]'
  done
}

while :; do
  shopt -s nullglob
  for marker in "${WATCH_ROOT}"/story-*/blocked-waiting.json; do
    ino="$(stat -c '%i' "${marker}" 2>/dev/null || echo "")"
    [[ -z "${ino}" ]] && continue
    if [[ -z "${SEEN[${ino}]:-}" ]]; then
      SEEN[${ino}]="${marker}"
      send_notify "${marker}"
    fi
  done
  shopt -u nullglob
  cleanup_seen
  sleep "${POLL_INTERVAL}"
done
