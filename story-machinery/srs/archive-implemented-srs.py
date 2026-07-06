#!/usr/bin/env python3
"""Sweep implemented requirements from active SRS to implemented-archive + sync §7 counts + §6 Not Started table.

OPTIONAL module (gated by `srs.enabled` in runtime.config.yaml) — see srs/README.md.
Ported from mgt-openproject scripts/archive-implemented-srs.py; parsing logic unchanged,
only the paths (srs.srs_path / srs.archive_path) are config-driven instead of hardcoded docs/*.

Usage:
    python3 archive-implemented-srs.py [--dry-run]

Reads the active SRS, finds `#### XXX:` requirement blocks где
`| **Status** | implemented |` (case-insensitive), and moves them to
the archive doc под matching section heading.

After move:
- §7 Implementation Status counts recomputed from active-block statuses
  (partial / not_started / deprecated; "implemented" count from archive total).
- §7 "Active SRS Total" line (если есть) recomputed.
- §6 "Not Started (priority work)" table — rows whose req_id больше не в active SRS
  (полностью архивированы) удаляются. Multi-ID rows: остаются если ≥1 referenced
  req всё ещё active.

Idempotent: re-runs safely (no-op if nothing to move + counts already in sync).

Policy 2026-05-22: active SRS contains ONLY partial/not_started/deprecated.
Any implemented entry is auto-archived during /run-stories Phase B.1.6.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]  # config load degrades to defaults below


def _repo_root() -> Path:
    """Resolve the product repo root — git toplevel, falling back to cwd."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        )
        return Path(out.stdout.strip())
    except Exception:
        return Path.cwd()


def _load_srs_cfg() -> dict:
    """Read runtime.config.yaml `srs:` block — env override, safe defaults.

    Config resolution matches runtime-config-read.sh: $AI_RUNTIME_CONFIG, else
    ${CLAUDE_PROJECT_DIR:-.}/runtime.config.yaml. Missing file/key/PyYAML → defaults
    (srs.enabled defaults to False so main() no-ops).
    """
    cfg_path = Path(
        os.environ.get("AI_RUNTIME_CONFIG")
        or (os.environ.get("CLAUDE_PROJECT_DIR", ".") + "/runtime.config.yaml")
    )
    defaults = {
        "enabled": False,
        "srs_path": "docs/SRS.md",
        "archive_path": "docs/srs/implemented-archive.md",
        "rtm_path": "docs/rtm.yaml",
        "req_id_prefixes": ["FR", "NFR", "SEC"],
        "ac_notation": "ears",
    }
    if yaml is None:
        return defaults
    try:
        data = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
    except Exception:
        return defaults
    return {**defaults, **(data.get("srs") or {})}


_CFG = _load_srs_cfg()
REPO_ROOT = _repo_root()
SRS_PATH = REPO_ROOT / _CFG["srs_path"]
ARC_PATH = REPO_ROOT / _CFG["archive_path"]

# Heading patterns. Active SRS uses ### N.N sub-sections; archive uses ## N.N
# (wider top-level — content extracted from SRS as standalone document).
SRS_SECTION_RE = re.compile(r"^### (\d+\.\d+)\s+(.+?)\s*$", re.MULTILINE)
ARC_SECTION_RE = re.compile(r"^## (\d+\.\d+)\s+(.+?)\s*$", re.MULTILINE)
REQ_RE = re.compile(r"^#### ([A-Z][A-Z0-9-]+):\s*(.+?)$", re.MULTILINE)
STATUS_RE = re.compile(r"\|\s*\*\*Status\*\*\s*\|\s*(\w+)\s*\|", re.IGNORECASE)

# Not Started table row: `| FR-XXX-NNN | ... | Priority |` или `| **FR-XXX-NNN** | ... |`
# Allows multi-ID rows: `FR-DOMAIN-007..008`, `FR-DOMAIN-022..023, 025`, etc.
NOT_STARTED_ROW_RE = re.compile(
    r"^\|\s*\*{0,2}([A-Z][A-Z0-9-]+(?:\.\.[0-9]+)?(?:,\s*[0-9]+)*)\*{0,2}\s*\|.+?\|.+?\|\s*$",
    re.MULTILINE,
)

