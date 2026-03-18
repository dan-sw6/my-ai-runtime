# Module Scope Rules

## One Task = One Module = One Small Changeset
- Each task targets a single module or contour
- Don't mix features, refactoring, and formatting in one changeset
- Don't cross module boundaries without explicit planning

## Scope Discipline
- Avoid drive-by refactoring during feature work
- If you find issues outside your scope, note them for later
- Keep PRs focused and reviewable

## Shared Code
- Changes to shared utilities affect all consumers
- Test broadly when modifying `shared/` code
- Prefer narrow, well-typed interfaces
