---
name: implement-story
description: "Single-story closed-loop delivery (init→plan→implement→gate→verify→close) with git-worktree isolation and phase-contract state logging. Thin coordinator dispatching Sonnet subagents — for stories that need full harness rigor (migrations, cross-module, RBAC/security-sensitive, or any story routed through the AO story-machinery)."
argument-hint: "<STORY-ID> [STORY-ID2 ...] [--from-phase=<phase>] [--only-phase=<phase>]"
---

## Entry Points — Phase Skipping

Для retry / re-verify / re-close без перезапуска всего цикла.

**Args:**
- `--from-phase=<phase>` — стартовать с указанной фазы, пропустив предыдущие (подгрузить state с диска)
- `--only-phase=<phase>` — выполнить ТОЛЬКО одну фазу и остановиться

**Valid phase names:** `init` (Phase 0), `plan` (Phase 1), `implement` (Phase 2), `gate` (Phase 3), `verify` (Phase 4), `close` (Phase 5).

**State contract:** каждая фаза читает и пишет JSON-файлы в state-dir (`state_dir` из `runtime.config.yaml`, default `/tmp/claude-workers`) под `story-{id}/`:

| Input file (required) | Phase | Output file (produced) |
|-----------------------|-------|------------------------|
| — | init | `context.json` (story frontmatter + mem-search findings, if configured) |
| `context.json` | plan | `plan.json` (tasks, AC breakdown, executor prompt) |
| `plan.json` | implement | `diff.json` (changed files, commits, executor dispatches) |
| `diff.json` | gate | `gate.json` (lint/type/test results) |
| `gate.json` | verify | `verify.json` (AC status per criterion + review findings) |
| `verify.json` | close | `close.json` (RTM update + srs-pending reference, if `srs.enabled` + cross-session summary reference) |

**Skip rules:**
- При `--from-phase=X`: обязательно проверить существование всех required input-файлов предыдущих фаз (`scripts/ao/phase-guard.sh`). Если файл отсутствует — STOP, не запускать, отчитаться о missing state.
- При `--only-phase=X`: так же проверить input-файлы. Не писать новые фазы после X.
- Phase-log (`scripts/ao/phase-log-util.sh`) обновляется после завершения каждой фазы.

**Типичные сценарии:**
- Review нашёл проблемы → fix в существующем worktree → `--from-phase=gate` перезапускает gate + verify + close
- AC failed на 3-м attempt, сделали manual fix → `--from-phase=verify` пере-проверяет AC
- RTM/srs-pending забыли обновить → `--only-phase=close` досинхронизирует без пересчёта (SRS Edit'ы по-прежнему запрещены для worker'а — coordinator применит pending после merge, см. `references/srs-sync.md`)

**Default (no flags):** полный цикл phase-0 → phase-5 (текущее поведение).

---

## Role

You are the **coordinator** of a closed-loop delivery cycle. You are a **thin orchestrator** — you dispatch specialized agents, pass outputs between them, make go/no-go decisions, and manage memory. You NEVER implement code yourself and you NEVER perform deep codebase analysis yourself.

### Actors

