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
- Operational playbooks
- Shared rules (safety, git, secrets)
- Sync manifest and engine
- Bootstrap scripts

### Product Repo Owns
- All project governance (AGENTS.md, CLAUDE.md)
- Requirements (SRS.md, rtm.yaml)
- Planning state (NOW.md, BACKLOG.md, DECISIONS.md)
- BMAD state (bmad/, docs/bmad/, docs/stories/)
- Task definitions (tasks/)
- Customized agent profiles (agents/, .claude/agents/)
- Codex skills (.codex/skills/)
- Role prompts (docs/prompts/)

## Dual-Runtime Coexistence

Product repos may run two AI agent runtimes simultaneously:

- **Codex**: Automated closed-loop delivery (Planner → Implementer → Controller). Operates via FILE-HANDOFF protocol in tmux sessions. Governed by AGENTS.md.
- **Claude Code**: Interactive development assistance. Operates in developer's terminal. Uses .claude/agents/ subagents and .claude/skills/ workflows.

These systems are complementary:
- They share quality gate scripts (lint, test, type)
- They share MCP server configurations
- They do NOT share state — Codex uses FILE-HANDOFF, Claude uses interactive conversation
- Claude agents must never modify BMAD state or create handoff artifacts

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
product-repo/.claude/agents/   (seed: create once)
product-repo/.claude/skills/   (seed: create once)
product-repo/.claude/rules/    (managed: always overwrite)
```
