# MCP Usage Rules

> Детальные workflow per-server, recipes, token-costs, pitfalls — `.claude/references/mcp-tool-matrix.md` (on-demand). Полный per-tool inventory — `.claude/references/mcp-tool-inventory.md`.

## Profile → code-discovery MCP

Discipline ниже говорит о «code-discovery MCP активного профиля» — какой сервер это конкретно, зависит от `languages:` в `runtime.config.yaml`:

| Профиль | Code-расширения | Discovery MCP | Reference impl? |
|---------|------------------|----------------|------------------|
| **python** | `.py`, `.pyi` | **cbm** (codebase-memory-mcp, `{{CBM_PROJECT}}`) | да — граф-first |
| **typescript** | `.ts`, `.tsx`, `.js`, `.jsx` | **cbm** (тот же индекс, мультиязычный) | да |
| **csharp** (ADOPT) | `.cs`, `.xaml` (`.axaml` для Avalonia) | **serena(csharp)**: `find_symbol`/`find_referencing_symbols`, или Roslyn MCP (`CWM.RoslynNavigator`: `find_symbol`/`find_references`/`get_diagnostics`), если сконфигурирован | нет — serena/Roslyn первичны |

Если `cbm_project` в `runtime.config.yaml` пуст (`""`) — cbm выключен целиком, discovery-gate для python/typescript-профиля тоже падает на serena (fallback discovery-слой). cbm — это **reference-реализация** discovery-слоя, не единственно возможная; правила ниже описывают её как канон, но принцип («ALWAYS discovery-tool FIRST, не Grep/Read вслепую») переносится на любой профиль без изменений.

## MANDATORY ENFORCEMENT (hybrid)

