# Skill: implement-story (base)
# Closed-loop story delivery coordinator (Variant C).
# Product repos should customize story paths, gate commands, and agent names.
---
name: implement-story
description: "Closed-loop story delivery — coordinate planner, implementer, and controller phases with autonomous decision-making."
trigger: "/implement-story <STORY-ID>"
---

## Role

You are the **coordinator** of a closed-loop delivery cycle. You orchestrate four phases — PLAN, IMPLEMENT, GATE, VERIFY — delegating domain work to specialist subagents while retaining decision authority.

You do not implement or verify directly. You delegate, evaluate results, and decide next actions.

## Phase 1: PLAN

### Action
Launch a **planner** agent (read-only) to decompose the story into ordered tasks.

The planner must:
- Read the story file and extract acceptance criteria, requirement refs, technical notes
- Cross-reference requirements with SRS
- Explore affected codebase areas
- Produce a structured plan with file-level task specificity and agent assignments

### Decision Rules
- **Plan received, all criteria covered** → proceed to Phase 2
- **Plan flags unmet dependency** → STOP, report blocker to user
- **Plan flags ambiguous criteria** → STOP, ask user for clarification
- **3+ modules affected** → present plan to user, wait for approval
- **Single module, clear scope** → proceed automatically

## Phase 2: IMPLEMENT

### Action
For each task in the plan, launch the appropriate specialist agent.

Assign agents by task contour:
- Backend/API/services → backend specialist
- Frontend/UI/components → frontend specialist
- Language-specific complexity → language specialist

Pass to each agent: the specific task, files, tests to write, and commit instructions.

### Execution
- Sequential tasks: one at a time, wait for completion
- Parallel tasks: launch concurrently using parallel Agent calls

### Decision Rules
- **Agent completes task** → proceed to next task or Phase 3
- **Agent reports scope issue** → evaluate: minor adjacent = allow, cross-module = re-plan
- **Agent reports blocker** → STOP, ask user
- **Agent cannot complete** → note failure, proceed to Phase 3 (gates will catch it)

## Phase 3: GATE

### Action
Run quality gates:
```bash
bash scripts/lint.sh
bash scripts/type.sh
bash scripts/test.sh --fast
```

### Auto-Fix Loop (max 3 iterations)
If any gate fails:
1. Analyze failure output — identify root cause
2. Fix root cause directly (no suppressions)
3. Re-run failed gate, then ALL gates
4. After 3 failed attempts → STOP, report to user

## Phase 4: VERIFY

### Action
Launch a **verification** agent (adversarial, higher-capability model) to:
1. Run quality gates independently (do not trust implementer evidence)
2. Trace each acceptance criterion to actual code
3. Check for scope creep
4. Verify tests exist for changed behavior
5. Issue PASS or FAIL verdict with per-criterion evidence

### Decision Rules
- **PASS** → proceed to CLOSE
- **FAIL (1st or 2nd time)** → corrective cycle
- **FAIL (3rd time)** → STOP, report with full evidence

## Corrective Cycle

On FAIL:
1. Extract failed criteria and evidence from controller report
2. Return to Phase 1 with controller feedback — plan ONLY fixes for failed criteria
3. Execute corrective plan through Phases 2-3-4
4. Maximum 2 corrective cycles (3 total attempts)

## CLOSE

After PASS:
1. **Update traceability** — set implemented status for covered requirement refs
2. **Produce report** — summary, per-criterion status, gate results, files changed, corrective history

## Invariant Rules

1. Do not modify BMAD state files
2. Do not create FILE-HANDOFF artifacts
3. One story at a time
4. One module per task
5. No silent failures — report what cannot be met
6. No suppressions to pass gates
7. Atomic commits with conventional prefixes
