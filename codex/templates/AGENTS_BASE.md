# AGENTS.md — Base Template

This is a template for project-specific AGENTS.md governance files.
Customize sections marked with `[PROJECT]` for your project.

## 1. Core Principles

1. Modular work: one task = one module = one small changeset
2. [PROJECT] communication language
3. Plan before implementing
4. No destructive actions without consent
5. Source of Truth hierarchy: SRS > planning docs > context > memory

## 2. BMAD Governance

- Closed-loop workflow: Planner → Implementer → Controller
- Story tracking via BMAD sprint/workflow status
- Namespace guards for task versions

## 3. Project Invariants

- [PROJECT] database as operational SoT
- [PROJECT] canonical contours and paths
- No parallel contract changes to the same endpoint/schema

## 4. Closed-Loop Protocol

- FILE-HANDOFF is the canonical path for agent communication
- YAML validation required before handoff
- Handoff schemas in `docs/prompts/PROMPT_HANDOFF_SCHEMAS.md`

## 5. Quality Gates

- [PROJECT] lint command
- [PROJECT] type check command
- [PROJECT] test command

## 6. MCP Matrix

| Task Type | Required Servers | Optional |
|-----------|-----------------|----------|
| [PROJECT] | [PROJECT] | [PROJECT] |
