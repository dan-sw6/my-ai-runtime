---
name: verify-story
description: "Verify a story is complete — criteria, gates, Definition of Done."
argument-hint: "<STORY-ID>"
---

## Workflow

1. **Load Criteria**: Read story file, list acceptance criteria
2. **Trace**: For each criterion, find implementing code and tests
3. **Run Gates**: Execute quality gate commands
4. **DoD Check**: Verify all Definition of Done items
5. **Verdict**: Produce PASS/FAIL with evidence

## Rules
- Be thorough — a PASS must be trustworthy
- Report only, do not fix issues
- Do not modify BMAD state
