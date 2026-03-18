# Codex Runtime (Secondary)

This directory contains base templates for the Codex automated agent runtime.

**Status**: Secondary runtime. Claude Code is the primary runtime for new work.

Codex remains available for batch/unattended execution scenarios. These templates are not actively developed but are maintained for compatibility with product repos that use the Codex layer.

## Contents

- `agents/` — Base Codex agent profiles (supervisor, planner, implementer, controller)
- `prompts/` — Role-specific prompt templates
- `templates/` — Governance templates (AGENTS.md base, bmad project config)

## Relationship to Claude Code

| Aspect | Claude Code (primary) | Codex (secondary) |
|--------|----------------------|-------------------|
| Coordinator | Skill script (inline) | Supervisor agent (tmux) |
| Communication | Subagent delegation | FILE-HANDOFF YAML |
| Closed loop | Variant C skill | FILE-HANDOFF cycle |
| Quality gates | Shared bash scripts | Shared bash scripts |
