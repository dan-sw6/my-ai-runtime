#!/usr/bin/env bash
# pr-merge-story.sh — push story-ветку → открыть PR → (опц.) squash-merge.
#
# Единый PR-merge для обоих каналов: /run-stories coordinator (B.1.4) и
# /implement-story standalone (Phase 5.6). Заменяет локальный
# merge-with-rtm-strategy.sh на активном пути: код приземляется на base-ветку
# ЧЕРЕЗ GitHub PR, а не локальным `git merge`.
#
# Контракт (решения 2026-06-05):
#   - merge по локальному gate, remote-CI НЕ ждём (CI бежит async как запись/дрейф-detector)
#   - pipeline авто-мержит при --auto-merge (squash + delete-branch)
#   - всё идемпотентно (повторный вызов не дублирует PR / не падает на merged)
#
# Предусловия (обеспечивает caller):
#   - worktree-gate.sh уже синхронил origin/<base> в worktree (Check 4.5) и дал pass:true
#   - RTM/SRS файлы НЕ в ветке (coordinator-single-writer — см. srs-sync.md), если SRS-модуль включён
#   - ветка worktree-<STORY-ID> существует с ≥1 коммитом поверх base
#
# Usage:
#   bash scripts/pr-merge-story.sh STORY-ID [--base BR] [--auto-merge] [--draft]
#                                  [--title T] [--body-file F] [--no-push]
#
# Output (stdout, последняя строка): JSON
#   {"status":"merged|pr-open|skipped|error","pr":N|null,"branch":"...","details":"..."}
# Exit: 0 = merged|pr-open|skipped ; 1 = error (caller эскалирует)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID [--base BR] [--auto-merge] [--draft] [--title T] [--body-file F] [--no-push]}"
shift || true

BASE="$(rcfg ao.base_ref main)"
AUTO_MERGE=0
DRAFT=0
PR_TITLE=""
BODY_FILE=""
NO_PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; shift ;;
    --auto-merge) AUTO_MERGE=1; shift ;;
    --draft) DRAFT=1; shift ;;
    --title) PR_TITLE="$2"; shift 2 ;;
    --title=*) PR_TITLE="${1#--title=}"; shift ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --body-file=*) BODY_FILE="${1#--body-file=}"; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
  esac
done

emit() {  # status pr branch details
  printf '{"status":"%s","pr":%s,"branch":"%s","details":%s}\n' \
    "$1" "${2:-null}" "${3:-}" \
    "$(printf '%s' "${4:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip()))')"
}

command -v gh >/dev/null 2>&1 || { emit "error" null "" "gh CLI not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { emit "error" null "" "gh not authenticated"; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { emit "error" null "" "not-a-git-repo"; exit 1; }
BRANCH="worktree-${STORY_ID}"
STORY_DIR="$(rcfg ao.story_dir docs/stories)"

# ── Branch sanity ──
if ! git -C "$REPO_ROOT" rev-parse --verify "refs/heads/${BRANCH}" >/dev/null 2>&1; then
  emit "error" null "$BRANCH" "branch refs/heads/${BRANCH} not found"
  exit 1
fi

# Ветка должна быть впереди base (иначе PR пустой).
AHEAD="$(git -C "$REPO_ROOT" rev-list --count "${BASE}..${BRANCH}" 2>/dev/null || echo 0)"
if [[ "$AHEAD" -eq 0 ]]; then
  emit "skipped" null "$BRANCH" "branch has 0 commits ahead of ${BASE} — nothing to PR"
  exit 0
fi

# ── Soft gate-guard: если есть gate.json и pass:false — отказ от merge ──
SID_LC="${STORY_ID#STORY-}"; SID_LC="${SID_LC,,}"
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
GATE_JSON="${STATE_DIR}/story-${SID_LC}/gate.json"
if [[ "$AUTO_MERGE" -eq 1 && -f "$GATE_JSON" ]]; then
  GATE_PASS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pass",""))' "$GATE_JSON" 2>/dev/null || echo "")"
  if [[ "$GATE_PASS" == "False" || "$GATE_PASS" == "false" ]]; then
    emit "error" null "$BRANCH" "gate.json pass=false — отказ от auto-merge (soft branch-protection)"
    exit 1
  fi
fi

# ── Step 1: push ветки на origin (idempotent) ──
if [[ "$NO_PUSH" -eq 0 ]]; then
  if ! git -C "$REPO_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1; then
    # non-fast-forward (ветка уже была запушена и переписана локально) → force-with-lease
    if ! git -C "$REPO_ROOT" push --force-with-lease -u origin "$BRANCH" >/dev/null 2>&1; then
      emit "error" null "$BRANCH" "push failed (origin/${BRANCH})"
      exit 1
    fi
  fi
fi

# ── Step 2: PR title/body ──
STORY_FILE="${REPO_ROOT}/${STORY_DIR}/${STORY_ID}.md"
if [[ -z "$PR_TITLE" ]]; then
  TITLE_RAW=""
  [[ -f "$STORY_FILE" ]] && TITLE_RAW="$(grep -m1 -E '^(title|name):' "$STORY_FILE" 2>/dev/null | sed -E 's/^(title|name):[[:space:]]*//; s/^"//; s/"$//' || true)"
  if [[ -n "$TITLE_RAW" ]]; then
    PR_TITLE="feat(${STORY_ID}): ${TITLE_RAW}"
  else
    PR_TITLE="feat(${STORY_ID}): pipeline story"
  fi
fi

BODY_TMP=""
if [[ -z "$BODY_FILE" ]]; then
  BODY_TMP="$(mktemp)"; BODY_FILE="$BODY_TMP"
  HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short "$BRANCH" 2>/dev/null || echo '?')"
  {
    echo "## Story: ${STORY_ID}"
    echo
    echo "Авто-PR от AI-pipeline (\`scripts/pr-merge-story.sh\`). Приземляется на \`${BASE}\` через squash-merge после прохождения локального worktree-gate."
    echo
    echo "- Ветка: \`${BRANCH}\` (${AHEAD} commit(s) ahead)"
    echo "- HEAD: \`${HEAD_SHA}\`"
    [[ -f "$STORY_FILE" ]] && echo "- Story: \`${STORY_DIR}/${STORY_ID}.md\`"
    echo
    echo "> Remote CI (ci.yml / playwright) бежит асинхронно как дрейф-detector — merge не ждёт его (решение: gate по локальному worktree-gate)."
  } > "$BODY_FILE"
