> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

## Phase 5: CLOSE

> **CHECKPOINT 3 — CRITICAL**: Phase 5 contains 6 mandatory steps (5.0 → 5.5).
> Do NOT produce the final report (5.2) and skip the rest.
> Complete ALL steps in order: **[5.0 Write result.json — INTERACTIVE-ONLY, FIRST] → RTM/SRS sync (5.1) → Report (5.2) → cross-session summary (5.3) → Progress close (5.4) → [5.5 Close tmux window — INTERACTIVE-ONLY, LAST]**.
> **5.3 НЕ пропускать** — structured summary = основной источник контекста для будущих workers.

> **Merge scope clarification**: Phase 5 **НЕ делает локальный merge** worktree-branch → target. Landing — через **PR-flow**: `/run-stories` coordinator (после wave gate) push → open PR → squash-merge → ff-sync, либо standalone — Phase 5.4.1 (`scripts/ao/pr-merge-story.sh`). **Worker НЕ должен** делать `git merge --no-ff` сам — это ответственность coordinator/PR-flow (см. `.claude/skills/run-stories/SKILL.md`, если этот orchestrating skill присутствует в проекте).

### 5.0 Write result.json (INTERACTIVE MODE — BLOCKING FIRST STEP)

> **⚠ BLOCKING CHECKPOINT 5.0** — если `CLAUDE_WORKER_MODE=interactive`, этот шаг **ПЕРВЫЙ** в Phase 5.
> БЕЗ result.json coordinator не увидит completion (`wait-wave.sh` gate = `result.json size > 10`) — worker будет висеть WAITING вечно, wave никогда не закроется.
> НЕ пропускать. НЕ откладывать на 5.4. НЕ надеяться на wrapper-stub (он пишет is_error:true).
> **inline-mode тоже hard-gate.** Даже когда `/implement-story` вызван напрямую (не `/run-stories`, `CLAUDE_WORKER_MODE` может быть пуст) — result.json + close.json ОБЯЗАНЫ быть записаны до завершения skill'а. `phase-guard` для `close` валидирует close.json; добавь самопроверку перед тем как отчитаться done. Inline без result.json = incomplete close.

