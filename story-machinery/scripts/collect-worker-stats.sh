#!/usr/bin/env bash
# collect-worker-stats.sh — Parse worker result.json + story frontmatter → append to CSV
# Usage: bash scripts/collect-worker-stats.sh STORY-ID [--wave N]
#
# Sources:
#   ${STATE_DIR}/{story-id}/result.json  → cost, tokens, duration, turns, model
#   ${STATE_DIR}/{story-id}/phase         → final phase
#   ${STATE_DIR}/{story-id}/exit_code     → success/failure
#   ${STATE_DIR}/{story-id}/phase-log     → per-phase timing (optional)
#   ${STORY_DIR}/{STORY-ID}.md            → SP, contour, priority, files, etc.
#
# Output: docs/project/worker-stats.csv (append, idempotent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/runtime-config-read.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "[ERROR] not a git repo" >&2; exit 1; }
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="$(rcfg ao.story_dir docs/stories)"
CSV_FILE="${REPO_ROOT}/docs/project/worker-stats.csv"

STORY_ID="${1:?Usage: $0 STORY-ID [--wave N] [--channel tmux|inline|agent]}"
WAVE="0"
CHANNEL_OVERRIDE=""

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wave) WAVE="$2"; shift 2 ;;
    --channel) CHANNEL_OVERRIDE="$2"; shift 2 ;;
    --channel=*) CHANNEL_OVERRIDE="${1#--channel=}"; shift ;;
    *) echo "[WARN] Unknown arg: $1"; shift ;;
  esac
done

# WORKER_DIR — lowercase canonical form (согласовано с launcher + wave-status.sh).
# Stub: tmux/subagent каналы пишут сюда; inline канал использует сиблинг-каталог
# inline-story/ рядом с STATE_DIR.
WORKER_DIR="${STATE_DIR}/story-${STORY_ID#STORY-}"
INLINE_DIR="$(dirname "${STATE_DIR}")/inline-story/${STORY_ID#STORY-}"
STORY_FILE="${REPO_ROOT}/${STORY_DIR}/${STORY_ID}.md"

# CSV header (32 columns — base + tool usage + channel for 3-tier routing)
HEADER="story_id,model,effort,sp,contour,priority,files_affected_count,ui_surface,db_impact,budget_usd,total_cost_usd,budget_util_pct,duration_ms,duration_api_ms,num_turns,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,cache_efficiency_pct,cost_per_sp,cost_per_turn,status,phase_reached,stop_reason,wave,date,mcp_calls,skill_calls,builtin_calls,top_mcp_servers,channel"

# Create CSV with header if not exists
if [[ ! -f "$CSV_FILE" ]]; then
  mkdir -p "$(dirname "$CSV_FILE")"
  echo "$HEADER" > "$CSV_FILE"
fi

# Idempotency: skip if story already in CSV (exact match on story_id column)
if grep -q "^${STORY_ID}," "$CSV_FILE" 2>/dev/null; then
  echo "[INFO] ${STORY_ID} already in CSV, skipping"
  exit 0
fi

# ── Resolve result.json source (tmux/subagent → WORKER_DIR; inline → INLINE_DIR) ──
RESULT_FILE=""
RESULT_SOURCE_CHANNEL=""
if [[ -s "${WORKER_DIR}/result.json" ]]; then
  RESULT_FILE="${WORKER_DIR}/result.json"
  RESULT_SOURCE_CHANNEL="tmux"   # default for worker-dir; refined below if JSON.channel present
elif [[ -s "${INLINE_DIR}/result.json" ]]; then
  RESULT_FILE="${INLINE_DIR}/result.json"
  RESULT_SOURCE_CHANNEL="inline"
else
  if [[ ! -f "${WORKER_DIR}/result.json" && ! -f "${INLINE_DIR}/result.json" ]]; then
    echo "[WARN] No result.json for ${STORY_ID} (checked ${WORKER_DIR} and ${INLINE_DIR})"
  else
    echo "[WARN] Empty result.json for ${STORY_ID} (worker likely SIGKILL'd mid-run) — skipping stats"
  fi
  exit 0
fi