# Implementation Status table rows
STATUS_ROW_RE = re.compile(
    r"^\|\s*(implemented|partial|not_started|deprecated)\s*\|\s*(\d+)\s*\|(.*)\|\s*$",
    re.MULTILINE,
)


def parse_blocks(
    text: str, section_re: re.Pattern[str]
) -> tuple[dict[str, list[tuple[int, int, str]]], list[tuple[str, str, int]]]:
    """Return (blocks_by_section, sections_list).

    blocks_by_section[section_key] = list of (start_offset, end_offset, req_id)
    sections_list = list of (section_key, section_title, start_offset)
    """
    sections = []
    for sm in section_re.finditer(text):
        sections.append((sm.group(1), sm.group(2), sm.start()))

    blocks_by_section: dict[str, list[tuple[int, int, str]]] = {s[0]: [] for s in sections}

    # Find all #### blocks; each block goes from its heading to next #### or next ## boundary
    req_matches = list(REQ_RE.finditer(text))
    for i, rm in enumerate(req_matches):
        req_id = rm.group(1)
        start = rm.start()
        # End is start of next #### OR next ## OR EOF
        next_req_start = req_matches[i + 1].start() if i + 1 < len(req_matches) else len(text)
        next_section_start = len(text)
        for s in sections:
            if s[2] > start:
                next_section_start = s[2]
                break
        end = min(next_req_start, next_section_start)

        # Find which section this block belongs to
        owning_section = None
        for s in sections:
            if s[2] < start:
                owning_section = s[0]
        if owning_section is None:
            continue
        blocks_by_section[owning_section].append((start, end, req_id))

    return blocks_by_section, sections


def block_status(block_text: str) -> str | None:
    m = STATUS_RE.search(block_text)
    return m.group(1).lower() if m else None


def collect_active_status_counts(srs_text: str) -> dict[str, int]:
    """Count active blocks (post-archive) by Status."""
    counts: dict[str, int] = {"implemented": 0, "partial": 0, "not_started": 0, "deprecated": 0}
    req_matches = list(REQ_RE.finditer(srs_text))
    for i, rm in enumerate(req_matches):
        start = rm.start()
        end = req_matches[i + 1].start() if i + 1 < len(req_matches) else len(srs_text)
        # Limit to first 30 lines of block for performance
        block_excerpt = srs_text[start:end][:2000]
        status = block_status(block_excerpt)
        if status in counts:
            counts[status] += 1
    return counts


def collect_active_req_ids(srs_text: str) -> set[str]:
    """Return set of req IDs that have active `#### XXX:` block в active SRS."""
    return {m.group(1) for m in REQ_RE.finditer(srs_text)}


def expand_row_ids(token: str) -> list[str]:
    """Expand `FR-DOMAIN-007..008` / `FR-DOMAIN-022..023, 025` → list of IDs.

    Returns ['FR-DOMAIN-007', 'FR-DOMAIN-008'] etc.
    Single IDs return [id]. Comma-separated suffixes share the prefix from first token.
    """
    # Split on ", " then handle each piece
    pieces = [p.strip() for p in token.split(",")]
    out: list[str] = []
    base_prefix: str | None = None
    for piece in pieces:
        # piece может быть `FR-X-007` или `FR-X-007..009` или `025` (suffix)
        m = re.match(r"^([A-Z][A-Z0-9-]+?)-(\d+)(?:\.\.(\d+))?$", piece)
        if m:
            prefix, lo, hi = m.group(1), int(m.group(2)), m.group(3)
            base_prefix = prefix
            hi_int = int(hi) if hi else lo
            for n in range(lo, hi_int + 1):
                out.append(f"{prefix}-{n:03d}")
        elif piece.isdigit() and base_prefix:
            n = int(piece)
            out.append(f"{base_prefix}-{n:03d}")
        else:
            out.append(piece)
    return out