| Role | Actor | What it does |
|------|-------|-------------|
| **Coordinator** | you | Dispatch agents, pass outputs, go/no-go decisions, memory, RTM, report, executor prompt assembly |
| **Analyst** | this product's code-discovery MCP (coordinator direct) | Codebase analysis, call graphs, impact analysis |
| **Planner** | `story-planner` agent | Task decomposition from story + analysis — **MANDATORY** в Phase 1.3: inline-plan координатором ЗАПРЕЩЁН, dispatch обязателен независимо от story size |
| **Designer** | `ui-designer` agent (via this project's design skill, if configured) | Frontend design specs (new pages/wizards) — optional frontend-profile capability, see `references/design-modes.md` |
| **Executor** | `story-executor` agent (Sonnet, fresh context per task) | Code + tests implementation — **MANDATORY** в Phase 2.1: per-task dispatch обязателен, `general-purpose` / inline-execution координатором ЗАПРЕЩЕНЫ |
| **Reviewer** | `solo-reviewer` agent | Post-execution review — security + code quality + accessibility + AC verification в одном Sonnet-проходе. MANDATORY, любой sp — skip запрещён |
| **Migration Reviewer** | `migration-reviewer` agent, **if configured in this project** | DB migration safety review (downgrade/lock-time/backfill) — MANDATORY when present AND diff touches `ao.migrations_dir`; if not configured, this role doesn't exist for this project |
| **Arch Reviewer** | `architect-reviewer` agent | Architecture review (conditional — только cross-module new contract / ADR-level / new shared kit) |
| **QA (Phase 4 verify)** | `qa-expert` agent | Финальные quality gates + AC re-verify (escalation path, re-run после corrective cycle) |
| **Simplifier** | project's simplifier agent, **if configured** | Pre-review cleanup (Phase 2.1.5) — MANDATORY when present, independent of diff size; if not configured, this phase doesn't apply |

### Execution Modes

**Inline mode** (single story, called directly): Coordinator runs all phases in current conversation. All Agent(), Skill(), MCP tools available.

**Headless worker mode** (called via `claude -p` from a `/run-stories`-style batch orchestrator): This skill runs inside a full Claude Code session. ALL tools are available — Agent(), Skill(), MCP servers. The worker MUST:
1. Report progress via `log_phase_event` helper (see `references/logging-protocol.md`). НЕ использовать `echo` напрямую — helper пишет JSON-lines формат и обновляет phase-log атомарно.
2. Respect scope lock: only modify files in story `files_affected`
3. Use the MCP servers configured for this product (code-discovery, context7, DB-verification, browser-verification — see `.claude/rules/mcp-usage.md`)
4. Spawn `solo-reviewer` agent in Phase 2.2 (+ conditional `migration-reviewer` / `architect-reviewer`, if configured)
5. **Editing layer (worktree workers only)**: if this product's worktree provisions a symbol-editing MCP (e.g. Serena) with native LSP disabled for isolation, use its symbol-tools (find/replace/insert/rename, diagnostics) instead of large Read+Edit; keep the code-discovery MCP for discovery/impact. See the worktree `CLAUDE.md` for this project's actual tool routing.

### Agent-view engine (optional)

Native background-agent execution backend — an **opt-in** alternative to tmux + `wait-wave.sh`
dispatch/polling. **DEFAULT stays tmux / wait-wave.** Only relevant on Claude Code versions that
ship it, and each `--bg` agent burns its own quota (N agents = N× rate-limit). Full
dispatch/poll/lifecycle/worktree details — `references/agent-view-engine.md`. Do not switch
an execution path to it without accounting for the N× cost.

---

## Phase Overview

| Phase | What | Reference |
|-------|------|-----------|
| 0 | Session + memory init | `references/phase-0-init.md` |
| 1 | Plan | `references/phase-1-plan.md` |
| 2 | Implement | `references/phase-2-implement.md` |
| 3 | Gate | `references/phase-3-gate.md` |
| 4 | AC verify | `references/phase-4-verify.md` |
| 5 | Close | `references/phase-5-close.md` |

## Cross-cutting Concerns — Conditional Loading

Coordinator грузит reference-файлы по триггерам, **не все сразу**. Это критично для token economy на длинных story.

### MUST READ (один раз в начале сессии)

- `references/invariants.md` — non-negotiable rules across all phases. Нарушение = блокер на любой фазе.
- `references/effort-by-phase.md` — phase → effort table. Coordinator применяет per-phase override перед каждой фазой.

### Triggered by phase

| Reference | Триггер загрузки | Phase |
|-----------|------------------|-------|
| `references/phase-0-init.md` | старт сессии | 0 |
| `references/phase-1-plan.md` | guard ok для phase=plan | 1 |
| `references/phase-2-implement.md` | guard ok для phase=implement | 2 |
| `references/phase-3-gate.md` | guard ok для phase=gate | 3 |
| `references/phase-4-verify.md` | guard ok для phase=verify | 4 |
| `references/phase-5-close.md` | guard ok для phase=close | 5 |

### Triggered by story attributes (НЕ грузить если триггер не сработал)

| Reference | Триггер | Когда НЕ грузить |
|-----------|---------|------------------|
| `references/design-modes.md` | `contour ∈ {frontend, full-stack}` ИЛИ `ui_surface != none` **и** this product's frontend profile has a design/visual-verification capability | чистый backend без UI, или продукт без такой capability |
| `references/srs-sync.md` | старт Phase 5.1, **только если `srs.enabled: true`** | `srs.enabled: false` — Phase 5.1 сводится к одному no-op write, файл можно не грузить |
| `references/parallel-execution.md` | argv contains ≥2 STORY-IDs — **DEPRECATED**: use `/run-stories` for batch; `/implement-story` is single-story only | single-story запуск (норма) |
| `references/interactive-checkpoints.md` | `env CLAUDE_WORKER_MODE == "interactive"` | headless mode |

### Triggered on-demand (lazy load при первом использовании)

| Reference | Триггер |
|-----------|---------|
| `references/mcp-cheatsheet.md` | первый MCP-вызов, требующий деталей API (не каждый раз) |
| `references/logging-protocol.md` | первый `log_phase_event` / `phase-complete.sh` / `phase-skip.sh` |
| `references/agent-view-engine.md` | ТОЛЬКО если явно выбран agent-view backend (opt-in); иначе НЕ грузить — default tmux/wait-wave |

### Decision algorithm на старте сессии

1. Read `invariants.md` (always).
2. Read `phase-0-init.md`.
3. Parse story frontmatter:
   - if `contour ∈ {frontend, full-stack}` OR `ui_surface != none` AND this product has a frontend design/visual-verification capability → mark `design-modes` as "will load at Phase 1.4"
   - else → SKIP `design-modes` entirely
4. Check `env CLAUDE_WORKER_MODE`:
   - if `"interactive"` → mark `interactive-checkpoints` as "will load at Phase 1.7"
   - else → SKIP entirely
5. Check argv:
   - if ≥2 STORY-IDs → mark `parallel-execution` as "will load before launch"
   - else → SKIP entirely
6. Phase files (1–5) грузить только перед стартом соответствующей фазы.
7. `mcp-cheatsheet` и `logging-protocol` — НЕ грузить proactively, только когда координатор реально не помнит детали.

> **Anti-pattern**: грузить весь `references/` в начале сессии «на всякий случай». Backend story не должна видеть `design-modes`. Single-story запуск не должен видеть `parallel-execution`.

## How to use

1. **Start of session**: read `references/invariants.md` + `references/phase-0-init.md`. Parse story frontmatter и env vars per «Decision algorithm» выше — определи какие conditional references понадобятся, остальные НЕ грузи.

2. **Per phase**: перед каждой фазой грузи соответствующий `references/phase-N-*.md`. Используй `bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} <phase-name> || exit 1` для guard+start.

3. **On-demand**: `mcp-cheatsheet.md` и `logging-protocol.md` грузить только когда нужны детали API/протокола — не каждый раз.

4. **Чтение reference-файлов**: используй `Read(file_path, offset, limit)` для нужного фрагмента .md, не дёргай whole-file без offset.

---

## Agent Dispatch Summary

| Phase | Agents | Parallel? |
|-------|--------|-----------|
| 0.1-0.2 | mem-search (if configured) + file init (coordinator direct) | — |
| 1.1 + 1.2 | code-discovery MCP graph queries (coordinator direct) | — (no agents) |
| 1.3 | `story-planner` | **ВСЕГДА**, любой sp — inline-plan координатором ЗАПРЕЩЁН; skip запрещён |
| 1.4 | this project's design skill / `ui-designer.md` review, if configured | for frontend/full-stack, only when the capability exists |
| 1.5 | coordinator (inline assembly) | after 1.3 (and 1.4) |
| 2.1 | `story-executor` (per-task, fresh-context, Sonnet) | **ВСЕГДА**, любой sp — `general-purpose` / inline-execution ЗАПРЕЩЕНЫ. **2.1.1 parallel-mandate**: independent tasks (`depends_on` пустой/satisfied) ОБЯЗАНЫ dispatched в **ОДНОМ message с N Agent() блоками** — серия одиночных messages ЗАПРЕЩЕНА (invariant 15). |
| 2.2 + 2.3 | `solo-reviewer` (+ `migration-reviewer` MANDATORY-if-configured when migration files) | **ВСЕГДА**, любой sp — skip запрещён |
| 3.1 | `qa-expert` (escalation path) | — |
| 3.2 | `architect-reviewer` | only cross-module new contract / ADR-level / new shared kit |
| 3.3 | project-specific audit skills, if configured | parallel, conditional |
| 3.4 | coordinator → Claude subagent | corrective (max 3) → повторный `solo-reviewer` |
| 4.1 + 4.2 | `qa-expert` ‖ `accessibility-tester` (if browser-verification tool configured) | YES (visual verify only if the capability exists) |
| 5.3 | cross-session structured summary (coordinator direct, if memory plugin configured) | — |
| 5.4 | file progress close (coordinator direct) | — |
| 2.1.5 | project's simplifier agent, if configured | **ВСЕГДА when present** — skip запрещён |

## Knowledge-Source Agents

These agents are NOT dispatched directly. The **executor** reads their files as Step 0 to load domain knowledge before coding, if present in this project's `.claude/agents/`:

| Agent file | Domain |
|------------|--------|
| `.claude/agents/backend-developer.md` | Backend feature work — routers/services/migrations |
| `.claude/agents/frontend-developer.md` | Frontend patterns (React/TS or this product's stack) |
| `.claude/agents/python-pro.md` | Python idioms, type-checking, async, ORM patterns |
| `.claude/agents/typescript-pro.md` | Strict TypeScript, generics |
| `.claude/agents/react-specialist.md` | React 18+, data-fetching/state patterns |
