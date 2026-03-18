# Skill: update-rtm (base)
# Update Requirements Traceability Matrix after changes.
---
name: update-rtm
description: "Update RTM to reflect current implementation status."
trigger: "/update-rtm [scope]"
---

## Workflow

1. **Identify Scope**: Changed files from git diff or explicit scope
2. **Read RTM**: Current traceability state
3. **Map to Requirements**: Cross-reference changed code with requirement IDs
4. **Update Entries**: Set status, add file/test references
5. **Report**: Coverage delta, gaps, orphan entries

## Rules
- Update status fields only, not requirement definitions
- Be conservative — mark `implemented` only with code AND test evidence
- Do not modify the SRS
