# mgt-ai-runtime

Reusable AI workflow infrastructure for MGT projects.

## Purpose

This repository provides shared templates, base agent definitions, quality gates, and playbooks that are synced into product repositories. It is the **template source** — product repos are the **source of truth** for project-specific artifacts.

## Structure

```
docs/                  Architecture and onboarding guides
shared/templates/      Reusable story, task, handoff, closeout templates
shared/quality-gates/  Definition of Done, MCP matrix
shared/playbooks/      Operational playbooks (closed-loop, corrective, setup)
claude/agents/_base/   Base Claude Code subagent definitions
claude/skills/         Base Claude Code skill definitions
claude/settings/       Base Claude settings templates
claude/rules/          Shared safety, git, scope, secret rules
codex/agents/          Base Codex agent profiles
codex/prompts/         Base Codex role prompts
codex/templates/       Base governance templates (AGENTS.md, bmad)
bootstrap/             Scripts to scaffold a new product repo
sync/                  Sync manifest and engine
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
