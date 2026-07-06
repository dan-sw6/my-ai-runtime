> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

## Phase 2: IMPLEMENT

### 2.0 UI-redesign delegation (optional — only if this project has a dedicated redesign skill)

> Some products ship a mock-/canon-driven UI redesign skill (e.g. a `/redesign-page`-style
> skill) that owns page-level refactors end-to-end instead of the worker hand-writing them.
> This runtime does not ship one — check `.claude/skills/` for this project before assuming
> it exists.

**Decision rule (if such a skill IS configured):** before dispatching any UI task, check whether
the story has a redesign-style block, or an AC explicitly asks to bring a page to a canon/mock.
If so, delegate the UI portion to that skill (in its own `--auto`/non-interactive mode — no
human at the keyboard inside a worker) and deliver the **remaining non-UI ACs** (API, schema,
tests) normally in the same Phase-2 pass, treating that skill's verifier output as evidence for
the UI ACs in Phase 4. Do NOT re-implement the page refactor by hand afterward.

If no such skill is configured in this project — this subsection does not apply; continue to 2.1.

### 2.1 Per-Task Dispatch (story-executor subagent — MANDATORY, NO-SKIP)

> **⚠ BLOCKING CHECKPOINT 2.1**: каждая task из `plan.json.tasks[]` ОБЯЗАНА быть dispatched через `Agent(subagent_type="story-executor", model="sonnet")`. ЗАПРЕЩЕНЫ:
> - **inline-execution координатором** (coordinator пишет код сам через Edit/Write/Bash) — даже для маленьких, single-file tasks, "точечный фикс"
> - **`subagent_type="general-purpose"`** — тёплый label ("Task N STORY-XXX executor") не делает агента story-executor; subagent_type обязан быть `story-executor`
> - **batch-dispatch** (один Agent на все tasks) — каждый task = отдельный fresh-context Agent
> - skip-причины (`tasks-trivial`, `single-task-inline-faster`, `context-window-sufficient`, `coord-direct-write`) — НЕ принимаются
>
> **Why mandate**: a `general-purpose` dispatch misses the Self-Review Loop, MCP discipline gate, and BLOCKED/QUESTION escalation protocol built into `story-executor.md`.
>
> **Enforcement**: coordinator пишет `diff.json` через `phase-complete.sh` с полем `executor_dispatches: [{task, subagent_type:"story-executor", model, status, commit}]`. `phase-complete.sh` блокирует переход к 3-gate если хотя бы один dispatch не `story-executor` или commits[] содержит не-hex40 SHA.
>
> **Pattern**: coordinator dispatches each task from `plan.json` to a **fresh-context** `story-executor` subagent. Coordinator does NOT write code directly; coordinator orchestrates dispatch, aggregates results, handles BLOCKED/QUESTION escalations.
> Why fresh context: каждая task короткая (1-3 файла), не размывает coordinator-context (long-running, holds plan/risks/baseline). Атомарные commits. BLOCKED/QUESTION возвращаются в coordinator для решения.

**Dispatch loop** — per task in `plan.json` tasks[]:

```
Agent(subagent_type="story-executor", model="sonnet", description="Task {N} STORY-{ID}", prompt="""
Story: STORY-{ID}  |  Task {N}/{TOTAL}: {task.title}
Worker dir: ${CLAUDE_WORKER_DIR}
Story file: {ao.story_dir}/STORY-{ID}.md (read in_scope + AC affected by this task)
Plan: <state_dir>/story-{id}/plan.json (read full plan + read task {N} body)

Files in scope для этой task:
{task.files_affected}

AC covered by this task:
{task.ac_ids}

Constraints / patterns / risks (extracted from plan):
{task.constraints}

Frontend visual contract (если применимо и продукт имеет такую capability — см. references/design-modes.md):
{{contract_path}} / {{fingerprint_path}} / {{mock_anchor}}

Step 1: code-discovery MCP + context7 pre-checks (MANDATORY per agent prompt).
Step 2: implement task. Atomic commit с feat|fix|test|docs|chore prefix.
Step 3: self-review (см. story-executor.md "Self-Review Loop").
Step 4: return JSON {status: done|blocked|question, commit_sha, files_changed, notes, escalation?}.
""")
```

### 2.1.1 Parallel dispatch (HARD-MANDATORY — single-message multi-Agent)

