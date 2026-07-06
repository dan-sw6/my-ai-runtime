#!/usr/bin/env bash
# phase-complete.sh — atomic "finalize phase" wrapper for /implement-story.
#
# Contract: .claude/rules/phase-contract.md
# Usage:
#   bash scripts/phase-complete.sh STORY-ID PHASE STATE-JSON-FILE
#
# Что делает:
# 1. Читает user-provided state-JSON (частичный, без _complete/_ts).
# 2. Валидирует required keys для фазы (per phase-contract).
# 3. Добавляет `_complete: true` + `_ts: <now ISO8601>`.
# 4. Пишет финальный state-JSON в state-dir (`state_dir`) под `story-{ID}/<phase>.json`.
# 5. Вызывает `log_phase_event <phase> complete`.
#
# Примеры phase значений: 0-init, 1-plan, 2-implement, 3-gate, 4-verify, 5-close.
# Микрофазы (0.1/2.1.5/2.2/3.3) — используй phase-skip.sh или log_phase_event event напрямую.
#
# STATE-JSON-FILE: путь к JSON-файлу с payload'ом (либо "-" для stdin).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?usage: phase-complete.sh STORY-ID PHASE STATE-JSON-FILE}"
PHASE="${2:?usage: phase-complete.sh STORY-ID PHASE STATE-JSON-FILE}"
STATE_INPUT="${3:?usage: phase-complete.sh STORY-ID PHASE STATE-JSON-FILE (use - for stdin)}"

# Worker-dir ALWAYS lowercase (ext4 case-sensitive; phase-guard.sh:32 normalizes
# identically). Raw ${STORY_ID#STORY-} caused story-D17 vs story-d17 split-brain
# (STORY-D17 incident 2026-05-19). Single source of truth: lowercase.
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="${STATE_DIR}/story-$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"

# Load input (file or stdin)
if [[ "${STATE_INPUT}" == "-" ]]; then
  PAYLOAD=$(cat)
else
  if [[ ! -f "${STATE_INPUT}" ]]; then
    echo "{\"error\":\"state-input-file-not-found:${STATE_INPUT}\"}" >&2
    exit 2
  fi
  PAYLOAD=$(cat "${STATE_INPUT}")
fi

# Phase → (output-filename, required-keys, non-empty-constraints).
# Payload передаётся через env var (избегаем quoting-проблем heredoc).
PAYLOAD="${PAYLOAD}" python3 - "${STORY_DIR}" "${PHASE}" "${STORY_ID}" << 'PY'
import json, os, re, sys, time
from pathlib import Path

story_dir = Path(sys.argv[1])
phase = sys.argv[2]
story_id = sys.argv[3]
payload_text = os.environ.get("PAYLOAD", "")

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

# Contract per phase
SPEC = {
    "0-init":      ("context.json", ["story_id", "story_frontmatter"], {}),
    "1-plan":      ("plan.json",    ["tasks", "ac_mapping", "executor_prompt", "planner_agent_used"],
                    {"arrays": ["tasks"], "objects": ["ac_mapping"], "strings": ["executor_prompt"],
                     "true_bools": ["planner_agent_used"]}),
    "2-implement": ("diff.json",    ["changed_files", "commits", "executor_dispatches"],
                    {"arrays": ["changed_files", "commits", "executor_dispatches"]}),
    "3-gate":      ("gate.json",    ["lint", "typecheck", "tests"], {}),
    "4-verify":    ("verify.json",  ["ac_results", "mode"],
                    {"objects": ["ac_results"], "strings": ["mode"]}),
    # 5-close: rtm_updated + summary_path обязательны. SRS-поле — одно из двух:
    # `srs_pending: true` (new contract 2026-05-21+, worker записал srs-pending.json
    # для coordinator) ИЛИ legacy `srs_updated: true` (worker сам обновил SRS).
    # Backward-compat — старые in-flight workers продолжают проходить валидацию.
    "5-close":     ("close.json",   ["rtm_updated", "summary_path"],
                    {"strings": ["summary_path"], "any_of_true": [["srs_pending", "srs_updated"]]}),
}

if phase not in SPEC:
    print(json.dumps({"status": "error", "reason": f"unknown-phase:{phase}",
                      "valid": list(SPEC.keys())}), file=sys.stderr)
    sys.exit(2)

filename, required, constraints = SPEC[phase]
state_path = story_dir / filename

try:
    data = json.loads(payload_text) if payload_text.strip() else {}
