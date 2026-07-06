#!/usr/bin/env bash
# auto-fixup-from-review.sh STORY-ID [--wait-for-pid=PID] [--max-wait=60]
#
# Парсит review.json (точнее: `$(rcfg state_dir)/review-${STORY_ID}/result.json`,
# который пишет launch-review-worker.sh) и для каждого `severity: high` finding
# генерит fixup-story в `$(rcfg ao.story_dir)/STORY-<parent>-fixup{,N}.md`.
#
# Severity mapping (см. .claude/agents/solo-reviewer.md output schema):
#   high   → blocking, попадает в fixup-story (= P0/P1 в нотации story-spec)
#   medium → followup, не блокирует — отправляется в Phase C report only
#   low    → skip (минорные nits)
#
# Recursion guard: STORY-ID, содержащий `-fixup` → bail out
# (env `MAX_FIXUP_DEPTH=1` — по умолчанию один уровень).
#
# Output: JSON `{story, fixup_id|null, findings_blocking, findings_followup, status}`
#         status ∈ clean | created | skipped-no-blocking | skipped-recursion
#                  | skipped-result-missing | skipped-result-malformed
#                  | skipped-all-files-retracted | skipped-wait-timeout | error
# Exit: 0 на любом не-error пути (создание story — не failure для caller'а),
#       1 только на error (script bug / IO failure / invalid input).
#
# **Security note**: result.json — LLM-controlled untrusted text. Все Python-блоки
# принимают значения через sys.argv (не интерполируются в исходник через unquoted
# heredoc), и heredoc для генерации story-файла — single-quoted с placeholder
# подстановкой через sed-by-id (а не bash $-expansion). Это блокирует triple-quote
# и `$(cmd)` injection из finding'ов.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID [--wait-for-pid=PID] [--max-wait=60]}"
shift || true

# Defense-in-depth: STORY_ID становится частью пути. Запрещаем path-traversal.
if ! [[ "$STORY_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  printf '{"status":"error","details":"invalid-story-id:%s"}\n' "$STORY_ID"
  exit 1
fi

WAIT_PID=""
MAX_WAIT=60
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait-for-pid=*) WAIT_PID="${1#--wait-for-pid=}"; shift ;;
    --wait-for-pid) WAIT_PID="$2"; shift 2 ;;
    --max-wait=*) MAX_WAIT="${1#--max-wait=}"; shift ;;
    --max-wait) MAX_WAIT="$2"; shift 2 ;;
    *) printf '{"status":"error","details":"unknown-arg:%s"}\n' "$1"; exit 1 ;;
  esac
done

if [[ -n "$WAIT_PID" ]] && ! [[ "$WAIT_PID" =~ ^[0-9]+$ ]]; then
  printf '{"status":"error","details":"invalid-wait-pid:%s"}\n' "$WAIT_PID"
  exit 1
fi
if ! [[ "$MAX_WAIT" =~ ^[0-9]+$ ]]; then
  printf '{"status":"error","details":"invalid-max-wait:%s"}\n' "$MAX_WAIT"
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf '{"status":"error","details":"not-a-git-repo"}\n'
  exit 1
}

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="$(rcfg ao.story_dir docs/stories)"
FIXUP_CONTOUR="$(rcfg ao.fixup_contour tooling)"

REVIEW_DIR="${STATE_DIR}/review-${STORY_ID}"
RESULT_FILE="${REVIEW_DIR}/result.json"

emit() {
  python3 - "$@" <<'PY'
import json, sys
keys = sys.argv[1:]
out = {}
for kv in keys:
    k, _, v = kv.partition("=")
    if v.lstrip("-").isdigit():
        out[k] = int(v)
    elif v in ("true", "false"):
        out[k] = v == "true"
    elif v == "null":
        out[k] = None
    else:
        out[k] = v
print(json.dumps(out, separators=(",", ":")))
PY
}

# Recursion guard — если STORY-ID уже fixup-story, не плодим бесконечно
if [[ "$STORY_ID" == *-fixup* ]] && (( ${MAX_FIXUP_DEPTH:-1} <= 1 )); then
  emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=0" "findings_followup=0" "status=skipped-recursion"
  exit 0
fi

# Optional: ждём, пока review-worker завершится
if [[ -n "$WAIT_PID" ]]; then
  WAITED=0
  while kill -0 "$WAIT_PID" 2>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
      emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=0" "findings_followup=0" "status=skipped-wait-timeout"
      exit 0
    fi
    sleep 2
    WAITED=$((WAITED + 2))
  done
