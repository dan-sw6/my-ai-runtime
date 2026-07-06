# MCP Anti-patterns

Расширенный список ошибок при работе с MCP. Дополняет `SKILL.md` (короткий список).

## codebase-memory-mcp (cbm)

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| `cbm:trace_path("UpdateUser")` без `search_graph` сначала — qn неугадан, вернёт 0. | `search_graph(name_pattern=".*UpdateUser.*")` → взять exact qn → `trace_path` с ним. |
| `cbm:get_code_snippet` с угаданным qn (`module.Class.method`) — неверный формат. | Сначала `search_graph` — получить точный `qualified_name` из ответа. |
| `cbm:trace_path(depth=4+)` без cypher-фильтра — экспоненциальный взрыв. | `depth=2-3` максимум; для глубже — `query_graph` с MATCH-фильтром. |
| `cbm` без указания `project="..."` — пустой результат или со всех проектов. | Всегда передавать `project="{{CBM_PROJECT}}"` (или sub-project). |
| Игнор stale index — правки <1 мин назад не видны. | `cbm:detect_changes(since="HEAD")` или `index_repository(mode="fast")` перед поиском. |
| `cbm` для типов / type hints — cbm не индексирует типы. | `cbm:get_code_snippet(qn)` для тела + Read targeted slice (offset/limit). |

## Edit / Write

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| `Write` поверх существующего файла без предварительного Read — потеря данных. | `Edit` для точечных правок; `Write` только для новых файлов. |
| `bash sed -i` / `awk` для правки. | `Edit` для точечной string-замены; `python3+pathlib+str.replace+assert` для batch. |
| Mass-rewrite файл-за-файлом через `Read+Edit` цикл. | `cbm:search_code(mode=files)` → один `python3+str.replace` на все targets. |
| Rename / safe-delete без проверки callers. | `cbm:trace_path(callers)` (или `find_referencing_symbols`) → если empty → Edit; иначе обновить все ref'ы. |

## claude-mem

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| Спросить пользователя «делали ли мы X» без `mem-search`. | ВСЕГДА `mem-search "X" --limit 5` сначала. |
| Одиночные `get_observations` calls по одному ID. | Batch'и: `get_observations 18280 18281 18282 18283` за один вызов. |
| `claude-mem search` с keywords-only («fix bug»). | Описательно: «fix order_total NULL on cart checkout». |
| Сохранять в claude-mem то что и так есть в git log. | Сохранять только `surprising` / `non-obvious` / `cross-session-relevant`. |

## context7

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| `query-docs` без `resolve-library-id` сначала. | Всегда: `resolve-library-id(libraryName="X")` → `query-docs(libraryId="<resolved>", query="...")`. |
| `WebFetch` на официальный сайт документации для API-вопроса. | `context7:query-docs` — даёт актуальную версию. WebFetch — fallback. |
| `query-docs` с очень общим query («tutorial»). | Конкретно: «v5 migration breaking changes», «useInfiniteQuery example with cursor». |
| Использование context7 для бизнес-логики / debugging своего кода. | Только для library/SDK/CLI/framework вопросов. |

## exa

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| `web_search_exa("React useEffect")` — keywords. | Описательно: «why does useEffect run twice in React 18 Strict Mode and how to handle it». |
| `web_fetch_exa(urls=[...])` по одному URL за раз. | Batch'и `urls=[url1, url2, url3]` — один вызов. |
| `exa` для library docs где есть context7. | Сначала context7 (официальные доки); exa — для community/best-practices. |
| `get_code_context_exa` без описательного query. | «production-grade FastAPI background scheduler with graceful shutdown signal handler». |

## Hooks / discipline (если репозиторий использует discovery-gate hooks)

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| Регулярно использовать bypass-флаг discovery-gate. | Только emergency. Если bypass нужен часто — пересмотреть подход. |
| Игнор deny-reason hook'а — повторять тот же tool. | Прочитать reason; переключиться на code-discovery MCP. |
| Использовать `Bash grep -r 'foo' src/` для code-discovery. | `cbm:search_code(pattern="foo", project="...")`. |
| Использовать `find -name '*.ts'` для discovery. | `cbm:search_graph(file_pattern=".*\\.ts$")`. |

## Workflow

| ❌ Anti-pattern | ✅ Правильно |
|---|---|
| Открыть Read для полного файла (1500 строк) чтобы найти один метод. | `cbm:search_graph` → `cbm:get_code_snippet(qn)`. |
| Параллельно `Grep` несколько раз без cbm в окне (≥3) — заблокирует hook (если настроен). | Первый шаг — `cbm:search_graph`. |
| Skill вне frontmatter `allowed-tools` пытается вызывать MCP-tools — нет доступа (если frontmatter ограничивает tools). | Указать tools в `allowed-tools` явно, если этот механизм используется. |
| Subagent игнорирует MANDATORY-блок дисциплины (нет инъекции в agent-файл). | Inject discipline-контракт в каждый agent-файл, если такой механизм принят в репозитории. |
