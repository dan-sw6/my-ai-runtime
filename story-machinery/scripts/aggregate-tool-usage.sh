#!/usr/bin/env bash
# aggregate-tool-usage.sh — Aggregate tool usage from per-session JSONL logs
# Usage: bash scripts/aggregate-tool-usage.sh SESSION-ID [--json]
#
# Reads: ${STATE_DIR}/tool-usage/{SESSION-ID}.jsonl
# Output: Human-readable summary or JSON with tool counts by type/server/skill
#
# Can also aggregate ALL sessions:
#   bash scripts/aggregate-tool-usage.sh --all [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

SESSION_ID="${1:?Usage: $0 SESSION-ID|--all [--json]}"
JSON_OUTPUT=0
ALL_MODE=0

if [[ "$SESSION_ID" == "--all" ]]; then
  ALL_MODE=1
  SESSION_ID=""
fi

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=1; shift ;;
    *) shift ;;
  esac
done

LOG_DIR="${STATE_DIR}/tool-usage"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "[INFO] No tool usage logs found"
  exit 0
fi

if [[ "$ALL_MODE" == "1" ]]; then
  INPUT_FILES="$LOG_DIR/*.jsonl"
else
  INPUT_FILES="$LOG_DIR/${SESSION_ID}.jsonl"
  if [[ ! -f "$LOG_DIR/${SESSION_ID}.jsonl" ]]; then
    echo "[INFO] No tool usage log for session: ${SESSION_ID}"
    exit 0
  fi
fi

JSON_OUT="$JSON_OUTPUT" python3 - $INPUT_FILES << 'PYEOF'
import json, sys, os
from collections import Counter, defaultdict
from pathlib import Path

json_output = os.environ.get("JSON_OUT", "0") == "1"
files = sys.argv[1:]

# Parse all JSONL entries
entries = []
for f in files:
    p = Path(f)
    if not p.exists():
        continue
    for line in p.read_text().strip().split('\n'):
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not entries:
    print("[INFO] No tool usage entries found")
    sys.exit(0)

# Aggregate
total_calls = len(entries)
by_type = Counter(e.get("type", "unknown") for e in entries)
by_tool = Counter(e.get("tool", "?") for e in entries)

# MCP breakdown
mcp_entries = [e for e in entries if e.get("type") == "mcp"]
by_mcp_server = Counter(e.get("mcp_server", "?") for e in mcp_entries)
by_mcp_tool = Counter(f'{e.get("mcp_server","?")}:{e.get("mcp_tool","?")}' for e in mcp_entries)

# Skill breakdown
skill_entries = [e for e in entries if e.get("type") == "skill"]
by_skill = Counter(e.get("skill", "?") for e in skill_entries)

# Builtin breakdown
builtin_entries = [e for e in entries if e.get("type") == "builtin"]
by_builtin = Counter(e.get("tool", "?") for e in builtin_entries)

if json_output:
    result = {
        "total_calls": total_calls,
        "by_type": dict(by_type),
        "mcp_calls": len(mcp_entries),
        "mcp_by_server": dict(by_mcp_server.most_common(20)),
        "mcp_top_tools": dict(by_mcp_tool.most_common(15)),
        "skill_calls": len(skill_entries),
        "skills_used": dict(by_skill.most_common(10)),
        "builtin_calls": len(builtin_entries),
        "builtin_top": dict(by_builtin.most_common(10)),
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
else:
    print(f"=== Tool Usage Summary ({total_calls} total calls) ===")
    print(f"  MCP: {len(mcp_entries)} | Skill: {len(skill_entries)} | Builtin: {len(builtin_entries)}")
    print()

    if by_mcp_server:
        print("=== MCP Servers ===")
        for server, count in by_mcp_server.most_common(15):
            pct = count / total_calls * 100
            print(f"  {server}: {count} calls ({pct:.0f}%)")
        print()

    if by_mcp_tool:
        print("=== Top MCP Tools ===")
        for tool, count in by_mcp_tool.most_common(10):
            print(f"  {tool}: {count}")
        print()

    if by_skill:
        print("=== Skills Used ===")
        for skill, count in by_skill.most_common(10):
            print(f"  {skill}: {count}")
        print()

    if by_builtin:
        print("=== Top Builtin Tools ===")
        for tool, count in by_builtin.most_common(10):
            print(f"  {tool}: {count}")
PYEOF
