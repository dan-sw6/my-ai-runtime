#!/usr/bin/env bash
# migrate-phase-log.sh STORY-ID — convert legacy plain-text phase-log to JSON-lines v1.
#
# Usage:
#   bash scripts/migrate-phase-log.sh STORY-213
#   bash scripts/migrate-phase-log.sh STORY-213 --dry-run    # show output, don't write
#
# Legacy format examples (timestamped or bare):
#   phase-0-init
#   2026-04-20T13:00:00+03:00 phase-1-plan
#   phase-2-implement
#
# Output:
#   {state_dir}/story-{ID}/phase-log.migrated   (.v1 schema, JSON-lines)
# Original preserved as phase-log.legacy.
# Optional: --replace moves migrated back to phase-log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?usage: migrate-phase-log.sh STORY-ID [--dry-run|--replace]}"
MODE="${2:-}"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
STORY_DIR="${STATE_DIR}/story-$(printf '%s' "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"
LEGACY_LOG="${STORY_DIR}/phase-log"

if [[ ! -f "${LEGACY_LOG}" ]]; then
  echo "phase-log not found: ${LEGACY_LOG}" >&2
  exit 2
fi

python3 - "${LEGACY_LOG}" "${STORY_ID}" "${MODE}" << 'PY'
import json, re, sys
from datetime import datetime
from pathlib import Path

legacy = Path(sys.argv[1])
story_id = sys.argv[2]
mode = sys.argv[3]

out_lines = []
now_iso = datetime.now().astimezone().isoformat(timespec='seconds')

# Header: schema marker
out_lines.append(json.dumps({
    "schema": "v1",
    "story": story_id,
    "started": now_iso,
    "ts": now_iso,
    "migrated_from": "legacy-plain-text",
}, ensure_ascii=False, separators=(",", ":")))

# Parse each legacy line
for raw in legacy.read_text().splitlines():
    raw = raw.strip()
    if not raw:
        continue
    # Try "ISO8601 phase-N..." pattern
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T[\d:+\-Z]+)\s+(phase-.+)$', raw)
    if m:
        ts = m.group(1)
        phase_value = m.group(2)
    else:
        ts = now_iso
        phase_value = raw

    # phase_value examples: phase-2-implement, phase-2.1.5-simplify-skipped:reason
    m2 = re.match(r'^phase-(.+?)(?:-(complete|skipped|failed|blocked)(?::(.+))?)?$', phase_value)
    if not m2:
        out_lines.append(json.dumps({"ts": ts, "raw": raw, "status": "unparsed"},
                                    ensure_ascii=False, separators=(",", ":")))
        continue
    phase = m2.group(1)
    status = m2.group(2) or "start"
    reason = m2.group(3)

    obj = {"ts": ts, "phase": phase, "status": status}
    if reason:
        obj["reason"] = reason
    out_lines.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))

out_text = "\n".join(out_lines) + "\n"

if mode == "--dry-run":
    print(out_text)
    sys.exit(0)

migrated = legacy.parent / "phase-log.migrated"
migrated.write_text(out_text)
print(f"wrote migrated: {migrated}")

if mode == "--replace":
    legacy_backup = legacy.parent / "phase-log.legacy"
    legacy.rename(legacy_backup)
    migrated.rename(legacy)
    print(f"replaced; legacy backed up to {legacy_backup}")
PY
