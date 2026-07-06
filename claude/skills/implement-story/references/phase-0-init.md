> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

> **Preflight artefact**: если `${WORKER_DIR}/preflight.json` существует — это результат `scripts/ao/preflight-gate.sh`, отработавшего со стороны `/run-stories` координатора ДО запуска воркера. Прочитай его в начале Phase 0 чтобы увидеть какие checks были `warn` (не блокирующие, но требующие внимания — например, `discovery-index-fresh: warn`).

> **Mem-context artefact**: если `${WORKER_DIR}/mem-context.json` существует и в проекте настроен memory-плагин — это top-N relevant cross-session observations, инжектированных координатором ДО запуска. Структура: `{observations: [{id, text, date, ...}]}`. Прочитай в Phase 0.1 ДО собственного mem-search вызова — это экономит токены и предотвращает повторение past mistakes. Если файл отсутствует или `observations: []` — fallback на свой mem-search (как раньше).

> **MCP inventory (worker session)**: discovery-gate и context-prime hook'и (если настроены в проекте) обычно skip'ают worktree-сессии — у тебя нет inventory-reminder'а, поэтому держи в голове доступные серверы для этого проекта:
>
> - **code-discovery MCP** (cbm / serena — см. `cbm_project` в runtime.config.yaml): search → trace → read-symbol — PRIMARY для discovery; для edits — Edit/Write
> - **cross-session memory** (если настроен, напр. claude-mem): search → get_observations([batch]) — past decisions
> - **DB-verification MCP** (если настроен, напр. `postgres_ro`): schema/constraint verification — для story с `db_impact != none`
> - **browser-verification tool** (если настроен, напр. playwright): auth-reuse через storage-state ДО navigate — UI verify
> - **context7**: `resolve-library-id` → `query-docs` — актуальная library docs
> - **research tool** (если настроен, напр. exa): web search → fetch — внешний research
>
> Полная матрица + workflow recipes — `.claude/rules/mcp-usage.md` + `.claude/references/mcp-tool-matrix.md`.

## Phase 0: SESSION + MEMORY INIT (coordinator) — БЛОКИРУЮЩИЙ CHECKPOINT

> **CANONICAL WORKER-DIR NAMING (known filesystem gotcha):**
> Worker-dir путь — **ВСЕГДА lowercase**: `<state_dir>/story-${STORY_ID#STORY-}` где `${STORY_ID#STORY-}` приводится к lowercase (`STORY-D03` → `story-d03`, не `story-D03`).
>
> **Why mandate**: ext4 case-sensitive — `story-D03/` и `story-d03/` это разные директории. Coordinator preflight может написать uppercase, worker tmux-wrapper — lowercase → phase-guard читает не тот файл без schema-v1 header → blocked.
>
> **Везде используй lowercase**:
> ```bash
> STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
> WORKER_DIR="${STATE_DIR}/story-$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"
> ```
>
> Coordinator preflight артефакты (preflight.json, preflight.md, mem-context.json), worker phase-log, worker state-JSONs (context.json, plan.json, diff.json, gate.json, verify.json, close.json, review.json, simplify.json, migration-review.json), result.json — **все в lowercase worker-dir**.

> **CHECKPOINT 0: Переход к Phase 1 ЗАПРЕЩЁН без выполнения 0.1 mem-search (если memory-плагин настроен в проекте).**
> Без cross-session memory worker теряет контекст prior work, тратит бюджет на повторный анализ.
> Если memory-плагин недоступен или не настроен — записать в phase файл "phase-0-failed" (недоступен) или skip с явной причиной (не настроен) и продолжить с предупреждением.

### 0.1 Search Cross-Session Memory (conditional, token economy)

**Run mem-search ONLY if** (all of):
- Проект использует memory-плагин (claude-mem или эквивалент) — иначе весь шаг skip
- И хотя бы одно из: story frontmatter has non-empty `depends_on:` (related prior stories) / has `epic:` field / title matches module flagged in a recent session summary

Otherwise **skip** — coordinator saves tokens (memory-hit rate на orphan stories обычно низкий).

```bash
log_phase_event <state_dir>/story-{id} 0.1-mem-search start
```
```
Skill("claude-mem:mem-search", args="STORY-{ID} {module} {contour}")   # или эквивалент этого проекта
```
```bash
log_phase_event <state_dir>/story-{id} 0.1-mem-search complete
```

**ЯВНЫЙ SKIP-БРАНЧ (если условия выше не сработали)**:
```bash
log_phase_event <state_dir>/story-{id} 0.1-mem-search skipped no-deps-no-epic
```

Если memory-плагин настроен, но недоступен в рантайме — НЕ silently skip:
```bash
log_phase_event <state_dir>/story-{id} 0.1-mem-search skipped claude-mem-unavailable
```

