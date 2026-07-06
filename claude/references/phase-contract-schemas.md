# Phase Contract — detailed schemas and algorithms

> On-demand reference для `/implement-story`. Короткий срез в `.claude/rules/phase-contract.md`.

## Phase-log JSON-lines format

Каждая запись — **одна строка валидного JSON, <500 байт**. Атомарно пишется через `scripts/ao/phase-log-util.sh::log_phase_event`.

### Обязательные поля
- `ts` — ISO8601 с TZ (`date -Iseconds`)
- `phase` — ID фазы
- `status` — `start` | `complete` | `skipped` | `failed` | `blocked`

### Условные поля
- `reason` — обязательно при `status ∈ {skipped, failed, blocked}`. kebab-case (`no-deps-no-epic`, `threshold-not-met`).
- `metrics` — optional объект с числовыми метриками (simplifier: `{"loc":187,"files":4,"repeat":2}`).

### Полный пример сессии
```json
{"schema":"v1","story":"STORY-214","started":"2026-04-20T13:34:00+03:00","ts":"2026-04-20T13:34:00+03:00"}
{"ts":"2026-04-20T13:34:02+03:00","phase":"0-init","status":"start"}
{"ts":"2026-04-20T13:34:15+03:00","phase":"0-init","status":"complete"}
{"ts":"2026-04-20T13:34:16+03:00","phase":"0.1-mem-search","status":"skipped","reason":"no-deps-no-epic"}
{"ts":"2026-04-20T13:35:00+03:00","phase":"1-plan","status":"start"}
{"ts":"2026-04-20T13:42:00+03:00","phase":"1-plan","status":"complete"}
{"ts":"2026-04-20T13:42:05+03:00","phase":"2-implement","status":"start"}
{"ts":"2026-04-20T14:08:00+03:00","phase":"2-implement","status":"complete"}
{"ts":"2026-04-20T14:08:05+03:00","phase":"2.1.5-simplify","status":"skipped","reason":"threshold-not-met","metrics":{"loc":187,"files":4,"repeat":2}}
{"ts":"2026-04-20T14:08:10+03:00","phase":"2.2-a11y","status":"skipped","reason":"mode-c-fingerprint-primary"}
{"ts":"2026-04-20T14:08:15+03:00","phase":"3-gate","status":"start"}
{"ts":"2026-04-20T14:15:00+03:00","phase":"3-gate","status":"complete"}
{"ts":"2026-04-20T14:15:05+03:00","phase":"3.3-audits","status":"skipped","reason":"no-god-nodes-no-security-no-perf"}
{"ts":"2026-04-20T14:15:10+03:00","phase":"4-verify","status":"start"}
{"ts":"2026-04-20T14:18:00+03:00","phase":"4-verify","status":"complete"}
{"ts":"2026-04-20T14:18:05+03:00","phase":"5-close","status":"start"}
{"ts":"2026-04-20T14:22:00+03:00","phase":"5-close","status":"complete"}
```

## Coordinator trust model (STORY-231)

**Worker output НЕ доверяется content-wise.** Worker может:
- Сфабриковать phase-log через прямой `echo '{fake}' >> phase-log` (bypass `log_phase_event`)
- Сфабриковать state-JSON через heredoc с `_complete:true` (bypass `phase-complete.sh`)
- Записать `diff.json` с несуществующими commit SHA
- Записать `verify.json` с "all AC pass" без реальной проверки

**Защиты на уровне coordinator (не worker):**
- `scripts/ao/worktree-gate.sh STORY-ID` — независимый gate: verify commits[].sha через `git rev-parse`, запуск реального `typecheck`/`vitest`/`pytest` в worktree, отказ при dirty working tree
- `run-stories` Phase B.1.3 → coordinator-gate MANDATORY перед merge; worker's `gate.json` — только для stats/telemetry
- Race protection: `launch-story-worker.sh` watch-subshell fully detached — pipe `| tail -N` больше не держит coordinator блокированным

**Защиты на уровне git (STORY-232 + follow-up):**
- `.githooks/pre-commit` через `core.hooksPath=.githooks` — блокирует commits из cwd НЕ под `.claude/worktrees/` когда есть живые worker PIDs в state-dir (`state_dir`) `*/pid`
- `.githooks/reference-transaction` (git 2.28+) — блокирует ЛЮБЫЕ ref-updates на protected branches (trunk — `ao.base_ref` из runtime.config.yaml, по умолчанию `main`) когда есть живые worker PIDs. Закрывает bypass через `git branch -f`, `git update-ref`, `git push`, `git rebase`
- Human override: `GIT_ALLOW_WORKER_COMMIT=1 git commit ...`
- Bootstrap: `bash scripts/ao/install-git-hooks.sh`

**Known residuals (mitigated, не closed):**
- HMAC/sequence-integrity на phase-log — mitigated via coordinator-gate
- AC evidence parsing в verify.json — mitigated via real test execution в coordinator-gate

## Major-phase complete enforcement

`log_phase_event <phase> complete` REFUSES запись для major фаз (`0-init`, `1-plan`, `2-implement`, `3-gate`, `4-verify`, `5-close`), если в worker-dir отсутствует соответствующий state-JSON с ключом `_complete: true` ИЛИ `_skipped: true`. Выход: exit code 3 + stderr `"state-json missing: create via phase-complete.sh"`.

