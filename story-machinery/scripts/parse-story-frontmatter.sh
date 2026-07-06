#!/usr/bin/env bash
# parse-story-frontmatter.sh <story-file>
# Reads YAML frontmatter from a story markdown file and outputs it as compact JSON.
# Caller queries via jq. Single source of truth for story frontmatter parsing.
set -euo pipefail

STORY_FILE="${1:?Usage: $0 <story-file>}"

if [[ ! -f "$STORY_FILE" ]]; then
  echo '{"error":"story-file-not-found"}'
  exit 1
fi

python3 - "$STORY_FILE" <<'PY'
import sys, yaml, json
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
parts = text.split('---', 2)
if len(parts) < 3:
    print(json.dumps({"error": "no-frontmatter"}))
    sys.exit(1)
try:
    fm = yaml.safe_load(parts[1]) or {}
except yaml.YAMLError as e:
    print(json.dumps({"error": "yaml-parse-error", "detail": str(e)}))
    sys.exit(1)
print(json.dumps(fm, ensure_ascii=False))
PY
