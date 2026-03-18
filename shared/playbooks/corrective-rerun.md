# Corrective Rerun Playbook

## When to Use

When the Controller issues a FAIL verdict on an implementation cycle.

## Process

### 1. Analyze Failure
Read the controller's handoff artifact. Identify:
- Which acceptance criteria failed
- Which quality gates failed
- Root cause (missing logic, wrong implementation, test gap, etc.)

### 2. Scope the Fix
- Create a minimal corrective task brief targeting only failed criteria
- Do NOT re-implement passing criteria
- Do NOT expand scope beyond the original story

### 3. Execute Correction
- Implementer receives corrective handoff
- Focuses only on failed items
- Runs full quality gates (not just the failed ones)

### 4. Re-verify
- Controller re-checks ALL criteria (not just previously failed ones)
- A fix for criterion A must not break criterion B

## Limits

- Maximum 3 corrective cycles before escalating to manual review
- If the same criterion fails 2+ times, flag for architectural review
- Corrective cycles must not introduce new features or scope changes
