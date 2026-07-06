# MCP Tool Inventory — полный реестр

> Документально полный список tools каждого MCP. Для краткой матрицы выбора — `.claude/rules/mcp-usage.md`. Для углублённых рецептов — `.claude/references/mcp-tool-matrix.md`.

Условные обозначения:
- ⭐ **must-use** — задействуется в типовом workflow.
- 🔧 **on-demand** — для специфичных кейсов.
- 🧰 **advanced** — диагностика, обслуживание индекса, перенос конфигов.

CBM project name: `{{CBM_PROJECT}}` (ENV `CBM_PROJECT`, из `runtime.config.yaml::cbm_project`). Пусто → cbm выключен, discovery-gate падает на serena. Монорепо с несколькими индексируемыми под-деревьями обычно заводят под-проекты (`{{CBM_PROJECT}}-<subdir>`) — конвенция самого cbm, не этого рантайма.

---

## codebase-memory-mcp (cbm) — code knowledge graph (python/typescript профили, reference impl)

PRIMARY для code discovery на профилях, где сконфигурирован (`cbm_project` не пуст). Hard-block в `discovery-gate` хуке срабатывает на recursive grep/rg/find без предварительного discovery-вызова.

| Tool | Status | Когда |
|---|---|---|
| `search_graph` | ⭐ | Найти Function/Class/Route/Variable. Принимает `query` (BM25 + camelCase split + structural boost), `name_pattern` (regex), `qn_pattern` (qualified-name regex), `semantic_query` (массив keywords для cosine), фильтры `label`/`file_pattern`/`min_degree`/`max_degree`/`relationship`. |
| `search_code` | ⭐ | Graph-augmented grep. Modes: `compact` (file+line+signatures), `full` (with body), `files` (file list). `path_filter` regex. |
| `trace_path` | ⭐ | Цепочки вызовов. `mode=calls` (caller↔callee), `mode=data_flow` (A→B), `mode=cross_service`. `direction=both/callers/callees`. `depth` 1-3. |
| `get_code_snippet` | ⭐ | Прочитать тело по qualified_name. Возвращает source. Заменяет `Read` для code-файлов активного профиля. |
| `query_graph` | 🔧 | Cypher по графу. Custom nodes: Function, Class, Route, Module, File. Пример: `MATCH (n) WHERE size((n)--()) > 50 RETURN n` (god-nodes). |
| `get_architecture` | 🔧 | Обзор структуры. `aspects=["packages","services","dependencies"]`. На большие codebase'ы. |
| `get_graph_schema` | 🔧 | Описание node-labels и edge-types — справка перед сложным `query_graph`. |
| `list_projects` | 🧰 | Все индексированные проекты, размер, ноды/рёбра. |
| `index_status` | 🧰 | Статус индексации проекта. |
| `index_repository` | 🧰 | Запуск/обновление индекса. `mode="fast"` для секунд, `full` для глубокой переиндексации. |
| `detect_changes` | 🔧 | Что изменилось `since=HEAD~N` или с момента последней индексации. Полезно для свежих правок. |
| `ingest_traces` | 🧰 | Подмесить runtime-traces (call-frequencies) — улучшает ранжирование. |
| `manage_adr` | 🔧 | Чтение/линковка ADR'ов в граф. |
| `delete_project` | 🧰 | Удалить индекс проекта. Опасная — confirm с пользователем. |

**Эталонный workflow** (discover-then-trace):
```
search_graph(query="update user settings")
  → trace_path(function_name="<exact qn>", mode="calls", direction="both", depth=2)
  → get_code_snippet(qualified_name="<from step 1>")
```

**Anti-patterns**:
- ❌ `trace_path` с угаданным именем (вернёт 0).
- ❌ `get_code_snippet` без discovery (неверный qn).
- ❌ `depth=4+` без cypher-фильтра — экспоненциальный взрыв.

---

## csharp discovery — serena(csharp) / Roslyn MCP (csharp-профиль, ADOPT)

На csharp-профиле cbm обычно не задействован (`.cs`/`.xaml` вне его типового покрытия); discovery-роль закрывает **serena** с `language: csharp` (Roslyn LS) или `csharp_omnisharp` (для .NET Framework 4.8) в `.serena/project.yml`, либо отдельный Roslyn MCP — reference: `CWM.RoslynNavigator` (15 semantic tools: `find_symbol`, `find_references`, `find_callers`, `find_implementations`, `get_diagnostics`, `get_type_hierarchy`, dead-code detection и др.). Какой из них — mandatory-инструмент, решает `discovery:` ключ (`serena` | `roslyn-navigator`) в `runtime.config.yaml`/`runtime.fragment.yaml`. Подробности установки — `profiles/csharp/adopt.md` в этом рантайме.

