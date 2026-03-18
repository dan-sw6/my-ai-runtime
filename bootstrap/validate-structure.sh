#!/usr/bin/env bash
# validate-structure.sh — Check product repo has required Claude infrastructure
set -euo pipefail

PRODUCT_DIR="${1:?Usage: validate-structure.sh <product-repo-path>}"
errors=0

check_dir() {
  if [[ ! -d "$PRODUCT_DIR/$1" ]]; then
    echo "MISSING: $1/"
    ((errors++)) || true
  else
    echo "OK: $1/"
  fi
}

check_file() {
  if [[ ! -f "$PRODUCT_DIR/$1" ]]; then
    echo "MISSING: $1"
    ((errors++)) || true
  else
    echo "OK: $1"
  fi
}

echo "=== Validating Claude infrastructure in $PRODUCT_DIR ==="
echo ""

check_file "CLAUDE.md"
check_dir ".claude/agents"
check_dir ".claude/skills"
check_file "scripts/sync-ai-runtime.sh"

# Check for at least one agent
agent_count=$(find "$PRODUCT_DIR/.claude/agents" -name "*.md" 2>/dev/null | wc -l)
if [[ "$agent_count" -eq 0 ]]; then
  echo "WARN: No agents found in .claude/agents/"
else
  echo "OK: $agent_count agents in .claude/agents/"
fi

# Check for at least one skill
skill_count=$(find "$PRODUCT_DIR/.claude/skills" -name "*.md" 2>/dev/null | wc -l)
if [[ "$skill_count" -eq 0 ]]; then
  echo "WARN: No skills found in .claude/skills/"
else
  echo "OK: $skill_count skills in .claude/skills/"
fi

echo ""
if [[ "$errors" -gt 0 ]]; then
  echo "FAIL: $errors missing items. Run bootstrap or sync."
  exit 1
else
  echo "PASS: All required structure present."
fi
