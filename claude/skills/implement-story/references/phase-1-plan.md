> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

## Phase 1: PLAN

### 1.0 Prior-work scan (cross-session memory READ APIs — ОБЯЗАТЕЛЬНО перед plan, если memory-плагин настроен)

До codebase-analysis вытащи всю известную историю по files_affected и модулю (если в проекте настроен memory-плагин вроде claude-mem). Это отличается от Phase 0.1 mem-search тем, что запрос **привязан к конкретным файлам/символам**, а не к story-wide keywords. Если memory-плагин не настроен — весь этот подшаг пропускается, `plan.json.risks.prior_findings: []`.

> **Delegate в Haiku-subagent.** Несколько mem-search вызовов сериально — overhead на coordinator context. Лучше один Haiku batch.
>
> ```
> Agent({
>   subagent_type: "general-purpose",
>   model: "haiku",
>   description: "Prior-work scan for STORY-{ID}",
>   prompt: "
>     Run cross-session memory prior-work scan for STORY-{ID}. files_affected: {LIST}, module: {MODULE}, pattern_type: {PATTERN_OR_NULL}.
>
>     Steps:
>     1. Read ${CLAUDE_WORKER_DIR}/preflight.md if exists — extract prior touches/decisions.
>     2. For each file in files_affected: Skill('claude-mem:mem-search', args='<path>') → list of touching stories + conclusions.
>     3. Skill('claude-mem:mem-search', args='{module} decision architecture') → architectural constraints.
>     4. If pattern_type set: Skill('claude-mem:mem-search', args='{pattern_type} migration recipe') → recipe.
>
>     Return ONLY JSON (no preamble):
>     {
>       \"prior_findings\": [
>         {\"source\":\"mem-search\",\"query\":\"...\",\"count\":N,\"key_insights\":[\"...\"]},
>         ...
>       ],
>       \"summary\": \"<1-2 предложения для plan.risks>\"
>     }
>
>     Если ничего не нашлось: prior_findings: [], summary: 'no prior work found'.
>   "
> })
> ```
>
> Coordinator парсит JSON, кладёт в `plan.json` под полем `risks.prior_findings`. Шаги (a)-(e) ниже — fallback / ручной режим, если subagent недоступен.

**a) Read preflight artifact (если `/run-stories` pre-flight создал)**:
```
Read("${CLAUDE_WORKER_DIR}/preflight.md")
```
Там уже собраны: prior touches per file, decisions per module, semantic neighbors.

**b) Per-file history** — для каждого файла в `files_affected`:
```
Skill("claude-mem:mem-search", args="<path/to/file>")          # natural-language search
```
Список stories, которые уже редактировали файл + conclusions.

**c) Semantic neighbors для story keywords** (если preflight не создан) — project-specific timeline/search tool, если есть.

**d) Prior decisions в модуле**:
```
Skill("claude-mem:mem-search", args="{module} decision architecture")
```
Архитектурные решения, которые ограничивают реализацию.

**e) Pattern recipes** (если story — migration/elimination):
```
Skill("claude-mem:mem-search", args="{pattern_type} migration recipe")
```
Рецепт из `<state_dir>/story-{id}/pattern-recipe.md`, сохранённый прошлым worker'ом (Phase 5.3b).

> **MANDATORY recipe-inject в executor-prompt**: для story с pattern_type `rbac-migration` / `legacy-api-elimination` / `framework-upgrade` — найденный recipe вставлять как **Step 0.5** в КАЖДЫЙ executor-prompt (initial и corrective). Иначе executor#2 повторяет ошибку executor#1 — каждый открывает паттерн заново. С inject первый executor пишет recipe в `pattern-recipe.md` (Phase 5.3b), planner следующей story находит через mem-search и инжектит всем executor'ам сразу.

**Декларация в plan.json**: в поле `risks` добавить блок `prior_findings: [{source:"mem-search", query:"...", count:N, key_insights:["..."]}]` — подтверждение, что prior work review выполнен (или `[]`, если memory-плагин не настроен).

