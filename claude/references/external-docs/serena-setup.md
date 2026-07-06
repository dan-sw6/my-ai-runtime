# Serena MCP — setup & usage (research snapshot 2026-06-30, v1.5.3)

> Источник: github.com/oraios/serena README + `docs/02-usage/*` + `docs/01-about/035_tools.md` + CHANGELOG. Чтобы не ресёрчить повторно.

## Install / run (canonical)

- **НЕ ставить через MCP/plugin-marketplace.** README hard-warning verbatim: *«Do not install Serena via an MCP or plugin marketplace! They contain outdated and suboptimal installation commands.»* Если какой-то plugin-marketplace предлагает Serena — держать его выключенным и ставить сервер напрямую.
- PyPI пакет — `serena-agent`, console-script `serena`. Запуск без предустановки: `uvx --from serena-agent serena start-mcp-server [opts]`. Verified: `uvx --from serena-agent serena --help` (EXIT 0), Serena 1.5.3.
- Для Claude Code апстрим предлагает helper `serena setup claude-code` или `claude mcp add ...` — практика этого рантайма: держать server `serena` как plain MCP entry в конфиге проекта (`.mcp.json` или эквивалент), не через plugin.

### Пример main-конфига (`.mcp.json`) — python/typescript профили
```json
"serena": { "command": "uvx", "args": ["--from","serena-agent","serena","start-mcp-server",
            "--context","claude-code","--project-from-cwd","--mode","editing"] }
```
### Пример для изолированных worker-контекстов (worktree-скрипт подготовки) — git+main вариант, тот же набор флагов
```
uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code --project-from-cwd --mode editing
```
(pin на `serena-agent` PyPI вместо git+main — не обязательный, но рекомендуемый follow-up для воспроизводимости.)

### csharp-профиль (ADOPT) — язык вместо контекста
Для csharp-профиля флаги `--context`/`--project-from-cwd`/`--mode` те же; языковую часть задаёт `.serena/project.yml`:
```yaml
language: csharp             # Roslyn LS — default, быстрый, нужен современный .NET SDK
# language: csharp_omnisharp # OmniSharp — для .NET Framework 4.8 / старых WPF-проектов
```
См. `profiles/csharp/adopt.md` этого рантайма для полного install-runbook (WPF собирается только на native Windows, не WSL).

