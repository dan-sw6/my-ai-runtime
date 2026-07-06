# claude-mem (thedotmack) — fine-tuning reference

> Источники: `docs.claude-mem.ai/configuration`, `docs.claude-mem.ai/progressive-disclosure`, `docs.claude-mem.ai/context-engineering`. Применяется к `~/.claude-mem/settings.json`. Live preview: `http://localhost:37777` (Context Settings Modal).

## Философия (progressive disclosure)

3-layer pattern, enforced by claude-mem MCP tools:

1. **Layer 1 — Search index** (`search`, `~50-100 ток/result`): titles + types + token cost only.
2. **Layer 2 — Timeline** (`timeline`, `~70-100 ток`): chronological context вокруг anchor.
3. **Layer 3 — Full observations** (`get_observations([IDs])`, `~300-1000 ток/each`): narrative + facts + concepts + files. **Always batch IDs** — single SQL `IN`, single HTTP.

**Anti-pattern**: одиночные `get_observations` calls (3× overhead). **Anti-pattern**: dump full history at session start.

Цель cost-efficiency: index fetch ≈ 1k ток / 10 results, full deep-dive 1.5k ток / 3 observations. Total <3k ток на survey + relevant deep-dive. 10× экономия vs naive «fetch everything».

## Settings reference (`~/.claude-mem/settings.json`)

### Loading (вкус)

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_CONTEXT_OBSERVATIONS` | `50` | Сколько recent observations инжектить (range 1-200) |
| `CLAUDE_MEM_CONTEXT_SESSION_COUNT` | `10` | Из скольких последних сессий тянуть (1-50) |
| `CLAUDE_MEM_CONTEXT_FULL_COUNT` | `5` | Сколько observations показывать full vs compact (0-20) |
| `CLAUDE_MEM_CONTEXT_FULL_FIELD` | `narrative` | Какое поле раскрывать full: `narrative` или `facts` |

### Filters (точечный контроль шума)

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_CONTEXT_OBSERVATION_TYPES` | (none) | Comma-separated whitelist типов |
| `CLAUDE_MEM_CONTEXT_OBSERVATION_CONCEPTS` | (none) | Comma-separated whitelist концептов (теги типа `security`, `performance`) |

### Type icons (для index)

| Icon | Type | Когда ценно |
|------|------|-------------|
| 🔴 | `gotcha` | Critical edge case / pitfall — fetch immediately |
| 🟤 | `decision` | Architecture decision |
| ⚖️ | `trade-off` | Deliberate compromise |
| 🟠 | `why-it-exists` | Design rationale |
| 🟣 | `discovery` | Learning / insight |
| 🟡 | `problem-solution` | Bug fix / workaround |
| 🔵 | `how-it-works` | Technical explanation |
| 🟢 | `what-changed` | Code/architecture change (часто видно в git log → шум) |
| 🎯 | `session-request` | User's session goal (orientation only — повторно не нужен) |
| 🟣 | `feature` / `refactor` / `change` | Часто шумовые — git log покрывает |

### Display

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS` | `true` | Показывать стоимость fetch (нужно для prog-disclosure) |
| `CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS` | `true` | Tokens invested в создание observation |
| `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT` | `true` | "Сэкономлено N токенов" — декоративно |
| `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT` | `false` | Процент экономии — декоративно |
| `CLAUDE_MEM_CONTEXT_SHOW_TERMINAL_OUTPUT` | `false` | Включать ли terminal output snippets |
| `CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY` | `false` | Дублирует session handoff из других каналов |
| `CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE` | `false` | Final message прошлой сессии (часто избыточно) |

### Mode / language

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_MODE` | `code` | Workflow profile + язык observations: `code--ru` для русского, `code--zh` для китайского, `code--es`, `code--ja`, etc. Доступные — `~/.claude/plugins/marketplaces/thedotmack/plugin/modes/` |

> Пример: для продукт-репо, где UI/docs/commits на русском (как в этом рантайме), `code--ru` уменьшает cross-lingual overhead и делает observations homogeneous с проектной терминологией. Для англоязычного продукта — оставить `code` (default).

