# Phase logging protocol (MANDATORY for all phases)

Coordinator ОБЯЗАН логировать каждую фазу через helper `scripts/ao/phase-log-util.sh::log_phase_event`. Никаких silent skip-ов — если фаза не выполняется, записать `status=skipped` с явной причиной.

**Contract**: `.claude/rules/phase-contract.md` (invariants + phase IDs). Полные state-JSON schemas + guard-алгоритм + skip registry + примеры — `.claude/references/phase-contract-schemas.md` (on-demand, читать при необходимости).

**Three helpers — use the right one for each situation**:

### `log_phase_event` — для `start` и granular events

Source once в начале worker session (launcher делает это автоматически; inline-режим — вручную):
```bash
source scripts/ao/phase-log-util.sh
```

Использовать ТОЛЬКО для:
- `start` event в начале каждой фазы: `log_phase_event <state_dir>/story-{id} <phase-id> start`
- Диагностические events внутри фазы (редко).

**НЕ использовать для `complete`/`skipped` — для этого есть wrappers ниже.**

### `phase-complete.sh` — финализация фазы (MANDATORY для завершения любой major фазы)

```bash
echo '<STATE-JSON-PAYLOAD>' | bash scripts/ao/phase-complete.sh STORY-{ID} <phase> -
```

Что делает (атомарно):
1. Читает payload JSON (файл или stdin).
2. Валидирует обязательные ключи per `.claude/rules/phase-contract.md`.
3. Проверяет non-empty инварианты (массивы не пусты, строки не пусты и т.д.).
4. Добавляет `_complete: true` + `_ts: <ISO8601>`.
5. Пишет в state-dir (`state_dir` из runtime.config.yaml) под `story-{id}/<phase-file>.json`.
6. Вызывает `log_phase_event <phase> complete`.

Если валидация провалилась (missing key или empty array) — exit 2 + error JSON в stderr. Coordinator ОБЯЗАН fix'ить payload, не продолжать фазу.

**Примеры payload'ов per phase**: `.claude/references/phase-contract-schemas.md` → раздел "State files — per-phase contract".

### `phase-skip.sh` — skip условной фазы (MANDATORY — никаких silent skip)

```bash
bash scripts/ao/phase-skip.sh STORY-{ID} <phase> <reason> [metrics-JSON]
```

Что делает:
1. Пишет `{"_skipped": true, "_reason": "...", "_ts": "...", "metrics": {...}}` в state-файл (для major фазы) или только в phase-log (для micro фазы).
2. Вызывает `log_phase_event <phase> skipped <reason> <metrics>`.

Canonical reasons — см. skip-reason registry в `.claude/rules/phase-contract.md`.

**Canonical phase IDs**: `0-init`, `0.1-mem-search`, `1-plan`, `2-implement`, `2.1.5-simplify`, `2.2-a11y`, `3-gate`, `3.3-audits`, `4-verify`, `5-close`.

**Phase-guard transitions**: перед стартом крупных фаз (1, 2, 3, 4, 5) coordinator вызывает:
```bash
bash scripts/ao/phase-guard.sh STORY-{ID} <next-phase>
# exit 0 → ok, phase может стартовать
# exit 1 → blocked, фаза НЕ должна стартовать (reason в stdout JSON)
# exit 2 → warning (legacy worker-dir), coordinator продолжает но логирует warning
```
Если guard вернул `blocked` — coordinator записывает `log_phase_event ... <phase> blocked guard-failed:<reason>` и останавливается с отчётом.
