> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

## Phase 3: GATE

### 3.1 Quality Gates + Base Audits

**Default — coordinator inline** (token economy):
```bash
# Per-language gate commands из runtime.config.yaml (gates.<lang>.{lint,type,test}),
# по одному набору на каждый профиль в `languages:`. {paths} expand'ится к
# профильным target-путям (paths.backend/paths.frontend, если заданы).
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} gate || exit 1

# Пример для python-профиля (см. gates.python в runtime.config.yaml):
ruff check {paths}      # или сконфигурированная gates.python.lint команда
mypy {paths}            # gates.python.type
pytest {paths}          # gates.python.test
# Аналогично для typescript/csharp — см. gates.typescript / gates.csharp.
```
Coordinator diff'ит с baseline сам — новые fail'ы = regressions. Inline дешевле, чем эскалация в agent для типовой story.

> **Regression-vs-pre-existing split**: чтобы не путать новые failures со старыми, использовать:
> ```bash
> bash scripts/ao/gate-diff-vs-base.sh STORY-{ID} "${AO_BASE_REF:-main}"
> # → <state_dir>/story-{id}/gate-delta.json: {"new_failures":[...],"preexisting":[...],"fixed":[...]}
> ```
> Тест-команда конфигурируется через `ao.diff_test_cmd` (default — whole-repo pytest; **переопределить** для non-pytest / non-Python стеков или когда тесты живут в подкаталоге). Только `new_failures` блокируют gate.

**Escalate to `qa-expert` agent ONLY if**: story ≥ 8 SP OR cross-module impact OR coordinator нашёл подозрительные failures и нужна deep-dive аналитика.

**Legacy agent launch (conditional):**

```
Agent(subagent_type="qa-expert", model="sonnet", description="Gate STORY-{ID}", prompt="""
Run quality gates for STORY-{ID}.
Changed files: [list]
Baseline failures (recorded before implementation):
[paste baseline from Phase 1.5]

Step 1 — Run the configured gate commands (gates.<lang>.{lint,type,test} per active
language profile) and compare against baseline. Only NEW failures (not in baseline)
count as regressions.

Step 2 — Run project-specific audit skills on changed files, if configured
(e.g. a code-principles / complexity / dead-code auditor — check what's actually
available in this repo before assuming a name).

MANDATORY: use this product's configured code-discovery MCP (see `.claude/rules/mcp-usage.md`)
for code analysis — do NOT use recursive Grep/Glob; Read with offset/limit OK для known files.

Report: gate results (pass/fail + regression list) + audit findings with severity.
""")
```

**Progress step:**
```bash
# Phase-guard перед стартом 3-gate (проверяет diff.json от Phase 2). БЛОКИРУЕТ при invalid state.
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} gate || exit 1
# ... lint + type + test ...
# После gates — записать gate.json через wrapper (валидирует lint/typecheck/tests keys present).
cat > /tmp/gate-{ID}.json <<JSON
{"lint":{"pass":true,"new_failures":0},"typecheck":{"pass":true,"new_failures":0},"tests":{"pass":true,"new_failures":0}}
JSON
bash scripts/ao/phase-complete.sh STORY-{ID} 3-gate /tmp/gate-{ID}.json

# 3.3 Audits (conditional — god-nodes OR security OR perf triggers):
# Если триггер сработал: log_phase_event 3.3-audits complete (micro-phase — без state-JSON)
# Если не сработал:
#   bash scripts/ao/phase-skip.sh STORY-{ID} 3.3-audits no-god-nodes-no-security-no-perf
```

> **Background-task waiting discipline**: длинный test-run (несколько минут), `Agent(run_in_background)`, subagent-dispatch — **harness-tracked**: по завершении приходит completion-notification и сессия re-invoke'ится автоматически. НЕ ставить `ScheduleWakeup`-фоллбэки на короткие интервалы для опроса таких задач — это мёртвое ожидание без выгоды. Просто завершить ход и ждать notification. `ScheduleWakeup` оправдан ТОЛЬКО для external untracked состояния (CI/deploy/remote queue), и тогда delay подбирается под реальную длительность.

### 3.2 Architecture Review (architect-reviewer — conditional supplement)

