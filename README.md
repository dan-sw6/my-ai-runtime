# mgt-ai-runtime

Reusable AI workflow infrastructure for MGT projects.

## Purpose

This repository provides shared templates, base agent definitions, quality gates, and playbooks that are synced into product repositories. It is the **template source** — product repos are the **source of truth** for project-specific artifacts.

## Structure

```
claude/                    Claude Code runtime (PRIMARY)
├── agents/_base/          Base subagent definitions (12 agents, VoltAgent-sourced)
├── skills/                Base skill definitions (closed-loop coordinator, etc.)
├── rules/                 Shared safety, git, scope, secret rules
└── settings/              Base settings templates

shared/                    Shared resources
├── quality-gates/         Definition of Done, MCP matrix
├── playbooks/             Operational playbooks (closed-loop, corrective, setup)
└── templates/             Story, task, handoff, closeout templates

codex/                     Codex runtime (SECONDARY, legacy)
├── agents/                Base Codex agent profiles
├── prompts/               Base Codex role prompts
└── templates/             Governance templates (AGENTS.md, bmad)

bootstrap/                 Scripts to scaffold new product repos
sync/                      Sync manifest and engine
docs/                      Architecture and onboarding guides
```

## Sync Model

Sync is **one-way**: runtime → product. Three modes:

| Mode | Behavior |
|---|---|
| `seed` | Create target only if it does not exist. Project customizations preserved. |
| `managed` | Always overwrite target. Runtime owns these files. |
| `template` | Create if missing, warn if source is newer than target. |

Product-specific files (SRS, RTM, AGENTS.md, stories, tasks, BMAD state) are **never synced**.

## Usage

From a product repo:

```bash
bash scripts/sync-ai-runtime.sh              # Apply sync
bash scripts/sync-ai-runtime.sh --dry-run    # Preview changes only
bash scripts/sync-ai-runtime.sh --force      # Overwrite even seed files
```

## Bootstrap a New Project

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh /path/to/product-repo
```

## Closed-Loop Delivery

The primary delivery model is Claude-native closed loop (Variant C — skill-as-coordinator):

```
/implement-story STORY-ID
  → PLAN (story-planner, read-only)
  → IMPLEMENT (specialist subagents)
  → GATE (bash quality gates, auto-fix)
  → VERIFY (qa-expert, adversarial)
  → PASS / corrective loop
```

See `shared/playbooks/closed-loop-cycle.md` and `docs/ARCHITECTURE.md` for details.
