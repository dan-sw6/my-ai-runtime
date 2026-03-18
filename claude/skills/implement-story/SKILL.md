# Skill: implement-story (base)
# End-to-end story implementation workflow.
# Product repos should customize file paths and quality gate commands.
---
name: implement-story
description: "End-to-end story implementation — plan, implement, test, verify."
trigger: "/implement-story <STORY-ID>"
---

## Workflow

1. **Read Story**: Load story file, extract acceptance criteria and requirement refs
2. **Plan**: Break into tasks, identify files, find existing patterns to reuse
3. **Implement**: One module per task, tests alongside code
4. **Quality Gates**: Run lint, typecheck, tests — all must pass
5. **Verify**: Check each acceptance criterion is met with evidence
6. **Update Traceability**: Update RTM for implemented requirements
7. **Report**: Produce summary with file changes, criteria status, gate results

## Rules
- One story at a time
- Do not modify BMAD state files
- Do not create Codex FILE-HANDOFF artifacts
- If a criterion cannot be met, report it
