# Cross-MCP Recipes

Канонические последовательности для типовых задач. Дополняет 4-step ritual из `SKILL.md`.

## Recipe 1 — Новая фича

```
1. claude-mem:mem-search "название фичи" --limit 5
   → если есть прошлая работа — get_observations [batch IDs]
2. cbm:search_graph(query="похожая фича", project="{{CBM_PROJECT}}")
   → get_code_snippet(qn) для паттернов
3. cbm:get_code_snippet для целевых extension points (тело символа)
4. context7:query-docs если нужно внешнее API
5. plan/edit (Edit / Write; python3+str.replace для mass-rewrite)
```

## Recipe 2 — Bug fix

```
1. cbm:search_graph(query="симптом или сообщение об ошибке")
2. cbm:trace_path(function_name="<qn>", mode="calls", direction="callers", depth=2)
3. cbm:get_code_snippet(qualified_name="<qn>") — тело функции
4. cbm:trace_path(callers, depth=3) для понимания impact
5. Edit точечно (или python3+str.replace для mass-rewrite одного паттерна)
6. add test (regression)
```

## Recipe 3 — Рефакторинг (rename / extract)

```
1. cbm:query_graph (Cypher) для god-nodes / orphans:
   MATCH (n) WHERE size((n)--()) > 50 RETURN n
2. cbm:trace_path(callers) — все референсы для каждого target
3. Решение: rename, split, extract
4. N×Edit или python3+str.replace per file (проверка ref'ов через cbm-список ОБЯЗАТЕЛЬНА перед rename/delete)
5. cbm:index_repository(mode="fast") — обновить индекс + verify через cbm:detect_changes(since=HEAD)
```

## Recipe 4 — Library migration

```
1. context7:resolve-library-id(libraryName="...")
2. context7:query-docs(libraryId="...", query="migration v4 to v5")
3. cbm:search_code(pattern="deprecatedAPI", mode="files")
   → список call-sites
4. batch edit:
   - Edit per call-site (или python3+str.replace если паттерн идентичен)
5. test
```

## Recipe 5 — Cross-project pattern

```
1. exa:web_search_exa("idiomatic X best practice")
2. exa:web_fetch_exa(urls=[top-3])
3. exa:get_code_context_exa(query="X production example") — реальный код
4. claude-mem:knowledge-agent build "тема" — сохранить выводы (если доступен)
5. plan
```

## Recipe 6 — Архитектурный аудит

```
1. cbm:get_architecture(aspects=["packages", "services", "dependencies"])
2. cbm:query_graph (Cypher для god-nodes / circular deps):
   MATCH (a)-[*1..3]->(a) RETURN a
3. claude-mem:pathfinder — duplicate concerns (если доступен)
4. cbm:manage_adr — линковка ADR в граф (если репозиторий ведёт ADR)
5. ADR-черновик
```

## Recipe 7 — DB-schema verify

```
postgres_ro:list_objects(schema="public")
  → get_object_details(name="<table>")
  → execute_sql("SELECT ... LIMIT 100")  # ВСЕГДА с LIMIT
```

## Recipe 8 — UI verify (после изменений)

```
playwright:browser_set_storage_state(path="<auth-state-file>")  # если auth нужен
  → browser_navigate(url="<local-dev-url>")
  → browser_take_screenshot
  → если регрессия: browser_console_messages, browser_network_requests
```

## Recipe 9 — Импорт/расширение существующего модуля

```
1. cbm:get_architecture(aspects=["packages"]) — где модуль
2. cbm:search_graph(name_pattern=".*<keyword>.*", file_pattern="<module-path>/.*")
3. cbm:get_code_snippet(qn) для тел symbols
4. claude-mem:mem-search "module x" — прошлые решения
5. Edit / Write
```

## Recipe 10 — Frontend-design (новая страница)

```
1. claude-mem:mem-search "design system / page skeleton canon" — какой канон принят в этом репозитории
2. cbm:search_graph для shared-компонентов (list-page/table/form kit'ы, если есть)
3. context7:query-docs для UI-библиотеки (Radix, MUI, TanStack Query) — новые API
4. python3+str.replace или Edit для правок разметки
5. playwright verify (screenshot затронутых экранов)
```