### 1.1 + 1.2 Codebase Analysis (discovery-MCP graph queries — NO agents needed)

Read the story file: `${AO_STORY_DIR}/STORY-{ID}.md` (`ao.story_dir`, default `docs/stories`). Then use **this product's code-discovery MCP** (e.g. codebase-memory-mcp / cbm) for instant analysis — no subagents required.

> **WHY:** A pre-indexed graph query returns the same data as spinning up dedicated explorer/architect agents, at a fraction of the token cost — when the project has one configured (`cbm_project` in runtime.config.yaml). If no code-discovery MCP is configured for this project, fall back to `serena` (`get_symbols_overview`/`find_symbol`) or, as a last resort, targeted `Read`/`Grep` on files named in `files_affected` (never recursive).

**Step 0 (OPTIONAL, only if `cross_module: true` in story frontmatter): architecture overview**

Для cross-module stories (затрагивают >1 модуль) перед точечными запросами сделать один широкий overview-запрос через discovery MCP (packages/services aggregate), затем — pattern-search для integration points.

**Project id:** значение `cbm_project` из `runtime.config.yaml` этого продукта (см. `.claude/rules/mcp-usage.md`).

**Step A: Component discovery** — for each main component in `files_affected`:
```
<discovery-mcp>.search_graph(project="<cbm_project>", query="<main component name from files_affected>", limit=10)
```
→ Returns: qualified_name, file_path, line range, label (Function/Class/Route)

**Step B: Dependency graph** — for the primary component:
```
<discovery-mcp>.trace_path(project="<cbm_project>", function_name="<component name>", mode="calls", depth=2, direction="both")
```
→ Returns: full call graph — callers + callees at 2 hops.

**Step C: Impact analysis** (if modifying existing code):
```
<discovery-mcp>.detect_changes(project="<cbm_project>", since="HEAD~5")
```
→ Returns: recently changed functions that may conflict with story scope.

**Step D: Pattern lookup** (if story requires reusing existing patterns):
```
<discovery-mcp>.search_code(project="<cbm_project>", pattern="<pattern to find>", mode="compact", limit=10)
```
→ Returns: graph-augmented grep results ranked by structural importance.

**Step E: Architecture overview** (if story touches multiple modules):
```
<discovery-mcp>.get_architecture(project="<cbm_project>")
```
→ Returns: packages, services, node/edge counts. One-time call, result is small.

**Step F: Deep read** (only for specific symbols that need body inspection):
```
<discovery-mcp>.get_code_snippet(project="<cbm_project>", qualified_name="<qn from Step A>")
```
→ Returns: source code of specific function. Use sparingly — only when graph metadata is insufficient.

**Fallback:** If the code-discovery MCP is unavailable or not configured, use Read with `offset`/`limit` on specific files identified from story `files_affected` and grep through Bash on narrow paths (NOT recursive).

**Progress step:**
```bash
# Phase-guard перед стартом 1-plan (проверяет context.json от Phase 0). БЛОКИРУЕТ при invalid state.
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} plan || exit 1
```

### 1.3 Task Decomposition (story-planner agent — MANDATORY, NO-SKIP)

> **⚠ BLOCKING CHECKPOINT 1.3:** Phase 1 завершается ТОЛЬКО через `Agent(subagent_type="story-planner")`. Inline-decomposition координатором ЗАПРЕЩЕНА — даже для маленьких story, даже когда «всё очевидно». Skip-причины (`tasks-trivial`, `single-file`, `sp-too-small`, `context-sufficient`) НЕ принимаются.
>
> **Why mandate**: без dedicated planner координатор рискует потерять file-level breakdown, AC↔task mapping, risk list — Phase 3 review теряет ground truth для AC verification, а Phase 2 рискует получить `general-purpose` dispatch вместо `story-executor` (нарушение invariant 15).
>
> **Enforcement**: после Agent() вызова coordinator пишет `plan.json` через `phase-complete.sh` с полем `planner_agent_used: true`. `phase-guard.sh`/`phase-complete.sh` блокирует переход к 2-implement если это поле не `true`.

