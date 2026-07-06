#!/usr/bin/env bash
# apply-srs-pending.sh — coordinator single-writer SRS status sync from a worker's
# srs-pending.json. Replaces the PYSWEEP pseudo-code placeholder in
# run-stories/references/srs-status-sync.md (devcycle-audit #9/#10/#11/#12, 2026-05-29).
#
# OPTIONAL module: no-op when srs.enabled is false in runtime.config.yaml.
#
# For each proposed[] entry in <state_dir>/story-<lc>/srs-pending.json:
#   - SKIP the flip if review.json overall verdict == block.
#   - flip `| **Status** | ... |` in the SRS (srs.srs_path) detail block to proposed_status.
#   - if proposed_status==implemented OR move_to_archive==true:
#       * inject `| **Verified At** |` + `| **Story** |` rows after Status (if absent)
#       * append notes_delta to the `| **Notes** |` row (if non-empty)
#       * MOVE the whole `#### <req_id>: ...` block from the SRS to the archive
#         (srs.archive_path, under an auto-archive section)
#       * delete the summary-table row `| **<req_id>** | ... |` from the SRS  (#11)
#       * append <req_id> to the section `> **Delivered requirements:**` pointer (#10)
#   - rebuild RTM once at the end.
#
# Standalone-safe (#12): works for `/implement-story` runs outside `/run-stories`.
#
# Usage:
#   bash apply-srs-pending.sh STORY-ID            # DRY-RUN (default; prints plan)
#   bash apply-srs-pending.sh STORY-ID --apply    # write changes + rebuild-rtm
# Exit: 0 ok / no-op, 1 error. Idempotent: already-archived reqs are skipped.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../runtime-config-read.sh"
rcfg_bool srs.enabled || { echo '{"skipped":"srs-disabled","applied":false}'; exit 0; }

STORY_ID="${1:?Usage: $0 STORY-ID [--apply]}"
APPLY=0
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    *) echo "{\"error\":\"unknown-arg:$1\"}"; exit 1 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo '{"error":"not-a-git-repo"}'; exit 1; }
SID_LC="$(printf '%s' "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WD="${STATE_DIR}/story-${SID_LC}"
PENDING="${WD}/srs-pending.json"
REVIEW="${WD}/review.json"
SRS_REL="$(rcfg srs.srs_path docs/SRS.md)"
ARC_REL="$(rcfg srs.archive_path docs/srs/implemented-archive.md)"

[[ -s "$PENDING" ]] || { echo "{\"error\":\"no-srs-pending:${PENDING}\"}"; exit 1; }

VERDICT="pass"
[[ -s "$REVIEW" ]] && VERDICT="$(jq -r '.overall_verdict // .verdict // "pass"' "$REVIEW" 2>/dev/null || echo pass)"

APPLY="$APPLY" STORY_ID="$STORY_ID" VERDICT="$VERDICT" REPO_ROOT="$REPO_ROOT" \
SRS_REL="$SRS_REL" ARC_REL="$ARC_REL" \
python3 - "$PENDING" <<'PY'
import json, os, re, sys, pathlib

pending = json.load(open(sys.argv[1]))
apply = os.environ["APPLY"] == "1"
story = os.environ["STORY_ID"]
verdict = os.environ["VERDICT"]
root = pathlib.Path(os.environ["REPO_ROOT"])
srs = root / os.environ["SRS_REL"]
arc = root / os.environ["ARC_REL"]

if verdict == "block":
    print(json.dumps({"story": story, "skipped": "review-verdict-block", "applied": False}))
    sys.exit(0)

src = srs.read_text()
arc_src = arc.read_text()
actions = []

ARCHIVE_MARK = "## Auto-archived (apply-srs-pending.sh)\n"

