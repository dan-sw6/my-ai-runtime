#!/usr/bin/env bash
# phase-log-util.sh — helper functions for /implement-story phase logging
#
# Contract: .claude/rules/phase-contract.md
# Usage:    source this file in scripts or worker sessions.
#           log_phase_event STORY_DIR PHASE STATUS [REASON] [METRICS_JSON]
#
# Invariant: один event = одна строка JSON <500 байт. Bash append `>>` атомарен
# для PIPE_BUF (4KB на Linux), что гарантирует single-writer без flock.

set -euo pipefail

# log_phase_event: атомарно дописывает JSON-line в phase-log
# Аргументы:
#   $1 — story-dir (например /tmp/claude-workers/story-214)
#   $2 — phase ID (например "2-implement", "2.1.5-simplify")
#   $3 — status (start|complete|skipped|failed|blocked)
#   $4 — reason (опционально; обязателен для skipped/failed/blocked)
#   $5 — metrics JSON (опционально, напр. '{"loc":187,"files":4}')
log_phase_event() {
  local story_dir="${1:?story-dir required}"
  local phase="${2:?phase required}"
  local _status="${3:?status required}"
  local reason="${4:-}"
  local metrics="${5:-}"

  # Enforcement: major phases MUST have state-JSON before recording complete.
  # File-based check: verifies {phase}.json with _complete:true or _skipped:true exists
  # in worker-dir. This replaces the fragile PHASE_COMPLETE_WRAPPER=1 sentinel
  # (three bypass vectors: manual env set, env inheritance, direct echo to phase-log).
  # Microphases (0.1-mem-search, 2.1.5-simplify, 2.2-a11y, 3.3-audits) — allowed directly.
  if [[ "${_status}" == "complete" ]]; then
    case "${phase}" in
      0-init|1-plan|2-implement|3-gate|4-verify|5-close)
        local _state_file=""
        case "${phase}" in
          0-init)      _state_file="context.json" ;;
          1-plan)      _state_file="plan.json" ;;
          2-implement) _state_file="diff.json" ;;
          3-gate)      _state_file="gate.json" ;;
          4-verify)    _state_file="verify.json" ;;
          5-close)     _state_file="close.json" ;;
        esac
        local _state_path="${story_dir}/${_state_file}"
        if [[ ! -f "${_state_path}" ]]; then
          echo "[ERROR] log_phase_event: major phase '${phase}' complete requires state-JSON" >&2
          echo "[ERROR] Expected: ${_state_path}" >&2
          echo "[ERROR] state-json missing: create via phase-complete.sh" >&2
          return 3
        fi
        local _has_flag
        _has_flag=$(python3 -c "
import json, sys
try:
    d = json.loads(open(sys.argv[1]).read())
    print('1' if d.get('_complete') or d.get('_skipped') else '0')
except Exception:
    print('0')
" "${_state_path}")
        if [[ "${_has_flag}" != "1" ]]; then
          echo "[ERROR] log_phase_event: ${_state_path} lacks _complete:true or _skipped:true" >&2
          echo "[ERROR] state-json missing: create via phase-complete.sh" >&2
          return 3
        fi
        ;;
    esac
  fi

  local phase_log="${story_dir}/phase-log"
  local phase_file="${story_dir}/phase"
  local ts
  ts=$(date -Iseconds)

  mkdir -p "${story_dir}"

  # Собрать JSON через python3 — безопасная сериализация, гарантированная one-line.
  local line
  line=$(python3 - "${ts}" "${phase}" "${_status}" "${reason}" "${metrics}" << 'PY'
import json, sys
ts, phase, status, reason, metrics = sys.argv[1:6]
obj = {"ts": ts, "phase": phase, "status": status}
if reason:
    obj["reason"] = reason
if metrics:
    try:
        obj["metrics"] = json.loads(metrics)
    except Exception:
        obj["metrics_raw"] = metrics
# compact, no trailing newline — printf ниже добавит ровно один \n
print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")), end="")
PY
  )

  # Dedup guard (devcycle-audit #15, 2026-05-29): drop a re-log of the SAME
  # (phase,status) as the last event. Worker re-entry / double-log produced
  # duplicate `0-init complete` + `4-verify start` lines that reset the
  # stuck-detection elapsed anchor in wave-status.sh. Legit phase changes pass;
  # only identical consecutive transitions are skipped (phase pointer still updated below).
  if [[ -s "${phase_log}" ]]; then
    local _last
    _last=$(tail -n1 "${phase_log}" 2>/dev/null)
    if printf '%s' "${_last}" | grep -q "\"phase\":\"${phase}\"" \
       && printf '%s' "${_last}" | grep -q "\"status\":\"${_status}\""; then
      printf '%s\n' "phase-${phase}$([[ "${_status}" == "complete" ]] && echo "-complete")" > "${phase_file}"
      return 0
    fi
  fi

  # Atomic append: printf в single syscall через O_APPEND (bash >>)
  printf '%s\n' "${line}" >> "${phase_log}"

  # phase file — текущее состояние (совместимость с legacy readers)
  local phase_file_value="phase-${phase}"
  if [[ "${_status}" == "complete" ]]; then
    phase_file_value="phase-${phase}-complete"
  elif [[ "${_status}" == "skipped" ]]; then
    phase_file_value="phase-${phase}-skipped:${reason:-unspecified}"
  elif [[ "${_status}" == "failed" ]]; then
    phase_file_value="phase-${phase}-failed:${reason:-unspecified}"
  elif [[ "${_status}" == "blocked" ]]; then
    phase_file_value="phase-${phase}-blocked:${reason:-unspecified}"
  fi
  printf '%s\n' "${phase_file_value}" > "${phase_file}"
}

