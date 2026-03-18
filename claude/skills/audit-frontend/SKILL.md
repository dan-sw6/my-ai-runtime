---
name: audit-frontend
description: "Audit frontend for patterns, TypeScript, accessibility, and design system."
argument-hint: "[path]"
---

## Workflow

1. **Scope**: Default to main frontend source directory
2. **Pattern Audit**: Component patterns, state management, data fetching
3. **TypeScript Audit**: Strict compliance, type coverage, unused exports
4. **Accessibility Audit**: Semantic HTML, ARIA, keyboard, contrast
5. **Design System**: Consistent styling, state coverage, responsive
6. **Report**: Categorized findings (Critical > Warning > Info)

## Rules
- Report only, do not apply fixes
- Reference specific file paths and line numbers
- Frontend code only