> **`solo-reviewer` (Phase 2.2), если присутствует, уже покрывает code-quality + arch-smells + AC + a11y + security.**
> `architect-reviewer` запускается **дополнительно** ТОЛЬКО когда story вводит
> архитектурный контракт, потребляемый ≥2 модулями, ИЛИ ADR-level изменение.
> **НЕ триггеры**: новый shared sub-component с pilot-only потреблением, additive
> API-эндпойнт, новый shared kit используемый 1-2 pilot-потребителями — это НЕ
> ADR-level, solo-reviewer (или обычный code-reviewer) достаточно.
>
> **Phase 3-gate ВСЕГДА assert'ит наличие review artifacts, любой sp:**
> 1. `<state_dir>/story-{id}/review.json` — от post-execution review агента (Phase 2.2). Gate fails если отсутствует.
> 2. `<state_dir>/story-{id}/simplify.json` — от pre-review simplification (Phase 2.1.5), **если этот шаг сконфигурирован** в проекте. Format: `{findings_count, commits, rationale, test_result}`. Empty-diff = `findings_count:0` без коммита, но файл должен быть.
> 3. `<state_dir>/story-{id}/migration-review.json` — от migration-reviewer (Phase 2.2), **если** такой агент настроен в проекте **и** diff затрагивает миграции БД (`ao.migrations_dir`). Иначе not required.
>
> **Bash assert template:**
> ```bash
> STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
> WORKER_DIR="${STATE_DIR}/story-${STORY_ID#STORY-}"
> for f in review.json; do
>   [[ -s "$WORKER_DIR/$f" ]] || { echo "[gate] missing $f — phase 2.x review pipeline skipped" >&2; exit 1; }
> done
> MIGRATIONS_DIR="$(rcfg ao.migrations_dir '')"
> if [[ -n "$MIGRATIONS_DIR" ]] && git diff --name-only HEAD~$N..HEAD | grep -q "$MIGRATIONS_DIR"; then
>   [[ -s "$WORKER_DIR/migration-review.json" ]] || { echo "[gate] migration touched but migration-review.json missing" >&2; exit 1; }
> fi
> ```

```
# Только при триггере (cross-module new contract / ADR-level / new shared kit):
Agent(subagent_type="architect-reviewer", model="sonnet", description="Arch review STORY-{ID}", prompt="""
Evaluate architecture decisions for STORY-{ID}.
Changed files: [list]
Module boundaries: [from story-planner]
Reviewer findings so far: [paste relevant code-quality findings из review.json — не дублировать]

Produce: strategic concerns, tactical improvements, observations with trade-off options. JSON: {findings:[...], verdict:pass|concerns|block}.
""")
# findings → merge в <state_dir>/story-{id}/review.json (agents[] += "architect-reviewer").
```

### 3.3 Heavy Audits (coordinator dispatches — conditional, project-specific)

Launch project-specific audit skills **in parallel**, if this repo has them configured, based on triggers. This runtime ships `/audit-frontend`; other audit skills (security, dependency, observability, concurrency, dead-code, complexity...) are project-specific — check `.claude/skills/` before assuming a name.

| Audit | Trigger |
|-------|---------|
| project security auditor (if present) | backend / full-stack contour, diff touches auth/RBAC/crypto/secrets |
| `/audit-frontend` | frontend / full-stack contour, new page or redesign |
| project concurrency auditor (if present) | diff вводит async race / advisory-lock / outbox |
| project dependency/codebase auditor (if present) | large stories (≥8 SP) |

> **Subsumption rule**: таблица выше — *кандидаты*, не безусловный запуск. Если post-execution review (2.2) verdict ∈ {pass, concerns} И migration-review (если был) = pass И story НЕ вводит новый cross-module контракт/ADR — heavy-audits **subsumed** (review уже покрыл security/quality/arch-smells/a11y/AC). Запускать точечно только по конкретному триггеру из таблицы. Иначе — `bash scripts/ao/phase-skip.sh STORY-{ID} 3.3-audits <reason>` где reason из enum: `subsumed-by-review` | `no-trigger` | `deferred-followup`. Story size сама по себе НЕ форсит heavy audits если review чистый — это token-burn без сигнала.


### 3.4 Corrective Loop (max 3 iterations; same-failure early-escalate after 2)

