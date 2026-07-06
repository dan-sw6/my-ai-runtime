#!/usr/bin/env bash
# wait-wave.sh — Wait for all story workers in a wave to complete (event-driven).
# Usage: bash scripts/wait-wave.sh STORY-178 STORY-189 [--interval 30] [--timeout 14400]
#
# Polls ${STATE_DIR}/story-{N}/ for completion signals (lowercase, matches
# launch-story-worker.sh). Multi-signal detection — first one to fire wins:
#
#   1. done.flag — written by Claude Code Stop hook (worker-signal-done.sh) AS
#      SOON AS skill produces a complete result.json. This is the primary
#      signal in interactive mode where TUI never auto-exits. Hook is registered
#      in .claude/settings.json (shared via git with worktrees).
#   2. result.json complete — file size >10b AND `.finished_at` set
#      OR `.status` ∈ {"done", "ok"}. Backup if Stop hook fired before
#      worker-signal-done.sh got installed (legacy worktrees) or hook crashed.
#   3. exit_code — written by tmux-wrapper.sh ONLY когда TUI exits. Reliable
#      for headless mode but useless in interactive (TUI doesn't auto-exit).
#
# Pre-loop check fires immediately if any worker already satisfied criteria
# before this script started (race-free re-launches and resume).
#
# Event-driven path uses inotifywait if installed (`apt install inotify-tools`).
# Fallback: 5s polling — same correctness, slightly higher CPU.
#
# Heartbeat: every 60s emits a still-waiting line to stdout so Monitor tool
# never goes silent during long waits. Cf. industry pattern from
# tmux-agent-status / claude-session-manager (status hooks + ~/.cache files).
#
# Outputs progress lines for Monitor tool consumption. Exits 0 when all
# workers done OR timeout (--timeout, default 14400s = 4h).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