> **⚠ BLOCKING CHECKPOINT 2.1.1**: tasks из `plan.json.tasks[]` с уже-удовлетворёнными (или пустыми) `depends_on` ОБЯЗАНЫ dispatched в **ОДНОМ assistant-message с N `Agent()` tool_use блоками** — НЕ серия из N сообщений, каждое со своим Agent.
>
> Симптом нарушения: user видит в Claude Code TUI первый агент в foreground, второй в queue; нужно вручную ↓ background первого чтобы второй стартовал. Это значит coordinator отправил Agent #1 → дождался результата → отправил Agent #2 — **серийная dispatch, нарушение контракта**.
>
> **Корректное поведение**: coordinator формирует одно assistant-сообщение, в котором СРАЗУ N `Agent(...)` tool-use блоков для всех независимых tasks волны (`depends_on` пустой/satisfied). Claude Code harness запускает их concurrent; user в TUI видит multi-agent fanout, первый автоматически уходит в background при поступлении второго (не нужно ручного ↓).
>
> **Pattern matching для dispatch wave**:
> 1. Прочитать `plan.json.tasks[]`.
> 2. Построить множество `ready_tasks = [t for t in tasks if all(dep in done_set for dep in t.depends_on)]`.
> 3. Если `len(ready_tasks) >= 2` — один message, multiple Agent() блоков. Если `== 1` — один Agent().
> 4. Дождаться результатов ВСЕХ Agent'ов волны (Claude Code собирает их параллельно), потом aggregate, потом следующая волна.

**Пример корректного parallel dispatch** (2 independent tasks):

```python
# WRONG (serial — нарушение):
# Message 1: Agent(subagent_type="story-executor", description="Task 1 STORY-X", prompt="...")
# [wait for result]
# Message 2: Agent(subagent_type="story-executor", description="Task 2 STORY-X", prompt="...")

# RIGHT (parallel — single message, два Agent блока):
Agent(subagent_type="story-executor", model="sonnet", description="Task 1 STORY-X", prompt="...")
Agent(subagent_type="story-executor", model="sonnet", description="Task 2 STORY-X", prompt="...")
# ↑ ОБА вызова в ОДНОМ assistant message. Harness запустит concurrent.
```

**Серийность допустима ТОЛЬКО** когда:
- task B имеет `depends_on: [task-A.id]` И A не выполнен (real code-зависимость, например frontend ждёт endpoint от backend)
- files_affected пересекаются → scope-lock violation при concurrent execution

**Frontend-task, потребляющий лишь API-контракт из plan** идёт параллельно backend-impl: контракт уже зафиксирован в plan.json, executor читает его как input — не требует backend-task finished.

**Anti-pattern checklist** перед dispatch:
- ❌ Серия одиночных Agent() сообщений для independent tasks → user видит «backgrounded agent» вручную
- ❌ Один Agent на батч tasks («batch-dispatch» — already запрещён 2.1 mandate)
- ❌ `await result; then Agent()` для tasks без real depends_on
- ✅ One message → N `Agent()` blocks → harness parallel

**Auto-wave decomposition algorithm (coordinator responsibility)**:
```
done = set()
while len(done) < len(tasks):
    ready = [t for t in tasks if t.n not in done and all(d in done for d in t.depends_on)]
    if not ready: ERROR — циклическая зависимость в plan
    # dispatch ВСЕ ready tasks в ОДНОМ message с N Agent() блоков
    results = await_all_agents(ready)
    done.update(t.n for t in ready if results[t.n].status == "done")
    handle_blocked_or_question(results)  # see protocol below
```
Алгоритм — coordinator responsibility; story-planner не делает этой работы (выдаёт `depends_on` граф, всё). Не запускать «wave 1 — все теоретически параллельные» руками — токены тратятся на ручной топосорт.

**`diff.json` schema reference (для phase-complete.sh)**:
Required keys: `changed_files: [str]`, `commits: [{sha: hex40, task: int, subject: str}]`, `executor_dispatches: [{task: int, subagent_type: "story-executor", model: str, status: str, commit: hex40}]`.
**Pitfalls (known):**
- `sha` ОБЯЗАН быть **full 40-hex** — `git rev-parse <short>` для расширения.
- `executor_dispatches[].subagent_type` ОБЯЗАТЕЛЬНО литерал `"story-executor"` — без него guard blocks.
- Это поле **отдельно от commits[]** — validation проверяет оба массива.
Готовый builder (Python):
```python
import json, subprocess
short_shas = ["8c4a283","d6dfc04"]; out = []
for s in short_shas: out.append(subprocess.check_output(["git","rev-parse",s], text=True).strip())
# build dispatches/commits/diff dict here, json.dump → <state_dir>/story-{id}/diff.json
```