def sync_not_started_table(srs_text: str, active_ids: set[str]) -> tuple[str, int]:
    """Drop rows from "Not Started (priority work)" table where ALL referenced
    req IDs больше не в active SRS.

    Returns (new_text, removed_count).
    """
    # Find the "Not Started (priority work)" section heading
    marker = "### Not Started (priority work)"
    idx = srs_text.find(marker)
    if idx == -1:
        return srs_text, 0
    # Section ends at next ## or ### heading
    rest = srs_text[idx:]
    next_section = re.search(r"^(?:## |### )", rest[len(marker) :], re.MULTILINE)
    if next_section:
        section_end = idx + len(marker) + next_section.start()
    else:
        section_end = len(srs_text)
    section_text = srs_text[idx:section_end]

    removed = 0
    new_section_lines: list[str] = []
    for line in section_text.splitlines(keepends=True):
        stripped = line.lstrip()
        # Only attempt prune on data rows (start with `|`, not header/separator)
        is_table_row = stripped.startswith("|") and "---" not in line and not stripped.startswith("| Req ID")
        if is_table_row:
            m = NOT_STARTED_ROW_RE.match(line)
            if m:
                token = m.group(1)
                ids = expand_row_ids(token)
                # Keep row if ≥1 referenced ID still active
                if not any(i in active_ids for i in ids):
                    removed += 1
                    continue
        new_section_lines.append(line)

    new_section = "".join(new_section_lines)
    return srs_text[:idx] + new_section + srs_text[section_end:], removed


def sync_status_counts(srs_text: str, active_counts: dict[str, int], archive_impl_total: int) -> tuple[str, bool]:
    """Update §7 Implementation Status table counts.

    - implemented row → archive_impl_total (cumulative)
    - partial / not_started / deprecated rows → active counts
    Returns (new_text, changed).
    """
    changed = False
    new_text = srs_text
    desired = {
        "implemented": archive_impl_total,
        "partial": active_counts.get("partial", 0),
        "not_started": active_counts.get("not_started", 0),
        "deprecated": active_counts.get("deprecated", 0),
    }
    for m in list(STATUS_ROW_RE.finditer(new_text)):
        status = m.group(1)
        current = int(m.group(2))
        target = desired.get(status)
        if target is None or current == target:
            continue
        old_row = m.group(0)
        # Replace count в second column
        new_row = re.sub(
            r"^\|\s*" + re.escape(status) + r"\s*\|\s*\d+\s*\|",
            f"| {status} | {target} |",
            old_row,
            count=1,
            flags=re.MULTILINE,
        )
        new_text = new_text.replace(old_row, new_row, 1)
        changed = True
    return new_text, changed


# Match "Genuine remaining: ...<tokens>." — tokens may contain ".." range notation,
# so stop only at a lone "." (not "..") followed by whitespace / end-of-cell.
_GENUINE_RE = re.compile(r"Genuine remaining:\s*((?:(?!\.\s|\.$).)+)\.")


def _extract_base_ids(token: str) -> list[str]:
    """Extract full requirement IDs from one prose token.

    Examples:
        'FR-2FA-001 AC7'         → ['FR-2FA-001']
        'FR-RBAC-014/015'        → ['FR-RBAC-014', 'FR-RBAC-015']
        'NFR-QUAL-008/016/017'   → ['NFR-QUAL-008', 'NFR-QUAL-016', 'NFR-QUAL-017']
        'FR-DOMV2-001..008 (post-MVP)' → ['FR-DOMV2-001']  (range — treat as single)
    """
    # Strip parenthetical qualifier
    base = re.sub(r"\s*\([^)]+\)", "", token).strip()
    # Drop trailing "AC<N>" qualifiers
    base = re.sub(r"\s+AC\d+.*$", "", base).strip()
    if ".." in base:
        # Range — keep only the first ID as representative
        return [base.split("..")[0].split("/")[0]]
    # Match "PREFIX-NUMBER" or "PREFIX-NUMBER/NUMBER/..."
    m = re.match(r"^([A-Z]+(?:-[A-Z0-9]+)*?)-(\d+(?:/\d+)*)$", base)
    if not m:
        return []
    prefix = m.group(1)
    nums = m.group(2).split("/")
    return [f"{prefix}-{n}" for n in nums]


