#!/usr/bin/env bash
# wave-dashboard.sh — live dashboard для `_control` pane в tmux session wave-current.
# Показывает статус всех workers в этой wave — pid/alive/result-size/waiting-marker.
# Запускается автоматически из launch-story-worker-interactive.sh при создании session.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
INTERVAL="${DASHBOARD_INTERVAL:-3}"

while :; do
  clear
  echo "=== wave-current · dashboard ($(date '+%H:%M:%S')) ==="
  echo ""
  echo "Attach worker pane:  tmux select-window -t story-NNN"
  echo "Next / prev:         Ctrl+b n / Ctrl+b p"
  echo "Kill all:            tmux kill-session"
  echo ""
  echo "-----------------------------------------------------------------"
  printf "%-22s %-7s %-6s %-10s %s\n" "STORY-DIR" "PID" "ALIVE" "RESULT" "WAITING"
  echo "-----------------------------------------------------------------"

  shopt -s nullglob
  dirs=("${STATE_DIR}"/story-*/)
  shopt -u nullglob

  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "  (no workers yet)"
  else
    for d in "${dirs[@]}"; do
      id=$(basename "$d")
      pid=$(cat "${d}/pid" 2>/dev/null || echo "-")
      if [[ "${pid}" != "-" ]] && kill -0 "${pid}" 2>/dev/null; then
        alive="alive"
      else
        alive="gone"
      fi
      if [[ -f "${d}/result.json" ]]; then
        result_size=$(wc -c < "${d}/result.json" 2>/dev/null || echo 0)
      else
        result_size=0
      fi
      if [[ -f "${d}/blocked-waiting.json" ]]; then
        waiting="YES (ответьте в пане!)"
      else
        waiting="-"
      fi
      printf "%-22s %-7s %-6s %-10s %s\n" "${id}" "${pid}" "${alive}" "${result_size}B" "${waiting}"
    done
  fi

  echo ""
  echo "Recent notifications (watcher log):"
  tail -3 "${STATE_DIR}/watcher.log" 2>/dev/null | sed 's/^/  /' || echo "  (no watcher log)"

  sleep "${INTERVAL}"
done
