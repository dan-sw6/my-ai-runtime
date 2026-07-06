#!/usr/bin/env bash
# worker-liveness.sh <STORY-ID> — cheap "is the worker actually working vs
# stalled at idle prompt" probe. Replaces ad-hoc per-session pane/live.log
# token-counter scraping (coordinator did this manually all over Wave 0).
#
# Heuristic: sample live.log size twice (default 2s apart). Growth ⇒ the TUI
# is producing tokens ⇒ active. Also surfaces current phase and whether the
# worker is inside a corrective loop (phase-log lags during corrective rounds,
# so a frozen phase + growing log = working, not stuck).
#
# Usage: scripts/worker-liveness.sh STORY-347 [sample_secs]
# Output: single JSON line
#   {"story","active":bool,"log_delta_bytes":N,"phase","in_corrective":bool,
#    "result_json":bool,"sample_s":N}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

SID_RAW="${1:?Usage: worker-liveness.sh STORY-ID [sample_secs]}"
SAMPLE="${2:-2}"
SID_LC=$(echo "${SID_RAW#STORY-}" | tr '[:upper:]' '[:lower:]')
DIR="${STATE_DIR}/story-${SID_LC}"
LOG="${DIR}/live.log"

sz() { [[ -f "$1" ]] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

S1=$(sz "${LOG}")
sleep "${SAMPLE}"
S2=$(sz "${LOG}")
DELTA=$(( S2 - S1 ))

PHASE=$(cat "${DIR}/phase" 2>/dev/null || echo "unknown")
RESULT_JSON=false
[[ -s "${DIR}/result.json" ]] && [[ "$(wc -c < "${DIR}/result.json" 2>/dev/null | tr -d ' ')" -gt 10 ]] && RESULT_JSON=true

# Corrective-loop detection: tail of live.log (strip ANSI) mentions corrective
# round / story-executor corrective dispatch.
IN_CORR=false
if [[ -f "${LOG}" ]]; then
  if tail -c 8000 "${LOG}" 2>/dev/null | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
       | grep -qiE 'corrective (r|round)|Corrective:'; then
    IN_CORR=true
  fi
fi

ACTIVE=false
[[ "${DELTA}" -gt 0 ]] && ACTIVE=true

printf '{"story":"STORY-%s","active":%s,"log_delta_bytes":%d,"phase":"%s","in_corrective":%s,"result_json":%s,"sample_s":%s}\n' \
  "${SID_LC}" "${ACTIVE}" "${DELTA}" "${PHASE}" "${IN_CORR}" "${RESULT_JSON}" "${SAMPLE}"
