# Closed-Loop Agent Cycle

## Overview

The closed-loop cycle is the core execution pattern for automated multi-agent delivery:

```
Planner → Implementer → Controller → (Planner if FAIL)
```

## Phases

### 1. Planner Phase
- Reads story, SRS sections, existing code structure
- Produces task breakdown with file-level specificity
- Creates handoff artifact (YAML) for implementer
- Specifies execution order (sequential or parallel with wave barriers)

### 2. Implementer Phase
- Reads planner handoff artifact
- Executes tasks in specified order
- Runs quality gates after each task (lint, typecheck)
- Runs full test suite after all tasks
- Creates handoff artifact (YAML) for controller with evidence

### 3. Controller Phase
- Reads implementer handoff artifact
- Verifies each acceptance criterion against implementation
- Runs independent quality gate checks
- Issues PASS or FAIL verdict

### 4. Corrective Loop (if FAIL)
- Controller handoff returns to planner with failure details
- Planner creates corrective task brief
- Cycle repeats until PASS or manual intervention

## Rules

- Each phase operates on FILE-HANDOFF artifacts (not conversation state)
- Agents must not skip phases or self-approve
- Quality gates are the shared verification layer between all phases
- BMAD state updates happen only at phase boundaries