fi

if [[ ! -s "$RESULT_FILE" ]]; then
  emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=0" "findings_followup=0" "status=skipped-result-missing"
  exit 0
fi

# launch-review-worker.sh пишет text (claude --output-format text); реальная JSON
# может быть обёрнута в prose. Извлекаем последний (наиболее полный) JSON-блок.
# Single-quoted heredoc — LLM-controlled content в RESULT_FILE проходит через
# Python file-read, не через bash interpolation. Безопасно.
PARSED=$(python3 - "$RESULT_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    txt = f.read()
candidates = []
depth = 0
start = -1
for i, ch in enumerate(txt):
    if ch == "{":
        if depth == 0:
            start = i
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0 and start >= 0:
            candidates.append(txt[start:i+1])
            start = -1
parsed = None
for c in reversed(candidates):
    try:
        d = json.loads(c)
        if isinstance(d, dict) and "findings" in d:
            parsed = d
            break
    except Exception:
        continue
print(json.dumps(parsed) if parsed is not None else "")
PY
)

if [[ -z "$PARSED" || "$PARSED" == "null" ]]; then
  emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=0" "findings_followup=0" "status=skipped-result-malformed"
  exit 0
fi

BLOCKING=$(jq -c '[.findings[]? | select(.severity == "high")]' <<<"$PARSED")
FOLLOWUP=$(jq -c '[.findings[]? | select(.severity == "medium")]' <<<"$PARSED")
BLOCK_N=$(jq 'length' <<<"$BLOCKING")
FOLLOW_N=$(jq 'length' <<<"$FOLLOWUP")

if (( BLOCK_N == 0 )); then
  emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=0" "findings_followup=$FOLLOW_N" "status=skipped-no-blocking"
  exit 0
fi

# Edge case: все blocking findings указывают на retracted (несуществующий) файл.
# REPO_ROOT и BLOCKING — sys.argv (single-quoted heredoc), безопасно.
KEPT=$(python3 - "$REPO_ROOT" "$BLOCKING" <<'PY'
import json, os, sys
repo = sys.argv[1]
blocking = json.loads(sys.argv[2])
kept, retracted = [], []
for f in blocking:
    fp = f.get("file", "")
    if fp and os.path.exists(os.path.join(repo, fp)):
        kept.append(f)
    else:
        retracted.append(fp)
print(json.dumps({"kept": kept, "retracted": retracted}))
PY
)
KEPT_FINDINGS=$(jq -c '.kept' <<<"$KEPT")
RETRACTED_LIST=$(jq -c '.retracted' <<<"$KEPT")
KEPT_N=$(jq 'length' <<<"$KEPT_FINDINGS")

if (( KEPT_N == 0 )); then
  # Patch result.json — пометить blocking как auto_resolved.
  # RESULT_FILE и RETRACTED_LIST — sys.argv, не interpolation.
  python3 - "$RESULT_FILE" "$RETRACTED_LIST" <<'PY'
import json, sys
path = sys.argv[1]
retracted = json.loads(sys.argv[2])
with open(path, encoding="utf-8") as f:
    txt = f.read()
patched = txt.rstrip() + "\n\n<!-- auto-fixup-from-review: all blocking findings retracted (files removed): " + ",".join(retracted) + " -->\n"
with open(path, "w", encoding="utf-8") as f:
    f.write(patched)
PY
  emit "story=$STORY_ID" "fixup_id=null" "findings_blocking=$BLOCK_N" "findings_followup=$FOLLOW_N" "status=skipped-all-files-retracted"
  exit 0
fi

# Resolve fixup-story id (увеличиваем суффикс при существовании предыдущего;
# нумерация: первый = `-fixup` (без суффикса), затем `-fixup-2`, `-fixup-3`...
# `-fixup-1` слот не используется — смысловая равность с первым).
SUFFIX=""
N=1
while [[ -e "${REPO_ROOT}/${STORY_DIR}/STORY-${STORY_ID#STORY-}-fixup${SUFFIX}.md" ]]; do
  N=$((N + 1))
  SUFFIX="-${N}"
done
FIXUP_ID="STORY-${STORY_ID#STORY-}-fixup${SUFFIX}"
FIXUP_PATH="${REPO_ROOT}/${STORY_DIR}/${FIXUP_ID}.md"