def find_block(text, req_id):
    """Return (start, end) char offsets of the '#### <req_id>: ...' block (until next #### / ### / ##), or None."""
    m = re.search(r"^#### " + re.escape(req_id) + r":.*$", text, re.M)
    if not m:
        return None
    start = m.start()
    nxt = re.search(r"^(#### |### |## )", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    return (start, end)

# Accept both srs-pending schemas: coordinator canon {proposed:[{req_id}]}
# and the worker variant {requirements:[{requirement_ref}]} (STORY-549 drift, 2026-07-05).
for entry in (pending.get("proposed") or pending.get("requirements") or []):
    req = entry.get("req_id") or entry.get("requirement_ref")
    if not req:
        actions.append({"action": "skip-no-req-id", "entry": entry})
        continue
    new_status = entry.get("proposed_status", "implemented")
    to_archive = bool(entry.get("move_to_archive")) or new_status == "implemented"
    verified_at = entry.get("verified_at", "")
    notes_delta = entry.get("notes_delta", "")

    if ("#### " + req + ":") in arc_src:
        actions.append({"req": req, "action": "already-archived-skip"})
        continue

    blk = find_block(src, req)
    if not blk:
        actions.append({"req": req, "action": "block-not-found-in-SRS", "note": "may already be archived or never authored"})
        continue

    block_text = src[blk[0]:blk[1]]

    # flip status
    new_block = re.sub(r"(\|\s*\*\*Status\*\*\s*\|\s*)[a-z_]+(\s*\|)",
                       lambda mm: mm.group(1) + new_status + mm.group(2), block_text, count=1)

    if to_archive:
        # inject Verified At + Story rows after Status (if absent)
        if "**Verified At**" not in new_block and verified_at:
            new_block = re.sub(r"(\|\s*\*\*Status\*\*\s*\|[^\n]*\n)",
                               r"\1| **Verified At** | " + verified_at + r" |\n| **Story** | " + story + r" |\n",
                               new_block, count=1)
        # append notes_delta to Notes row
        if notes_delta:
            if "**Notes**" in new_block:
                new_block = re.sub(r"(\|\s*\*\*Notes\*\*\s*\|\s*)([^\n]*?)(\s*\|)",
                                   lambda mm: mm.group(1) + (mm.group(2).rstrip() + " — " + notes_delta) + mm.group(3),
                                   new_block, count=1)
            else:
                new_block = new_block.rstrip() + "\n| **Notes** | " + notes_delta + " |\n"

        # remove block from SRS, append to archive under auto-section
        src = src[:blk[0]] + src[blk[1]:]
        if ARCHIVE_MARK not in arc_src:
            arc_src = arc_src.rstrip() + "\n\n" + ARCHIVE_MARK + "\n"
        arc_src = arc_src.rstrip() + "\n\n" + new_block.rstrip() + "\n"

        # delete summary-table row
        row_re = re.compile(r"^\|\s*\*\*" + re.escape(req) + r"\*\*\s*\|.*\|\s*$\n?", re.M)
        n_rows = len(row_re.findall(src))
        src = row_re.sub("", src, count=1)

        # update section pointer (append req to nearest preceding '> **Delivered requirements:**')
        ptr_re = re.compile(r"(> \*\*Delivered requirements:\*\* [^\n]*)")
        ptrs = list(ptr_re.finditer(src))
        ptr_updated = False
        if ptrs:
            # heuristic: the pointer of the req's category — append to ALL? No: append to the one
            # whose existing IDs share the req prefix (e.g. NFR-SEC). Fallback: last pointer.
            prefix = re.match(r"([A-Z]+-[A-Z0-9]+)-", req)
            target = None
            if prefix:
                pfx = prefix.group(1)
                for pm in ptrs:
                    if pfx in pm.group(1):
                        target = pm
                        break
            target = target or ptrs[-1]
            if req not in target.group(1):
                src = src[:target.start()] + target.group(1) + ", " + req + src[target.end():]
                ptr_updated = True

        actions.append({"req": req, "action": "archived", "status": new_status,
                        "summary_row_removed": n_rows >= 1, "pointer_updated": ptr_updated})
    else:
        src = src[:blk[0]] + new_block + src[blk[1]:]
        actions.append({"req": req, "action": "status-flip-in-place", "status": new_status})

result = {"story": story, "applied": apply, "verdict": verdict, "actions": actions}

if apply and any(a["action"] in ("archived", "status-flip-in-place") for a in actions):
    srs.write_text(src)
    arc.write_text(arc_src)
    result["written"] = [os.environ["SRS_REL"], os.environ["ARC_REL"]]

print(json.dumps(result, ensure_ascii=False, indent=2))
PY
RC=$?

if [[ "$APPLY" == "1" && $RC -eq 0 ]]; then
  echo "[apply-srs-pending] rebuilding RTM..." >&2
  ( cd "$REPO_ROOT" && bash "$SCRIPT_DIR/rebuild-rtm.sh" >&2 ) || true
fi
exit $RC
