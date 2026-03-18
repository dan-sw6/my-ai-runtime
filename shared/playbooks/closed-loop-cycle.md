# Closed-Loop Delivery Cycle

## Overview

The closed-loop cycle is the core execution pattern for multi-agent story delivery:

```
PLAN → IMPLEMENT → GATE → VERIFY → (PLAN if FAIL)
```

## Runtime Models

This playbook applies to both supported runtimes:

| | Claude Code (primary) | Codex (secondary) |
|---|---|---|
| Coordinator | Skill script (main instance) | Supervisor agent (tmux) |
| Communication | In-memory subagent delegation | FILE-HANDOFF YAML artifacts |
| Planner | story-planner subagent (read-only) | Planner agent (FILE-HANDOFF) |
| Implementer | Specialist subagents | Implementer agent (FILE-HANDOFF) |
| Controller | qa-expert subagent (adversarial) | Controller agent (FILE-HANDOFF) |
| Loop control | Skill decision rules | Supervisor routing |

## Phases

### 1. PLAN Phase
- Read story specification and extract acceptance criteria
- Cross-reference requirements with SRS
- Explore affected codebase areas
- Produce structured task breakdown with file-level specificity
- Assign each task to the appropriate specialist
- Specify execution order (sequential or parallel)

**Constraints**: Read-only — planner never modifies code.

### 2. IMPLEMENT Phase
- Execute each task using the assigned specialist
- Stay within module scope per task
- Write tests alongside implementation
- Commit atomically after each task
- Follow project conventions

**Constraints**: One module per task. No scope creep.

### 3. GATE Phase
- Run quality gates: lint, typecheck, tests
- If any fail: analyze, fix root cause, re-run (max 3 iterations)
- Never suppress errors to pass gates

**Constraints**: No `# noqa`, `@ts-ignore`, `--no-verify`.

### 4. VERIFY Phase
- Independent adversarial verification
- Run quality gates independently (do not trust implementer evidence)
- Trace each acceptance criterion to actual implementation
- Check for scope creep
- Issue PASS or FAIL verdict with evidence

**Constraints**: Verify-only — controller never fixes issues.

### 5. Corrective Loop (if FAIL)
- Scope fix to ONLY failed criteria
- Do not re-implement passing criteria
- Do not expand scope
- Maximum 2 corrective cycles (3 total attempts)
- If same criterion fails 2+ times, flag for architectural review
- Controller re-checks ALL criteria on each pass (not just previously failed)

## Decision Rules

### When to Proceed Automatically
- Single module affected, clear acceptance criteria
- Quality gates pass
- Controller issues PASS

### When to Stop and Ask
- 3+ modules affected (present plan for approval)
- Unmet story dependencies (blocked_by)
- Ambiguous acceptance criteria
- Quality gates fail after 3 fix attempts
- Controller FAIL after 3 total cycles

### When to Block Completion
- Any acceptance criterion not met
- Quality gates do not pass
- Scope creep detected (changes outside story scope)
- Missing tests for new behavior

## Quality Gates

Shared across all runtimes:
```bash
bash scripts/lint.sh    # Lint (ruff + tsc + governance)
bash scripts/type.sh     # Type check (mypy + tsc)
bash scripts/test.sh     # Full test suite
```