STORIES=()
TIMEOUT=14400          # 4h wallclock cap
HEARTBEAT_INTERVAL=60  # stdout pulse so Monitor sees we're alive
POLL_INTERVAL=5        # fallback poll cadence when inotifywait unavailable

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --check-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --interval) POLL_INTERVAL="$2"; shift 2 ;;  # legacy alias
    --heartbeat) HEARTBEAT_INTERVAL="$2"; shift 2 ;;
    STORY-*) STORIES+=("$1"); shift ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ${#STORIES[@]} -eq 0 ]]; then
  echo "Usage: $0 STORY-ID [STORY-ID ...] [--timeout N] [--heartbeat N] [--interval N]" >&2
  exit 2
fi

TOTAL=${#STORIES[@]}
START=$(date +%s)

# ── Resolve worker dirs (lowercase canonical, matches launch-story-worker.sh) ──
declare -A WDIR_FOR
for id in "${STORIES[@]}"; do
  suffix="${id#STORY-}"
  WDIR_FOR["${id}"]="${STATE_DIR}/story-${suffix,,}"
done

# ── Completion criterion: any of done.flag | result.json complete | exit_code present ──
_is_worker_done() {
  local wdir="$1"
  # done.flag — primary (Stop hook).
  if [[ -s "${wdir}/done.flag" ]]; then return 0; fi
  # result.json — backup. Require >10 bytes AND finished_at OR status:done|ok.
  if [[ -s "${wdir}/result.json" ]] && [[ "$(wc -c < "${wdir}/result.json")" -gt 10 ]]; then
    if jq -e '
      (.finished_at != null and .finished_at != "")
      or (.status == "done")
      or (.status == "ok")
    ' "${wdir}/result.json" >/dev/null 2>&1; then
      return 0
    fi
  fi
  # exit_code — legacy headless signal (tmux-wrapper writes on TUI exit).
  if [[ -s "${wdir}/exit_code" ]]; then return 0; fi
  return 1
}

# ── Track which workers are still pending ──
declare -A PENDING
for id in "${STORIES[@]}"; do
  PENDING["${id}"]=1
done

_remaining_count() {
  local n=0
  for id in "${STORIES[@]}"; do
    [[ -n "${PENDING[${id}]+x}" ]] && n=$((n+1))
  done
  echo "${n}"
}

_remaining_list() {
  local out=()
  for id in "${STORIES[@]}"; do
    [[ -n "${PENDING[${id}]+x}" ]] && out+=("${id}")
  done
  echo "${out[*]}"
}

_check_all_pending() {
  # Returns 0 if any newly-completed worker was found and removed from PENDING.
  local newly_done=0
  for id in "${STORIES[@]}"; do
    [[ -z "${PENDING[${id}]+x}" ]] && continue
    if _is_worker_done "${WDIR_FOR[${id}]}"; then
      unset 'PENDING[${id}]'
      ELAPSED=$(( $(date +%s) - START ))
      echo "WORKER_DONE: ${id} after ${ELAPSED}s ($(_remaining_count)/${TOTAL} still running)"
      newly_done=1
    fi
  done
  return $((1 - newly_done))  # 0 if any newly done
}

# ── Pre-loop sweep: catch already-completed workers before entering the wait loop ──
_check_all_pending || true

# ── Wait loop ──
HAS_INOTIFY=0
if command -v inotifywait >/dev/null 2>&1; then
  HAS_INOTIFY=1
fi

LAST_HEARTBEAT=$(date +%s)
TIMED_OUT=0

while [[ "$(_remaining_count)" -gt 0 ]]; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))
  if [[ "${TIMEOUT}" -gt 0 ]] && [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    TIMED_OUT=1
    break
  fi

  if [[ "${HAS_INOTIFY}" -eq 1 ]]; then
    # Event-driven: block on the first fs event in any pending worker dir.
    # close_write — result.json/done.flag finalised by hook or skill.
    # moved_to    — atomic mv (worker-signal-done.sh uses mktemp+rename).
    # We cap the inotifywait lifetime at HEARTBEAT_INTERVAL so the heartbeat
    # ticks predictably even if no events arrive.
    DIRS_TO_WATCH=()
    for id in "${STORIES[@]}"; do
      [[ -z "${PENDING[${id}]+x}" ]] && continue
      DIRS_TO_WATCH+=("${WDIR_FOR[${id}]}")
    done
    # Some dirs may not exist yet (worker still launching) — filter them.
    EXISTING=()
    for d in "${DIRS_TO_WATCH[@]}"; do
      [[ -d "${d}" ]] && EXISTING+=("${d}")
    done
    if [[ ${#EXISTING[@]} -eq 0 ]]; then
      sleep 2
    else
      inotifywait \
        --quiet \
        --timeout "${HEARTBEAT_INTERVAL}" \
        --event close_write \
        --event moved_to \
        --event create \
        "${EXISTING[@]}" >/dev/null 2>&1 || true
    fi
  else
    sleep "${POLL_INTERVAL}"
  fi

  _check_all_pending || true

  # Heartbeat — emits a "still waiting" pulse каждые HEARTBEAT_INTERVAL секунд.
  # Without this, Monitor tool sees zero stdout for hours and assumes we hung.
  NOW=$(date +%s)
  if [[ $(( NOW - LAST_HEARTBEAT )) -ge "${HEARTBEAT_INTERVAL}" ]]; then
    if [[ "$(_remaining_count)" -gt 0 ]]; then
      ELAPSED=$(( NOW - START ))
      REMAIN="$(_remaining_list)"
      # Per-worker phase summary (best-effort — file may be missing).
      PHASES=""
      for id in ${REMAIN}; do
        ph=$(cat "${WDIR_FOR[${id}]}/phase" 2>/dev/null || echo "init")
        PHASES="${PHASES}${id}:${ph} "
      done
      echo "still-waiting elapsed=${ELAPSED}s remaining=$(_remaining_count)/${TOTAL} phases=[${PHASES%% }]"
    fi
    LAST_HEARTBEAT=${NOW}
  fi
done

# ── Print JSON summary ──
ELAPSED=$(( $(date +%s) - START ))

NONZERO_COUNT=0
TIMEOUT_COUNT=0
for id in "${STORIES[@]}"; do
  WDIR="${WDIR_FOR[${id}]}"
  if [[ -n "${PENDING[${id}]+x}" ]]; then
    TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
    NONZERO_COUNT=$((NONZERO_COUNT + 1))
    continue
  fi
  EC=$(cat "${WDIR}/exit_code" 2>/dev/null | tr -d '[:space:]')
  EC="${EC#exit_code=}"  # tmux-wrapper may write `exit_code=N` key=value; want bare N
  if [[ -z "${EC}" ]]; then
    # Done via done.flag/result.json but TUI still alive (typical interactive).
    # Treat as 0 if Stop hook fired (done.flag) OR result.json shows success.
    if [[ -s "${WDIR}/done.flag" ]]; then
      EC="0"
    elif [[ -s "${WDIR}/result.json" ]] && jq -e '.status == "done" or .status == "ok"' "${WDIR}/result.json" >/dev/null 2>&1; then
      EC="0"
    else
      EC="?"
    fi
  fi
  [[ "${EC}" != "0" ]] && NONZERO_COUNT=$((NONZERO_COUNT + 1))
done

if [[ "${TIMED_OUT}" -eq 1 ]]; then
  echo "WAVE_TIMEOUT: ${TIMEOUT_COUNT}/${TOTAL} workers exceeded ${TIMEOUT}s wallclock — workers may still be running, coordinator decides whether to kill or wait"
elif [[ "${NONZERO_COUNT}" -eq 0 ]]; then
  echo "WAVE_COMPLETE: all ${TOTAL} workers done in ${ELAPSED}s"
else
  echo "WAVE_PARTIAL: ${NONZERO_COUNT}/${TOTAL} workers non-zero exit_code in ${ELAPSED}s — coordinator NOT to merge failed/timeout-killed stories, route to Phase B.2 resume"
fi

echo "{"
for id in "${STORIES[@]}"; do
  WDIR="${WDIR_FOR[${id}]}"
  EC=$(cat "${WDIR}/exit_code" 2>/dev/null | tr -d '[:space:]')
  EC="${EC#exit_code=}"  # tmux-wrapper may write `exit_code=N` key=value; want bare N
  if [[ -z "${EC}" ]]; then
    if [[ -s "${WDIR}/done.flag" ]]; then
      EC="0"  # Stop hook signalled — treat as success unless overridden by exit_code
    elif [[ -s "${WDIR}/result.json" ]] && jq -e '.status == "done" or .status == "ok"' "${WDIR}/result.json" >/dev/null 2>&1; then
      EC="0"
    else
      EC="?"
    fi
  fi
  PHASE=$(cat "${WDIR}/phase" 2>/dev/null || echo "unknown")
  if [[ -s "${WDIR}/result.json" ]]; then
    RESULT_SIZE=$(wc -c < "${WDIR}/result.json")
  else
    RESULT_SIZE=0
  fi
  HAS_DONE_FLAG=$(test -s "${WDIR}/done.flag" && echo true || echo false)

  COST="0"
  case "${EC}" in
    0)   STATUS="done" ;;
    124) STATUS="timeout-killed" ;;
    \?)  STATUS="failed-no-exit-code" ;;
    *)   STATUS="failed-exit-${EC}" ;;
  esac
  if [[ -n "${PENDING[${id}]+x}" ]]; then
    STATUS="timed-out"
    EC="?"
  fi
  # Only flag empty-result if neither done.flag (authoritative Stop hook) nor a
  # result.json with completion markers is present.
  if [[ "${EC}" == "0" ]] && [[ "${RESULT_SIZE}" -le 10 ]] && [[ "${HAS_DONE_FLAG}" != "true" ]]; then
    STATUS="failed-empty-result"
  fi
  if [[ "${RESULT_SIZE}" -gt 10 ]]; then
    COST=$(python3 -c "import json; print(json.load(open('${WDIR}/result.json')).get('total_cost_usd',0))" 2>/dev/null || echo "0")
  fi

  echo "  \"${id}\": {\"status\": \"${STATUS}\", \"exit_code\": \"${EC}\", \"phase\": \"${PHASE}\", \"result_bytes\": ${RESULT_SIZE}, \"done_flag\": ${HAS_DONE_FLAG}, \"cost\": ${COST}},"
done
echo "  \"elapsed_s\": ${ELAPSED},"
echo "  \"timed_out\": $( [[ ${TIMED_OUT} -eq 1 ]] && echo true || echo false ),"
WSTATUS=$( [[ ${TIMED_OUT} -eq 1 ]] && echo TIMEOUT || ( [[ ${NONZERO_COUNT} -eq 0 ]] && echo COMPLETE || echo PARTIAL ) )
echo "  \"wave_status\": \"${WSTATUS}\""
echo "}"
# Exit 0 даже при PARTIAL/TIMEOUT — coordinator сам решает per-story merge/resume.
exit 0