Coordinator после каждого Agent():
- `status=done` → next task (или, при параллельном dispatch, собрать все результаты волны)
- `status=blocked` → analyze + либо resolve inline либо escalate user (per BLOCKED/QUESTION protocol)
- `status=question` → coordinator answers (using mem-search / docs / context7) → re-dispatch task с answer в prompt

**Implementation rules** (применяются субагентом, NOT coordinator):
1. code-discovery MCP + context7 pre-checks per agent frontmatter MANDATORY block
2. Edit/Write напрямую для кода
3. DB-verification MCP (если настроен) для DB work (verify schema, explain queries) ДО написания SQL/migrations
4. Activate this project's toolchain environment before running language commands (venv / node_modules / etc — per this repo's own conventions)
5. Quality gates after each commit: the configured `gates.<lang>.{lint,type}` commands for the touched language(s)
6. Atomic commits, NEVER suppression comments/flags to silence a failure

**Coordinator-only operations** (NOT delegated):
- Any project-specific design/redesign skill invocation (mode decision), if configured
- `phase-guard-or-exit.sh` + `phase-complete.sh` writes (state-JSON ownership per phase-contract single-writer invariant)
- `diff.json` aggregation (after all tasks done)
- BLOCKED/QUESTION resolution via mem-search / clarification
- Plan revision (если task discovery surfaces unknown — coordinator updates plan.json before re-dispatch)

**For frontend stories with new pages/wizards/redesign, if this project has a design skill configured** (coordinator invokes BEFORE dispatch loop):
```
Skill("<project's frontend-design skill>", args="component/page description")
```