Обязательно выполнить через Bash tool ПЕРВЫМ действием Phase 5. **Используй `${CLAUDE_WORKER_DIR}`** (экспортирован launcher'ом) — НЕ вычисляй путь сам, иначе split-brain на STORY-ID с буквами:

```bash
if [[ "${CLAUDE_WORKER_MODE:-}" == "interactive" ]]; then
  : "${CLAUDE_WORKER_DIR:?launcher must export CLAUDE_WORKER_DIR}"

  # Self-kill carve-out: ТОЛЬКО для launcher-spawned worker (tmux-target present).
  # Direct invocation в primary-сессии → tmux-target нет → НЕ убивать (иначе kill
  # сессии пользователя).
  if [[ ! -s "${CLAUDE_WORKER_DIR}/tmux-target" ]]; then
    echo "[5.5] no tmux-target — direct invocation, skip self-kill (5.0-5.4 done)"
    date -Iseconds > "${CLAUDE_WORKER_DIR}/finished_at"; echo 0 > "${CLAUDE_WORKER_DIR}/exit_code"
    return 0 2>/dev/null || exit 0
  fi
  cat > "${CLAUDE_WORKER_DIR}/result.json" <<JSON
{
  "is_error": false,
  "mode": "interactive",
  "story": "${CLAUDE_STORY_ID}",
  "completed_at": "$(date -Iseconds)",
  "phase_summary": "Phase 5 started — all AC passed; closing out",
  "result": "See summary.md for full report"
}
JSON
  echo "[5.0] result.json written → $(wc -c < ${CLAUDE_WORKER_DIR}/result.json)B"
fi
```

В headless mode этот шаг пропустить (`claude -p` сам формирует result.json из своего stdout).


### 5.1 Update RTM linkage + write srs-pending.json (worker — NO SRS edits)

См. `references/srs-sync.md` — полный алгоритм, гейт `srs.enabled`, контракт single-writer (только coordinator меняет active SRS / archive).

> **MANDATORY: worker НЕ редактирует SRS-файлы напрямую** (когда `srs.enabled: true`).
> Status флип + archive move делает ТОЛЬКО `/run-stories` coordinator post-merge (или пользователь standalone). Worker пишет структурированное предложение `${CLAUDE_WORKER_DIR}/srs-pending.json` и НА ЭТОМ ОСТАНАВЛИВАЕТСЯ.
>
> **Worker НЕ трогает `rtm.yaml` (когда `srs.enabled: true`)** — ни Edit/Write, ни rebuild-скрипт, ни `git add`. RTM — coordinator-single-writer (код приземляется через squash-merge, а параллельные RTM-правки в ветках конфликтуют без auto-resolve). RTM регенерируется координатором из story frontmatter после merge волны.
>
> **Когда `srs.enabled: false`** — весь SRS/RTM-модуль не установлен в проекте; Шаг 2 ниже сводится к записи `{"story":"STORY-NNN","srs_disabled":true,"proposed":[]}` в `srs-pending.json` (no-op-плейсхолдер — нужен только чтобы удовлетворить schema close.json, см. `references/srs-sync.md`).

**Workflow (worker) — только когда `srs.enabled: true`:**
1. Update story frontmatter — **`status: done`** (НЕ `in_review` / `closed` / `merged` — canonical terminal state = `done`). Также `requirement_refs`, `verified_at` если применимо.
2. Сформировать `${CLAUDE_WORKER_DIR}/srs-pending.json` с proposed Status / archive-move / notes_delta для каждого requirement_ref (структура — см. `references/srs-sync.md` Шаг 2).
3. `git add ${AO_STORY_DIR}/STORY-{ID}.md` (ТОЛЬКО frontmatter).
4. Commit одним коммитом. **НЕ git add rtm.yaml / SRS-файлы** — всё это coordinator-single-writer.

> **ЗАПРЕЩЁННЫЕ статусы в Phase 5 close**: `in_review`, `wip`, `pending-review`, `closed`. Контракт: `draft` → `done` без intermediate states. Worker завершил AC + review-cycle done = `done`. Если есть unresolved review findings — fixup в текущей сессии, не stash через `in_review`.

### 5.2 Produce Report (coordinator)

```
## STORY-{ID}: [title]

**Summary**: [1-2 sentences]
**Executor**: Claude subagent(s)

### Acceptance Criteria
| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|

### Gates: Lint [status] | Type [status] | Tests [status]

### Reviews
- post-execution review (solo-reviewer / code-reviewer): [verdict + key findings per category]
- migration-review: [verdict, if migration files and agent configured]
- architect-review: [verdict, if triggered — cross-module new contract / ADR-level]

### Audits
- Base audits (if configured): [status]
- Heavy/project-specific audits: [list of triggered audits + status]

### Files: [changed files list]
### RTM: [updated refs, if srs.enabled]
### Risks / Follow-ups: [remaining items]
### Memory: Updated — [brief summary, if claude-mem available]
```

### 5.2.5 MCP Discipline Self-Review (3 строки)

В worker'е discovery-gate hook обычно skip'нут (by design — worker управляется SKILL'ом). Поэтому worker сам делает self-review и пишет результат в close.json для postmortem, если usage-tracking включён в этом проекте.

```bash
# Worker узнаёт свой session_id через переменную или из самой свежей jsonl-записи
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
SID=$(ls -t "${STATE_DIR}/tool-usage"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)
DISCIPLINE=$(bash scripts/ao/aggregate-tool-usage.sh "$SID" 2>/dev/null | tail -20)
# Вставить в close.json как поле mcp_discipline (строкой) при формировании payload в 5.4
```

При discovery-MCP=0 и Grep/Read≥10 — flag в Risks/Follow-ups (см. 5.2). Это не блокирует merge, но signals для будущих stories, что в данной заняли «grep-heavy» подход.

### 5.3 Structured Delivery Summary (ОБЯЗАТЕЛЬНО, если claude-mem/cross-session memory настроен в проекте)

Записать structured summary в файл в worker-dir. Это высококачественный итог работы для будущих сессий — подхватывается memory-hook'ами (если настроены) и попадает в cross-session timeline.

```bash
cat > ${CLAUDE_WORKER_DIR}/summary.md << 'EOF'
# STORY-{ID} Delivery Summary: {title}

## Module: {module}
## Contour: {contour}

## Что сделано
{1-3 sentences}

## Архитектурные решения
- {decision 1: что выбрали и ПОЧЕМУ}
- {decision 2}

## Pitfalls / Edge cases
- {gotcha 1: что сломалось или чуть не сломалось}
- {gotcha 2}

## Паттерны для повторного использования
- {pattern: что можно переиспользовать в будущих stories для этого модуля}

## Затронутые файлы
- {file1}: {что изменено}
- {file2}: {что изменено}

## При следующей работе с этим модулем учесть
- {рекомендация 1}
- {рекомендация 2}
EOF
```

> **Качество summary критично.** Это основной источник контекста для будущих workers через cross-session memory search (если настроена в проекте).
> Плохой summary: "Добавил эндпоинт и тесты" — бесполезен.
> Хороший summary: конкретный routing/data-flow decision + конкретный pitfall + конкретный edge case, с именами реальных функций/полей.

> **Не писать в memory-сервис напрямую через HTTP** — если проект использует read-only cross-session memory API, запись observations идёт автоматически через hook'и сессии, не через прямой POST. Файл `summary.md` — канонический artefact delivery независимо от того, есть memory-плагин или нет.

**5.3b Pattern Library (для migration/elimination stories):**

Если story включала массовую замену паттернов (across many files), записать **рецепт замены** отдельным файлом:

```bash
cat > ${CLAUDE_WORKER_DIR}/pattern-recipe.md << 'EOF'
# Pattern Recipe: {pattern_type} migration in {module}

## Pattern: {что заменяли}
## Recipe:
1. Find: `{grep pattern}`
2. Replace with: `{replacement pattern}`
3. Shared helper created: `{file path}`

## Gotchas:
- {edge case 1}
- {edge case 2}

## Files affected: {count}
## Reusable for: {future stories that can use same recipe}
EOF
```

> Future workers с похожей задачей найдут рецепт через cross-session memory search (`{pattern_type} migration recipe`), если она настроена в проекте.

### 5.4 Progress Close (coordinator)

```bash
# Phase-guard перед стартом 5-close (проверяет verify.json от Phase 4). БЛОКИРУЕТ при invalid state.
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} close || exit 1
# ... RTM update (worker) + srs-pending.json (worker) + cross-session summary ...
# Записать close.json. Worker НЕ редактирует SRS — поле srs_updated всегда false
# (флип делает coordinator post-merge, если srs.enabled). srs_pending = true означает,
# что worker оставил предложение (или no-op, если srs.enabled=false) в srs-pending.json;
# coordinator его обработает. close.json ОБЯЗАН содержать rtm_updated (bool),
# summary_path (непустая строка) и один из {srs_pending, srs_updated} = true.
cat > /tmp/close-{ID}.json <<JSON
{"rtm_updated":true,"srs_updated":false,"srs_pending":true,"claude_mem_observations":["obs-NNNN"],"summary_path":"${CLAUDE_WORKER_DIR}/summary.md"}
JSON
bash scripts/ao/phase-complete.sh STORY-{ID} 5-close /tmp/close-{ID}.json
```

> **NOTE**: pre-review simplification (Phase 2.1.5, если такой шаг/агент сконфигурирован в проекте) запускается перед Phase 2.2 review чтобы reviewers работали с уже-очищенным кодом, а не в Phase 5.4. См. `references/phase-2-implement.md`.

### 5.4.1 Standalone PR-merge (PR-flow — только при прямом вызове, не из /run-stories)

> Phase 5 worker НЕ делает локальный merge (контракт §5 выше). Но при **standalone**
> `/implement-story STORY-XXX` (вызван напрямую, без `/run-stories` coordinator) merge
> никто не сделает — поэтому skill сам открывает PR через `scripts/ao/pr-merge-story.sh`.
> При launcher-spawned worker (`/run-stories`) шаг ПРОПУСКАЕТСЯ — coordinator владеет
> merge в своей wave-логике.
>
> Детект standalone — тот же маркер, что 5.5 carve-out: `[[ ! -s "${CLAUDE_WORKER_DIR}/tmux-target" ]]`
> (пустой/нет tmux-target = прямой вызов в primary-сессии). Идемпотентно: даже если шаг
> сработает в agent-view-воркере, coordinator увидит существующий PR и не задублит.

```bash
if [[ ! -s "${CLAUDE_WORKER_DIR}/tmux-target" ]]; then
  # Standalone: открыть PR. По умолчанию БЕЗ auto-merge (человек ревьюит сам);
  # IMPLEMENT_STORY_AUTO_PR=1 → squash-merge сразу (как batch pipeline).
  PR_ARGS=(--base "${AO_BASE_REF:-main}")
  [[ "${IMPLEMENT_STORY_AUTO_PR:-0}" == "1" ]] && PR_ARGS+=(--auto-merge)
  PR_RESULT=$(bash scripts/ao/pr-merge-story.sh "STORY-{ID}" "${PR_ARGS[@]}")
  echo "$PR_RESULT"  # {"status":"merged|pr-open|skipped|error","pr":N,...}
  PR_STATUS=$(jq -r .status <<<"$PR_RESULT")
  echo "[5.4.1] PR-flow status=${PR_STATUS}. Если pr-open — смержить: bash scripts/ao/pr-merge-story.sh STORY-{ID} --auto-merge"
  if [[ "$(rcfg srs.enabled false 2>/dev/null || echo false)" == "true" ]]; then
    echo "[5.4.1] После merge — apply-srs-pending.sh STORY-{ID} --apply (rebuild-rtm внутри)."
  fi
fi
```

### 5.5 Close tmux window (INTERACTIVE MODE — BLOCKING LAST STEP)

> **⚠ BLOCKING CHECKPOINT 5.5** — если `CLAUDE_WORKER_MODE=interactive`, worker ОБЯЗАН сам закрыть свою tmux-панe после того как 5.0-5.4 завершены.
> Без этого шага worker висит в TUI бесконечно, coordinator'у приходится чистить вручную (`tmux kill-session`). В interactive mode это **финальное действие** skill'а — после него claude TUI получит SIGHUP и корректно выйдет.

> **⚠ CARVE-OUT (иначе убивает сессию пользователя):** 5.5 self-kill выполнять ТОЛЬКО если worker был spawned launcher'ом (`launch-story-worker*.sh`) — индикатор: существует `${CLAUDE_WORKER_DIR}/tmux-target` НЕПУСТОЙ И `${CLAUDE_WORKER_DIR}/pid` принадлежит отдельному процессу-воркеру. Если `/implement-story` вызван **напрямую в primary-сессии пользователя** (нет tmux-target, или pid = текущая интерактивная сессия) — `tmux kill-window` **УБЬЁТ сессию пользователя посреди работы**. В этом случае: выполнить 5.0–5.4, записать finished_at/exit_code, и **НЕ** делать kill-window — просто завершить skill нормально. Guard ниже это проверяет.
>
> **⚠ ANTI-HALLUCINATION:** «direct invocation» детектируется **ИСКЛЮЧИТЕЛЬНО** через `[[ ! -s "${CLAUDE_WORKER_DIR}/tmux-target" ]]` — пустой/отсутствующий файл. **НЕ** решать по имени tmux session: launcher inherit'ит coordinator's session, поэтому реальное имя может быть любым. Session-name ≠ wave-current **НЕ означает** primary invocation. Если tmux-target file существует и непустой — ВСЕГДА kill-window независимо от session name.

Выполнить через Bash tool ПОСЛЕДНИМ действием Phase 5 (после 5.4 `phase-complete`). **Используй `${CLAUDE_WORKER_DIR}`** (launcher-экспорт):

```bash
if [[ "${CLAUDE_WORKER_MODE:-}" == "interactive" ]]; then
  : "${CLAUDE_WORKER_DIR:?launcher must export CLAUDE_WORKER_DIR}"

  # Фиксируем финальный статус ДО закрытия window (wrapper bash может не успеть написать).
  date -Iseconds > "${CLAUDE_WORKER_DIR}/finished_at"
  echo 0 > "${CLAUDE_WORKER_DIR}/exit_code"

  # Закрываем собственную tmux window. Claude TUI получит SIGHUP → exit.
  TMUX_TARGET=$(cat "${CLAUDE_WORKER_DIR}/tmux-target" 2>/dev/null)
  if [[ -n "${TMUX_TARGET}" ]] && command -v tmux >/dev/null; then
    echo "[5.5] Closing tmux window ${TMUX_TARGET}..."
    tmux kill-window -t "${TMUX_TARGET}" 2>/dev/null &
    # & — background чтобы bash успел вернуться ДО SIGHUP убил нас.
  fi
fi
```

> В headless mode этот шаг пропустить — `claude -p` сам выходит после JSON output.

---