**Enforcement model (file-based, STORY-230)**: проверка идёт по факту существования файла `{phase}.json` в state-dir (`state_dir` в runtime.config.yaml) под `story-{ID}/`, не по env-флагу. Прежний sentinel `PHASE_COMPLETE_WRAPPER=1` удалён (три bypass-вектора: ручной export, наследование env, прямая запись в phase-log).

**Micro-phases** (`0.1-mem-search`, `2.1.5-simplify`, `2.2-a11y`, `3.3-audits`) разрешены через `log_phase_event` напрямую — у них нет обязательного state-JSON.

**Skipped** разрешён через `log_phase_event` напрямую для любой фазы (для major используется `phase-skip.sh`, пишущий state-JSON с `_skipped: true`).

## State files — per-phase contract

Каждая фаза пишет один state-JSON в state-dir (`state_dir`) под `story-{ID}/` с обязательными ключами и финальным флагом.

### Финальные флаги
- `_complete: true` + `_ts: "<ISO8601>"` — успешно завершена
- ИЛИ `_skipped: true` + `_reason: "<kebab-case>"` + `_ts: "<ISO8601>"` — пропущена

### `context.json` (Phase 0)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T13:34:15+03:00",
  "story_id": "STORY-214",
  "story_frontmatter": { "contour": "frontend", "story_points": 3 },
  "mem_search": { "performed": false, "reason": "no-deps-no-epic", "findings": [] }
}
```
Обязательные: `story_id`, `story_frontmatter`, `mem_search.performed`.

### `plan.json` (Phase 1)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T13:42:00+03:00",
  "tasks": [ { "id": 1, "title": "...", "files": ["..."] } ],
  "ac_mapping": { "AC1": ["task-1"], "AC2": ["task-2","task-3"] },
  "executor_prompt": "...",
  "risks": [ "..." ]
}
```
Обязательные: `tasks` (len ≥ 1), `ac_mapping` (len ≥ 1), `executor_prompt` (непустая).

### `diff.json` (Phase 2)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T14:08:00+03:00",
  "changed_files": ["path/to/file1.tsx"],
  "commits": [ { "sha": "abc123", "message": "feat: ..." } ],
  "executor_report": "..."
}
```
Обязательные: `changed_files` (len ≥ 1), `commits` (len ≥ 1).

### `gate.json` (Phase 3)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T14:15:00+03:00",
  "lint": { "pass": true, "new_failures": 0 },
  "typecheck": { "pass": true, "new_failures": 0 },
  "tests": { "pass": true, "new_failures": 0 },
  "audits": { "performed": false, "reason": "no-god-nodes-no-security-no-perf" }
}
```
Обязательные: `lint.pass`, `typecheck.pass`, `tests.pass` (все bool).

### `verify.json` (Phase 4)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T14:18:00+03:00",
  "ac_results": {
    "AC1": { "status": "pass", "evidence": "..." }
  },
  "review_findings": [],
  "mode": "inline"
}
```
Обязательные: `ac_results` (len ≥ 1), `mode` (`inline` | `agent`).

### `close.json` (Phase 5)
```json
{
  "_complete": true,
  "_ts": "2026-04-20T14:22:00+03:00",
  "rtm_updated": true,
  "srs_updated": true,
  "claude_mem_observations": ["obs-7830"],
  "summary_path": "/tmp/claude-workers/story-214/summary.md"
}
```
Обязательные: `rtm_updated` (bool), `srs_updated` (bool), `summary_path` (непустая).

### Skipped-вариант
```json
{ "_skipped": true, "_reason": "threshold-not-met", "_ts": "...", "metrics": {"loc":187} }
```
Остальные ключи опциональны при `_skipped: true`.

## Guard-transitions

`phase-guard.sh <STORY-ID> <NEXT-PHASE>` запускается только на крупных переходах:

| Before → After | State файл |
|----------------|------------|
| 0 → 1 | `context.json` |
| 1 → 2 | `plan.json` |
| 2 → 3 | `diff.json` |
| 3 → 4 | `gate.json` |
| 4 → 5 | `verify.json` |

Микрофазы (2.1.5, 2.2, 3.3) валидируются inline через skip-protocol без guard-вызова.

Guard-алгоритм:
1. Читает phase-log первую строку, парсит `schema`. Legacy → warning + exit 0.
2. Читает требуемый state-JSON.
3. Проверяет `_complete: true` ИЛИ `_skipped: true` с `_reason`.
4. Проверяет обязательные ключи и non-empty инварианты.
5. Exit codes:
   - `0` — ok
   - `1` — blocked (stdout JSON `{"status":"blocked","reason":"..."}`)
   - `2` — warning (legacy)

## Skip-reason registry

| Фаза | Reason | Когда |
|------|--------|-------|
| 0.1-mem-search | `no-deps-no-epic` | story без `depends_on:` и `epic:` |
| 0.1-mem-search | `claude-mem-unavailable` | MCP сервер не отвечает |
| 2.1.5-simplify | `threshold-not-met` | diff < 200 LOC OR files < 6 OR repeat < 3× |
| 2.1.5-simplify | `no-duplication-found` | simplifier scan не нашёл patterns |
| 2.2-a11y | `mode-c-fingerprint-primary` | Mode C с `contract_path` + fingerprint-diff |
| 2.2-a11y | `no-ui-surface` | backend-only story |
| 3.3-audits | `no-god-nodes-no-security-no-perf` | триггеры не сработали |
| 3.3-audits | `god-nodes-only` → partial | только архитектурный audit |
| 3-gate | (не skippable) | — |
| 4-verify | (не skippable) | — |
