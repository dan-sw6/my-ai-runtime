#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

# cleanup-stale-pids.sh — снимает stale PID-файлы и мёртвые tmux панели,
# чтобы .githooks/reference-transaction не блокировал merge.
#
# Симптом ДО фикса: worker exit 124 → tmux pane оставался "alive" с PID
# процесса-зомби. ${STATE_DIR}/story-X/pid показывал live PID →
# reference-transaction hook отклонял merge с сообщением:
#   [reference-transaction] Rejected ref updates: refs/heads/main(...->...)
#   [reference-transaction] Override: GIT_ALLOW_WORKER_COMMIT=1
#
# Поведение:
# 1. Скан ${STATE_DIR}/*/pid
# 2. Для каждого PID:
#    - kill -0 → если dead: rm pid file (cleanup stale)
#    - alive AND result.json существует и >10 байт (worker завершил доставку)
#      → tmux pane осталось живо после exit, активно убить (kill -9 + pkill -P)
# 3. Tmux session: prune мёртвые windows (где worker process exited)
#
# Output: краткий JSON отчёт что почистили.
#
# Usage:
#   bash scripts/cleanup-stale-pids.sh [--verbose]

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

cleaned_stale=0
killed_zombie=0
preserved_alive=0
cleaned_agent_marker=0
preserved_agent=0

shopt -s nullglob
for pidfile in "${STATE_DIR}"/story-*/pid; do
  pid="$(cat "${pidfile}" 2>/dev/null || echo "")"
  worker_dir="$(dirname "${pidfile}")"
  story="$(basename "${worker_dir}")"

  [[ -z "${pid}" ]] && { rm -f "${pidfile}"; cleaned_stale=$((cleaned_stale+1)); continue; }

  if ! kill -0 "${pid}" 2>/dev/null; then
    # Dead PID — remove stale file
    rm -f "${pidfile}"
    cleaned_stale=$((cleaned_stale+1))
    [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: removed stale pid ${pid}"
    continue
  fi

  # PID is alive — check if it's a zombie tmux pane after worker exit
  result_json="${worker_dir}/result.json"
  if [[ -f "${result_json}" ]]; then
    result_size=$(stat -c%s "${result_json}" 2>/dev/null || echo 0)
    if [[ "${result_size}" -gt 10 ]]; then
      # Worker delivered (result.json populated), but PID still alive →
      # tmux pane lingered. Kill it.
      pkill -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      sleep 0.3
      kill -9 "${pid}" 2>/dev/null || true
      rm -f "${pidfile}"
      killed_zombie=$((killed_zombie+1))
      [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: killed zombie tmux pane (pid ${pid}, result.json=${result_size}b)"
      continue
    fi
  fi

  # Truly alive worker (still running)
  preserved_alive=$((preserved_alive+1))
  [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: PRESERVED active worker (pid ${pid})"
done

# --- Agent-mode markers (/team-stories) ---
# running.json пишется координатором перед Agent() spawn, удаляется в B.1.9.
# Stale если: result.json уже есть (worker завершил, marker устарел) ИЛИ
# marker старше 6 часов (orphan от crashed координатора — Agent harness сам
# давно завершил агент). Activity = вживую висящий, не трогаем.
NOW=$(date +%s)
STALE_AGE_SEC=$((6*3600))
for marker in "${STATE_DIR}"/story-*/running.json; do
  [[ -f "${marker}" ]] || continue
  worker_dir="$(dirname "${marker}")"
  story="$(basename "${worker_dir}")"
  result_json="${worker_dir}/result.json"

  # Result.json present → worker delivered, marker is stale
  if [[ -f "${result_json}" ]] && [[ $(stat -c%s "${result_json}" 2>/dev/null || echo 0) -gt 10 ]]; then
    rm -f "${marker}"
    cleaned_agent_marker=$((cleaned_agent_marker+1))
    [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: removed agent marker (result.json present)"
    continue
  fi

  # Marker age > stale threshold → orphan from crashed coordinator
  marker_mtime=$(stat -c%Y "${marker}" 2>/dev/null || echo "${NOW}")
  age=$((NOW - marker_mtime))
  if (( age > STALE_AGE_SEC )); then
    rm -f "${marker}"
    cleaned_agent_marker=$((cleaned_agent_marker+1))
    [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: removed agent marker (age ${age}s > ${STALE_AGE_SEC}s)"
    continue
  fi

  # Otherwise — assume agent still running (harness owns lifecycle)
  preserved_agent=$((preserved_agent+1))
  [[ "${VERBOSE}" -eq 1 ]] && echo "[cleanup] ${story}: PRESERVED agent marker (age ${age}s)"
done

# JSON summary
printf '{"cleaned_stale":%d,"killed_zombie":%d,"preserved_alive":%d,"cleaned_agent_marker":%d,"preserved_agent":%d}\n' \
  "${cleaned_stale}" "${killed_zombie}" "${preserved_alive}" "${cleaned_agent_marker}" "${preserved_agent}"
