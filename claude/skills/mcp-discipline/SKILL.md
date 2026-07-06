---
name: mcp-discipline
description: "Use when starting any non-trivial code task — explores how to discover, edit, recall, and research using MCP tools (code-discovery MCP / claude-mem / context7 / exa) instead of grep/Read/WebFetch. Apply at task kickoff BEFORE clarifying questions to the user. Skip for trivial single-line edits to known files."
---

# MCP Discipline — обязательный workflow

Этот skill активируется в начале любой нетривиальной задачи. Цель — заставить себя пройти 4-step ритуал и не пропустить MCP-инструменты, заменив их на Grep/Read/WebFetch/«спросить пользователя».

> Если в этом репозитории настроены discovery-hooks (deny-on-missing-MCP-call) — они защищают hard-rules независимо от этого skill'а; soft-rules остаются на дисциплине агента. Recipes — `references/recipes.md` рядом с этим файлом; расширенный список ошибок — `references/anti-patterns.md`.

## 4-step ritual

### Шаг 1 — Cross-session memory (claude-mem) — MANDATORY

**Перед клар-вопросами пользователю** «делали ли мы X?» / «как мы решали Y?» — ОБЯЗАТЕЛЬНО поиск в claude-mem:

```
/mem-search "ключевые слова темы"        # skill claude-mem:mem-search, limit=3-5
# либо bash:
claude-mem search "тема" --limit 5
claude-mem get_observations 18280 18281  # batch — несколько IDs за раз
```

Если найдены релевантные observations — прочитать (батч `get_observations`), упомянуть IDs в plan. Без mem-search клар-вопрос про прошлые решения = anti-pattern (см. ниже).

### Шаг 2 — Code discovery — PRIMARY tool

Code-discovery MCP этого профиля — primary tool для всего что касается кода (read, navigate, impact). Никаких Read/Grep code-файла «вслепую». Какой именно MCP — зависит от активного языкового профиля репозитория:

- **Python / TypeScript** — `codebase-memory-mcp` (cbm), graph-based структурный поиск по проекту `{{CBM_PROJECT}}`.
- **C#** — Roslyn MCP (или `serena` в ADOPT-режиме) — symbol-level поиск.
- **Универсальный fallback** (cbm/Roslyn не настроены для профиля) — `serena`: `get_symbols_overview` → `find_symbol`.

```
mcp__codebase-memory-mcp__list_projects  # выбрать project name (обычно "{{CBM_PROJECT}}")
mcp__codebase-memory-mcp__search_graph(
  query="natural language description",
  project="{{CBM_PROJECT}}",
  limit=10
)
# Затем:
mcp__codebase-memory-mcp__trace_path(function_name="<exact qn>", direction="both", depth=2)
mcp__codebase-memory-mcp__get_code_snippet(qualified_name="<exact qn>", project="{{CBM_PROJECT}}")
```

Если cbm не настроен для этого профиля/языка — тот же ритуал через serena:

```
mcp__serena__get_symbols_overview(file)
mcp__serena__find_symbol(name_path)
```

Если индекс stale (правки <1 мин назад) — `detect_changes(since="HEAD")` или `index_repository(mode="fast")`.

Bash-обёртки для friction-reduction (если есть в этом репозитории — проверить `scripts/`):
```
scripts/cbm-q.sh <keyword> [Function|Class|Route] [limit]
scripts/cbm-trace.sh <exact-name>
scripts/cbm-freshness.sh
```

### Шаг 3 — Edit (Edit / Write / python3+str.replace)

Когда найден target через `get_code_snippet` (или `find_symbol`) — прямые правки:

- **Любой code-файл** (`.py` / `.ts` / `.tsx` / `.jsx` / `.sh` / `.md` / `.yaml` / `.toml` / `.json` / `.cs`): `Edit` для точечных правок; `Write` для новых файлов.
- **Mass rewrite «во всех X→Y»**: `search_code(mode=files)` → `python3+str.replace` per file. Шаблон:
  ```bash
  python3 << 'PY'
  from pathlib import Path
  p = Path("path/to/file")
  txt = p.read_text()
  old = "уникальный кусок"
  new = "новый кусок"
  assert old in txt and txt.count(old) == 1
  p.write_text(txt.replace(old, new))
  PY
  ```
- **Rename / safe-delete**: `trace_path(callers)` (или `find_referencing_symbols` в serena) для sanity ПЕРЕД удалением/переименованием → N×Edit / `python3+str.replace`. Пропустить эту проверку — anti-pattern.

### Шаг 4 — External docs (context7) — если нужна библиотека

Для ЛЮБОГО вопроса про библиотеку / фреймворк / SDK / API (React, FastAPI, TanStack, SQLAlchemy, Entity Framework, ASP.NET Core, Vitest, Playwright — независимо от языкового профиля):

```
mcp__context7__resolve-library-id(libraryName="TanStack Query")
mcp__context7__query-docs(libraryId="<resolved>", query="useInfiniteQuery v5 migration")
```

НЕ WebFetch на официальный сайт документации напрямую — context7 даёт актуальную версию доки.

### Шаг 5 (опц.) — Open research (exa) — если нужны best practices

```
mcp__exa__web_search_exa(query="idiomatic FastAPI background scheduler shutdown pattern")
mcp__exa__web_fetch_exa(urls=["<top-3>"])  # batch! не по одному
mcp__exa__get_code_context_exa(query="FastAPI graceful shutdown signal handler")
```

Query формулируй описательно. Не «React useEffect», а «why does useEffect run twice in React 18 Strict Mode».

## When NOT to use this skill

Skill — overhead для тривиальных правок. Пропускай если ВСЕ верны:

- Изменение в одном файле, путь известен.
- Одна-две короткие правки (типа typo, переименование переменной, замена literal).
- Не затрагивает поведение функций/классов вне локального scope.
- Не требует знания внешних API.

В таких случаях — `Edit` напрямую.

## Anti-patterns (не делать)

1. ❌ `Grep -r 'функция'` по всему codebase. → `search_graph(query="функция")` через code-discovery MCP.
2. ❌ `Read` всего файла на 1500 строк, чтобы найти один метод. → `search_graph` + `get_code_snippet(qn)`.
3. ❌ Спросить пользователя «делали ли мы X в прошлой сессии». → `/mem-search "X"` сначала.
4. ❌ `WebFetch` на официальный сайт документации библиотеки. → `context7:query-docs` сначала.
5. ❌ `trace_path("UpdateUser")` без `search_graph` сначала — qn неизвестен, вернёт 0.
6. ❌ Mass-rewrite файл-за-файлом через `Read+Edit` цикл. → `search_code(mode=files)` → один `python3+str.replace` на все targets.
7. ❌ Одиночные `claude-mem get_observations` — batch'и 3-10 IDs в одном вызове.
8. ❌ Игнорировать deny-reason discovery-hook'а (если настроен) и повторять тот же tool — переключиться на code-discovery MCP.

## Verification

После применения skill в задаче — если в репозитории есть usage-tracking (например `scripts/mcp-usage-report.sh`), проверить ratio MCP-tools vs builtin (Grep/Read/Bash). Низкий ratio MCP-вызовов при высоком Grep/Read — сигнал пересмотреть подход.

## Reference files

- `references/recipes.md` — cross-MCP recipes для типовых задач.
- `references/anti-patterns.md` — расширенный список ошибок.
- Формальные hard/soft-правила и hook enforcement — см. MCP-usage rules этого репозитория, если они настроены.