---

## serena (`mcp__serena__*`) — symbol-level navigation & edit (все профили)

LSP-backed symbol layer (PyPI `serena-agent`). Единый namespace `mcp__serena__*` в main-сессии и в изолированных worker-контекстах. Авто-проект (`--context claude-code --project-from-cwd --mode editing`) — ручной `activate_project` НЕ нужен в single-project контексте. **Не** заменяет cbm для discovery/impact на python/typescript (дополняет как EDIT-слой); на csharp — первичный discovery+edit слой.

**Symbol tools** (главное):
- `get_symbols_overview(file)` — outline символов файла (вход в workflow).
- `find_symbol(name_path, depth?)` — найти символ по name-path.
- `find_referencing_symbols` — refs (звать ПЕРЕД rename/safe-delete). TS-caveat #1586 (см. ниже).
- `replace_symbol_body` / `insert_after_symbol` / `insert_before_symbol` — правка тела/вставка по границе символа.
- `rename_symbol` / `safe_delete_symbol` — rename/удаление с учётом refs.
- `get_diagnostics_for_file` — диагностика после правок (в main native LSP тоже жив; в изолированном worker-контексте serena — единственный источник).
- доп.: `find_declaration`, `find_implementations`, memory-ops (`write_memory`/`read_memory`/`list_memories`).

**Каноничный workflow**: `get_symbols_overview` → `find_symbol` → `replace_symbol_body`/`insert_*` → `find_referencing_symbols` (перед rename/delete) → `get_diagnostics_for_file`.