### Worker / infrastructure

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_PROVIDER` | `claude` | AI provider: `claude` (CLI auth), `gemini`, `openrouter` |
| `CLAUDE_MEM_MODEL` | `sonnet` | Model для observation processing |
| `CLAUDE_MEM_TIER_ROUTING_ENABLED` | `true` | Tiered routing: simple → haiku, summary → sonnet |
| `CLAUDE_MEM_TIER_SIMPLE_MODEL` | `haiku` | Модель для простых observations |
| `CLAUDE_MEM_WORKER_PORT` | `37700+(uid%100)` | Port для worker. Для multi-profile — fix через env |
| `CLAUDE_MEM_DATA_DIR` | `~/.claude-mem` | Изолированные профили: `~/.claude-mem-work`, `~/.claude-mem-personal` |
| `CLAUDE_MEM_MAX_CONCURRENT_AGENTS` | `2` | Concurrent observation processors |
| `CLAUDE_MEM_SKIP_TOOLS` | `ListMcpResourcesTool,SlashCommand,Skill,TodoWrite,AskUserQuestion` | Не записывать observations для этих tool calls |
| `CLAUDE_MEM_EXCLUDED_PROJECTS` | `` | Comma-separated проекты, которые гейт File Read и инжект пропускают |

### Vector / chroma

| Key | Default | Что делает |
|-----|---------|-----------|
| `CLAUDE_MEM_CHROMA_ENABLED` | `true` | Включает Chroma vector store для semantic search через `mem-search` skill |
| `CLAUDE_MEM_CHROMA_MODE` | `local` | `local` или `remote` (HTTP) |
| `CLAUDE_MEM_SEMANTIC_INJECT` | `false` | Авто-инжект semantic-relevant observations при каждом prompt — DO NOT enable, дорого |
| `CLAUDE_MEM_SEMANTIC_INJECT_LIMIT` | `0` | Если SEMANTIC_INJECT=true — сколько вытаскивать |

## File Read Gate (PreToolUse:Read hook)

Активен по умолчанию (через plugin hooks). При `Read` файла с прежними observations показывает compact timeline вместо full content. Файлы <1500 байт пропускаются. Можно отключить через `CLAUDE_MEM_EXCLUDED_PROJECTS` для конкретного проекта.

Эффект: 5-50k → ~370 токенов на типовой файл. Дальнейший escalation (semantic priming → get_observations → smart_outline → full read) — agent decides.

## Best practices

1. **Use defaults где можно** — overrides только для конкретных задач.
2. **Live preview** через `http://localhost:37777` — gear icon → settings panel → Terminal Preview справа.
3. **Type filtering > observation count** — отфильтровать noise (`what-changed`, `feature`, `change`, `refactor`) и оставить high-signal (`gotcha`, `decision`, `trade-off`, `why-it-exists`, `discovery`, `problem-solution`, `how-it-works`).
4. **FULL_COUNT=2-5** — баланс: top-N detailed + остальные compact.
5. **Never enable SEMANTIC_INJECT** — semantic search через `mem-search` on-demand эффективнее.
6. **Use mode по языку проекта** — `code--ru`/`code--<lang>` для не-англоязычных продуктов, `code` (English) — default.
7. **Multi-profile через DATA_DIR** — work/personal/client изоляция через env vars.
8. **Batch get_observations** — всегда multiple IDs в одном вызове (single SQL `IN`, single HTTP).

## Sources

- https://docs.claude-mem.ai/configuration — full env-vars reference
- https://docs.claude-mem.ai/progressive-disclosure — 3-layer philosophy
- https://docs.claude-mem.ai/context-engineering — Anthropic principles applied
- https://docs.claude-mem.ai/file-read-gate — PreToolUse Read interception
- https://docs.claude-mem.ai/usage/search-tools — MCP search/timeline/get_observations
- https://github.com/thedotmack/claude-mem