# C.1+C.3 (2026-05-08): объединили парсинг result.json + frontmatter + derived
# metrics + session_id в ОДИН Python heredoc вместо 4 отдельных subprocess.
# Frontmatter parsing — через `parse-story-frontmatter.sh` (single source of truth).
FRONTMATTER_JSON='{}'
if [[ -f "$STORY_FILE" ]]; then
  FRONTMATTER_JSON=$(bash "${SCRIPT_DIR}/parse-story-frontmatter.sh" "$STORY_FILE" 2>/dev/null || echo '{}')
fi

eval "$(python3 - <<PY
import json, sys

# --- result.json ---
try:
    with open('${RESULT_FILE}') as f:
        d = json.load(f)
except (json.JSONDecodeError, ValueError) as e:
    sys.stderr.write(f'[WARN] Invalid JSON in result.json for ${STORY_ID}: {e}\n')
    sys.exit(42)

u = d.get('usage', {}) or {}
mu = d.get('modelUsage', {}) or {}

# Model from modelUsage keys (claude); inline emits minimal JSON — leave empty.
model = ''
for k in mu:
    model = k.replace('claude-', '')
    break

total_cost = d.get('total_cost_usd', 0) or 0
duration_ms = d.get('duration_ms', 0) or 0
if not duration_ms and d.get('duration_s'):
    duration_ms = int((d.get('duration_s') or 0) * 1000)
duration_api_ms = d.get('duration_api_ms', 0) or 0
num_turns = d.get('num_turns', 0) or 0
input_tokens = u.get('input_tokens', 0) or 0
output_tokens = u.get('output_tokens', 0) or 0
cache_read = u.get('cache_read_input_tokens', 0) or 0
cache_creation = u.get('cache_creation_input_tokens', 0) or 0
stop_reason = d.get('stop_reason', '') or ''
channel_self = d.get('channel', '') or ''
session_id = d.get('session_id', '') or ''

total_input = cache_read + input_tokens
cache_eff = round(cache_read / total_input * 100, 1) if total_input > 0 else 0

# --- frontmatter (from parse-story-frontmatter.sh) ---
fm = json.loads('''${FRONTMATTER_JSON}''') if '''${FRONTMATTER_JSON}'''.strip() else {}
sp = fm.get('story_points', '') or ''
contour = fm.get('contour', '') or ''
priority = fm.get('priority', '') or ''
ui_surface = fm.get('ui_surface', '') or ''
db_impact = fm.get('db_impact', '') or ''
fa = fm.get('files_affected', []) or []
files_count = len(fa) if isinstance(fa, list) else 0

# --- derived metrics ---
sp_num = float(sp) if (str(sp).replace('.','').isdigit() and float(sp) > 0) else 0
cost_per_sp = round(total_cost / sp_num, 2) if sp_num > 0 else ''
cost_per_turn = round(total_cost / num_turns, 4) if num_turns > 0 else ''

def sh(s):
    # bash-safe single-quote escape: ' → '\\''
    return str(s).replace("'", "'\\\\''")

