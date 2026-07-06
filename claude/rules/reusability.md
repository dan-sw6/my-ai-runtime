# Reusability Rules

ВСЕГДА писать переиспользуемый код. Не дублировать, не копипастить, не делать локальные обёртки повторно.

## Перед написанием нового кода

1. **Найти существующий shared kit.** Перед тем как создать новый компонент/хук/сервис — поискать готовый:
   - Frontend (typescript-профиль): каталог shared-компонентов проекта (`src/shared/`, `src/components/ui/` или эквивалент)
   - Backend (python/csharp-профиль): каталог shared-утилит проекта (`shared/`, общие сервисы модуля)
   - Реестры/индексы: project-level design-registry doc, корневой `CLAUDE.md`/`AGENTS.md`, `<module>/CLAUDE.md`
2. **Если в shared есть похожее, но не покрывает потребность** — расширить shared (новый prop, generic-параметр, optional-поле). НЕ делать локальную копию.
3. **Если функциональность нужна ≥2 местам** — это shared-кандидат. Вынести **сразу**, не позже.

## Принципы

- **Generic over specific.** Если компонент/функция работает с конкретным типом сущности (`Employee`, `Task`, `User`) — параметризовать через generic-параметр (`<TItem>` в TS, generic в C#, TypeVar в Python). Универсальная list-page обёртка, generic sort-helper, universal server-side-sort hook — эталон паттерна.
- **Interfaces over copy-paste.** Поведение, повторяющееся в нескольких местах — выносить в `interface`/protocol (props-контракт) или функцию-сервис. Запрещено копировать тело компонента/функции.
- **Один источник правды.** Логика сортировки/пагинации/фильтрации/skeleton'а должна жить в одном месте. Изменение поведения — точечная правка одного файла, не N.
- **Hooks для frontend, helpers/services для backend.** Обёртывать reusable-логику в hook (`useXxx`) или функцию-сервис/DI-сервис (`apply_xxx`, `build_xxx`, C# `IXxxService`). Не оставлять inline-state-machines, которые потом будут копироваться.
- **Композиция > наследование.** Мелкие generic-обёртки лучше чем одно «универсальное» большое решение — composable-блоки переиспользуются гибче.

## Антипаттерны (запрещено)

- ❌ Копирование тулбара/таблицы/skeleton'а из одной страницы в новую с локальными правками.
- ❌ Локальный ad-hoc state для сортировки/пагинации + ручное derive когда есть готовый shared-hook/helper.
- ❌ Inline ORDER BY-логика в каждом list-endpoint вместо общего sort-helper'а.
- ❌ Локальный domain-specific компонент таблицы (`<EmployeesTable>`, `<TasksTable>`) — использовать generic `<DataTable<TItem>>` (или эквивалент).
- ❌ Дублирование backend query-builders в каждом сервисе. Общие куски (sort/filter/pagination) — в shared.
- ❌ "Просто скопирую и подправлю" — это технический долг с момента написания.

## Чек перед PR

1. Этот код повторится в другой сущности через 1-2 спринта?
2. Если да — вынесен ли он в shared с generic-параметром?
3. Существующие `shared/`-потребители обновлены на новый API?
4. В реестре (design-registry doc для UI / соответствующий CLAUDE.md/AGENTS.md для модуля) добавлена запись о новом shared?
5. Есть ли в коде отдельные «копии» того же поведения, которые нужно тоже переключить на новый shared?

---

> ### Reference implementations (из Python/TS-монорепо-консьюмера)
>
> Иллюстративный пример того, как выглядит зрелый shared-слой на практике (не предписание — конкретные имена ниже принадлежат одному консьюмеру рантайма, у вашего проекта будут свои):
>
> - **Frontend admin list-page (filter+sort+bulk)**: generic `EntityListPage<TItem>` — обёртка над page-layout + toolbar + table-shell + table + status-states.
> - **Frontend admin list+side-panel**: облегчённый вариант list-page для случаев, когда генерик слишком жёсткий (нужны кастомные слоты для side-panel/dialogs).
> - **Frontend status-states**: единый набор `{ TableLoadingState, TableErrorState, TableEmptyState, TableNoResultsState }` — единственный легитимный источник loading/error/empty компонентов в list-страницах.
> - **Frontend server-side sort**: hook, возвращающий `{sorting, setSorting, sortBy, sortDir, manualSorting}`.
> - **Frontend infinite scroll**: sentinel-driven `fetchNextPage` hook (если у проекта запрещена pagination в пользу infinite-scroll — фиксировать это в ADR).
> - **Frontend tables**: generic `DataTable<T>` (TanStack-based) + `TreeDataTable<T>` для treegrid со своим `emptyState`.
> - **Frontend toolbar / filter chips**: общий toolbar-компонент + `FilterChip`.
> - **Frontend quick view / full page**: generic quick-view / profile-summary / detail-page-shell / metrics-row компоненты.
> - **Frontend forms**: `useZodForm` + `submitAction` — форма-хук + сервер-error mapping + toast, поверх RHF+Zod.
> - **Backend sort/order**: whitelist-based `apply_sort(query, sort_by, sort_dir, whitelist)` с tie-break.
> - **Backend pagination**: `PaginationParams` + `paginate()`.
>
> Полный реестр shared с сигнатурами и anti-patterns у такого консьюмера обычно живёт в отдельном design-registry doc + ADR на page-skeleton canon + pre-flight чеклист для новых страниц.
