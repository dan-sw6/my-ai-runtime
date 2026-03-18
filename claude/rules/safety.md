# Safety Rules

## Destructive Operations
Before executing any destructive operation, confirm with the user:
- `git reset --hard`, `git push --force`, `git checkout .`
- `rm -rf`, file deletion outside tracked scope
- Database DROP/TRUNCATE statements
- Killing processes, removing containers

## Reversibility
- Prefer reversible actions (new commit > amend, branch > checkout)
- Create backups before bulk operations
- Use `--dry-run` when available

## Shared State
Confirm before actions visible to others:
- Pushing to remote branches
- Creating/closing PRs or issues
- Modifying CI/CD pipelines
- Sending messages to external services

## Unknown State
When encountering unfamiliar files, branches, or configuration:
- Investigate before modifying or deleting
- It may be someone's in-progress work
- Ask before overwriting uncommitted changes
