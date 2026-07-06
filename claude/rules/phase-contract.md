# Phase Contract — `/implement-story` state machine

> **Детали on-demand**: `.claude/references/phase-contract-schemas.md` (state-JSON схемы, guard-алгоритм, skip registry, примеры). Читать при работе с `/implement-story` / `phase-guard` / правками AO-скриптов (`scripts/ao/*`).

## Schema version

Текущая: **v1**. Маркер в первой строке `phase-log`:
```json
{"schema":"v1","story":"STORY-XXX","started":"<ISO>","ts":"<ISO>"}
```
Без маркера → legacy, guard возвращает warning + exit 0. `--from-phase` отказывает.

## Phase IDs — canonical list

```
0-init
0.1-mem-search
1-plan
2-implement
2.1.5-simplify
2.2-a11y
3-gate
3.3-audits
4-verify
5-close
```

## Core invariants

- **Single-writer**: phase-log пишет только coordinator (одна Claude Code сессия). Subagents не получают путь. `phase-guard.sh` / `wave-status.sh` read-only. Append через `>>` атомарен (записи <500 байт, PIPE_BUF=4KB).
- **Major-phase complete enforcement**: `log_phase_event <major> complete` REFUSES если нет `{phase}.json` в state-dir (`state_dir` в runtime.config.yaml) под `story-{ID}/` с `_complete:true` ИЛИ `_skipped:true`. Exit 3 + stderr `"state-json missing: create via phase-complete.sh"`. Major = `0-init`, `1-plan`, `2-implement`, `3-gate`, `4-verify`, `5-close`. Micro (`0.1`, `2.1.5`, `2.2`, `3.3`) разрешены напрямую.
- **Skipped** статус разрешён напрямую для любой фазы (major — через `phase-skip.sh`, пишущий `_skipped:true`).
- **Coordinator trust**: worker output НЕ доверяется content-wise — `worktree-gate.sh` делает независимую валидацию (real typecheck/tests, git rev-parse SHA). Worker `gate.json` — только для stats.

## JSON-lines event format

Одна строка валидного JSON <500 байт. Обязательные поля: `ts` (ISO8601+TZ), `phase`, `status` (`start`|`complete`|`skipped`|`failed`|`blocked`). При `status ∈ {skipped,failed,blocked}` обязателен `reason` (kebab-case). Атомарная запись через AO-скрипт `phase-log-util.sh::log_phase_event` (`scripts/ao/phase-log-util.sh`).

## Interactive mode marker (out-of-band)

`blocked-waiting.json` в state-dir (`state_dir`) под `story-{ID}/` — **ephemeral marker**, НЕ событие phase-log. Пишется PreToolUse hook'ом (`scripts/ao/worker-mark-waiting.sh`) при вызове `AskUserQuestion` в interactive worker'е; удаляется PostToolUse hook'ом после ответа пользователя. Phase-log-контракт (single-writer coordinator) не затронут — hooks пишут в отдельный файл. `wait-wave.sh` видит marker и показывает статус `WAITING_USER(tmux-target)` вместо `running`. При долгой блокировке (>5 мин) coordinator MAY дополнительно залогировать `log_phase_event <phase> blocked reason=waiting-for-user` — это по желанию, не обязательно.

## Interactive mode: phase-log как OPTIONAL progress hint

В `interactive` mode worker работает в tmux TUI без оркестратора в роли `single-writer`. Поэтому:

- **Phase-log events становятся OPTIONAL** — worker MAY писать `log_phase_event <phase> <status>` через Bash для lineage/debug, но это НЕ load-bearing для completion detection.
- **Primary completion marker** в interactive mode — `result.json` size > 10 bytes (скилл пишет его в Phase 5.0 через Bash; `wait-wave.sh` уже gate'ит по этому).
- **Secondary hint** — `tmux-target` file + `finished_at`/`exit_code` (пишутся skill'ом в Phase 5.5).
- **Phase-guard / state-JSON invariants** (plan.json, diff.json, gate.json, verify.json, close.json) остаются в силе — они независимы от mode и пишутся скиллом через `phase-complete.sh`.
- `wave-status.sh` для interactive worker'а SHOULD показывать: phase из последней state-JSON (`close.json` → `5-close complete`, etc.) + tmux-target; если ни phase-log, ни state-JSON нет, но `result.json` > 10B — считать DONE.

**Single-writer invariant для headless mode остаётся неизменным** — там coordinator пишет phase-log, workers не трогают.

## Git protection

- `.githooks/pre-commit` + `.githooks/reference-transaction` блокируют commits/ref-updates в protected branches (trunk — `ao.base_ref` из runtime.config.yaml, по умолчанию `main`) когда есть живые worker PIDs в state-dir (`state_dir`) `*/pid`
- Override: `GIT_ALLOW_WORKER_COMMIT=1`
- Bootstrap: `bash scripts/ao/install-git-hooks.sh` (idempotent)