def _update_srs_status_prose(archived_ids: list[str], srs_text: str) -> tuple[str, bool]:
    """Drop tokens matching archived_ids from §7 not_started row "Genuine remaining: ..." prose.

    Idempotent: returns (srs_text, False) when nothing to drop.
    Supports partial token drop for slash-joined IDs (e.g. 'FR-RBAC-014/015').
    """
    if not archived_ids:
        return srs_text, False
    m = _GENUINE_RE.search(srs_text)
    if not m:
        return srs_text, False

    archived_set = {a.strip() for a in archived_ids}
    raw = m.group(1)
    tokens = [t.strip() for t in raw.split(",")]
    kept: list[str] = []
    for tok in tokens:
        base_ids = _extract_base_ids(tok)
        if not base_ids:
            # Unrecognised token format — keep as-is
            kept.append(tok)
            continue
        remaining = [bid for bid in base_ids if bid not in archived_set]
        if not remaining:
            continue  # all IDs in this token archived — drop entire token
        if len(remaining) == len(base_ids):
            kept.append(tok)  # nothing removed in this token
        else:
            # Partial drop — emit compact form "PREFIX-N1/N2" so re-parse on next
            # run still recognises the token (idempotency contract — AC10).
            qualifier = ""
            q_match = re.search(r"(\s*\([^)]+\))$", tok)
            if q_match:
                qualifier = q_match.group(1)
            prefix = remaining[0].rsplit("-", 1)[0]
            suffixes = [rid.rsplit("-", 1)[-1] for rid in remaining]
            kept.append(f"{prefix}-{'/'.join(suffixes)}{qualifier}")

    new_sentence = "Genuine remaining: " + ", ".join(kept) + "."
    if new_sentence == m.group(0):
        return srs_text, False
    new_text = srs_text[: m.start()] + new_sentence + srs_text[m.end() :]
    return new_text, True


