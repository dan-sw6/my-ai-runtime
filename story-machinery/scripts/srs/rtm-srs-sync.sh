#!/usr/bin/env bash
# rtm-srs-sync.sh REQ-ID — return canonical Status (from SRS) + RTM linkage for a requirement.
# Usage:
#   bash rtm-srs-sync.sh NFR-UI-002
#   bash rtm-srs-sync.sh NFR-UI-002 FR-PROJ-001    # multiple IDs
#
# OPTIONAL module: no-op (JSON `{"error":"srs-disabled"}`) when srs.enabled is false.
#
# Since 2026-05-06: status field живёт ТОЛЬКО в SRS (canonical) — RTM хранит только
# stories/files/tests/verified_at (no status). `rtm_status` always null + `in_sync: true`
# (один источник — drift невозможен) для backward-compat output shape.
#
# Output (compact JSON):
# {
#   "checked_at": "2026-05-06T...",
#   "items": [
#     {
#       "id": "NFR-UI-002",
#       "rtm_status": null,
#       "srs_status": "implemented",
#       "in_sync": true,
#       "rtm_stories": ["STORY-080","STORY-081","STORY-213"],
#       "rtm_verified_at": "2026-04-20"
#     }
#   ],
#   "drift_count": 0
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../runtime-config-read.sh"
rcfg_bool srs.enabled || { echo '{"error":"srs-disabled","items":[],"drift_count":0}'; exit 0; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo '{"error":"not-a-git-repo"}'; exit 1; }
SRS_FILE="${REPO_ROOT}/$(rcfg srs.srs_path docs/SRS.md)"
SRS_ARCHIVE="${REPO_ROOT}/$(rcfg srs.archive_path docs/srs/implemented-archive.md)"
RTM_FILE="${REPO_ROOT}/$(rcfg srs.rtm_path docs/rtm.yaml)"

if [[ $# -lt 1 ]]; then
  echo '{"error": "usage: rtm-srs-sync.sh REQ-ID [REQ-ID ...]"}' >&2
  exit 2
fi

python3 - "${SRS_FILE}" "${SRS_ARCHIVE}" "${RTM_FILE}" "$@" << 'PY'
import json, re, sys
from pathlib import Path

srs_path = Path(sys.argv[1])
srs_archive_path = Path(sys.argv[2])
rtm_path = Path(sys.argv[3])
req_ids = sys.argv[4:]

srs_active = srs_path.read_text() if srs_path.exists() else ""
srs_archive = srs_archive_path.read_text() if srs_archive_path.exists() else ""
# Active SRS first (wins on collision); archive carries delivered requirements.
srs = srs_active + "\n" + srs_archive
rtm = rtm_path.read_text() if rtm_path.exists() else ""

def rtm_entry(req_id: str):
    rx = re.search(rf'^  {re.escape(req_id)}:\s*\n((?:    .*\n)+)', rtm, re.MULTILINE)
    if not rx:
        return None
    block = rx.group(1)
    stories = re.search(r'^\s+stories:\s*\[(.*?)\]', block, re.MULTILINE)
    verified = re.search(r'^\s+verified_at:\s*"?([\d-]+)"?', block, re.MULTILINE)
    return {
        "stories": [s.strip() for s in stories.group(1).split(",")] if stories and stories.group(1).strip() else [],
        "verified_at": verified.group(1) if verified else None,
    }

def srs_entry(req_id: str):
    rx = re.search(rf'^####\s+{re.escape(req_id)}:\s.*?\n(.*?)(?=^####\s|\Z)', srs, re.MULTILINE | re.DOTALL)
    if not rx:
        return None
    block = rx.group(1)
    status = re.search(r'\|\s*\*\*Status\*\*\s*\|\s*([^\|]+?)\s*\|', block)
    return {
        "status": status.group(1).strip() if status else None,
    }

items = []
for rid in req_ids:
    r = rtm_entry(rid)
    s = srs_entry(rid)
    items.append({
        "id": rid,
        "rtm_status": None,                       # RTM no longer carries status (since 2026-05-06)
        "srs_status": s.get("status") if s else None,
        "in_sync": True,                          # single source — always in sync by construction
        "rtm_stories": r.get("stories") if r else [],
        "rtm_verified_at": r.get("verified_at") if r else None,
        "missing_in_rtm": r is None,
        "missing_in_srs": s is None,
    })

import time
print(json.dumps({
    "checked_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "items": items,
    "drift_count": 0,
}, ensure_ascii=False, separators=(",", ":")))
PY