After 1.1 + 1.2 complete, launch the **story-planner** agent (СИНХРОННО, no parallel):

```
Agent(subagent_type="story-planner", model="sonnet", description="Plan STORY-{ID}", prompt="""
Story: STORY-{ID}
Story file: {ao.story_dir}/STORY-{ID}.md

Codebase analysis (from discovery-MCP queries above):
[paste findings]

Cross-session memory context (from Phase 0.1/1.0, if available):
[paste mem-search results if any]

Produce an ordered task breakdown with file-level specificity, AC mapping, and risks.
Output JSON schema: {tasks:[{n,title,files_affected,ac_ids,constraints,risks,depends_on:[task_n...]}], total_tasks, plan_version}.
`depends_on` — task numbers, которые ОБЯЗАНЫ завершиться раньше (реальная зависимость кода/контракта, не «логический порядок»). Независимые таски → `depends_on:[]` (исполнятся параллельно — speed lever #1). Frontend, потребляющий только API-контракт, известный из плана, НЕ зависит от backend-impl-таска (контракт заморожен в plan).

**HARD: NO test-only tasks**. `tasks[]` НЕ должен содержать пунктов вида `write tests for X` / `add unit tests` / отдельной test/QA phase. Тесты пишутся INLINE в impl-task рядом с кодом. Phase 3 gate (configured lint/type/test commands) — единственная инстанция, которая проверяет покрытие; если coverage красное на новой функциональности, coordinator уходит в corrective loop. План = что построить; верификация = Phase 3, не plan.
""")
```

Coordinator парсит результат → пишет `plan.json`:
```bash
cat > /tmp/plan-{ID}.json <<JSON
{"planner_agent_used":true,"tasks":[...],"total_tasks":N,"plan_version":1}
JSON
bash scripts/ao/phase-complete.sh STORY-{ID} 1-plan /tmp/plan-{ID}.json
```

**ЗАПРЕЩЕНО:**
- Inline `tasks` массив без `Agent(story-planner)` dispatch — фаза не завершается
- `plan.json` без `planner_agent_used:true` — guard блокирует Phase 2
- `model="opus"` для story-planner — sonnet (token economy), если проектом не задано иначе в `ao.worker_model`/эквивалентной политике для subagents
- **Test-task в `tasks[]`** — тесты пишутся INLINE в impl-task, coverage верифицирует Phase 3 gate. Если planner вернул такой task — coordinator MUST отклонить plan и пере-dispatch'нуть story-planner с явным напоминанием (или вручную слить test-task в соответствующий impl-task перед `phase-complete.sh`).

Output: ordered tasks, file-level breakdown, AC mapping, execution order, risks.

### 1.4 Frontend Design (ОБЯЗАТЕЛЬНО для frontend/full-stack stories, если продукт имеет соответствующую capability)

См. `references/design-modes.md` — этот runtime не поставляет собственный design-contract механизм; это optional capability конкретного frontend-профиля продукта. Если продукт такого механизма не имеет — Phase 1.4 сводится к lightweight review против `.claude/agents/ui-designer.md` (если присутствует).

### 1.5 Specialist Knowledge + Pre-checks

#### 1.5a Load Specialist Knowledge by Contour

Read the relevant agent .md files for patterns and conventions (если эти агенты присутствуют в `.claude/agents/` этого проекта):

| Contour | Read these files |
|---------|-----------------|
| backend | `.claude/agents/backend-developer.md` + `.claude/agents/python-pro.md` (или язык-специфичный аналог) |
| frontend | `.claude/agents/frontend-developer.md` + `.claude/agents/react-specialist.md` |
| full-stack | `.claude/agents/backend-developer.md` + `.claude/agents/frontend-developer.md` |

#### 1.5b MCP Pre-checks (MANDATORY — BEFORE writing any code)

