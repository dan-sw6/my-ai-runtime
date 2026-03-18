# Two-Repository AI Workflow Architecture

## Overview

The AI workflow model separates **reusable infrastructure** from **project-specific configuration** across two repositories:

1. **AI Runtime Repo** (`mgt-ai-runtime`) — templates, base agents, quality gates, playbooks
2. **Product Repo** (e.g., `mgt-openproject`) — project truth, customized agents, governance

## Separation of Concerns

### Runtime Repo Owns
- Base agent definitions (generic, parameterized)
- Reusable templates (story, task, handoff, closeout)
- Quality gate definitions (DoD, MCP matrix)
- Operational playbooks (closed-loop cycle, corrective rerun)
- Shared rules (safety, git, secrets, module scope)
- Sync manifest and engine
- Bootstrap scripts

### Product Repo Owns
- All project governance (CLAUDE.md, AGENTS.md)
- Requirements (SRS.md, rtm.yaml)
- Planning state (NOW.md, BACKLOG.md, DECISIONS.md)
- BMAD state (bmad/, docs/bmad/, docs/stories/)
- Task definitions (tasks/)
- Customized agent profiles (.claude/agents/, agents/)
- Custom agents not in runtime (e.g., story-planner)
- Codex skills (.codex/skills/)
- Role prompts (docs/prompts/)

## Runtime Priority Model

Product repos use two AI runtimes with clear priority:

### Claude Code (PRIMARY)
- **Closed-loop delivery** via skill-as-coordinator pattern (Variant C)
- Skill script (`/implement-story`) IS the coordinator — orchestrates phases inline
- Phases: PLAN (story-planner subagent) → IMPLEMENT (specialist subagents) → GATE (bash scripts) → VERIFY (qa-expert subagent)
- Communication: in-memory subagent delegation (no filesystem artifacts)
- Operates in developer's terminal

### Codex (SECONDARY)
- Available but not the default runtime for new work
- Automated closed-loop via FILE-HANDOFF YAML protocol in tmux sessions
- Governed by AGENTS.md
- Useful for batch/unattended execution when needed

### Shared Between Runtimes
- Quality gate scripts (lint.sh, test.sh, type.sh)
- MCP server configurations
- Definition of Done and MCP matrix
- Shared rules (safety, git, module scope, secrets)

### Boundary Rules
- Claude Code agents must never modify BMAD state or create FILE-HANDOFF artifacts
- Codex agents follow AGENTS.md governance
- Both runtimes respect module scope rules

## Sync Flow

```
mgt-ai-runtime (source)
    │
    ├── sync/manifest.yaml (declares entries + modes)
    │
    └── sync/sync-engine.sh (core logic)
            │
            ▼
product-repo/scripts/sync-ai-runtime.sh (wrapper)
            │
            ▼
product-repo/.claude/agents/         (seed: create once)
product-repo/.claude/skills/         (seed: create once)
product-repo/.claude/rules/          (managed: always overwrite)
product-repo/.claude/quality-gates/  (managed: always overwrite)
product-repo/.claude/templates/      (template: create if missing)
```

## Claude-Native Closed Loop

```
User → /implement-story STORY-ID
         │
    ┌────▼──────────────────┐
    │  SKILL (coordinator)   │  Main Claude instance
    └────┬──────────────────┘
         │
    ┌────▼─────┐
    │  PLAN     │  story-planner subagent (read-only)
    └────┬─────┘  → structured task breakdown
         │
    ┌────▼─────┐
    │ IMPLEMENT │  specialist subagents (one per task)
    └────┬─────┘  → code changes + commits
         │
    ┌────▼─────┐
    │  GATE     │  bash quality gates (auto-fix, max 3)
    └────┬─────┘  → lint + typecheck + tests
         │
    ┌────▼─────┐
    │  VERIFY   │  qa-expert subagent (adversarial)
    └────┬─────┘  → PASS / FAIL with evidence
         │
    ┌────▼─────┐
    │ DECISION  │  PASS → close
    └──────────┘  FAIL → corrective loop (max 2 cycles)
```
