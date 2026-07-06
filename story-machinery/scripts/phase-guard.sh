#!/usr/bin/env bash
# phase-guard.sh — validate phase transition before next phase starts.
#
# Contract:  .claude/rules/phase-contract.md
# Usage:     bash scripts/phase-guard.sh STORY-ID NEXT-PHASE
#            bash scripts/phase-guard.sh STORY-214 implement
#
# Guard запускается на крупных переходах /implement-story:
#   0 → 1 (pass "plan"):     validates context.json
#   1 → 2 (pass "implement"): validates plan.json
#   2 → 3 (pass "gate"):      validates diff.json
#   3 → 4 (pass "verify"):    validates gate.json
#   4 → 5 (pass "close"):     validates verify.json
#
# Exit codes:
#   0 — ok; фаза может стартовать
#   1 — blocked; фаза НЕ должна стартовать (stdout: {"status":"blocked","reason":"..."})
#   2 — warning; legacy worker-dir или non-critical issue (stdout: {"status":"warning",...})
#
# Output: ВСЕГДА компактный JSON в stdout (coordinator-friendly parse).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?usage: phase-guard.sh STORY-ID NEXT-PHASE}"
NEXT_PHASE="${2:?usage: phase-guard.sh STORY-ID NEXT-PHASE}"

# Accept both "STORY-214" and "214" as STORY_ID
if [[ "${STORY_ID}" != STORY-* ]]; then
  STORY_ID="STORY-${STORY_ID}"
fi
# Canonical story-dir — ВСЕГДА lowercase (ext4 case-sensitive; tmux/wrapper кладёт lowercase).
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
SID_LC="$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"
STORY_DIR="${STATE_DIR}/story-${SID_LC}"

PHASE_LOG="${STORY_DIR}/phase-log"

# Auto-recovery (opt-in via PHASE_GUARD_AUTO_RECOVER=1 или флага --auto-recover).
# Введено после Wave D06+D08+D09: D08 worker зависал на phase-log-missing 3×
# подряд + missing-required-keys:context.json 1× перед finally start (~30s burn).
# При AUTO_RECOVER:
#   - phase-log missing → create schema-v1 header
#   - context.json missing/incomplete → parse docs/stories/${ID}.md frontmatter,
#     write minimal {story_id, story_frontmatter, _complete:true, _ts}
# Default OFF (backwards-compat для legacy tests/strict ci).
AUTO_RECOVER="${PHASE_GUARD_AUTO_RECOVER:-0}"
for arg in "$@"; do
  if [[ "$arg" == "--auto-recover" ]]; then
    AUTO_RECOVER=1
    break
  fi
done

emit() {
  # emit STATUS REASON [EXTRA_JSON]
  local status="$1"
  local reason="$2"
  local extra="${3:-}"
  python3 - "${status}" "${reason}" "${extra}" "${STORY_ID}" "${NEXT_PHASE}" << 'PY'
import json, sys
status, reason, extra, story, nxt = sys.argv[1:6]
out = {"status": status, "story": story, "next_phase": nxt, "reason": reason}
if extra:
    try:
        out["extra"] = json.loads(extra)
    except Exception:
        out["extra_raw"] = extra
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
PY
}

# Step 1: schema-version check. Legacy worker-dir → warning+exit 0.
if [[ ! -f "${PHASE_LOG}" ]]; then
  if [[ "${AUTO_RECOVER}" == "1" ]]; then
    mkdir -p "${STORY_DIR}"
    NOW="$(date -Iseconds)"
    printf '{"schema":"v1","story":"%s","started":"%s","ts":"%s"}\n' \
      "${STORY_ID}" "${NOW}" "${NOW}" > "${PHASE_LOG}"
    # fall through to schema check below
  else
    emit "blocked" "phase-log-missing" ""
    exit 1
  fi
fi

FIRST_LINE=$(head -n1 "${PHASE_LOG}" 2>/dev/null || echo "")
SCHEMA=$(echo "${FIRST_LINE}" | jq -r '.schema // "legacy"' 2>/dev/null || echo "legacy")

if [[ "${SCHEMA}" != "v1" ]]; then
  emit "warning" "legacy-worker-dir-pre-v1-schema" ""
  exit 2
fi

# Step 2: pick required state file + mandatory keys for NEXT_PHASE.
case "${NEXT_PHASE}" in
  plan|1|1-plan)
    REQUIRED_FILE="context.json"
    REQUIRED_KEYS='["story_id","story_frontmatter"]'
    ;;
  implement|2|2-implement)
    REQUIRED_FILE="plan.json"
    REQUIRED_KEYS='["tasks","ac_mapping","executor_prompt"]'
    NONEMPTY_ARRAYS='["tasks"]'
    NONEMPTY_OBJECTS='["ac_mapping"]'
    NONEMPTY_STRINGS='["executor_prompt"]'
    ;;
  gate|3|3-gate)
    REQUIRED_FILE="diff.json"
    REQUIRED_KEYS='["changed_files","commits"]'
    NONEMPTY_ARRAYS='["changed_files","commits"]'
    ;;
  verify|4|4-verify)
    REQUIRED_FILE="gate.json"
    REQUIRED_KEYS='["lint","typecheck","tests"]'
    ;;
  close|5|5-close)
    REQUIRED_FILE="verify.json"
    REQUIRED_KEYS='["ac_results","mode"]'
    NONEMPTY_OBJECTS='["ac_results"]'
    NONEMPTY_STRINGS='["mode"]'
    ;;
  *)
    emit "blocked" "unknown-next-phase:${NEXT_PHASE}" ""
    exit 1
    ;;