**Code-discovery MCP (PREFERRED, token-efficient):**
```
<discovery-mcp>.search_graph(project: "<cbm_project>", query: "<symbol name>")
<discovery-mcp>.trace_path(project: "...", function_name: "<component>", mode: "calls", depth: 2)
<discovery-mcp>.get_code_snippet(project: "...", qualified_name: "<qn from search_graph>")
<discovery-mcp>.search_code(project: "...", pattern: "<pattern>", mode: "compact")
```
> Use graph queries FIRST. Edit/Write для модификаций.

**context7 — framework docs (ОБЯЗАТЕЛЬНО для ВСЕХ contours, независимо от стека):**
```
mcp__plugin_context7_context7__resolve-library-id(libraryName: "<framework/library actually used>")
mcp__plugin_context7_context7__query-docs(libraryId: "/org/lib", query: "specific API question")
```
> Вызвать `resolve-library-id` + `query-docs` для КАЖДОГО фреймворка/библиотеки, используемого в story. Не полагаться на training data — документация может отличаться.

**DB-verification MCP (ОБЯЗАТЕЛЬНО для backend/full-stack, если этот проект работает с БД и такой MCP настроен, например `postgres_ro`):**
```
<db-mcp>.query(sql: "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = '...'")
```
> Проверить схему, индексы, constraints для ВСЕХ таблиц, затронутых story.

> **Constraint front-load (speed lever — снижает риск corrective-циклов):** для ЛЮБОГО coded/enum/status-поля, которое story пишет в БД, ОБЯЗАТЕЛЬНО заранее (если DB-verification MCP доступен):
> 1. Проверить CHECK/enum domain поля через DB-MCP — допустимый набор значений фиксируется в executor-prompt (иначе runtime-ошибка + corrective + лишний review round).
> 2. Перед тем как executor определит НОВУЮ const/enum/option-список — code-discovery MCP-поиск существующей канонической константы в том же домене; переиспользовать/extend, не создавать дубль с другими значениями.
> Эти два факта кладутся в `plan.json` и в каждый relevant executor-prompt как hard constraint.

> **Note**: если в этом проекте настроен только один DB MCP (или ни одного) — смотреть `.claude/rules/mcp-usage.md` / `.mcp.json` этого репозитория за actual списком, не предполагать конкретное имя сервера.

State findings: "Pre-check results: [what I found]. Proceeding with implementation."
If findings conflict with the plan, STOP and report to user.

#### 1.5c Baseline failures

```bash
# Configured test command(s) for the active language profile(s) — см. gates.<lang>.test
# в runtime.config.yaml; отфильтровать FAIL-строки для baseline snapshot.
```

**Progress step:**
```bash
# Записать итоговый plan.json через wrapper — он валидирует tasks[]/ac_mapping{}/executor_prompt
# и автоматически добавляет _complete/_ts + логирует event.
cat > /tmp/plan-{ID}.json <<JSON
{"tasks":[...tasks...],"ac_mapping":{"AC1":["task-1"],...},"executor_prompt":"..."}
JSON
bash scripts/ao/phase-complete.sh STORY-{ID} 1-plan /tmp/plan-{ID}.json
```

> **CHECKPOINT 1**: Before proceeding to Phase 2, verify:
> - [ ] Progress file updated after 1.1+1.2
> - [ ] Specialist agent .md files read (if present in this project)
> - [ ] code-discovery MCP graph queries used for affected files
> - [ ] context7 queried for EVERY framework/library actually used
> - [ ] DB-verification MCP queried for schema/constraints (backend/full-stack stories touching a DB, if such an MCP is configured)
> - [ ] Baseline failures noted

### 1.6 Decision Rules

- **Analysis complete, pre-checks passed** → proceed to Phase 2
- **Unmet dependency** (blocked_by) → STOP, report blocker
- **Ambiguous criteria** → **interactive mode**: `AskUserQuestion` прямо в worker-TUI и дождаться ответа; **headless mode**: `log_phase_event 1-plan blocked reason=ambiguous-criteria` и exit.


### 1.7 Interactive Checkpoints (when CLAUDE_WORKER_MODE=interactive)

См. `references/interactive-checkpoints.md` — interactive vs headless, canonical checkpoints, ветвление.
