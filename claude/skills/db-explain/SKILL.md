---
name: db-explain
description: "Анализ SQL-запроса: EXPLAIN (ANALYZE, BUFFERS) → проверка индексов → план оптимизации (новый индекс / переписать запрос / денормализация). Используй при подозрении на slow query, N+1, неоптимальный план. Работает через postgres_ro MCP — read-only безопасно."
argument-hint: "<sql или путь к файлу/функции с SQL>"
---

## Назначение

Закрытый цикл анализа PostgreSQL-запроса через `postgres_ro` MCP без выхода из чата.

## Pre-flight

1. Убедись, что `postgres_ro` MCP подключён: проверка через `mcp__postgres_ro__list_schemas`. Если не отвечает — MCP-конфиг корректен, но сервер не запущен — попроси пользователя стартовать.
2. БД — read-only replica/snapshot. EXPLAIN ANALYZE безопасен для SELECT, но опасен для INSERT/UPDATE/DELETE → отказ для не-SELECT.

## Workflow

### Шаг 1 — собрать SQL

Если аргумент — SQL: использовать как есть.
Если файл/функция: прочитать через code-discovery MCP этого профиля (см. `mcp-discipline`), извлечь raw SQL (включая параметры). Заменить bind-параметры (`$1`, `:name`) типичными значениями для EXPLAIN — отметить, что план может отличаться от prod при skewed data.

### Шаг 2 — EXPLAIN

```
mcp__postgres_ro__explain_query(sql=<query>, analyze=true, buffers=true)
```

Вытащить из плана:
- Total time, planning time
- Самый дорогой узел (наибольший `actual time`)
- Seq Scan на больших таблицах (>10k rows)?
- Missing index hints (несоответствие estimated/actual rows >10x → плохая статистика)
- Buffers: shared hit vs read (cache miss heavy?)

### Шаг 3 — проверка индексов

```
mcp__postgres_ro__analyze_query_indexes(sql=<query>)
```

Получить:
- Какие индексы есть на затронутых таблицах
- Какие НЕ используются для этого запроса
- Рекомендации hypopg, если доступно

### Шаг 4 — health check (опционально)

Если запрос участвует в hot-path:
```
mcp__postgres_ro__analyze_db_health(health_type="all")
```
Проверить bloat / unused indexes / cache hit ratio.

### Шаг 5 — рекомендации

Сгруппировать по категориям:

**Quick wins** (без миграции):
- Переписать запрос (добавить условие, убрать `SELECT *`, использовать LATERAL вместо subquery)
- Добавить hint через `pg_hint_plan` (если включен)

**Migration required**:
- Новый индекс (B-tree / GIN / BRIN — обосновать тип)
- Партиционирование
- Денормализация / materialized view
- → ОБЯЗАТЕЛЬНО написать `CREATE INDEX CONCURRENTLY` для prod-safe deploy
- → Указать estimated build time и lock-time
- → Передать на ревью миграций (dedicated agent, если репозиторий его использует, иначе — человеку-ревьюеру)

**Application-level**:
- Batch вместо N+1 (eager-loading в ORM: joinedload/selectinload в SQLAlchemy, Include в EF Core и т.п.)
- Кеш слой (Redis, in-memory)
- Pagination через keyset вместо OFFSET

## Output Format

```
## Query Analysis

**Source**: <file:line или inline>

### Plan summary
- Total: <ms> (planning <ms>, exec <ms>)
- Hottest node: <Seq Scan on X — actual M ms, N rows>
- Cache: <hit% / read>

### Issues
1. <issue> — <impact>

### Recommendations

**Quick win**: <action>
**Migration**: <SQL для CREATE INDEX CONCURRENTLY>
**Application**: <code change>

### Estimated improvement
<before vs after if testable>
```

## Constraints

- Не предлагать DROP INDEX без проверки в `analyze_workload_indexes` — может ломать другие запросы
- Не предлагать денормализацию без согласия пользователя — большое архитектурное решение
- Если запрос содержит prod-данные / PII — НЕ копировать в чат, ссылаться на файл
