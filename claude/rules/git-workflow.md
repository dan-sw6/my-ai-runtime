# Git Workflow Rules

## Commit Conventions
- Prefixes: `feat|fix|test|docs|chore`
- Atomic commits after each logical change
- Focus the commit message on "why" not "what"

## Branch Safety
- Never rewrite history without explicit permission
- Never force-push to main/stable branches
- Create new commits rather than amending unless asked

## Pre-commit
- Never skip hooks (`--no-verify`) unless explicitly requested
- If a hook fails, fix the root cause

## Staging
- Stage specific files by name, not `git add -A`
- Avoid committing `.env`, credentials, or large binaries
