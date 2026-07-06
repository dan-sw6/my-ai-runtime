#!/usr/bin/env bash
# render-wave-report.sh WAVE-ID STORY-IDS...
#
# Генерирует stub executive report по wave из:
# - commits diff <base-ref>..HEAD
# - AC results aggregated из ${STATE_DIR}/story-*/result.json
# - file change summary (commit list + numstat aggregated)
# - inline TODO для "Lessons learned" / "Next waves разблокированы"
#
# Coordinator затем дописывает narrative section (lessons, decisions). Эталон
# финального report — любой прошлый `docs/reports/wave-*-report.md` в проекте.
#
# Usage:
#   bash scripts/render-wave-report.sh wave-D06-D08-D09 STORY-D06 STORY-D08 STORY-D09
#
# Output: пишет в docs/reports/wave-<ID>-report.md (overwrites). Stdout — путь.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="$(rcfg ao.story_dir docs/stories)"
BASE_REF="$(rcfg ao.base_ref main)"

WAVE_ID="${1:?Usage: $0 WAVE-ID STORY-IDS...}"
shift
STORIES=("$@")
[[ ${#STORIES[@]} -gt 0 ]] || { echo "ERROR: нужен хотя бы один STORY-ID" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not-a-git-repo" >&2; exit 2; }
cd "$REPO_ROOT"

MAIN_REF=$(git merge-base HEAD "origin/${BASE_REF}" 2>/dev/null || git rev-parse HEAD~30)
REPORT_PATH="docs/reports/wave-${WAVE_ID,,}-report.md"
mkdir -p docs/reports

NOW=$(date +%Y-%m-%d)
HEAD_SHA=$(git rev-parse --short HEAD)

{
  echo "# Wave ${WAVE_ID} — executive report"
  echo
  echo "**Дата завершения**: ${NOW}"
  echo "**Базовая ветка**: $(git rev-parse --abbrev-ref HEAD)"
  echo "**HEAD**: \`${HEAD_SHA}\`"
  echo
  echo "## Executive summary"
  echo
  echo "<!-- TODO: 3-5 предложений narrative — coordinator дописывает -->"
  echo
  echo "## Stories"
  echo
  echo "| Story | Title | SP | Контур | AC | Verdict |"
  echo "|-------|-------|----|--------|-----|---------|"
  for SID in "${STORIES[@]}"; do
    SF="${STORY_DIR}/${SID}.md"
    if [[ -f "$SF" ]]; then
      TITLE=$(awk '/^title:/ { sub(/^title:[[:space:]]*"?/, ""); sub(/"$/, ""); print; exit }' "$SF")
      SP=$(awk '/^story_points:/ { print $2; exit }' "$SF")
      CONT=$(awk '/^contour:/ { print $2; exit }' "$SF")
    else
      TITLE="<missing-story-file>"; SP="?"; CONT="?"
    fi
    SID_LC=$(echo "${SID#STORY-}" | tr '[:upper:]' '[:lower:]')
    RES_FILE="${STATE_DIR}/story-${SID_LC}/result.json"
    if [[ -f "$RES_FILE" ]]; then
      AC_SUMMARY=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    ac=d.get('ac_results',{})
    passed=sum(1 for v in ac.values() if v=='pass')
    total=len(ac)
    print(f'{passed}/{total}')
except Exception:
    print('?')
" "$RES_FILE" 2>/dev/null)
      VERDICT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','?'))" "$RES_FILE" 2>/dev/null)
    else
      AC_SUMMARY="-"; VERDICT="-"
    fi
    echo "| ${SID} | ${TITLE} | ${SP} | ${CONT} | ${AC_SUMMARY} | ${VERDICT} |"
  done
  echo
  echo "## Commits"
  echo
  echo "\`\`\`"
  git log --oneline "${MAIN_REF}..HEAD" 2>/dev/null | head -50
  echo "\`\`\`"
  echo
  echo "## Files changed"
  echo
  CHANGE_COUNT=$(git diff --name-only "${MAIN_REF}..HEAD" 2>/dev/null | wc -l)
  INS=$(git diff --shortstat "${MAIN_REF}..HEAD" 2>/dev/null | grep -oE '[0-9]+ insertion' | awk '{print $1}')
  DEL=$(git diff --shortstat "${MAIN_REF}..HEAD" 2>/dev/null | grep -oE '[0-9]+ deletion' | awk '{print $1}')
  echo "- Files: ${CHANGE_COUNT}"
  echo "- Insertions: ${INS:-0}"
  echo "- Deletions: ${DEL:-0}"
  echo
  echo "## Покрытые требования (SRS)"
  echo
  for SID in "${STORIES[@]}"; do
    SF="${STORY_DIR}/${SID}.md"
    if [[ -f "$SF" ]]; then
      REFS=$(awk '/^requirement_refs:/,/^[a-z_]+:/' "$SF" | grep -E '^\s+-\s+' | sed -E 's/^\s+-\s+//' | tr '\n' ' ')
      echo "- **${SID}** — ${REFS:-<none>}"
    fi
  done
  echo
  echo "## Lessons learned"
  echo
  echo "<!-- TODO coordinator — incidents, retry-loops, architectural decisions -->"
  echo
  echo "## Next waves разблокированы"
  echo
  echo "<!-- TODO coordinator — какие downstream stories теперь не blocked -->"
  echo
  echo "## Verification"
  echo
  echo "\`\`\`bash"
  echo "git log --oneline ${MAIN_REF}..${HEAD_SHA}"
  if rcfg_bool srs.enabled; then
    echo "bash scripts/ao/srs/rebuild-rtm.sh"
  fi
  echo "# then run this project's configured gate commands (see runtime.config.yaml gates/ao.gate_registry)"
  echo "\`\`\`"
  echo
  echo "---"
  echo "_Сгенерировано \`scripts/render-wave-report.sh\` ${NOW}. Coordinator дописывает narrative-секции (executive summary, lessons learned, next waves)._"
} > "$REPORT_PATH"

echo "$REPORT_PATH"