# log_phase_init: пишет schema:v1 маркер первой строкой phase-log.
# Идемпотентен: если phase-log уже существует со schema marker'ом v1 — не truncate'ит,
# а дописывает событие "init-skipped:already-initialized" (защита от двойной инициализации
# launcher'ом и skill'ом — bug discovered in STORY-214 pilot).
log_phase_init() {
  local story_dir="${1:?story-dir required}"
  local story_id="${2:?story-id required}"

  local phase_log="${story_dir}/phase-log"
  local ts
  ts=$(date -Iseconds)

  mkdir -p "${story_dir}"

  # Idempotent check: если уже есть v1 schema marker — не truncate'им (иначе теряются все events).
  if [[ -f "${phase_log}" ]]; then
    local first_line
    first_line=$(head -n1 "${phase_log}" 2>/dev/null || echo "")
    local existing_schema
    existing_schema=$(echo "${first_line}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('schema','legacy'))" 2>/dev/null || echo "legacy")
    if [[ "${existing_schema}" == "v1" ]]; then
      # Уже инициализирован — пишем диагностическое событие и выходим.
      local skip_line
      skip_line=$(python3 - "${ts}" << 'PY'
import json, sys
ts = sys.argv[1]
print(json.dumps({"ts": ts, "phase": "0-init", "status": "init-skipped", "reason": "already-initialized"},
                 ensure_ascii=False, separators=(",", ":")), end="")
PY
      )
      printf '%s\n' "${skip_line}" >> "${phase_log}"
      return 0
    fi
  fi

  local line
  line=$(python3 - "${ts}" "${story_id}" << 'PY'
import json, sys
ts, story_id = sys.argv[1:3]
obj = {"schema": "v1", "story": story_id, "started": ts, "ts": ts}
print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")), end="")
PY
  )

  # Truncate + write (первая строка всегда schema marker — только при first init).
  printf '%s\n' "${line}" > "${phase_log}"
}

# Если скрипт вызван напрямую (не source) — CLI режим для debug:
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  cmd="${1:?usage: phase-log-util.sh (init|event) ARGS...}"
  shift
  case "${cmd}" in
    init)  log_phase_init "$@" ;;
    event) log_phase_event "$@" ;;
    *) echo "unknown cmd: ${cmd}" >&2; exit 2 ;;
  esac
fi