def main() -> int:
    if not _CFG.get("enabled"):
        print("[srs] disabled")
        return 0

    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true", help="Show plan without writing files")
    args = parser.parse_args()

    if not SRS_PATH.exists():
        print(f"ERROR: {SRS_PATH} not found", file=sys.stderr)
        return 1
    if not ARC_PATH.exists():
        print(f"ERROR: {ARC_PATH} not found", file=sys.stderr)
        return 1

    srs_text = SRS_PATH.read_text()
    arc_text = ARC_PATH.read_text()

    srs_blocks, srs_sections = parse_blocks(srs_text, SRS_SECTION_RE)
    _arc_blocks, arc_sections = parse_blocks(arc_text, ARC_SECTION_RE)

    section_titles = {s[0]: s[1] for s in srs_sections}
    arc_section_keys = {s[0] for s in arc_sections}

    # Collect implemented blocks
    to_move: list[tuple[str, str, int, int, str]] = []  # (section_key, req_id, start, end, block_text)
    for sec_key, blocks in srs_blocks.items():
        for start, end, req_id in blocks:
            block_text = srs_text[start:end]
            status = block_status(block_text)
            if status == "implemented":
                to_move.append((sec_key, req_id, start, end, block_text))

    if to_move:
        print(f"[archive-srs] found {len(to_move)} implemented requirements to archive:")
        by_section: dict[str, list[str]] = {}
        for sec_key, req_id, *_ in to_move:
            by_section.setdefault(sec_key, []).append(req_id)
        for sk in sorted(by_section):
            print(f"  §{sk} {section_titles.get(sk, '???')}: {', '.join(by_section[sk])}")
    else:
        print("[archive-srs] no implemented requirements in active SRS — checking §6/§7 drift only")

    # Build new active SRS: remove blocks (reverse order to preserve offsets)
    new_srs = srs_text
    for sec_key, req_id, start, end, block_text in sorted(to_move, key=lambda x: -x[2]):
        new_srs = new_srs[:start] + new_srs[end:]

    # Build new archive: append blocks under their section
    # Group by section
    section_appends: dict[str, list[str]] = {}
    for sec_key, req_id, _, _, block_text in to_move:
        section_appends.setdefault(sec_key, []).append(block_text)

    new_arc = arc_text
    for sec_key in sorted(section_appends.keys()):
        # Find section in archive
        if sec_key not in arc_section_keys:
            # Section doesn't exist in archive — append new section at end
            section_title = section_titles.get(sec_key, f"Section {sec_key}")
            new_arc = new_arc.rstrip() + f"\n\n## {sec_key} {section_title}\n\n"
            for block in section_appends[sec_key]:
                new_arc += block.rstrip() + "\n\n"
        else:
            # Find section boundary — next ## or EOF
            arc_secs = list(ARC_SECTION_RE.finditer(new_arc))
            sec_start = None
            sec_end = len(new_arc)
            for i, sm in enumerate(arc_secs):
                if sm.group(1) == sec_key:
                    sec_start = sm.end()
                    if i + 1 < len(arc_secs):
                        sec_end = arc_secs[i + 1].start()
                    break
            if sec_start is None:
                continue
            # Insert blocks at end of section
            insert_text = ""
            for block in section_appends[sec_key]:
                insert_text += block.rstrip() + "\n\n"
            new_arc = new_arc[:sec_end] + insert_text + new_arc[sec_end:]

    # === SYNC §6 "Not Started" table + §7 Implementation Status counts ===
    active_ids = collect_active_req_ids(new_srs)
    active_counts = collect_active_status_counts(new_srs)

    # Archive total impl: blocks в archive после merge (~ count of #### in new_arc)
    archive_impl_total = len(REQ_RE.findall(new_arc))

    new_srs2, removed_rows = sync_not_started_table(new_srs, active_ids)
    new_srs3, counts_changed = sync_status_counts(new_srs2, active_counts, archive_impl_total)

    archived_ids_list = [req_id for _, req_id, *_ in to_move]
    new_srs4, prose_changed = _update_srs_status_prose(archived_ids_list, new_srs3)

    changed = bool(to_move) or removed_rows > 0 or counts_changed or prose_changed

    if not changed:
        print("[archive-srs] active SRS clean + §6/§7 in sync — no-op")
        return 0

    counts_summary = (
        f"impl={archive_impl_total} archive, "
        f"partial={active_counts['partial']}, "
        f"not_started={active_counts['not_started']}, "
        f"deprecated={active_counts['deprecated']}"
    )

    if args.dry_run:
        print(
            f"\n[archive-srs] --dry-run: would move {len(to_move)} blocks, "
            f"prune {removed_rows} §6 rows, "
            f"§7 counts {'update' if counts_changed else 'unchanged'}, "
            f"§7 prose {'update' if prose_changed else 'unchanged'} "
            f"({counts_summary})"
        )
        return 0

    SRS_PATH.write_text(new_srs4)
    ARC_PATH.write_text(new_arc)

    print(f"\n[archive-srs] moved {len(to_move)} blocks to {ARC_PATH}")
    print(f"  active SRS: {len(srs_text.splitlines())} → {len(new_srs4.splitlines())} lines")
    print(f"  archive: {len(arc_text.splitlines())} → {len(new_arc.splitlines())} lines")
    print(
        f"  §6 Not Started rows pruned: {removed_rows}; "
        f"§7 counts {'updated' if counts_changed else 'in sync'}; "
        f"§7 prose {'updated' if prose_changed else 'in sync'} "
        f"({counts_summary})"
    )
    print("[archive-srs] verify: rebuild-rtm.sh (sibling script) && review the diff")
    return 0


if __name__ == "__main__":
    sys.exit(main())