> **Phase-log liveness**: phase-log ЗАМОРАЖИВАЕТСЯ на `2.2-a11y-complete`/`3-gate` пока идёт corrective — coordinator/`wait-wave` видят frozen phase, ложно подозревают stuck. **ОБЯЗАТЕЛЬНО логировать вход/выход каждого раунда:**
> ```bash
> source scripts/ao/phase-log-util.sh
> log_phase_event "$WDIR" 3.4-corrective start    # round N start (micro-phase, без state-JSON)
> # ... corrective executor + targeted re-validation ...
> log_phase_event "$WDIR" 3.4-corrective complete # round N done
> ```
> Micro-phase `3.4-corrective` разрешён напрямую (не major). `wave-status.sh`/
> `worker-liveness.sh` тогда видят движение, не false-stuck.

If new gate failures, blocking review findings, or critical audit findings:

1. Analyze failure output — identify root cause
2. Search memory for relevant context (если claude-mem доступен): `Skill("claude-mem:mem-search", args="[failing module/pattern]")`
3. Assemble **corrective executor prompt** directly (coordinator, NOT a separate agent):
   ```
   Agent(subagent_type="story-executor", model="sonnet", description="Corrective fix STORY-{ID}", prompt="""
   You are the corrective executor for STORY-{ID}.

   ## Failure Analysis
   [specific failures with file:line references]
   [blocking findings from post-execution review (review.json)]
   [critical items from migration-review / architect-review / qa-expert / auditors, if any]

   ## Memory Context
   [targeted mem-search results, if claude-mem available]

   ## Step 1: MCP Pre-Checks (MANDATORY)
   - this product's code-discovery MCP — find failing functions by name (PREFERRED)
   - trace callers/callees of failing function
   - read failing function body
   - context7 query-docs if the failure is API-related
   State: "Pre-check complete: [summary]. Fixing [specific issues]."

   ## Step 2: Corrective Work
   [focused fixes from failure analysis — ONLY the failures, nothing else]

   ## Step 3: Validation (TARGETED — never full suite)
   Re-run ONLY the failed check, changed-scope (targeted gates.<lang>.{lint,type,test}
   subset, not the full sweep).

   ## Rules
   1. Fix ONLY the listed failures — no drive-by changes
   2. Use configured discovery MCP for code navigation; Edit/Write для модификаций
   3. NEVER use suppression comments/flags to silence the failure (`# noqa`, `@ts-ignore`, `--no-verify`, etc.)
   4. Activate the project's toolchain env (venv / node modules) per this repo's conventions

   Report: files changed, MCP tools used, targeted gate results.
   """)
   ```
4. Re-run **ONLY** failed gates/audits — story-scoped, not the full test.sh-style sweep. Full sweep — ОДИН раз перед close, не на каждой итерации corrective.
5. **Early-escalate cap**: после iteration **2** (не 3) если тот же check всё ещё fail — STOP blind retry. Coordinator делает root-cause analysis сам (trace + read failing code), пишет диагноз в `<state_dir>/story-{id}/corrective-escalation.md`, и ЛИБО даёт executor'у точечный fix-prompt с конкретным diagnosis, ЛИБО эскалирует user'у (interactive: AskUserQuestion). 3-я слепая итерация ЗАПРЕЩЕНА — loop-thrash сжигает round-trips без прогресса. Разные failures между итерациями = прогресс, продолжать ≤3.

Rules: no suppression comments/flags to pass gates.

**Progress step (per iteration):**
```bash
log_phase_event <state_dir>/story-{id} 3-gate-corrective start "iteration-{N}"
```

### 3.5 Gate Decision Rules

- **All gates + reviews + audits pass** → proceed to Phase 4
- **Same failure persists after iteration 2** → coordinator root-cause analysis (corrective-escalation.md) before any 3rd attempt; no blind retry
- **Gates fail after 3 iterations** → STOP, report to user

> **CHECKPOINT 2**: Before proceeding to Phase 4, verify progress tracking in Phase 2-3:
> - [ ] `git diff --stat` run in 2.2
> - [ ] Progress file updated after 2.2+2.3
> - [ ] Progress file updated after 3.1
> - [ ] If corrective loops ran: progress file updated per iteration