## `--context` (default `desktop-app`!)
`desktop-app` (полный/дублирующий тулсет) · **`claude-code`** (режет тулзы, перекрытые встроенными CC; single-project) · `ide` (generic IDE; single-project) · `codex` · `agent` · client-specific (`vscode`, `claude-desktop`, `jb-*`, `chatgpt`, `copilot-cli`, `antigravity`, `junie`).
**Naming change** (PR #825, дек-2025): старый `ide-assistant` разделён/переименован → `claude-code` + `ide`. Конфиги с `--context ide-assistant` — stale.

## `--mode` (combinable; `--mode` переопределяет, `--add-mode` добавляет)
`planning` · `editing` · `interactive` · `one-shot` · `no-onboarding` · `onboarding` · `no-memories` · `query-projects`.
**Breaking v1.3.0** (2026-05-11): `project.yml` больше НЕ переопределяет `base_modes` (юзать `added_modes`); дефолтные `interactive`+`editing` переехали в `base_modes`.

## Project activation
- `--project <path|name>` — явная активация; `--project-from-cwd` — авто-детект (вверх по дереву ищет `.serena/project.yml` или `.git`), сделан под CLI-агентов.
- `activate_project` **авто-отключается** в single-project контекстах (`claude-code`/`ide`) когда задан `--project*` на старте. Без `--project*` (Codex/Desktop) — звать вручную каждую сессию.
- `.serena/project.yml`: `project_name`, `language`/`languages` (для мультиязычных проектов — **список**), encoding, ignore-rules, `additional_workspace_folders` (cross-package refs, **TS-only**), initial_prompt. Local-only → gitignored `project.local.yml`.

## Languages / LSP
- 40+ языков (LSP backend, free). Python = pyright. TypeScript = `typescript` (typescript-language-server) или `typescript_vts` (vtsls). C# = Roslyn LS (`language: csharp`) или OmniSharp (`language: csharp_omnisharp`, для .NET Framework 4.8).
- **Мультиязык одновременно** — PR #704 (~окт-2025): `languages: [python, typescript]` реально стартует оба LS (раньше один на проект). Полезно для python+typescript монорепо; на чисто csharp-профиле нужен только один язык.
- **Баг #1586 (открыт на 1.5.3)**: `find_referencing_symbols` по TS-символам в монорепо без корневого `tsconfig.json` → 0 hits (inferred project). `find_symbol`/overview/declaration работают. Python/pyright НЕ затронут. Митигатор: `additional_workspace_folders` или кросс-чек через cbm (если сконфигурирован).
- `tsgo` (TS7 native LSP) — запрос #1402, не смержен.

## Tool inventory (v1.5.3)
- **symbol**: `get_symbols_overview`, `find_symbol`, `find_declaration`, `find_implementations`, `find_referencing_symbols`, `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rename_symbol`, `safe_delete_symbol`, `get_diagnostics_for_file`, `get_diagnostics_for_symbol`(opt), `restart_language_server`(opt).
- **file**: `read_file`, `create_text_file`, `find_file`, `list_dir`, `search_for_pattern`, `replace_content`, `replace_in_files`, line-ops(opt).
- **memory**: `write_memory`, `read_memory`, `list_memories`, `edit_memory`, `rename_memory`, `delete_memory`.
- **config**: `activate_project`, `get_current_config`, `open_dashboard`(opt).
- **workflow**: `initial_instructions`, `onboarding`. **cmd**: `execute_shell_command`.
- New v1.3.0: `find_declaration`/`find_implementations`/`get_diagnostics_*`. Removed v1.5.0: `check_onboarding_performed`.

### Каноничный workflow
`get_symbols_overview` → `find_symbol(name_path)` → `replace_symbol_body`/`insert_*` → перед rename/safe-delete: `find_referencing_symbols` → после правок: `get_diagnostics_for_file`.
Design-rationale (upstream lessons_learned.md): symbol/string-edit > line-number-edit (LLM плохо считает строки, номера дрейфуют).

## Best-practice
- `serena project index` — пред-кэш символов на большом репо (убирает латентность первого вызова; дальше авто-обновление).
- `onboarding` один раз на проект → пишет memories в `.serena/memories/`. **Memories — local-only** (typical `.gitignore` игнорит `.serena/*`; коммитится только `!.serena/project.yml` — languages-пин). v1.5.0 сделал onboarding менее инвазивным (спрашивает юзера).
- Медленный старт (uvx-докачка) → увеличить MCP timeout (например `MCP_TIMEOUT=60000` в settings).
- **CC-adherence** (named upstream problem): свежие CC+Opus «drastically reduced» следование внешним тулзам (встроенные тул-дескрипшены ~16k токенов биасят к внутренним). Воркэраунды (опц., если serena не «тянется»): launch `claude --system-prompt="$(serena prompts print-cc-system-prompt-override)"`; serena CC-hooks `remind` (нудж к symbol-tools) + `auto-approve`. Одного project-governance-файла (CLAUDE.md/AGENTS.md), по апстриму, недостаточно.

## Versions (релевантное)
1.3.0 base_modes breaking + new LSP-tools · 1.5.0 onboarding less invasive, `check_onboarding_performed` removed, `mem:` cross-ref · 1.5.2 `serena-agent` entrypoint + pyright/fortls on-the-fly + dashboard host-validation · 1.5.3 (current pin) metadata. Контекст-rename `ide-assistant`→`claude-code`/`ide` = PR #825.