Hard rules защищены discipline-хуками из **глобального** канала рантайма (`global/hooks/` → устанавливаются один раз на машину через `install-global.sh`, не per-repo; читают `runtime.config.yaml` продукт-репо в рантайме, а не at sync-time — так один и тот же хук работает на любой репо с любым профилем). Ключевые: `discovery-gate` (PreToolUse:Bash — блокирует blind grep/rg/find на code), `discovery-augment` (PreToolUse:Grep|Glob — молча добавляет граф-контекст, если discovery MCP доступен, иначе no-op), `discovery-session-reminder` (SessionStart — печатает discovery-протокол), `mcp-soft-discipline` (PreToolUse:WebFetch|WebSearch — soft hint), `mcp-usage-tracker` (PostToolUse — usage-лог). Все возвращают JSON `permissionDecision=deny|allow+reason` (не `exit 2` — известные баги upstream #43407/#26923).

### HARD rules (block via hook)

1. **ALWAYS use the profile's code-discovery MCP FIRST** для code-discovery в расширениях активного языкового профиля (см. таблицу выше). Сначала graph/symbol-discovery-запрос (`search_graph`/`query`/`find_symbol` — по серверу), потом trace/read (`trace_path`/`get_code_snippet` для cbm; `find_referencing_symbols`/`get_symbols_overview` для serena/Roslyn). Никогда не Grep/Read code-файла «вслепую». **Discovery MCP — это PRIMARY tool для всего что касается кода (read, navigate, impact)**, без него работа на code-файлах не начинается.
2. **NEVER recursive `grep -r` / `rg` / `find -name '*.ts'`** через Bash — заблокировано. Эквивалент: cbm `search_code(pattern, mode=files|compact|full)` (python/typescript) или serena `search_for_pattern` (csharp/fallback).
3. **Before Read-ing code-файла** — FIRST discovery-запрос (найти QN/symbol) → `get_code_snippet(qn)` / `find_symbol`. Read только когда символ неизвестен или нужен whole-file context.
4. **Blind-grep block**: recursive `grep -r`/`rg`/`find -name '*.<code-ext>'` на code-расширениях активного профиля блокируется хуком немедленно (см. `discovery-gate` в глобальном канале); дополнительно rate-limited вариант (≥N Grep/Glob/Read для code в окне M calls без discovery-вызова → блок) может быть включён — точный алгоритм и пороги живут в самом hook-скрипте, не здесь.
5. **Legitimate fallback** (discovery возвращает empty):
   - индекс stale → `cbm:detect_changes(since="HEAD")` или `cbm:index_repository(mode="fast")` и retry (для serena — `restart_language_server`);
   - target — string-literal → Grep на конкретный файл (не recursive);
   - macro/preprocessor или generated code (C/C++, T4-templates, source-generators) → Grep как whole-fallback;
   - чтение `.md/.yaml/.json/.toml/.csv` — допустимо без discovery-tool (whitelisted в hook);
   - raw-SQL / генерируемые миграционные скрипты, специфичные для ORM (например Alembic `versions/*.py` или EF Core `Migrations/*.cs`) — discovery-граф их обычно не индексирует содержательно. Grep/Read разрешены без discovery-tool-перед-вызова, если так решено в hook whitelist конкретного репо.
   > Пример из практики (monorepo-консьюмер): whitelist для `platform/data/migrations/versions/*.py` был добавлен после серии багов, задиагностированных через string-literal grep на `op.execute` / `EXTRACT(YEAR FROM` / `jsonb_array_length` — обычный код-путь их бы не нашёл.

### SOFT rules (hint via systemMessage)

1. **Library docs → context7** (`resolve-library-id` → `query-docs`). Soft-discipline hook подсказывает при WebFetch на популярные libs.
2. **Open research → exa** (`web_search_exa` → `web_fetch_exa` или `get_code_context_exa`). Запросы описательные, не keywords.
3. **Cross-session memory → claude-mem ОБЯЗАТЕЛЕН ПЕРЕД клар-вопросами user'у** про прошлые решения. Skill `claude-mem:mem-search` (или CLI `claude-mem search/get_observations`) — РАНЬШЕ чем Read code-файла, РАНЬШЕ чем спросить «делали ли мы X?». Pattern: `mem-search "<topic>"` → если есть hits → `get_observations([batch ids])` за один вызов. Mem-search рефлекторно при старте задачи на знакомой теме (auth/RBAC/migrations/дедупликация и т.п.).
4. **LSP — ВСЕГДА после Edit / для type-intelligence** (см. секцию "LSP usage" ниже). Активные LSP зависят от языкового профиля: pyright (python), typescript (typescript), bash + shellcheck / yaml / json / markdown (везде). В custom subagents LSP **не propagate'ится** (баг Anthropic #38920) — workaround: pre-fetch в координаторе или Bash CLI (`pyright --outputjson`, `tsc --noEmit`, для csharp — `dotnet build`/`dotnet format --verify-no-changes`).

### Sub-agent model defaults (token economy)

**ХАРД-ПРАВИЛО**: ВСЕ subagents — `sonnet` или `haiku`. **НИКОГДА opus** в subagent (`Agent({model: "..."})`). Координатор главной сессии может быть Opus, subagents — нет.

Все read-only review/audit sub-agents (code-review, architecture-review, migration-review, QA/verify, type-design-analyzer и им подобные) — **Sonnet** в frontmatter `model:`. Лёгкие audit/docs агенты (accessibility, documentation) — **Haiku**.

Built-in subagent types (`Explore`, `Plan`, `general-purpose`) — ВСЕГДА явно `Agent({model: "sonnet"})` или `"haiku"`. НЕ полагаться на inheritance.

Override на opus **запрещён** даже для security/auth/RBAC-критичных ревью — критичность не оправдывает 5× cost. Если нужна большая мощь — split в два sonnet-вызова или координатор сам делает review.

> Паттерн-эталон: один консолидированный Sonnet-ревьюер (security + quality + a11y + AC verify в одном вызове) экономит ~3× system-prompt overhead относительно параллельного fanout из 4 узкоспециализированных агентов — предпочитай его, когда задача позволяет.

### Research-first discipline (НЕ ГАДАТЬ, СНАЧАЛА УЗНАТЬ)

Сначала выясни — потом пиши код. Триггеры обязательного research-вызова:

1. **Новая библиотека / minor-bump** — `import`/пакетный add/upgrade, миграция между версиями (React 18→19, Pydantic v1→v2, .NET Framework→.NET 8, Newtonsoft.Json→System.Text.Json): `context7:resolve-library-id(name)` → `context7:query-docs(id, "<конкретная задача>")` ДО написания кода. Никогда не угадывать API/имена методов/сигнатуры.
2. **Незнакомый API существующей либы** — feature, который раньше не использовался в проекте: сначала `context7:query-docs`. Discovery MCP — для проверки существующих использований в проекте, но это дополнение, не замена docs.
3. **Open research, паттерн без явной либы** ("как лучше делать X в FastAPI", "что safer для bulk update в Postgres", "идиоматичный DI-паттерн в ASP.NET Core"): `exa:web_search_exa(query)` (semantic-описательный запрос, НЕ keywords) → `exa:web_fetch_exa(urls=[...])` или `exa:get_code_context_exa` для production-кода с GitHub.
4. **Breaking change / deprecation** — если компилятор/linter ругается на deprecated API: сначала context7 → query-docs migration path → потом правка.
5. **Перед designing новой архитектуры/паттерна**: exa research + context7 для каждой потенциальной библиотеки. Решение фиксировать в ADR.

**Anti-patterns** (запрещено):
- Угадывать имя метода/сигнатуру по training-data вместо проверки в `context7:query-docs` — training-data может быть до cutoff, current версия может иметь другой API.
- WebFetch напрямую на официальные доки популярных библиотек — soft-discipline hook подскажет; preferred — context7.
- Использовать exa с keyword-формой запроса (`react vs vue`); правильно — semantic (`blog post comparing react performance for large lists`).
- Игнорировать exa и сразу писать "best-effort" код "из памяти" для нетривиальной задачи.

**Когда research НЕ нужен**: точечная правка известного кода, refactor с known-shape API, типографские правки. Не превращать research в churn.

**Output research'а — фиксировать в claude-mem**: когда узнал что-то нетривиальное (gotcha, deprecation, optimal pattern) — пиши факт в код-комментарий-проблему или переноси в `.claude/references/external-docs/<lib>-<topic>.md`. Не повторять research дважды.

### Bypass

Глобальные discipline-хуки поддерживают:

```bash
CLAUDE_BYPASS_DISCOVERY_GATE=1   # снимает discovery-gate (legacy alias: CLAUDE_BYPASS_CBM_GATE=1)
CLAUDE_BYPASS_MCP_SOFT=1         # отключает soft-hint при WebFetch/WebSearch
```

Только для emergency и специфичных skills.

#### Как реально включить bypass — критично

**Inline-prefix `CLAUDE_BYPASS_*=1 cmd` и `export VAR=1; cmd` из инструмента Bash НЕ РАБОТАЮТ.** Hook запускается Claude Code как отдельный child process и наследует env только из main-процесса Claude Code, а не из Bash-tool subshell. Inline-prefix (POSIX) ставит переменную только в env самой команды; `export` ставит её в env Bash-tool subshell — hook (sibling, не parent) этого env не видит.

Реальные способы:

1. **В shell, который запускает Claude Code**: `export CLAUDE_BYPASS_CBM_GATE=1; claude`. Применимо для всей сессии.
2. **В `~/.claude/settings.json`** через блок `"env"`:
   ```json
   { "env": { "CLAUDE_BYPASS_CBM_GATE": "1" } }
   ```
   Применимо для всех будущих сессий пользователя.
3. **В project `.claude/settings.local.json`** для конкретного проекта.
4. **В skill, запускающем Claude Code как subprocess** — выставить `CLAUDE_BYPASS_*` в env родительского shell ДО `claude` invocation.

**Если нужен bypass на одну операцию — НЕ пытайся inline.** Это replay-loop: hook снова заблокирует, токены сожгутся. Вместо этого делай прямой MCP-вызов — он быстрее любой правки settings.

### Subagent inject

Subagents (`Task`-tool) **НЕ наследуют** этот файл автоматически. Если у продукт-репо есть `.claude/agents/*.md` — встроить туда эквивалентный MANDATORY-блок (тот же контракт).

## Server Selection Matrix

| Server | Primary use | First call | Then |
|--------|-------------|------------|------|
| **code-discovery MCP** (профиль-зависимый; reference impl — **cbm**/codebase-memory-mcp для python/typescript) | **PRIMARY для всего code** — discovery, read symbol body, call graphs, impact, text search | cbm: `search_graph(name_pattern=".*X.*", label="Function")`; csharp/fallback: `get_symbols_overview(file)` → `find_symbol` | cbm: `trace_path(name=<exact>)` или `get_code_snippet(qn)`; serena: `find_referencing_symbols` |
| **LSP** (built-in tool) | **Live type-intelligence** — diagnostics после Edit, hover-types, schema-aware JSON/YAML | `LSP(operation=hover, file, line, char)` | `LSP(documentSymbol)` / `findReferences` / `goToDefinition` |
| **serena** (`mcp__serena__*`) | **Symbol-level EDIT** (все профили) — rename/safe-delete/тело символа без ручного N×Edit; авто-проект (claude-code ctx) | `get_symbols_overview(file)` → `find_symbol(name_path)` | `replace_symbol_body` / `insert_after_symbol` / `find_referencing_symbols` → `get_diagnostics_for_file` |
| **claude-mem** | **MANDATORY перед клар-вопросами user'у** — past decisions, "did we solve this?" | `mem-search(q, limit=3-5)` | `get_observations([batch ids])` |
| **postgres_ro** | DB schema/data verification (если проект использует Postgres) | `list_objects(schema="public")` | `get_object_details` или `execute_sql(LIMIT 100)` |
| **playwright** | UI verification (typescript-профиль с UI) | `browser_set_storage_state(path)` → `browser_navigate(url)` | `browser_take_screenshot` / `browser_snapshot` |
| **exa** | external research | `web_search_exa(query)` | `web_fetch_exa(urls=[best])` |
| **context7** | up-to-date library docs | `resolve-library-id(libraryName)` | `query-docs(libraryId, query)` |
| magicui / @21st-dev/magic / stitch | UI inspiration / design generation (typescript-профиль) | только внутри dedicated design-skill | — |

## File Reading Priority

- **Code (расширения активного профиля)**: discovery-tool (search_graph/find_symbol) → read symbol body (`get_code_snippet(qn)` / serena read) → fallback `Read(file_path, offset, limit)` (только когда символ неизвестен). После Edit auto-diagnostics через LSP — читать их inline.
- **Structured text (`.md`, `.yaml`, `.toml`, `.sh`)**: `Read(offset, limit)` для <500 строк → `bash sed -n 'N,Mp'` для больших docs. `LSP(documentSymbol)` для outline `.sh/.yaml` (быстрая структура без Read).
- **Non-code simple (`.json`, `.css`, `.txt`, `.csv`, `.env`)**: `Read`/`cat`. `Grep`/`find` допустимы — hook блокирует только code-расширения профиля. Для `.json` с `$schema` — `LSP(hover)` показывает schema-doc на ключе.

## Discovery-first — operation matrix

**Rule of thumb**: discovery/read/impact → **discovery MCP профиля**; editing → **Edit / Write / `python3+str.replace`** (или serena symbol-tools для symbol-level правок).

| Operation | Primary tool (python/typescript, cbm reference) | Primary tool (csharp / fallback) | Notes |
|-----------|--------------------------------------------------|-----------------------------------|-------|
| **Discovery** где определён символ | `cbm:search_graph(name_pattern, label)` | `serena:find_symbol` / Roslyn navigator | — |
| **Discovery** кто вызывает функцию | `cbm:trace_path(name=X, mode=callers)` | `serena:find_referencing_symbols` | — |
| **Discovery** text pattern в repo | `cbm:search_code(pattern, mode=files\|compact\|full)` | `serena:search_for_pattern` | — |
| **Discovery** архитектура | `cbm:get_architecture(aspects)` | — | cbm-specific |
| **Discovery** path между символами | `cbm:query_graph(MATCH …)` | — | cbm-specific (Cypher) |
| **Read** тело известного символа | `cbm:get_code_snippet(qn)` | `serena:find_symbol(..., include_body=true)` | дешевле чем `Read` whole file |
| **Read** outline файла | `cbm:search_graph(name_pattern=".*", file=...)` | `serena:get_symbols_overview(file)` | — |
| **Read** whole file | `Read(offset, limit)` | тот же | для .md/.yaml/.json — напрямую без discovery-tool |
| **Edit** тело функции/класса | `Edit` | `serena:replace_symbol_body` | предварительно прочитать тело для контекста |
| **Edit** точечная замена строки | `Edit` | `Edit` | — |
| **Edit** вставить рядом | `Edit` с anchor-текстом | `serena:insert_after_symbol` | — |
| **Edit** rename across project | discovery `trace_path`/`find_referencing_symbols`(callers) → ручной N×Edit / `python3+str.replace` | `serena:rename_symbol` | проверять refs discovery-tool'ом перед переименованием |
| **Edit** удалить с проверкой refs | callers-check → если empty → `Edit` | `serena:safe_delete_symbol` | проверка callers ОБЯЗАТЕЛЬНА перед delete |
| **Mass rewrite** «во всех X→Y» | `cbm:search_code(mode=files)` → `python3+str.replace` per file | `serena:search_for_pattern` → `python3+str.replace` per file | обязательно `assert old in txt` + `assert txt.count(old) == 1` |

### Каноничные workflow

1. **Discovery → Read → Edit**: discovery-search → read symbol body → `Edit`
2. **Impact-check + safe delete**: callers-trace → если empty → `Edit` / `safe_delete_symbol`
3. **Mass rewrite по pattern**: discovery `search_code`/`search_for_pattern`(mode=files) → `python3+str.replace` per file
4. **Insert next to existing**: discovery-search (placement target) → `Edit` с anchor / `insert_after_symbol`
5. **Rename across project**: callers-trace (sanity) → N×`Edit` / `python3+str.replace` / `rename_symbol` → detect_changes / `restart_language_server` для верификации

### Сильные стороны cbm (reference impl)

Graph traversal, ranking, aggregated views, cheap (~99% token reduction vs file-by-file), 155 lang. Минус — snapshot, может быть stale (`detect_changes` или `index_repository(mode=fast)` при подозрении). Read-only — для модификаций используем Edit/Write или Serena symbol-tools. cbm остаётся PRIMARY code-discovery MCP везде, где он сконфигурирован (`cbm_project` не пуст) — включая изолированные worktree/worker-контексты.

**Serena (все режимы работы, main-сессия + изолированные worker-контексты)**: namespace **`mcp__serena__*`**. Установка — **только** через PyPI (`uvx --from serena-agent serena start-mcp-server --context claude-code --project-from-cwd --mode editing`), апстрим прямо запрещает install через MCP/plugin-marketplace (см. `external-docs/serena-setup.md`). Авто-активация проекта по cwd — ручной `activate_project` не нужен в single-project контексте `claude-code`.

**МАНДАТ**: для symbol-level правок Serena — **первичный** путь (чище ручного N×Edit для rename/safe-delete/тела символа), для любого профиля. Каноничный workflow:
`get_symbols_overview(file)` → `find_symbol(name_path)` → `replace_symbol_body` / `insert_after_symbol` / `insert_before_symbol` → **перед** `rename_symbol`/`safe_delete_symbol` → `find_referencing_symbols` → после правок `get_diagnostics_for_file`. Discovery/impact на python/typescript-профилях всё равно предпочтительно через cbm, если сконфигурирован (Serena не заменяет cbm-граф, только дополняет как edit-слой); на csharp-профиле serena — единственный/первичный слой.

**Caveat TS (баг oraios/serena#1586)**: `find_referencing_symbols` по TS-символам в монорепо без корневого `tsconfig.json` может вернуть 0 (tsserver грузит файл как inferred project). Python/pyright не затронут. Для TS-референсов кросс-чекать через cbm, если доступен.

**Native LSP + Serena сосуществование**: в интерактивной main-сессии native LSP (pyright/tsc/bash/yaml/json/markdown, профиль-зависимо) остаётся включённым параллельно с Serena — раздельные stdio-процессы; роли: native = inline post-Edit диагностика + hover, Serena = deep `find_referencing_symbols` + symbol-edit + `rename_symbol`. В изолированных worker-контекстах (worktree-воркеры и т.п.) native LSP обычно **выключен** (LSP не propagate'ится в субагенты — баг #38920), поэтому Serena там единственный symbol/diagnostics-слой. Полная справка по setup/контекстам/режимам — `.claude/references/external-docs/serena-setup.md`.

## LSP usage (live type-intelligence)

LSP — built-in tool Claude Code, **дополняет discovery MCP не заменяет**. Discovery MCP = static graph snapshot (где сконфигурирован), LSP = live language server (pyright/tsc/bash-LS/yaml-LS/json-LS/marksman/csharp-LS в зависимости от профиля).

**ВСЕГДА используй LSP когда:**

1. **После Edit на code-файле активного профиля** — Claude Code авто-репортит diagnostics в conversation. Читать их inline, чинить найденное немедленно (type errors, unused imports, schema violations, shellcheck SCxxxx).
2. **Hover на ключе `.json`/`.yaml` с `$schema`** — `LSP(operation=hover, file, line, char)` показывает schema description. Быстрее чем читать schema doc.
3. **Navigation в больших code-файлах** — `LSP(documentSymbol, file, 1, 1)` даёт outline с line-numbers (часто дешевле чем discovery-tool + Read).
4. **Точная type-info на позиции** — `LSP(hover, file, line, char)` показывает inferred type / docstring. Discovery MCP даёт static signature, LSP — actual type-checked сигнатуру.
5. **Verify callers перед refactor/delete** — `LSP(findReferences, file, line, char)` + cross-check с cbm/serena trace. LSP видит usages внутри generics/decorators которые граф может пропустить.
6. **Call-graph trace** — `LSP(prepareCallHierarchy)` → `incomingCalls`/`outgoingCalls`. Альтернатива cbm `trace_path` для интерактивного traversal.
7. **Outline `.sh/.yaml/.json/.md`** — non-code файлы где discovery MCP не индексирует, но LSP-плагины (bash-LS/yaml-LS/json-LS/marksman) дают symbols.

**Operation cheatsheet:**

| Operation | Use case |
|-----------|----------|
| `documentSymbol(file, 1, 1)` | outline файла (быстрый nav) |
| `workspaceSymbol(query)` | global fuzzy-поиск символа |
| `hover(file, line, char)` | type / docstring / schema description |
| `goToDefinition(file, line, char)` | jump к definition |
| `goToImplementation(file, line, char)` | implementations interface/abstract |
| `findReferences(file, line, char)` | все usages символа |
| `prepareCallHierarchy(file, line, char)` | seed для call-graph |
| `incomingCalls` / `outgoingCalls` | callers / callees |

**LSP servers — profile-dependent** (активируются по `languages:` в `runtime.config.yaml`):

| Server | Профиль / файлы | Bonus |
|--------|------------------|-------|
| pyright | python — `.py/.pyi` | venv-aware через `pyrightconfig.json` |
| typescript | typescript — `.ts/.tsx/.js/.jsx/.mts/.cts/.mjs/.cjs` | подхватывает `tsconfig.json` |
| csharp-LS (omnisharp / csharp-ls) | csharp (ADOPT) — `.cs/.xaml/.csproj` | если сконфигурирован; иначе Roslyn MCP закрывает то же место |
| bash | все профили — `.sh/.bash/.zsh` | встроенный shellcheck (SCxxxx) |
| yaml | все профили — `.yaml/.yml` | schemas: compose / github-workflow / github-action / pre-commit / dependabot |
| json | все профили — `.json/.jsonc` | schemas: package / tsconfig / eslintrc / prettierrc / pyrightconfig / claude-plugin / claude-marketplace / renovate |
| markdown | все профили — `.md/.markdown` | marksman: heading-symbols + cross-ref check |

**Что LSP НЕ делает (не подменять):**

- Не читает файл целиком → `Read` / discovery MCP `get_code_snippet`/`find_symbol`.
- Не редактирует → `Edit` / `Write`.
- Не работает в named custom subagents (баг #38920 — built-in tools urезаны в `.claude/agents/*.md`). В subagent — workaround:
  - pre-fetch LSP в координаторе → inject в `prompt` subagent'а;
  - либо в subagent — Bash CLI: `pyright --outputjson file.py`, `npx tsc --noEmit`, `dotnet build`/`dotnet format --verify-no-changes`, `shellcheck -f json script.sh`, `yamllint -f parsable file.yaml`.

**Anti-patterns** (запрещено):

- Игнорировать `★ "X" is not accessed` после Edit — это hint pyright/tsc о dead code или забытом decorator/attribute. Проверять каждый раз.
- Игнорировать diagnostic блок `<new-diagnostics>` — если type error, чинить до завершения task. Если hint/warning не релевантен (осознанный false positive, например framework-специфичный handler `★ is not accessed`) — оставить, но осознанно.
- Hover не угадывая типа — есть `LSP(hover)`, не сочиняй сигнатуру по памяти.

## Critical Editing Rules

**Edit / Write — primary path для всех файлов.** Никаких mandatory pre-step через MCP — coordinator пишет напрямую (после discovery-tool discovery).

- **Code (расширения активного профиля) любого размера**: `Edit` для точечных правок; `Write` для новых файлов. Перед Edit'ом большой функции/класса — прочитать тело через discovery-tool (дешевле чем `Read whole file`). Для symbol-level rename/safe-delete/переписи тела целиком — предпочесть serena.
- **`.md`**: `Edit` напрямую.
- **Batch rewrites «во всех файлах X→Y»**: `python3 + pathlib + str.replace + assert` (с обязательным `assert old in txt` + `assert txt.count(old) == 1`) — независимо от расширения, включая JSX/TSX/Razor/XAML при массовой правке ≥3 файлов одинаково.
- **Rename / safe-delete с propagation**: callers-check (discovery-tool) для sanity → ручной N×Edit / `python3+str.replace` / serena `rename_symbol`/`safe_delete_symbol`.
- **Новый файл**: `Write`, не `cat > file <<EOF`.
- **НИКОГДА**: `sed -i` / `awk` через Bash для редактирования.

## Discipline & enforcement

- `discovery-gate` hook (глобальный канал, PreToolUse:Bash) — блокирует recursive grep/rg/find на code-расширениях активного профиля, читает `languages:`/`cbm_project:` из `runtime.config.yaml` продукт-репо в рантайме → deny с инструкцией (какой discovery-tool использовать вместо этого).
- `discovery-augment` hook (PreToolUse:Grep|Glob) — молча добавляет граф-контекст из discovery MCP, если он сконфигурирован; no-op иначе (никогда не блокирует).
- `mcp-usage-tracker` hook (PostToolUse) — пишет per-session JSONL usage-лог в `$CLAUDE_STATE_DIR/tool-usage/${SESSION_ID}.jsonl` (fallback `{{STATE_DIR}}/tool-usage/...`, если `CLAUDE_STATE_DIR` не задан).
- Self-review: usage-report по этому логу показывает ratio MCP/Bash. Если discovery-tool=0 при grep≥5 — пересмотреть подход.

## Frontend / UI stories (typescript-профиль с UI)

См. `.claude/rules/quality-gates.md` (Playwright верификация, dev-стек). Перед реализацией новых страниц/компонентов — свериться с design-системой проекта, если она есть.
