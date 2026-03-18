---
name: implement-story
description: "Closed-loop story delivery — coordinate planner, implementer, and controller phases with autonomous decision-making. Product repos should customize story paths, gate commands, and agent names."
argument-hint: "<STORY-ID>"
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
For each task in the plan, execute a two-step delegation:

**Step 1 — Prompt Synthesis**: Launch the **prompter** agent with the task details:
- Phase: IMPLEMENT
- Task contour (backend/frontend/full-stack/etc.)
- Task specifics from the plan (files, scope, what to do, tests)
- Story context and acceptance criteria
- Controller feedback (if corrective cycle)

**Step 2 — Execution**: Launch a **general-purpose** agent with:
- The **Execution Prompt** from the prompter's synthesis result
- Commit instructions (`feat:` or `fix:` prefix, module scope)

### Execution
- Sequential tasks: run Step 1 + Step 2 for each task in sequence
- Parallel tasks: prompter calls in parallel, then execution calls in parallel

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
Execute a two-step delegation for verification:

**Step 1 — Prompt Synthesis**: Launch the **prompter** agent with:
- Phase: VERIFY, contour: verification
- Story ID and story file path
- Role: adversarial controller — do NOT trust implementer evidence

**Step 2 — Execution**: Launch a **general-purpose** agent (higher-capability model) with:
- The **Execution Prompt** from the prompter's synthesis result
- Verification requirements: run gates independently, trace criteria to code, check scope creep, verify tests, issue PASS/FAIL verdict

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
