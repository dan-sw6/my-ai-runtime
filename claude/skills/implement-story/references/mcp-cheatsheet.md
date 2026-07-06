## Cross-session memory usage reference (READ-only — критично, если проект использует claude-mem или аналог)

**Cross-session memory пишется ТОЛЬКО hook'ами** при compaction/stop событиях Claude-сессии. Read APIs — read-only. Запись observations из bash/worker **невозможна**. Worker оставляет информацию для будущих сессий через **файлы в worker-dir** (`summary.md`, `pattern-recipe.md`, `preflight.md`) — hook их подхватит, если такой плагин настроен в проекте.

### Read APIs (использовать во ВСЕХ фазах, где нужен prior context — если memory-плагин настроен)

| Нужно | Tool | Когда |
|---|---|---|
| Поиск по natural-language query | `Skill("claude-mem:mem-search", args="...")` (или эквивалент этого проекта) | Phase 0.1 mem-search, Phase 1.0 prior-work, Phase 2 debug, Phase 4.1 verify |
| Ranked cross-session timeline | project-specific smart-search tool, если есть | Phase 1.0 semantic neighbors |
| Получить observation by ID | project-specific get_observations tool | Phase 2 если preflight ссылается на obs-id |
| Проект для таргетинга | этот проект (см. runtime config / memory-плагин setup) | Все запросы |

Если в проекте нет настроенного cross-session memory MCP/плагина — весь этот раздел и связанные шаги (Phase 0.1, Phase 5.3) **skip'аются** с явной причиной (`claude-mem-unavailable` / `no-memory-plugin-configured`), не silently.

### Write (через hook, не через API)

Файлы в `${CLAUDE_WORKER_DIR}/`, которые hook подхватывает (если настроен):
- `summary.md` — итог story (Phase 5.3, ОБЯЗАТЕЛЬНО когда memory-плагин доступен)
- `pattern-recipe.md` — рецепт миграции (Phase 5.3b, если применимо)
- `preflight.md` — scope analysis (создаётся orchestrator'ом до launch)
- Любой markdown в worker-dir — hook подхватит через filesystem watcher

**Не использовать**: прямой POST на memory-сервис — read-only HTTP API (если он вообще есть в этом проекте).


## MCP Usage

### Coordinator (direct)

| MCP | When | Priority |
|-----|------|----------|
| **this product's code-discovery MCP** (cbm/serena — see `.claude/rules/mcp-usage.md`) | Code navigation, call graphs, impact analysis, pattern search, code reading | 1st (PRIMARY for code) |
| **DB-verification MCP** (if configured, e.g. `postgres_ro`) | Verify schema/indexes/constraints before writing queries, migrations, models | 1st (DB operations, if this story touches a DB) |

> **HARD RULE**: code-discovery MCP for code READING + DISCOVERY. Edit/Write для модификаций. DB-verification MCP для DB VERIFICATION (если применимо к стеку/story).

### Executor (via prompt template)

The executor prompt template (Phase 1.5) enforces MCP usage as structured steps:
- **Step 0**: Load specialist knowledge from `.claude/agents/*.md`
- **Step 1a**: code-discovery MCP — search/trace/read-symbol (PRIMARY — instant, token-efficient)
- **Step 1b**: context7 — `resolve-library-id` + `query-docs` для КАЖДОГО используемого фреймворка/библиотеки (ОБЯЗАТЕЛЬНО для ВСЕХ contours)
- **Step 1c**: DB-verification MCP — schema, indexes, constraints (ОБЯЗАТЕЛЬНО для backend/full-stack stories touching a DB, если такой MCP настроен в проекте)
- **Step 1d**: frontend design-tooling MCP (if configured, e.g. magicui) — ОПЦИОНАЛЬНО, только для frontend-профиля
- **Step 1f**: Pre-check gate — state findings before coding

### Agent MCP Access

Agents inherit all MCP servers from the parent session. Each agent's `.md` file documents which servers to use:

| MCP | Used by agents |
|-----|---------------|
| **code-discovery MCP** | ALL agents (PRIMARY — token-efficient code navigation) |
| **DB-verification MCP** | code-reviewer, qa-expert, architect-reviewer, story-planner (if this story/product has a DB) |
| **context7** | architect-reviewer, story-planner, executor subagent |
| **browser-verification tool** (e.g. playwright) | accessibility-tester, qa-expert (frontend AC verification, if frontend capability configured) |
