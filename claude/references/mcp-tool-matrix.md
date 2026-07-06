# MCP Tool Selection Matrix — detailed

> On-demand reference. Короткий срез в `.claude/rules/mcp-usage.md`.

Research-base: Anthropic issues [#17301](https://github.com/anthropics/claude-code/issues/17301) (Edit bug на >2K files), [#19649](https://github.com/anthropics/claude-code/issues/19649) (bash cache miss), [#7336](https://github.com/anthropics/claude-code/issues/7336) (lazy MCP), [#38920](https://github.com/anthropics/claude-code/issues/38920) (LSP не propagate'ится в custom subagents). Общая специфика этого рантайма: `discovery-gate` хук блокирует blind recursive grep/rg/find на code-расширениях активного профиля; `claude-mem` PreToolUse:Read hook (`file-context`) перехватывает Read для `.md` с накопленными observations и возвращает «Only line 1 was read» + timeline вместо контента.

## READ — от дешёвого к дорогому

| Приоритет | Инструмент | Токены | Когда |
|---|---|---|---|
| 1 | discovery MCP `search_graph`/`find_symbol` → `get_code_snippet`/read symbol body | 200-500 + 2-4K | **старт любого code discovery** (профиль-зависимо: cbm для python/typescript, serena/Roslyn для csharp) |
| 2 | `bash sed -n 'N,Mp' file` | ~3/строка | конкретный диапазон строк (или fallback при hook-перехвате на .md) |
| 3 | `Read(file_path, offset, limit)` | ~4/строка | non-code structured text (`.md/.yaml/.json`, PRIMARY для <500 строк) |
| ❌ | `Read` без offset/limit на >500 строк | 2-4/line × N | triggers bug #17301 |
| ❌ | `Read` на code-расширениях активного профиля без предварительного discovery | blocked / discouraged | discovery-gate — читай через discovery-tool сначала |

## SEARCH — от дешёвого к дорогому

| Приоритет | Инструмент | Токены | Когда |
|---|---|---|---|
| 1 | discovery `search_code(pattern, mode=compact)` (cbm) / `search_for_pattern` (serena) | 200-500 | broad pattern, file+line |
| 2 | discovery `search_graph(query)` / `find_symbol` | 200-500 | structural find |
| 3 | `Grep` (built-in) | зависит | fallback если discovery-tool не знает |
| ❌ | `bash grep -r` | +30-40% vs built-in | cache miss (issue #19649) + заблокирован discovery-gate на code |

## Signal-words cheat-sheet

| Запрос | Инструмент |
|---|---|
| "кто вызывает X" | cbm `trace_path(X, mode=calls, direction=callers)` / serena `find_referencing_symbols` / Roslyn `find_callers` |
| "что вызывает X" | cbm `trace_path(X, mode=calls, direction=callees)` |
| "данные из A в B" | cbm `trace_path(A, mode=data_flow)` |
| "cross-service цепочка" | cbm `trace_path(A, mode=cross_service)` |
| "где определён символ" | cbm `search_graph(name_pattern\|qn_pattern)` / serena `find_symbol` |
| "что изменилось за N commits" | cbm `detect_changes(since="HEAD~N")` |
| "тело функции/класса" | cbm `get_code_snippet(qualified_name)` / serena `find_symbol(..., include_body)` |
| "обзор проекта" | cbm `get_architecture(aspects=["packages","services"])` |
| "паттерн с context" | cbm `search_code(pattern, mode=full)` |
| "сложный structural query" | cbm `query_graph(cypher)` |
| "god-nodes / refactor candidates" | cbm `query_graph("MATCH (n) WHERE size((n)--()) > 50 RETURN n")` / Roslyn dead-code detection |
| "навигация по requirements/RTM-докам" | `Read(offset, limit)` или `bash sed -n 'N,Mp'` |
| "whole-file read" | `Read(offset, limit)` (для .md / .yaml / .json) |

## EDIT — по типу файла

### Code-расширения активного профиля + `.md` / `.yaml` / `.toml` / `.json`

| Приоритет | Инструмент | Токены | Когда |
|---|---|---|---|
| 1 | `serena:replace_symbol_body` / `insert_after_symbol` / `rename_symbol` / `safe_delete_symbol` | symbol body | **symbol-level правка** (rename, удалить-с-проверкой-refs, переписать тело функции/класса) на любом профиле. Сначала `get_symbols_overview`→`find_symbol`; перед rename/delete — `find_referencing_symbols`; после — `get_diagnostics_for_file`. Чище ручного N×Edit. |
| 2 | `Edit` | ~old+new | точечная string-замена (не по границе символа), включая JSX/TSX/XAML/Razor. Перед большой правкой — прочитать тело через discovery-tool (~300-2000 ток) для контекста. |
| 3 | `Write` | size of new content | новый файл или полная перезапись |
| 4 | `bash python3 + pathlib + str.replace + assert` | 200-500/series | mass-rewrite по pattern (≥3 файла одинаково, независимо от расширения) |
| ❌ | `bash sed -i` / `awk` | — | правило: никогда |

> serena = `mcp__serena__*` (main + изолированные worker-контексты, авто-проект `--context claude-code`). Discovery на python/typescript всё равно предпочтительно cbm, если сконфигурирован. TS-caveat (баг #1586): `find_referencing_symbols` по TS может вернуть 0 в монорепо без корневого tsconfig → кросс-чек cbm. Полный setup — `external-docs/serena-setup.md`.

Новый файл: `Write` (НЕ `cat > file <<EOF` — каждый heredoc = permission cache miss).

## Batch-rewrite canonical pattern (mass "во всех файлах X→Y")

```bash
python3 << 'PY'
from pathlib import Path
p = Path("path/to/file.ext")
src = p.read_text()

old = "точный уникальный кусок"
new = "новый кусок"
assert old in src, "anchor not found"
src = src.replace(old, new, 1)

p.write_text(src)
PY
```
Атомарно несколько `replace` в одном скрипте. `assert` ловит устаревший anchor до записи. Применимо к любому расширению при массовой (≥3 файла) идентичной правке — не привязано к конкретному языковому профилю; для единичной точечной правки любого файла (включая JSX/TSX/XAML) обычный `Edit` предпочтительнее (дешевле и меньше boilerplate).

## Pre-computation pattern (90%+ экономии)

Паттерн: вынести повторяющиеся агрегации в bash-скрипты с компактным JSON на выходе. Coordinator делает один Read/Bash → JSON вместо 10+ tool calls.

Кандидаты (пример — не предписание, конкретные скрипты появляются по мере роста продукт-репо):
- `scripts/scope-summary.sh <task-id>` → `{files_affected, modules, LOC, cross_module}`
- `scripts/baseline-failures.sh` → список pre-existing fails, TTL-кеш 24h
- `scripts/requirements-sync.sh <REQ-ID>` → `{status, spec_status, diff}`

Правило: если operation повторяется в ≥3 skills или ≥3 раза за задачу — выносить в bash+JSON.

## Discovery bash fallback (для preflight/CI без MCP сессии)

Если discovery MCP недоступен из CI/plain-shell контекста, а продукт-репо держит тонкие bash-обёртки над ним (например `scripts/cbm-q.sh <keyword>`, `scripts/cbm-trace.sh <exact-name>`) — использовать их там, где MCP-сессия недоступна. Внутри Claude Code — всегда нативные MCP tools, не bash-обёртки.

## cbm подводные камни

1. **Индекс свежести**: правки <1 мин назад → `detect_changes(since=HEAD)` надёжнее. Для AST-изменений — `index_repository(mode="fast")` (секунды).
2. **qualified_name резолвится проектом**: все запросы принимают `project="{{CBM_PROJECT}}"`. Без этого пусто или со всех проектов.
3. **Trace depth**: `depth=2` — default. `depth=3+` → экспоненциальный взрыв, фильтруй через cypher.
4. **search_code mode**: `compact` (file+line) по умолчанию; `full` — только body snippets; `files` — подсчёт по директориям.
5. **Types**: cbm знает Function/Class/Route, но не TS types/Python hints/C# generics. Для типов — `get_code_snippet(qn)` + Read с offset, или LSP `hover`.
6. **Cypher**: `query_graph` принимает Cypher с custom nodes (Function, Class, Route, Module, File). Справка: `get_graph_schema()`.

## claude-mem hook поведение

**`PreToolUse:Read` (file-context)** перехватывает любой Read на `.md` с прежними observations и возвращает только line 1 + semantic timeline. Симптом — «Only line 1 was read».

Workarounds:
- `bash sed -n '1,200p' file.md` или `cat` — hook не трогает Bash. Дёшево для коротких файлов.
- После одного перехваченного Read файл регистрируется как прочитанный — последующий `Edit` работает нормально.

Не лечить через повторный Read с тем же offset — hook сработает снова на втором вызове и вернёт «Wasted call — file unchanged».

---

## Token cost per tool (per-call estimates)

| Tool | Cost (tokens) | Notes |
|------|---------------|-------|
| cbm `search_graph` | ~300-800 | scales with `limit` (default 100); set limit=10-20 для focused searches |
| cbm `trace_path` | ~500-1500 | scales with `depth` × call density; depth 2-3 для типичных случаев |
| cbm `get_code_snippet` | ~200-2000 | размер symbol body; функция ~300, класс ~1000+ |
| cbm `get_architecture` | ~500-1000 | one-shot codebase overview |
| cbm `search_code` | ~300-1000 | grep-like; scales с числом матчей |
| serena `find_symbol`/`get_symbols_overview` | ~200-1500 | сопоставимо с cbm-эквивалентом |
| `claude-mem.search` | ~50-100 per result | compact index format |
| `claude-mem.timeline` | ~200-500 | chronological context |
| `claude-mem.get_observations` | ~500-1000 per ID | full observation; **batch** для амортизации |
| `postgres_ro.execute_sql` | ~50 + N rows × ~50 | always set LIMIT |
| `postgres_ro.explain_query` (analyze=true) | ~500-1500 | full plan |
| `playwright.browser_snapshot` | ~1000-3000 | full DOM ARIA tree |
| `playwright.browser_take_screenshot` | ~50 (out) | image saved separately, not in context |
| `exa.web_search_exa` | ~500-2000 | depends on numResults |
| `exa.web_fetch_exa` | ~3000-10000 | per-URL × maxCharacters cap |
| `context7.query-docs` | ~1000-3000 | scoped doc snippets |

**Cheapest path для типичного code-discovery вопроса**: discovery `search_graph`/`find_symbol` (limit=5) → read symbol body ≈ 600 ток vs `Read` full file ≈ 2000-5000 ток.

## Per-server pitfalls

| Server | Pitfall | Fix |
|--------|---------|-----|
| cbm | `trace_path` returns 0 results | use `search_graph(name_pattern=".*Partial.*")` first to discover exact name |
| cbm | `get_code_snippet` "node not found" | wrong qualified_name format — copy from `search_graph` result |
| cbm | stale index (recent code edits not reflected) | `detect_changes` check + `index_repository(mode="fast")` |
| cbm | wrong project results | add `project="{{CBM_PROJECT}}"` |
| serena | TS `find_referencing_symbols` returns 0 in monorepo | needs root `tsconfig.json` (bug oraios/serena#1586) — cross-check cbm if available |
| claude-mem | TTL Chroma vector DB stale | `prime_corpus(corpus_id)` если результаты outdated |
| claude-mem | одиночные `get_observations` calls | **always batch IDs**: `get_observations([id1,id2,id3])` |
| postgres_ro | connection pool exhaustion | hard 5s `statement_timeout` уже настроен; не делать N×100 параллельных queries |
| postgres_ro | "SELECT *" без LIMIT может вернуть millions rows | always `LIMIT 100` |
| playwright | localStorage сбрасывается между навигациями на некоторых стеках | `browser_set_storage_state` ДО первого `browser_navigate`, не после |
| playwright | each session re-auth = +20s overhead | cache auth-state файл (TTL 1h, gitignored) |
| exa | "X vs Y" keyword query даёт generic results | semantic descriptions: "blog post comparing X and Y for use case Z" |
| context7 | wrong libraryId | always `resolve-library-id` ПЕРЕД `query-docs`, даже если name "очевиден" |

## Workflow recipes

### Recipe 1: Task/story planning analysis
```
cbm.get_architecture(aspects=["packages","services"])   # density по модулям, ~500 ток
cbm.detect_changes(since="HEAD~10")                       # touched files, conflicts
claude-mem.search(q=taskId+title, limit=3)                # prior similar work
```

### Recipe 2: Code review impact map
```
discovery.search_graph(name_pattern=".*ChangedFn.*")                    # find symbol
discovery.trace_path(name=<exact>, direction="inbound")                  # callers
# для каждого CRITICAL caller → discovery.get_code_snippet
```

### Recipe 3: DB migration verify
```
postgres_ro.execute_sql("SELECT version_num FROM alembic_version")  # head match (Alembic) / EF __EFMigrationsHistory
postgres_ro.get_object_details(table=<new>)                          # column types
postgres_ro.execute_sql("SELECT COUNT(*) FROM t WHERE col IS NULL")  # backfill
```

### Recipe 3b: Performance triage
```
postgres_ro.analyze_workload_indexes()                            # top queries из pg_stat_statements
postgres_ro.explain_query(query=..., analyze=true, buffers=true)  # full plan, cold-cache via BUFFERS
```

### Recipe 4: Frontend visual verify with auth
```
playwright.browser_set_storage_state(path="<auth-state-file>")
playwright.browser_navigate(url="<local dev URL>/<route>")
playwright.browser_take_screenshot(width=1440, height=900)
playwright.browser_snapshot()  # ARIA tree для a11y
```

### Recipe 5: Library upgrade research
```
context7.resolve-library-id(libraryName="React")
context7.query-docs(libraryId="<id>", query="useEffect cleanup migration v18→v19")
# fallback: exa.web_search_exa(...) → exa.web_fetch_exa([...])
```