print(f\"R_MODEL='{sh(model)}'\")
print(f\"R_COST={total_cost:.2f}\")
print(f\"R_DURATION_MS={int(duration_ms)}\")
print(f\"R_DURATION_API_MS={int(duration_api_ms)}\")
print(f\"R_TURNS={int(num_turns)}\")
print(f\"R_INPUT_TOKENS={int(input_tokens)}\")
print(f\"R_OUTPUT_TOKENS={int(output_tokens)}\")
print(f\"R_CACHE_READ={int(cache_read)}\")
print(f\"R_CACHE_CREATION={int(cache_creation)}\")
print(f\"R_CACHE_EFF={cache_eff}\")
print(f\"R_STOP_REASON='{sh(stop_reason)}'\")
print(f\"R_CHANNEL='{sh(channel_self)}'\")
print(f\"R_SESSION_ID='{sh(session_id)}'\")
print(f\"SP='{sh(sp)}'\")
print(f\"CONTOUR='{sh(contour)}'\")
print(f\"PRIORITY='{sh(priority)}'\")
print(f\"UI_SURFACE='{sh(ui_surface)}'\")
print(f\"DB_IMPACT='{sh(db_impact)}'\")
print(f\"FILES_COUNT={files_count}\")
print(f\"COST_PER_SP='{cost_per_sp}'\")
print(f\"COST_PER_TURN='{cost_per_turn}'\")
PY
)"

# If JSON parsing failed (exit 42 → eval gets empty) → R_COST unset → skip.
if [[ -z "${R_COST:-}" ]]; then
  echo "[WARN] Could not parse result.json for ${STORY_ID} — skipping stats"
  exit 0
fi

# ── Parse worker metadata ──
PHASE=$(cat "${WORKER_DIR}/phase" 2>/dev/null || echo "unknown")
EXIT_CODE=$(cat "${WORKER_DIR}/exit_code" 2>/dev/null || echo "")

# Determine status
if [[ "$PHASE" == *"phase-5"* ]] && [[ "$EXIT_CODE" == "0" || -z "$EXIT_CODE" ]]; then
  STATUS="done"
elif [[ -n "$EXIT_CODE" ]] && [[ "$EXIT_CODE" != "0" ]]; then
  STATUS="failed"
else
  STATUS="partial"
fi

# ── Parse launch parameters (from prompt.txt or infer) ──
EFFORT=$(grep -m1 "effort" "${WORKER_DIR}/prompt.txt" 2>/dev/null | grep -oP '(high|medium|low)' || echo "")
# Budget from launch args (not in result.json — extract from stderr or default)
BUDGET=""

# Derived: COST_PER_SP, COST_PER_TURN — уже посчитаны в едином Python-блоке выше.
# BUDGET_UTIL — нечем считать (BUDGET пустой, не передаётся в worker stderr); оставляем "".
BUDGET_UTIL=""
DATE=$(date +%Y-%m-%d)

# ── Resolve channel: --channel arg > result.json.channel > source-dir default ──
if [[ -n "$CHANNEL_OVERRIDE" ]]; then
  CHANNEL="$CHANNEL_OVERRIDE"
elif [[ -n "${R_CHANNEL:-}" ]]; then
  CHANNEL="$R_CHANNEL"
else
  CHANNEL="$RESULT_SOURCE_CHANNEL"
fi
# Validate
case "$CHANNEL" in
  tmux|inline|agent) ;;
  *) echo "[WARN] Unknown channel '${CHANNEL}', defaulting to tmux"; CHANNEL="tmux" ;;
esac

# ── Aggregate tool usage (conditional, C.2) ──
# session_id уже извлечён в едином Python-блоке как R_SESSION_ID. Aggregate
# вызывается ТОЛЬКО если jsonl существует — иначе поля остаются пустыми.
MCP_CALLS="" SKILL_CALLS="" BUILTIN_CALLS="" TOP_MCP=""

if [[ -n "${R_SESSION_ID:-}" ]] && [[ -f "${STATE_DIR}/tool-usage/${R_SESSION_ID}.jsonl" ]]; then
  TOOL_JSON=$(bash "${SCRIPT_DIR}/aggregate-tool-usage.sh" "${R_SESSION_ID}" --json 2>/dev/null || echo "{}")
  if [[ -n "$TOOL_JSON" ]] && [[ "$TOOL_JSON" != "{}" ]]; then
    read -r MCP_CALLS SKILL_CALLS BUILTIN_CALLS TOP_MCP < <(echo "$TOOL_JSON" | jq -r '
      [.mcp_calls // 0, .skill_calls // 0, .builtin_calls // 0,
       ([.mcp_by_server // {} | to_entries | sort_by(-.value) | .[:3][] | "\(.key):\(.value)"] | join(";"))]
      | @tsv')
  fi
fi

# ── Append to CSV ──
echo "${STORY_ID},${R_MODEL},${EFFORT},${SP},${CONTOUR},${PRIORITY},${FILES_COUNT},${UI_SURFACE},${DB_IMPACT},${BUDGET},${R_COST},${BUDGET_UTIL},${R_DURATION_MS},${R_DURATION_API_MS},${R_TURNS},${R_INPUT_TOKENS},${R_OUTPUT_TOKENS},${R_CACHE_READ},${R_CACHE_CREATION},${R_CACHE_EFF},${COST_PER_SP},${COST_PER_TURN},${STATUS},${PHASE},${R_STOP_REASON},${WAVE},${DATE},${MCP_CALLS},${SKILL_CALLS},${BUILTIN_CALLS},${TOP_MCP},${CHANNEL}" >> "$CSV_FILE"

echo "[INFO] Collected stats for ${STORY_ID}: channel=${CHANNEL}, cost=\$${R_COST}, turns=${R_TURNS}, duration=${R_DURATION_MS}ms, cache_eff=${R_CACHE_EFF}%, mcp=${MCP_CALLS}, skills=${SKILL_CALLS}, status=${STATUS}"