Если в проекте вообще нет memory-плагина:
```bash
log_phase_event <state_dir>/story-{id} 0.1-mem-search skipped no-memory-plugin-configured
```

If context found — integrate into subsequent agent dispatches.

### 0.1.4 Whitelist-driven scope check (optional, project-specific convention)

Для **migration / elimination** stories (pattern: `NFR-*`, legacy-removal, deprecation) — если в этом проекте есть governance-whitelist конвенция (файлы вида `_whitelist_*.json` рядом с governance-тестами), сверить `story_frontmatter.files_affected` с ней:

```bash
# Найти governance-whitelist файлы (путь зависит от проекта — проверить, что реально есть)
WL=$(find . -name "_whitelist_*.json" -path "*governance*" 2>/dev/null)
for f in $WL; do
  expected=$(jq -r '.[]' "$f" | sort)
  actual_paths=$(echo "${files_affected[@]}" | tr ' ' '\n' | sort)
  missing=$(comm -23 <(echo "$expected") <(echo "$actual_paths"))
  [[ -n "$missing" ]] && echo "[0.1.4] WARN: whitelist $f references files NOT in story scope: $missing"
done
```

Если у проекта нет такой конвенции — этот подшаг просто не применяется, никакого skip-log не требуется (он не является обязательным этапом).

### 0.1.5 Story-file presence contract (worktree) — БЛОКИРУЮЩИЙ

> **Известный гоча**: story-drafts иногда живут **в main repo как untracked** файлы (`?? <ao.story_dir>/STORY-{ID}.md`). Worktree их НЕ видит → каскад поломок: preflight `story-file-missing`, gate-скрипты падают на отсутствующий файл, RTM-rebuild пропускает story, Edit-to-main блокируется worktree-guard. Каждая всплывает по отдельности и стоит времени, если не проверить заранее.

ПЕРВЫМ действием Phase 0 (до 0.2) coordinator гарантирует наличие story-файла **в worktree**:

```bash
STORY_DIR="$(rcfg ao.story_dir docs/stories)"
WT_STORY="${STORY_DIR}/STORY-${ID}.md"
MAIN_STORY="$(git rev-parse --git-common-dir)/../${STORY_DIR}/STORY-${ID}.md"  # main worktree root
if [[ ! -f "$WT_STORY" && -f "$MAIN_STORY" ]]; then
  cp "$MAIN_STORY" "$WT_STORY"   # authoritative draft может быть untracked в main
  echo "[0.1.5] story-file imported main→worktree (will be committed on worktree branch in Phase 5.1)"
fi
[[ -f "$WT_STORY" ]] || { echo "[0.1.5] STORY-${ID}.md missing in BOTH main and worktree — abort"; exit 1; }
```

Контракт: worktree-копия становится authoritative для ветки и **коммитится в Phase 5.1** (status→done). MAIN-tree untracked-draft чистит coordinator/`/run-stories` перед merge.

### 0.2 Init Progress Tracking

> **context.json required-keys contract** (`phase-guard.sh` enforce): файл, который Phase 0 пишет для guard `plan`, ОБЯЗАН содержать top-level ключи **`story_id`** (string) и **`story_frontmatter`** (object — распарсенный YAML-frontmatter story). `_complete:true` сам по себе НЕ достаточен. Mem-findings — в произвольных доп-полях. Шаблон:
> ```json
> {"_complete":true,"story_id":"STORY-XXX","story_frontmatter":{...frontmatter...},"mem_findings":{...}}
> ```
> (Аналогично: plan.json→`tasks`/`ac_mapping`/`executor_prompt`; diff.json→`changed_files`/`commits`/`executor_dispatches`; gate.json→`lint`/`typecheck`/`tests`; verify.json→`ac_results`/`mode`; close.json→`rtm_updated`/`summary_path`+один из `{srs_pending,srs_updated}`. Источник истины — `scripts/ao/phase-complete.sh` / `scripts/ao/phase-guard.sh` SPEC.)

Worker-dir + phase-log init уже сделан `scripts/ao/launch-story-worker.sh` (schema v1 маркер записан первой строкой phase-log). Coordinator только дописывает phase-events:

```bash
# Source helper (один раз в начале worker session, если ещё не source-нут).
source scripts/ao/phase-log-util.sh

log_phase_event <state_dir>/story-{id} 0-init start
# ... (init work) ...
log_phase_event <state_dir>/story-{id} 0-init complete
```

> ⚠ В inline-режиме (запуск /implement-story в current session без launch-story-worker.sh) coordinator сам инициализирует phase-log:
> ```bash
> bash scripts/ao/phase-log-util.sh init <state_dir>/story-{id} STORY-{ID}
> ```

> **CHECKPOINT 0**: Before proceeding to Phase 1, verify:
> - [ ] `mem-search` completed (context integrated or empty), или явно skip'нут по причине
> - [ ] Progress file created
