#!/usr/bin/env bash
# phase-guard-or-exit.sh STORY-ID <phase-name>
# Wrapper: запускает phase-guard, при blocked — логирует и exit 1; при ok — логирует start.
# Использование: bash scripts/phase-guard-or-exit.sh STORY-{ID} plan || exit 1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: phase-guard-or-exit.sh STORY-ID <phase-name>}"
PHASE_NAME="${2:?Usage: phase-guard-or-exit.sh STORY-ID <phase-name>}"

# Маппинг phase-name → phase-id (canonical IDs из phase-contract.md)
case "$PHASE_NAME" in
  plan)      PHASE_ID="1-plan" ;;
  implement) PHASE_ID="2-implement" ;;
  gate)      PHASE_ID="3-gate" ;;
  verify)    PHASE_ID="4-verify" ;;
  close)     PHASE_ID="5-close" ;;
  *) echo "Unknown phase: $PHASE_NAME" >&2; exit 64 ;;
esac

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WORKER_DIR="${CLAUDE_WORKER_DIR:-${STATE_DIR}/story-$(printf '%s' "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')}"

# Source helper (idempotent)
source "$SCRIPT_DIR/phase-log-util.sh"

# Auto-recover ON by default — phase-guard сам пополняет phase-log header и
# context.json (для phase=plan) из story frontmatter, экономит worker budget
# на retry-loop'ах (Wave D06+D08+D09 D08 worker burned ~30s на 4 retry).
# Чтобы отключить — `PHASE_GUARD_AUTO_RECOVER=0` в env.
export PHASE_GUARD_AUTO_RECOVER="${PHASE_GUARD_AUTO_RECOVER:-1}"

if ! guard_out=$(bash "$SCRIPT_DIR/phase-guard.sh" "$STORY_ID" "$PHASE_NAME"); then
  reason=$(echo "$guard_out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "unknown")
  log_phase_event "$WORKER_DIR" "$PHASE_ID" blocked "guard-failed:$reason"
  exit 1
fi

log_phase_event "$WORKER_DIR" "$PHASE_ID" start
