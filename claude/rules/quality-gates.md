# Quality Gates Rules

## Python profile — venv

Если активный профиль включает `python` (`languages:` в `runtime.config.yaml`) — все команды Python выполнять в venv. Активировать при старте:

```bash
source .venv/bin/activate
```

Проверка: `which python` → `.venv/bin/python`.
В изолированном worker-контексте (worktree и т.п.): активировать venv из корня продукт-репо (`{{PROJECT_ROOT}}/.venv/bin/activate`), не создавать отдельный.

typescript/csharp-профили эквивалента не требуют (`npm`/`dotnet` не нуждаются в venv-подобной активации).

## Quality Gates

Перед коммитом и перед завершением работы — три gate-скрипта на корне продукт-репо. Это **generic-обёртки**: они читают активные профили (`languages:`) и `gates.<language>` map из `runtime.config.yaml`, и запускают соответствующие per-language команды (ruff/pytest/mypy для python; eslint/vitest/tsc для typescript; `dotnet build`/`test`/`format --verify-no-changes` для csharp):

```bash
bash scripts/lint.sh          # lint по всем активным профилям
bash scripts/test.sh          # test/build-smoke по всем активным профилям
bash scripts/type.sh          # type/format-check по всем активным профилям
```

Быстрый цикл при итерациях (если скрипт поддерживает changed-only режим):
```bash
bash scripts/test.sh --changed --base-ref "main"
```

**ПЕРЕД PUSH — ОБЯЗАТЕЛЕН полный test suite** (`bash scripts/test.sh`, не `--changed`).

Рекомендуемый паттерн enforcement — `pre-push` git-hook (`core.hooksPath`, устанавливается bootstrap-скриптом продукт-репо): гоняет `lint.sh` + `type.sh` + `test.sh` перед каждым push, заменяя часть hosted-CI локальным гейтом. Типичные escape-флаги (если продукт-репо их поддерживает):
- `PREPUSH_FAST=1 git push` — только lint+type (для WIP-пушей фича-ветки; полный `test.sh` — перед мержем)
- `git push --no-verify` / `GIT_SKIP_PREPUSH=1` — полный bypass (emergency)

Если `test.sh` требует поднятой БД/инфраструктуры (Postgres и т.п. через `docker compose up -d`) — без неё гейт падает; это ожидаемо, не баг гейта.

### Dependency vulnerability waivers

Если в проекте есть CVE без upstream fix или scoped-unused зависимости — задокументировать waiver-процесс (policy-файл + gate-скрипт, например `scripts/check-dependency-vulnerabilities.sh --report`, запускаемый из `lint.sh`) в `docs/operations/` продукт-репо. Не пропускать известную уязвимость молча — waiver должен быть explicit и review'ed.

Frontend-команды в изолированном worker-контексте — предпочесть тонкую обёртку поверх `npm`/`pnpm` (например `scripts/frontend-npm.sh <app-path> <command>`), если продукт-репо её предоставляет — так гарантируется правильный cwd/lockfile в worktree.

## Tests

- Backend (python/csharp): pytest / xUnit, parallel где возможно
- Frontend (typescript): vitest
- E2E: Playwright
- Минимум для endpoint/API: happy path + negative path + auth/forbidden
- Минимум для frontend: smoke render + один behavioural test

## Definition of Done

Полная параметризованная версия — `.claude/quality-gates/definition-of-done.yaml` (синкается из рантайма). Кратко:

1. Код собирается и запускается
2. Линтер/форматирование чистые
3. Типовые проверки без ошибок
4. Тесты добавлены или обновлены
5. Документация обновлена при изменении публичного поведения
6. Миграции добавлены при изменении схемы (Alembic для python, EF Core для csharp)
7. Frontend/UI задачи: визуальная верификация (Playwright) — скриншоты затронутых страниц/компонентов
8. Traceability (если проект её ведёт): RTM/требования отражают текущий статус реализации
