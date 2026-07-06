#!/usr/bin/env bash
# resolve-story-runtime.sh STORY-ID
# Resolves runtime config (model, effort, budget, timeout) for a story.
#   Model/effort — configured per product (ao.worker_model / ao.worker_effort in
#   runtime.config.yaml), not derived per-story from SP/file-size (workers are
#   full Claude Code sessions, not subagents).
#
# File-size stats всё ещё считаются и пробрасываются в JSON (для diagnostics
# и для tmux ROUTE_REASON), но не меняют model selection.
#
# Outputs JSON: {"model","effort","budget","timeout","sp","reason","largest_file_loc","total_loc"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STORY_DOCS_DIR="$(rcfg ao.story_dir docs/stories)"
STORY_FILE="${REPO_ROOT}/${STORY_DOCS_DIR}/${STORY_ID}.md"

[[ -f "$STORY_FILE" ]] || { echo "{\"error\":\"story file not found: $STORY_FILE\"}" >&2; exit 1; }

# --- Parse frontmatter via shared helper ---
FM=$(bash "$SCRIPT_DIR/parse-story-frontmatter.sh" "$STORY_FILE")
ERR=$(echo "$FM" | jq -r '.error // empty')
[[ -z "$ERR" ]] || { echo "{\"error\":\"frontmatter-parse: $ERR\"}" >&2; exit 1; }

SP=$(echo "$FM" | jq -r '.story_points // 0')
CONTOUR=$(echo "$FM" | jq -r '.contour // ""')
FILES=$(echo "$FM" | jq -r '(.files_affected // []) | .[]')
DB_IMPACT=$(echo "$FM" | jq -r '.db_impact // ""')
RBAC_CHANGES=$(echo "$FM" | jq -r '.rbac_changes // false')

# --- Compute file-size stats ---
LARGEST_LOC=0
TOTAL_LOC=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Strip leading "  - " yaml decorations and inline comments / parenthetical hints
  clean=$(echo "$f" | sed -E 's/^[[:space:]]*-?[[:space:]]*//; s/[[:space:]]*\(.*$//; s/[[:space:]]+$//')
  full="${REPO_ROOT}/${clean}"
  if [[ -f "$full" ]]; then
    lc=$(wc -l < "$full" 2>/dev/null || echo 0)
    TOTAL_LOC=$((TOTAL_LOC + lc))
    (( lc > LARGEST_LOC )) && LARGEST_LOC=$lc
  fi
done <<< "$FILES"

# --- Routing ---
MODEL="$(rcfg ao.worker_model opus)"
EFFORT="$(rcfg ao.worker_effort xhigh)"
REASON="configured-worker-model-effort"

# --- Budget + timeout DISABLED by default (unbounded workers) ---
# Поля budget/timeout остаются в JSON выходе для backward-compat, но не enforce'я.
# Coordinator + launchers их игнорируют. Workers running unbounded.
BUDGET="0"
TIMEOUT=0

# Test-density multiplier удалён вместе с timeout enforcement.
TEST_FILE_COUNT=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.test.tsx|*.test.ts|*.test.js|*.test.jsx) TEST_FILE_COUNT=$((TEST_FILE_COUNT + 1)) ;;
  esac
done <<< "$FILES"

# --- Channel routing (run-stories — tmux only) ---
# Все stories идут в tmux workers: worktree-изоляция + fresh session + независимый
# review pipeline. Model selection берётся из runtime.config.yaml (см. выше).
#
# pre_flight_smokes — список ключей smoke'ов, которые preflight-gate.sh обязан
# отработать ДО запуска worker'а независимо от наличия файлов в files_affected.
# Сейчас единственный ключ — `migrations_check` (db_impact: migration). Это
# страховка от story, которая трогает миграции через косвенный путь (sql seed,
# data fixture) без явного файла в files_affected. Дальше по цепочке этот smoke
# гейтится наличием `ao.migrations_dir` в конфиге (пусто → skip).
ROUTE="tmux"
PRE_FLIGHT_SMOKES="[]"
if [[ "$DB_IMPACT" == "migration" ]] || [[ "$RBAC_CHANGES" == "true" ]]; then
  ROUTE_REASON="db-impact-or-rbac-force-tmux(db_impact=${DB_IMPACT:-none},rbac=${RBAC_CHANGES})"
  if [[ "$DB_IMPACT" == "migration" ]]; then
    PRE_FLIGHT_SMOKES='["migrations_check"]'
  fi
elif (( LARGEST_LOC > 500 )) || (( TOTAL_LOC >= 1500 )); then
  ROUTE_REASON="file-size-override(largest=${LARGEST_LOC},total=${TOTAL_LOC})"
elif (( SP < 5 )); then
  ROUTE_REASON="${CONTOUR:-unknown}-sp<5-tmux"
else
  ROUTE_REASON="${CONTOUR:-unknown}-sp${SP}-tmux"
fi

cat <<JSON
{"model":"${MODEL}","effort":"${EFFORT}","budget":"${BUDGET}","timeout":${TIMEOUT},"sp":${SP},"contour":"${CONTOUR}","reason":"${REASON}","largest_file_loc":${LARGEST_LOC},"total_loc":${TOTAL_LOC},"test_file_count":${TEST_FILE_COUNT},"route":"${ROUTE}","route_reason":"${ROUTE_REASON}","db_impact":"${DB_IMPACT}","rbac_changes":${RBAC_CHANGES},"pre_flight_smokes":${PRE_FLIGHT_SMOKES}}
JSON
