#!/usr/bin/env bash
# phase-skip.sh — atomic "skip phase" wrapper for /implement-story.
#
# Contract: .claude/rules/phase-contract.md (skip-reason registry)
# Usage:
#   bash scripts/phase-skip.sh STORY-ID PHASE REASON [METRICS-JSON]
# Examples:
#   bash scripts/phase-skip.sh STORY-214 0.1-mem-search no-deps-no-epic
#   bash scripts/phase-skip.sh STORY-214 2.1.5-simplify threshold-not-met '{"loc":187,"files":4}'
#   bash scripts/phase-skip.sh STORY-214 2.2-a11y mode-c-fingerprint-primary
#   bash scripts/phase-skip.sh STORY-214 3.3-audits no-god-nodes-no-security-no-perf
#
# Что делает:
# 1. Валидирует PHASE (canonical list).
# 2. Пишет state-JSON со `_skipped:true`, `_reason`, `_ts`, опциональными metrics.
#    Для крупных фаз (1-plan/2-implement/3-gate/4-verify/5-close) файл привязан к имени
#    из phase-contract (plan.json/diff.json/...). Для микрофаз — без state-файла, только phase-log.
# 3. Вызывает `log_phase_event <phase> skipped <reason> [metrics]`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?usage: phase-skip.sh STORY-ID PHASE REASON [METRICS-JSON]}"
PHASE="${2:?usage: phase-skip.sh STORY-ID PHASE REASON [METRICS-JSON]}"
REASON="${3:?usage: phase-skip.sh STORY-ID PHASE REASON [METRICS-JSON]}"
METRICS="${4:-}"

# Worker-dir ALWAYS lowercase (ext4 case-sensitive; matches phase-guard.sh /
# phase-complete.sh normalization — inconsistent casing caused story-D17 vs
# story-d17 split-brain, STORY-D17 incident 2026-05-19).
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="${STATE_DIR}/story-$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"

# Major phases → write skipped state-JSON (phase-guard будет видеть _skipped:true).
# Micro phases — только phase-log event, без файла.
PAYLOAD_ENV="${METRICS}" python3 - "${STORY_DIR}" "${PHASE}" "${REASON}" << 'PY'
import json, os, sys, time
from pathlib import Path

story_dir = Path(sys.argv[1])
phase = sys.argv[2]
reason = sys.argv[3]
metrics_text = os.environ.get("PAYLOAD_ENV", "")

MAJOR = {
    "0-init":      "context.json",
    "1-plan":      "plan.json",
    "2-implement": "diff.json",
    "3-gate":      "gate.json",
    "4-verify":    "verify.json",
    "5-close":     "close.json",
}
MICRO = {"0.1-mem-search", "2.1.5-simplify", "2.2-a11y", "3.3-audits"}

if phase not in MAJOR and phase not in MICRO:
    print(json.dumps({"status": "error", "reason": f"unknown-phase:{phase}"}), file=sys.stderr)
    sys.exit(2)

obj = {
    "_skipped": True,
    "_reason": reason,
    "_ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
}
if metrics_text.strip():
    try:
        obj["metrics"] = json.loads(metrics_text)
    except Exception as e:
        print(json.dumps({"status": "error", "reason": f"invalid-metrics-json: {e}"}), file=sys.stderr)
        sys.exit(2)

if phase in MAJOR:
    story_dir.mkdir(parents=True, exist_ok=True)
    state_path = story_dir / MAJOR[phase]
    state_path.write_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
    print(json.dumps({"status": "ok", "phase": phase, "state_file": str(state_path), "skipped": True}))
else:
    print(json.dumps({"status": "ok", "phase": phase, "skipped": True, "note": "micro-phase-no-state-file"}))
PY

# Emit phase-log event
# shellcheck source=phase-log-util.sh
source "$SCRIPT_DIR/phase-log-util.sh"
log_phase_event "${STORY_DIR}" "${PHASE}" skipped "${REASON}" "${METRICS}"