esac

STATE_PATH="${STORY_DIR}/${REQUIRED_FILE}"

# Auto-recovery для context.json (phase=plan): если файл отсутствует или partial,
# собрать минимальный context из docs/stories/${ID}.md frontmatter.
if [[ "${AUTO_RECOVER}" == "1" && "${REQUIRED_FILE}" == "context.json" && ! -f "${STATE_PATH}" ]]; then
  STORY_DOCS_DIR="$(rcfg ao.story_dir docs/stories)"
  STORY_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/${STORY_DOCS_DIR}/${STORY_ID}.md"
  if [[ -f "${STORY_FILE}" ]]; then
    python3 - "${STORY_FILE}" "${STORY_ID}" "${STATE_PATH}" << 'RECOVER_PY'
import json, re, sys
from pathlib import Path
story_path = Path(sys.argv[1])
story_id = sys.argv[2]
out_path = Path(sys.argv[3])
text = story_path.read_text()
m = re.match(r'^---\n(.*?)\n---', text, re.DOTALL)
fm = {}
if m:
    for line in m.group(1).splitlines():
        line = line.rstrip()
        if not line or line.startswith('#'): continue
        mm = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$', line)
        if mm:
            key, val = mm.group(1), mm.group(2).strip()
            if val.startswith('"') and val.endswith('"'): val = val[1:-1]
            if val == '': val = None
            elif val.isdigit(): val = int(val)
            fm[key] = val
ctx = {
    "story_id": story_id,
    "story_frontmatter": fm,
    "_complete": True,
    "_ts": __import__("datetime").datetime.now().astimezone().isoformat(),
    "_auto_recovered": True,
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(ctx, ensure_ascii=False))
RECOVER_PY
  fi
fi

if [[ ! -f "${STATE_PATH}" ]]; then
  emit "blocked" "state-json-missing-for-previous-phase" '{"expected_file":"'"${REQUIRED_FILE}"'"}'
  exit 1
fi

# Step 3: validate contents via python (jq has edge cases with _complete/_skipped).
python3 - "${STATE_PATH}" "${REQUIRED_KEYS}" "${NONEMPTY_ARRAYS:-[]}" "${NONEMPTY_OBJECTS:-[]}" "${NONEMPTY_STRINGS:-[]}" "${STORY_ID}" "${NEXT_PHASE}" "${REQUIRED_FILE}" << 'PY'
import json, sys
from pathlib import Path

state_path = Path(sys.argv[1])
required_keys = json.loads(sys.argv[2])
nonempty_arrays = json.loads(sys.argv[3])
nonempty_objects = json.loads(sys.argv[4])
nonempty_strings = json.loads(sys.argv[5])
story_id = sys.argv[6]
next_phase = sys.argv[7]
file_name = sys.argv[8]

def emit(status, reason, extra=None):
    out = {"status": status, "story": story_id, "next_phase": next_phase, "reason": reason}
    if extra is not None:
        out["extra"] = extra
    print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))

try:
    data = json.loads(state_path.read_text())
except Exception as e:
    emit("blocked", f"state-file-invalid-json:{file_name}", {"error": str(e)})
    sys.exit(1)

if not isinstance(data, dict):
    emit("blocked", f"state-file-not-object:{file_name}")
    sys.exit(1)

completed = data.get("_complete") is True
skipped = data.get("_skipped") is True

if not completed and not skipped:
    emit("blocked", f"not-finalized:{file_name}-missing-_complete-or-_skipped")
    sys.exit(1)

if skipped and not data.get("_reason"):
    emit("blocked", f"skipped-without-reason:{file_name}")
    sys.exit(1)

# При _skipped: true обязательные ключи не проверяем — фаза пропущена осознанно.
if skipped:
    emit("ok", "skipped-ok", {"reason": data.get("_reason")})
    sys.exit(0)

# Проверяем обязательные ключи + non-empty инварианты.
missing = [k for k in required_keys if k not in data]
if missing:
    emit("blocked", f"missing-required-keys:{file_name}", {"missing": missing})
    sys.exit(1)

for k in nonempty_arrays:
    v = data.get(k)
    if not isinstance(v, list) or len(v) == 0:
        emit("blocked", f"array-empty-or-not-array:{k}", {"file": file_name})
        sys.exit(1)

for k in nonempty_objects:
    v = data.get(k)
    if not isinstance(v, dict) or len(v) == 0:
        emit("blocked", f"object-empty-or-not-object:{k}", {"file": file_name})
        sys.exit(1)

for k in nonempty_strings:
    v = data.get(k)
    if not isinstance(v, str) or v.strip() == "":
        emit("blocked", f"string-empty-or-not-string:{k}", {"file": file_name})
        sys.exit(1)

emit("ok", "complete-ok")
sys.exit(0)
PY