# SP cap: 1 SP per blocking finding, max 3 (сверх — split by future iteration)
SP=$(( KEPT_N > 3 ? 3 : KEPT_N ))

# Generate story file content полностью через Python: kept findings + ids
# передаются как sys.argv. Никакой bash-interpolation для LLM-controlled данных.
# Output — финальное содержимое story-file на stdout.
STORY_CONTENT=$(python3 - "$FIXUP_ID" "$STORY_ID" "$SP" "$KEPT_FINDINGS" "$FIXUP_CONTOUR" "$STATE_DIR" <<'PY'
import json, sys
fixup_id, parent, sp_str, kept_json, contour, state_dir = sys.argv[1:7]
sp = int(sp_str)
findings = json.loads(kept_json)

# unique files for files_affected block
seen = []
for f in findings:
    fp = f.get("file") or "<no-file>"
    if fp not in seen:
        seen.append(fp)
files_block = "\n".join(f'  - "{fp}"' for fp in seen)

# EARS-notation (WHEN/IF/THEN) acceptance criteria — один пункт на kept finding.
ac_lines = []
for i, f in enumerate(findings, start=1):
    sev = f.get("severity", "high")
    summary = (f.get("finding") or f.get("summary") or "<no summary>").replace("\n", " ").strip()
    file_ = f.get("file", "<no-file>")
    line = f.get("line")
    line_str = f":{line}" if line else ""
    suggestion = (f.get("suggestion") or f.get("recommendation") or "").replace("\n", " ").strip()
    # Escape any embedded `"` so the YAML stays parseable.
    summary = summary.replace('"', "'")
    suggestion = suggestion.replace('"', "'")
    ac = f'  - "AC-{i}: IF the {sev}-severity finding at {file_}{line_str} is still present THEN the fix SHALL resolve: {summary}'
    if suggestion:
        ac += f' (suggested approach: {suggestion})'
    ac += '"'
    ac_lines.append(ac)
ac_block = "\n".join(ac_lines)

# files_affected на 0 finding'ах — невозможно, KEPT_N≥1 проверен выше.

print(f"""---
id: {fixup_id}
parent: {parent}
title: "Auto fix-up: {parent} review findings ({len(findings)} blocking)"
status: draft
contour: {contour}
priority: P1
story_points: {sp}
epic: "{contour}/auto-fixup"
requirement_refs: []
depends_on:
  - {parent}
blocked_by: []
files_affected:
{files_block}
acceptance_criteria:
{ac_block}
db_impact: none
rbac_changes: false
---

## Контекст

Auto-generated by `scripts/auto-fixup-from-review.sh` after `launch-review-worker.sh`
завершил review parent story `{parent}`. Все blocking findings (`severity: high`) —
критические замечания, требующие фикса до закрытия parent.

Source review file: `{state_dir}/review-{parent}/result.json`.

## Acceptance Criteria

См. `acceptance_criteria` в frontmatter — каждый пункт в EARS-нотации (WHEN/IF/THEN)
описывает отдельный finding из review с file:line + suggested fix.

## Lifecycle

После успешного merge этой fixup-story parent `result.json` уже patched HTML-комментарием
`<!-- auto-fixup-from-review: blocking findings handed off to {fixup_id} at <ISO>; count=N -->`
(добавлено в момент создания fixup-story). `MAX_FIXUP_DEPTH=1` — этот файл сам не порождает
свои fixup'ы (recursion guard в helper'е).
""")
PY
)

# Atomic write story file: tmpfile в story-dir (тот же FS) + mv.
TMP_PATH="$(mktemp -p "${REPO_ROOT}/${STORY_DIR}" .fixup-XXXXX.md)"
printf '%s' "$STORY_CONTENT" > "$TMP_PATH"
mv "$TMP_PATH" "$FIXUP_PATH"

# Patch parent result.json — append handoff HTML-comment.
python3 - "$RESULT_FILE" "$FIXUP_ID" "$KEPT_N" <<'PY'
import datetime, sys
path, fixup_id, count = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(path, encoding="utf-8") as f:
    txt = f.read()
patched = txt.rstrip() + f"\n\n<!-- auto-fixup-from-review: blocking findings handed off to {fixup_id} at {now}; count={count} -->\n"
with open(path, "w", encoding="utf-8") as f:
    f.write(patched)
PY

emit "story=$STORY_ID" "fixup_id=$FIXUP_ID" "findings_blocking=$KEPT_N" "findings_followup=$FOLLOW_N" "status=created"
exit 0
