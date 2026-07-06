#!/usr/bin/env bash
# PreToolUse:Bash — block genuinely destructive / irreversible git operations.
# Normal `git push` (fast-forward), `git reset --hard <ref>` (reflog-recoverable),
# and `git branch -D` (routine merged-branch delete) are ALLOWED. Blocked:
#   * force-push (rewrites shared history): --force / -f / --force-with-lease / +refspec
#   * bulk untracked-file deletion: git clean -f[d]
#   * wholesale discard of working changes: git checkout . / git restore .
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

DANGEROUS_PATTERNS=(
  "git push[^|;&]*--force"
  "git push[^|;&]*--force-with-lease"
  "git push[^|;&]*[[:space:]]-f([[:space:]]|$)"
  "git push[^|;&]*[[:space:]][+][A-Za-z0-9_./-]+:"
  "git clean[[:space:]]+-[A-Za-z]*f"
  "git checkout[[:space:]]+\\.([[:space:]]|$)"
  "git restore[[:space:]]+\\.([[:space:]]|$)"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    echo "BLOCKED: '$COMMAND' matches dangerous pattern '$pattern'. The user has prevented you from doing this." >&2
    exit 2
  fi
done
exit 0