**Visual contract block (only if this product's frontend profile has a design-contract mechanism):**
See `references/design-modes.md` for what to inject into the executor prompt (contract path, fingerprint gate, mock anchor) when such a mechanism exists in this project. If it doesn't, skip this — nothing to inject.

**Batch strategy for migration/elimination tasks (files_affected > 10):**
> When the story involves replacing patterns across many files (inline styles, deprecated imports, etc.):
> 1. **Collect ALL** occurrences first via a code-discovery pattern search — get full scope
> 2. **Create ALL** replacement artifacts in one pass (shared helpers, utility files)
> 3. **Batch-replace** across all files — don't read-analyze-edit one by one
> 4. **Commit once** after all replacements
> This saves significant turns vs a file-by-file approach. Check cross-session memory for prior pattern recipes, if a memory plugin is configured (`"<pattern type> migration recipe"`).

**Implementation rules:**
1. Use the code-discovery MCP's graph-search + snippet-read tools for code navigation (PRIMARY).
2. Use its impact/trace tool to check impact before modifying functions.
3. **Code modifications**: Edit/Write directly.
4. Use context7 `query-docs` when unsure about API syntax.
5. **MANDATORY: use the DB-verification MCP (if configured) for ALL DB work** — creating/modifying queries, migrations, models touching a DB. Verify current schema/indexes/constraints, validate query plans, inspect table structure BEFORE writing SQL/migrations/ORM models.
6. Activate this project's toolchain environment before running language commands.
7. Quality gates after EACH logical change: the configured `gates.<lang>.{lint,type}` commands.
8. Atomic commits with `feat|fix|test|docs|chore` prefix.
9. NEVER use suppression comments/flags to pass gates.

**Progress step:**
```bash
# Phase-guard перед стартом 2-implement (проверяет plan.json от Phase 1). БЛОКИРУЕТ при invalid state.
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} implement || exit 1
# ... implementation cycle ...

# Migration head-conflict check (known pitfall): если story создала миграцию в
# `ao.migrations_dir` (если этот ключ сконфигурирован), ОБЯЗАТЕЛЬНО проверить
# single head/chain ДО diff.json с помощью этого стека's migration tool
# (Alembic: `alembic heads`; Django: `showmigrations`; EF Core: `dotnet ef migrations list`;
# etc). Иначе при merge параллельных worker'ов, оба создавших миграцию независимо,
# получим конфликтующую цепочку.
MIGRATIONS_DIR="$(rcfg ao.migrations_dir '')"
if [[ -n "$MIGRATIONS_DIR" ]] && git diff --name-only HEAD~${N:-1}..HEAD | grep -q "$MIGRATIONS_DIR"; then
  echo "[phase-2] migration files touched under ${MIGRATIONS_DIR} — verify single head with this stack's migration tool before diff.json"
fi

# После финального коммита — записать diff.json через wrapper
# (валидирует changed_files[] + commits[] non-empty + commit SHA = 40-char hex).
#
# ⚠ ZERO PLACEHOLDERS — каждый commit ОБЯЗАН содержать real SHA из git rev-parse.
# Запрещено: "pending", "pending-phase-5", "TBD", "abc", любые non-hex значения.
# phase-complete.sh enforce regex /^[0-9a-f]{40}$/ — fail при любом placeholder'е
# (known incident class — worker написал "pending" в commits[] до merge).
#
# Канонический алгоритм после финального git commit:
N=$(git log --oneline "HEAD..@{u}" 2>/dev/null | wc -l || echo 1)   # число новых коммитов на ветке
SHAS_JSON=$(git log --pretty=format:'{"sha":"%H","message":"%s"}' "HEAD~${N}..HEAD" | python3 -c '
import sys, json
items = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps(items))
')
CHANGED_JSON=$(git diff --name-only "HEAD~${N}..HEAD" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
python3 -c "
import json
print(json.dumps({
    'changed_files': json.loads('${CHANGED_JSON}'),
    'commits': json.loads('${SHAS_JSON}'),
    'executor_report': '...'
}))
" > /tmp/diff-{ID}.json
bash scripts/ao/phase-complete.sh STORY-{ID} 2-implement /tmp/diff-{ID}.json
```

### 2.1.5 Pre-Review Simplification (simplifier agent — MANDATORY IF configured, else not applicable)

> **If this project has a code-simplification agent configured** (e.g. a `code-simplifier`-equivalent): run it **ALWAYS** after Phase 2 — independent of diff size, skip forbidden.
> **If no such agent is configured in this project** — this subsection does not apply; proceed directly to 2.2. It is not a blocker to omit a capability the project never had.
> **Why before review**: clean up cosmetic noise (duplicates, nested ternaries, redundant abstractions) before the reviewer starts, so the reviewer focuses on real issues (security, logic, a11y, AC), not formatting. Write-agent before read-agent — no race condition.
> **Empty-diff case**: если diff действительно crystal-clean (например только doc-changes / single-line bugfix) — simplifier вернёт `findings_count=0`, фаза complete без правок. Это нормально.

```
Agent(subagent_type="<this project's simplifier agent>", model="sonnet", prompt="""
Simplify recently modified code for STORY-{ID}.
Changed files: [list]

Scope:
- Only files in this story's diff (git diff HEAD~1)
- Remove: DRY violations, nested ternaries (>2 levels), redundant comments, unused helpers called once
- Preserve: ALL functionality, public APIs, component prop contracts, test coverage

Rules:
- NEVER change behavior — only form
- NEVER touch files outside the diff
- NEVER remove tests or assertions
- Re-run the configured test gate after changes — if regression, revert
- Use Edit/Write for code edits

Report: files changed, simplification rationale per change, test result (PASS/FAIL).
""")
```

**Simplifier contract (MANDATORY, known lesson):** a simplifier can, e.g., hoist a function-local import to module-level and break a test relying on call-time re-resolution (monkeypatch pattern), or return a truncated result leaving uncommitted edits. Prompt MUST therefore contain:
> - **НЕ редактировать** test/spec файлы и не менять поведение (только форма).
> - Перед возвратом **самому прогнать lint+type+story-тесты** — pytest/test-runner PASS без type-check НЕ достаточен: extracted helpers с loose signatures проходят runtime, но дают type-regression. При type-регрессии — **revert simplification**, не оставлять на coordinator post-gate.
> - Вернуть structured JSON: `{findings_count, applied, reverted, reverted_reason, files[], commit_sha|"no-changes", test_result, typecheck_result, lint_result}`. `typecheck_result`/`lint_result` ОБЯЗАТЕЛЬНЫ (PASS|FAIL) — отсутствие = coordinator трактует как FAIL и re-run.
> - Function-local import / lazy-import часто намеренный паттерн для тестируемости (monkeypatch). НЕ hoist'ить без проверки usages/тестов.

**Post-simplify gate re-run (NOT optional — coordinator, only if simplifier ran):** simplify = gate-impacting write. Координатор ВСЕГДА после simplify сам re-run targeted gate ДО review:
```bash
# Targeted lint/type + story-own tests (НЕ весь suite) — configured gates.<lang> commands
```
Если регрессия → revert simplify-commit ИЛИ inline-fix (trivial поломку coordinator чинит сам), продолжить. Не передавать сломанный diff в review.

### 2.1.6 Diagnostics ≠ Gate (baseline-filter discipline)

> **Known lesson**: LSP diagnostics (pyright/tsc/etc, surfaced automatically after Edit) can flag stale/pre-existing findings across the whole file every turn — untouched functions, stale symbol references. Reacting to every one is a false-corrective risk + wasted attention.

Правило перед реакцией на диагностику от LSP:
1. **Gate ≠ LSP**: gate = the actually configured `gates.<lang>.{lint,type,test}` commands. A live-LSP finding that the gate tool doesn't report (e.g. a stricter reportReturnType on framework handlers that mypy/tsc's own config doesn't flag) — НЕ gate, ignore for gate purposes.
2. **NEW vs pre-existing**: diagnostic actionable только если (a) в **story-touched регионе** (строки твоего diff) И (b) не воспроизводится на base (сравнить с base branch). Pre-existing file-wide шум на нетронутых функциях — ignore, не корректировать.
3. **Stale**: подтверждать grep'ом текущего файла (символ реально присутствует?) до фикса — LSP-снапшот лагает за Edit.
4. Convention-driven unused-var markers (e.g. underscore-prefixed) — не добавлять suppression comment, это конвенция линтера.

После simplify — re-run targeted gate commands. Если регрессия → revert simplify-commit, продолжить с original diff.

**Progress step (если simplify запускался):**
```bash
log_phase_event <state_dir>/story-{id} 2.1.5-simplify complete
```
Если simplifier не настроен в проекте — `bash scripts/ao/phase-skip.sh STORY-{ID} 2.1.5-simplify no-simplifier-configured`.

### 2.2 + 2.3 Post-Execution Review (`solo-reviewer` — single Sonnet pass)

> **MANDATORY: Phase 2.2 review ВСЕГДА запускается, любой sp.**
> Skip недопустим — a story can pass gates and tests while still hiding security/logic findings that only surface via an independent read of the diff.
>
> **Review agent = `solo-reviewer`** — один Sonnet-проход (security + code quality + accessibility + AC verification, structured JSON). Заменяет параллельный fanout нескольких узкоспециализированных review-агентов — экономит system-prompt overhead.
>
> **ЗАПРЕЩЕНО**: skip Phase 2.2 с reason `inline-self-review` / `session-context-sufficient` / `coordinator-trusts-executor`. Worker НЕ имеет права заменить `solo-reviewer` своей self-review — это разные оптики (executor видел свой код во время написания, reviewer читает diff с нуля).
>
> **Migration-review, IF this project has a dedicated migration-reviewer agent**: если `git diff --name-only HEAD~1` содержит `ao.migrations_dir` — запускается **ВСЕГДА**, параллельно с `solo-reviewer` в том же сообщении. Migration-specific concerns (downgrade reversibility, lock-time под нагрузкой, FK/NOT NULL backfills, head-конфликты) не покрываются 4 категориями solo-reviewer. Если такого агента в проекте нет — этот шаг не применяется.

Before launching, the coordinator pre-computes the diff (token economy — agent reads file, not repo):
```bash
git diff --unified=5 HEAD~1 > /tmp/story-{ID}-diff.txt
git diff --stat HEAD~1
```

**Agent: `solo-reviewer`** (always — НЕ optional, НЕ skip):

```
Agent(subagent_type="solo-reviewer", model="sonnet", description="Solo review STORY-{ID}", prompt="""
Review the changes made for STORY-{ID}.
Story spec: {ao.story_dir}/STORY-{ID}.md (AC + module_boundaries).
Module boundaries: [from story-planner]
Acceptance criteria: [list ACs]
Diff stats: [paste git diff --stat output]
Contour: {{contour}} | Contract: {{contract_path — если задан}} | Fingerprint baseline: {{fingerprint_path — если задан}}

## Diff (pre-computed by coordinator)
/tmp/story-{ID}-diff.txt — Read с offset/limit, не Read целиком если >2000 строк.

## Rules
- Review the diff. Use this project's code-discovery MCP for symbol-level контекста; `Read(file, offset, limit)` max 30 строк когда нужен widening.
- Если contour ∈ {frontend, ui-design, react, full-stack} И этот проект имеет configured browser-verification tool И dev-стек поднят: сделать screenshots state variants (empty/error/loading), в report — только URI; если задан fingerprint_path — visual-diff tool как primary evidence.
- Stay concise. Target <30K tokens.

Выдай structured JSON по схеме из .claude/agents/solo-reviewer.md: 4 категории
(security / code-quality / accessibility / AC-verification) +
per-finding {category, severity:high|medium|low, file, line, issue, suggested_fix} +
ac_verification:[{ac, status:met|partial|missing, note}] +
overall_verdict ∈ {pass|concerns|block} (= APPROVE / concerns-non-blocking / REQUEST_CHANGES).
""")

# Дополнение (тот же message), ТОЛЬКО если у проекта есть migration-reviewer агент И
# git diff --name-only HEAD~1 затрагивает ao.migrations_dir:
Agent(subagent_type="migration-reviewer", model="sonnet", description="Migration review STORY-{ID}",
      prompt="Review the DB migration in diff HEAD~1: downgrade reversibility, lock-time под нагрузкой, FK/NOT NULL backfills, конфликты head'ов. JSON: {findings:[...], verdict:pass|concerns|block}.")
```

**Progress step:**
```bash
# solo-reviewer покрывает и code-review, и a11y — одна phase-фаза.
log_phase_event <state_dir>/story-{id} 2.2-a11y complete
# Если backend-only (no UI) — solo-reviewer всё равно делает security+quality+AC; a11y-категория просто пустая. Skip фазы НЕ нужен.
```

### 2.4 Review Decision Rules

- **solo-reviewer: `overall_verdict=pass`** → proceed to Phase 3
- **`overall_verdict=concerns`** (только non-blocking findings) → proceed to Phase 3; findings → followups в `result.json`
- **`overall_verdict=block`** (≥1 blocking finding) → corrective cycle (Phase 3.4), затем повторный `solo-reviewer`
- **Frontend story, а solo-reviewer не приложил visual evidence** (когда browser-verification tool сконфигурирован) → БЛОКЕР: вернуть с требованием screenshots/visual-diff
- **migration-reviewer (if present): `verdict=block`** → corrective cycle
- **architect-reviewer Phase 3.2 trigger**: запускать ТОЛЬКО при новом контракте, потребляемом ≥2 модулями, ИЛИ ADR-level. Shared sub-component / additive endpoint / pilot-only kit — НЕ триггер, solo-reviewer (arch-smells) достаточно.

### 2.5 Large Task Decomposition

For stories with multiple tasks or waves:
- Execute one wave at a time via separate subagent calls
- Review after each wave before proceeding
- Each wave should be independently testable


## diff.json freshness after amend/squash

> **If phase 2.1.5-simplify (or any later phase) amends/squashes/rebases commits, REGENERATE
> diff.json commits[] from the live branch before logging phase complete.** Simplify rewrites
> commit SHAs but diff.json (written here) keeps the OLD ones; the coordinator worktree-gate
> then `git rev-parse --verify`s the stale SHA, finds no such object, and reports
> `diff-json-fabricated-sha` — a TRUE-positive gate failure on legit work.
>
> ```bash
> BASE="$(git merge-base HEAD "${AO_BASE_REF:-main}")"
> python3 - "$CLAUDE_WORKER_DIR/diff.json" "$BASE" <<'EOF'
> import json, subprocess, sys
> path, base = sys.argv[1], sys.argv[2]
> d = json.load(open(path))
> shas = subprocess.check_output(["git","log",f"{base}..HEAD","--format=%H"]).decode().split()
> msgs = subprocess.check_output(["git","log",f"{base}..HEAD","--format=%s"]).decode().splitlines()
> d["commits"] = [{"sha": s, "msg": m} for s, m in zip(shas, msgs)]
> json.dump(d, open(path,"w"), ensure_ascii=False, indent=2)
> EOF
> ```