except Exception as e:
    print(json.dumps({"status": "error", "reason": f"invalid-json-payload: {e}"}), file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(json.dumps({"status": "error", "reason": "payload-not-object"}), file=sys.stderr)
    sys.exit(2)

# Validate required keys
missing = [k for k in required if k not in data]
if missing:
    print(json.dumps({"status": "error", "reason": "missing-required-keys",
                      "phase": phase, "missing": missing}), file=sys.stderr)
    sys.exit(2)

# Non-empty invariants
for k in constraints.get("arrays", []):
    v = data.get(k)
    if not isinstance(v, list) or len(v) == 0:
        print(json.dumps({"status": "error", "reason": f"array-empty-or-not-array:{k}",
                          "phase": phase}), file=sys.stderr)
        sys.exit(2)

for k in constraints.get("objects", []):
    v = data.get(k)
    if not isinstance(v, dict) or len(v) == 0:
        print(json.dumps({"status": "error", "reason": f"object-empty-or-not-object:{k}",
                          "phase": phase}), file=sys.stderr)
        sys.exit(2)

for k in constraints.get("strings", []):
    v = data.get(k)
    if not isinstance(v, str) or not v.strip():
        print(json.dumps({"status": "error", "reason": f"string-empty-or-not-string:{k}",
                          "phase": phase}), file=sys.stderr)
        sys.exit(2)

# `true_bools`: каждое поле должно быть literally True (не false, not None).
# Используется для mandate-флагов: planner_agent_used (Phase 1.3),
# executor_dispatches mandate enforcement (см. ниже Phase 2).
for k in constraints.get("true_bools", []):
    v = data.get(k)
    if v is not True:
        print(json.dumps({"status": "error", "reason": f"flag-not-true:{k}",
                          "phase": phase,
                          "hint": "MANDATORY agent dispatch flag — coordinator must call Agent() and set this true"}),
              file=sys.stderr)
        sys.exit(2)

# `any_of_true`: каждая группа — список ключей, минимум один должен быть True.
# Используется в Phase 5-close для backward-compat: либо srs_pending (new contract,
# 2026-05-21+), либо legacy srs_updated. Worker без обоих = incomplete close.
for group in constraints.get("any_of_true", []):
    if not any(data.get(k) is True for k in group):
        print(json.dumps({"status": "error", "reason": "none-of-flags-true",
                          "phase": phase, "group": group,
                          "hint": "Phase 5 close requires either srs_pending:true (new contract) or srs_updated:true (legacy). See implement-story/references/srs-sync.md"}),
              file=sys.stderr)
        sys.exit(2)

# Phase-specific: Phase 2 — executor_dispatches sanity (2026-05-14 mandate).
# Each dispatch ОБЯЗАН быть `subagent_type:"story-executor"`. general-purpose / inline ban.
if phase == "2-implement":
    dispatches = data.get("executor_dispatches", [])
    bad_dispatches = []
    for i, d in enumerate(dispatches):
        if not isinstance(d, dict):
            bad_dispatches.append(f"dispatches[{i}]:not-object")
            continue
        st = d.get("subagent_type", "")
        if st != "story-executor":
            bad_dispatches.append(f"dispatches[{i}].subagent_type={st!r}")
    if bad_dispatches:
        print(json.dumps({"status": "error", "reason": "executor-dispatch-not-story-executor",
                          "phase": phase, "bad": bad_dispatches,
                          "hint": "All task dispatches MUST use subagent_type=\"story-executor\" (2026-05-14 mandate)"}),
              file=sys.stderr)
        sys.exit(2)

# Phase-specific: 2-implement requires every commit SHA to be a real 40-char hex.
# Anti-placeholder guard: rejects "pending", "pending-phase-5", "TBD", short SHAs.
# 3 incidents 2026-05-08 (STORY-290/292/296): worker wrote "pending" in commits[].
if phase == "2-implement":
    bad_shas = []
    for i, c in enumerate(data.get("commits", [])):
        if isinstance(c, dict):
            sha = c.get("sha", "")
        elif isinstance(c, str):
            sha = c
        else:
            sha = ""
        if not sha or not SHA_RE.match(sha):
            bad_shas.append(f"commits[{i}]:{sha or '<empty>'}")
    if bad_shas:
        print(json.dumps({"status": "error", "reason": "commit-sha-not-hex40",
                          "phase": phase, "bad": bad_shas,
                          "hint": "use git rev-parse HEAD after commit; no placeholders"}),
              file=sys.stderr)
        sys.exit(2)

# Stamp completion
data["_complete"] = True
data["_ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")

story_dir.mkdir(parents=True, exist_ok=True)
state_path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
print(json.dumps({"status": "ok", "phase": phase, "state_file": str(state_path)}))
PY

# Log the event via helper (atomic JSON-lines append).
# State-JSON already written above — log_phase_event file-based check will pass.
# PHASE_COMPLETE_WRAPPER sentinel removed (STORY-230: env-based bypass was fragile).
# shellcheck source=phase-log-util.sh
source "$SCRIPT_DIR/phase-log-util.sh"
log_phase_event "${STORY_DIR}" "${PHASE}" complete