fi

# ── Step 3: ensure PR (idempotent) ──
PR_NUM="$(gh pr list --repo "$REPO_ROOT" --head "$BRANCH" --base "$BASE" --state all --json number --jq '.[0].number' 2>/dev/null || true)"
if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  CREATE_ARGS=(--head "$BRANCH" --base "$BASE" --title "$PR_TITLE" --body-file "$BODY_FILE")
  [[ "$DRAFT" -eq 1 ]] && CREATE_ARGS+=(--draft)
  if ! gh pr create "${CREATE_ARGS[@]}" >/dev/null 2>&1; then
    [[ -n "$BODY_TMP" ]] && rm -f "$BODY_TMP"
    emit "error" null "$BRANCH" "gh pr create failed (head=${BRANCH} base=${BASE})"
    exit 1
  fi
  PR_NUM="$(gh pr list --head "$BRANCH" --base "$BASE" --state all --json number --jq '.[0].number' 2>/dev/null || true)"
fi
[[ -n "$BODY_TMP" ]] && rm -f "$BODY_TMP"

if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  emit "error" null "$BRANCH" "PR number unresolved after create"
  exit 1
fi

# Лейблы — best-effort (отсутствие лейбла не должно блокировать PR; см. ensure-gh-labels.sh)
GH_LABELS="$(rcfg_list ao.gh_labels | paste -sd, -)"
[[ -z "$GH_LABELS" ]] && GH_LABELS="ai-generated,story"
gh pr edit "$PR_NUM" --add-label "$GH_LABELS" >/dev/null 2>&1 || true

# ── Step 4: merge (idempotent, не ждём CI) ──
if [[ "$AUTO_MERGE" -eq 0 ]]; then
  emit "pr-open" "$PR_NUM" "$BRANCH" "PR #${PR_NUM} открыт; auto-merge выключен — нужен ручной merge"
  exit 0
fi

MERGED_AT="$(gh pr view "$PR_NUM" --json mergedAt --jq '.mergedAt' 2>/dev/null || true)"
if [[ -n "$MERGED_AT" && "$MERGED_AT" != "null" ]]; then
  emit "merged" "$PR_NUM" "$BRANCH" "PR #${PR_NUM} уже merged (${MERGED_AT})"
  exit 0
fi

# GitHub может ещё считать mergeable-состояние сразу после create — короткий retry.
for _ in 1 2 3 4 5 6; do
  if gh pr merge "$PR_NUM" --squash --delete-branch >/dev/null 2>&1; then
    emit "merged" "$PR_NUM" "$BRANCH" "PR #${PR_NUM} squash-merged → ${BASE}, remote-branch удалён"
    exit 0
  fi
  MERGED_AT="$(gh pr view "$PR_NUM" --json mergedAt --jq '.mergedAt' 2>/dev/null || true)"
  if [[ -n "$MERGED_AT" && "$MERGED_AT" != "null" ]]; then
    emit "merged" "$PR_NUM" "$BRANCH" "PR #${PR_NUM} merged (race) ${MERGED_AT}"
    exit 0
  fi
  sleep 5
done

emit "error" "$PR_NUM" "$BRANCH" "gh pr merge не прошёл за 6 попыток — конфликт/блокировка, нужен ручной разбор"
exit 1
