# Corrective Rerun Playbook

## When to Use

When the controller/verifier issues a FAIL verdict on an implementation cycle.

## Process

### 1. Analyze Failure
Read the controller's verification report. Identify:
- Which acceptance criteria failed
- Which quality gates failed
- Root cause (missing logic, wrong implementation, test gap, etc.)

### 2. Scope the Fix
- Plan a minimal corrective task targeting only failed criteria
- Do NOT re-implement passing criteria
- Do NOT expand scope beyond the original story

### 3. Execute Correction
- Specialist agent receives corrective task
- Focuses only on failed items
- Runs full quality gates after fix (not just the failed ones)

### 4. Re-verify
- Controller re-checks ALL criteria (not just previously failed ones)
- A fix for criterion A must not break criterion B

## Limits

- Maximum 2 corrective cycles (3 total attempts including original)
- If the same criterion fails 2+ times, flag for architectural review
- Corrective cycles must not introduce new features or scope changes

## Runtime-Specific Notes

### Claude Code
- Coordinator (skill script) passes controller feedback to planner subagent
- Planner produces corrective plan scoped to failures only
- Same Phase 2-3-4 cycle with narrowed scope

### Codex
- Controller FILE-HANDOFF returns to supervisor with FAIL verdict
- Supervisor routes to planner with failure details
- Planner creates corrective task brief