**Anti-patterns / caveats**:
- ❌ Discovery/impact через serena вместо cbm там, где cbm сконфигурирован — cbm остаётся PRIMARY для python/typescript.
- ⚠️ TS `find_referencing_symbols` в монорепо без корневого `tsconfig.json` → 0 hits (баг oraios/serena#1586); Python/pyright ок → для TS-refs кросс-чек cbm.
- ❌ Install через plugin/MCP-marketplace (апстрим прямо запрещает) — держать server как plain MCP entry в конфиге проекта.

Полный setup/контексты/режимы/версии — `external-docs/serena-setup.md`.

---

## claude-mem (plugin) — cross-session memory

Автоматический plugin (`PreToolUse`/`SessionStart` hooks вне нашего контроля). Доступ через skills и manual cli (`claude-mem search/timeline/get_observations`).

### Skills (плагин-namespaced)

| Skill | Status | Когда |
|---|---|---|
| `claude-mem:mem-search` | ⭐ | Семантический поиск по observations. **ОБЯЗАТЕЛЬНО первый шаг** на любой нетривиальной задаче. |
| `claude-mem:learn-codebase` | 🔧 | Прочитать каждый source-файл при старте незнакомого репозитория. |
| `claude-mem:smart-explore` | 🔧 | AST-структурный поиск (tree-sitter) — когда графового индекса нет. |
| `claude-mem:make-plan` | 🔧 | Phase-разбитый имплементационный план с поиском доков. |
| `claude-mem:do` | 🔧 | Запустить approved plan через subagents. |
| `claude-mem:pathfinder` | 🔧 | Архитектурный обзор + унификация дублирующих систем. |
| `claude-mem:knowledge-agent` | 🔧 | Построить «brain» поверх observations по теме. |
| `claude-mem:timeline-report` | 🧰 | Narrative-отчёт по истории проекта. |
| `claude-mem:babysit` | 🧰 | Watch PR/review до merge. |
| `claude-mem:version-bump` | 🧰 | Автоматический semver release для plugins. |
| `claude-mem:how-it-works` | 🧰 | Объяснение что делает plugin. |

### Direct memory ops (через bash)

```bash
# Семантический поиск
mem-search "story XYZ implementation strategy" --limit 5

# Полный observation по ID-batch
get_observations 18280 18281 18282

# Хронология последних N записей
timeline --limit 20
```

**Anti-patterns**:
- ❌ Одиночные `get_observations` calls — батчить по 3-10 IDs.
- ❌ Пропускать `mem-search` в начале большой задачи и спрашивать пользователя «делали ли мы X».
- ❌ Сохранять в claude-mem то что можно вывести из git log / кода.

---

## context7 (plugin) — up-to-date library docs

Используется для ЛЮБЫХ вопросов про библиотеки/фреймворки/SDK/CLI — независимо от языкового профиля (React/FastAPI/Prisma/Tailwind/Django/TanStack/SQLAlchemy/Alembic/Vitest/Playwright для python/typescript; ASP.NET Core/EF Core/Polly/MediatR для csharp). Даже когда «знаешь ответ» — может быть устарело.

| Tool | Status | Когда |
|---|---|---|
| `resolve-library-id` | ⭐ | Превратить human-name (`React`) в context7-id (`/facebook/react`). Всегда первый шаг. |
| `query-docs` | ⭐ | Запрос конкретно по доке: API, syntax, migration, CLI usage. |

**Эталонный workflow**:
```
resolve-library-id(libraryName="TanStack Query")
  → query-docs(libraryId="<resolved>", query="useInfiniteQuery v5 migration")
```

**Когда НЕ context7**: refactoring, бизнес-логика, debugging своего кода, code review, общие концепции.

---

## exa — web search & code research

Внешние знания / best practices / open source примеры.

| Tool | Status | Когда |
|---|---|---|
| `web_search_exa` | ⭐ | Семантический web-search. Лучше формулировать как «blog post comparing X performance», не keywords. |
| `web_fetch_exa` | ⭐ | Полный контент батча URL'ов. Принимает `urls=[...]` — несколько за раз. |
| `get_code_context_exa` | ⭐ | Контекст по коду из открытых репо — для архитектурных решений и паттернов. Аналог GitHub-search но семантический. |

> Если MCP-конфиг проекта регистрирует exa под другим namespace (например через отдельный plugin-канал) — те же tool-имена, другой префикс сервера.

**Эталонный workflow**:
```
web_search_exa("idiomatic background-scheduler graceful shutdown patterns")
  → web_fetch_exa(urls=[<top-3 results>])
  → если нужны примеры кода: get_code_context_exa(query="background scheduler graceful shutdown")
```

**Anti-patterns**:
- ❌ Keywords-only query (`React useEffect`) — давай descriptive (`why useEffect runs twice in React 18 Strict Mode`).
- ❌ `web_fetch_exa` по одному URL за вызов — батчи по 3-5 в одном.
- ❌ Использовать exa для library docs где есть context7 — context7 даёт официальные доки.

---

## Cross-MCP recipe matrix

Канон последовательностей для типовых задач:

| Задача | Шаги |
|---|---|
| **Новая фича** | 1. `claude-mem:mem-search` тема → 2. discovery-tool похожих фич (`search_graph`/`find_symbol`) → 3. read тела для паттернов → 4. `context7.query-docs` если внешняя API → 5. plan/edit (Edit/Write) |
| **Bug fix** | 1. discovery-search симптом → 2. callers-trace → 3. read тела → 4. `Edit` или `python3+str.replace` (batch) → 5. add test |
| **Рефакторинг** | 1. god-nodes query (cbm `query_graph` или Roslyn dead-code detection) → 2. callers-trace для каждого target → 3. N×Edit / `python3+str.replace` per file / serena `rename_symbol` → 4. переиндексация для верификации |
| **Library migration** | 1. `context7.resolve-library-id` → 2. `query-docs` migration guide → 3. discovery `search_code`/`search_for_pattern` deprecated API usages → 4. batch edit |
| **Cross-project pattern** | 1. `exa.web_search_exa` "best practice X" → 2. `exa.get_code_context_exa` примеры → 3. `claude-mem:knowledge-agent` build brain → 4. plan |
| **Архитектурный аудит** | 1. `cbm.get_architecture` aspects (или эквивалент профиля) → 2. god-nodes/orphans query → 3. `claude-mem:pathfinder` → 4. ADR через `cbm.manage_adr` (если есть) |
| **DB-schema verify** | См. отдельно `postgres_ro` (вне scope этого inventory) — `list_objects → get_object_details → execute_sql LIMIT 100`. |
| **UI verify** | См. отдельно `playwright` — `browser_set_storage_state → browser_navigate → browser_take_screenshot`. |

---

## Bypass / emergency

Только для специфичных skills и emergency:
```bash
CLAUDE_BYPASS_DISCOVERY_GATE=1   # legacy alias: CLAUDE_BYPASS_CBM_GATE=1
```
Снимает блок `discovery-gate` хука. Не использовать как умолчание. Soft-warning hooks (`mcp-soft-discipline`, discovery-augment) не имеют bypass — они никогда не блокируют.
