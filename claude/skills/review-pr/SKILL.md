---
name: review-pr
description: "Comprehensive PR review using specialized agents"
argument-hint: "[review-aspects]"
---

# Comprehensive PR Review

Run a comprehensive pull request review, delegating to specialized subagents where the repo has them, otherwise performing each review pass directly.

**Review Aspects (optional):** "$ARGUMENTS"

## Review Workflow:

1. **Determine Review Scope**
   - Check git status to identify changed files
   - Parse arguments to see if user requested specific review aspects
   - Default: Run all applicable review dimensions

2. **Available Review Dimensions:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable dimensions (default)

3. **Identify Changed Files**
   - Run `git diff --name-only` to see modified files
   - Check if PR already exists: `gh pr view`
   - Identify file types and which dimensions apply

4. **Determine Applicable Dimensions**

   Based on changes:
   - **Always applicable**: general code quality review
   - **If test files changed**: test-coverage review
   - **If comments/docs added**: comment-accuracy review
   - **If error handling changed**: silent-failure review
   - **If types added/modified**: type-design review
   - **After passing review**: simplification pass (polish, preserve behavior)

5. **Run Each Dimension**

   **Preferred — delegate to a subagent** if this repo has one mapped to the dimension (e.g. a `code-reviewer` agent for general quality, `qa-expert` for test coverage, `architect-reviewer` for type/API design, `accessibility-tester` for a11y). Check `.claude/agents/` for what's actually configured before assuming a name.

   **Fallback — do the pass yourself** as the coordinator when no matching subagent exists. Read the diff, apply the same checklist a dedicated reviewer would, and produce the same structured findings.

   **Sequential vs parallel**: sequential is easier to act on one dimension at a time; parallel (user can request) is faster for a full sweep when multiple subagents are available.

6. **Aggregate Results**

   After all dimensions complete, summarize:
   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

7. **Provide Action Plan**

   Organize findings:
   ```markdown
   # PR Review Summary

   ## Critical Issues (X found)
   - [dimension]: Issue description [file:line]

   ## Important Issues (X found)
   - [dimension]: Issue description [file:line]

   ## Suggestions (X found)
   - [dimension]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR

   ## Recommended Action
   1. Fix critical issues first
   2. Address important issues
   3. Consider suggestions
   4. Re-run review after fixes
   ```

## Usage Examples:

**Full review (default):**
```
/review-pr
```

**Specific aspects:**
```
/review-pr tests errors
# Reviews only test coverage and error handling

/review-pr comments
# Reviews only code comments

/review-pr simplify
# Simplifies code after passing review
```

**Parallel review:**
```
/review-pr all parallel
# Runs all dimensions in parallel (requires subagents mapped for each)
```

## Review Dimension Descriptions:

**comments**:
- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**tests**:
- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**errors**:
- Finds silent failures
- Reviews catch blocks
- Checks error logging

**types**:
- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**code**:
- Checks project-convention compliance (CLAUDE.md / equivalent)
- Detects bugs and issues
- Reviews general code quality

**simplify**:
- Simplifies complex code
- Improves clarity and readability
- Applies project standards
- Preserves functionality

## Tips:

- **Run early**: Before creating PR, not after
- **Focus on changes**: Review the diff by default, not the whole tree
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use specific dimensions**: Target specific aspects when you know the concern

## Workflow Integration:

**Before committing:**
```
1. Write code
2. Run: /review-pr code errors
3. Fix any critical issues
4. Commit
```

**Before creating PR:**
```
1. Stage all changes
2. Run: /review-pr all
3. Address all critical and important issues
4. Run specific dimensions again to verify
5. Create PR
```

**After PR feedback:**
```
1. Make requested changes
2. Run targeted dimensions based on feedback
3. Verify issues are resolved
4. Push updates
```

## Notes:

- Whether each dimension runs as a dedicated subagent or as a direct pass by the coordinator depends on what's configured in this repo — check before assuming an agent name exists
- Results are actionable with specific file:line references
- Re-verify after every fix round before considering the PR ready
