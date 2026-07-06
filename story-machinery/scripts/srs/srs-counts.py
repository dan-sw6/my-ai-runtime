#!/usr/bin/env python3
"""Compute §7 SRS summary tables + the math invariant — single source of truth.

OPTIONAL module (gated by `srs.enabled` in runtime.config.yaml) — see srs/README.md.
Ported from mgt-openproject scripts/srs-counts.py; parsing logic unchanged, only the
paths (srs.srs_path / srs.archive_path) and the requirement-ID prefix taxonomy
(srs.req_id_prefixes, was a hardcoded `(?:FR|NFR|SEC)` literal) are config-driven.

Usage:
    python3 srs-counts.py            # print the §7 tables + INVARIANT line
    python3 srs-counts.py --audit    # exit nonzero if SRS-stated §7 numbers drift
    python3 srs-counts.py --write     # inject fresh tables into §7 markers (NOT in lint)

Reads the active SRS (partial / not_started / deprecated) + the implemented-archive
(implemented). Reuses the requirement-block / status regexes from
archive-implemented-srs.py (imported — never re-defined here).

Emits to stdout, in order:
  (a) Per-category Priority breakdown (Must / Should / Could), active requirements.
  (b) Implementation Status counts (Active from SRS; Archive from implemented-archive).
  (c) MATH INVARIANT line — last line of stdout, machine-checkable.

Definitions enforced:
  Active  = partial + not_started + deprecated   (all #### blocks in the active SRS)
  Archive = implemented                          (all #### blocks in implemented-archive)
  Surface = Active + Archive

PASS iff: (i) every active block status ∈ {partial,not_started,deprecated};
(ii) every archive block status == implemented; (iii) partial+not_started+deprecated
equals the active block count; (iv) no duplicate requirement IDs across the two files.
Else FAIL + one `WHY: <reason>` line to stderr.

Pure stdlib except PyYAML for config load — no other third-party deps.
"""

from __future__ import annotations

import argparse
import importlib.util
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

ACTIVE_STATUSES = ("partial", "not_started", "deprecated")
ALL_STATUSES = ("implemented", *ACTIVE_STATUSES)

# §7 injection markers for --write
SRS_COUNTS_START = "<!-- srs-counts:start -->"
SRS_COUNTS_END = "<!-- srs-counts:end -->"


def _load_archive_module():
    """Import archive-implemented-srs.py (hyphenated filename → importlib)."""
    mod_path = Path(__file__).resolve().parent / "archive-implemented-srs.py"
    spec = importlib.util.spec_from_file_location("archive_implemented_srs", mod_path)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise ImportError(f"cannot load {mod_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_arc = _load_archive_module()
# Reuse canonical regexes — do NOT redefine.
REQ_RE: re.Pattern[str] = _arc.REQ_RE
STATUS_RE: re.Pattern[str] = _arc.STATUS_RE

# Priority cell: `| **Priority** | Must Have |` — capture the leading word.
PRIORITY_RE = re.compile(r"\|\s*\*\*Priority\*\*\s*\|\s*([A-Za-z]+)", re.IGNORECASE)

# Requirement-ID prefix → category (strip the trailing numeric segment).
# Prefix alternation built from srs.req_id_prefixes (was a hardcoded `(?:FR|NFR|SEC)`
# literal in mgt-openproject — this is the one genuine ID-taxonomy hardcode in the
# whole SRS/RTM script cluster; every other regex here uses a generic `[A-Z]+`).
_PREFIX_ALT = "|".join(re.escape(p) for p in _CFG["req_id_prefixes"])
ID_RE = re.compile(rf"^((?:{_PREFIX_ALT})-[A-Z0-9]+(?:-[A-Z0-9]+)*)-\d+$")


def _iter_blocks(text: str):
    """Yield (req_id, block_text) for every `#### XXX:` block in *text*."""
    matches = list(REQ_RE.finditer(text))
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        yield m.group(1), text[start:end]


def _block_status(block_text: str) -> str | None:
    m = STATUS_RE.search(block_text)
    return m.group(1).lower() if m else None


def _block_priority(block_text: str) -> str:
    """Return normalized priority bucket: Must / Should / Could (else 'Must')."""
    m = PRIORITY_RE.search(block_text)
    if not m:
        return "Must"
    word = m.group(1).capitalize()
    return word if word in ("Must", "Should", "Could") else "Must"


def _category(req_id: str) -> str:
    """FR-DOMAIN-049 → FR-DOMAIN ; NFR-PERF-002 → NFR-PERF ; SEC-DOMAIN-001 → SEC-DOMAIN."""
    m = ID_RE.match(req_id)
    if m:
        return m.group(1)
    # Fallback: strip a trailing -<digits> if present.
    return re.sub(r"-\d+$", "", req_id)


def compute():
    """Return a dict with all computed counts + verdict.

    Keys:
      categories: {cat: {"Must": n, "Should": n, "Could": n, "Total": n}}
      status:     {"implemented": n, "partial": n, "not_started": n, "deprecated": n}
      active:     int (partial + not_started + deprecated)
      archive:    int (implemented)
      surface:    int
      verdict:    "PASS" | "FAIL"
      why:        str | None
    """
    srs_text = SRS_PATH.read_text(encoding="utf-8") if SRS_PATH.exists() else ""
    arc_text = ARC_PATH.read_text(encoding="utf-8") if ARC_PATH.exists() else ""

    categories: dict[str, dict[str, int]] = {}
    status_counts = {s: 0 for s in ALL_STATUSES}
    active_ids: list[str] = []
    archive_ids: list[str] = []

    why: str | None = None

    # --- active blocks (docs/SRS.md) ---
    active_block_count = 0
    for req_id, block in _iter_blocks(srs_text):
        active_block_count += 1
        active_ids.append(req_id)
        st = _block_status(block)
        if st not in ACTIVE_STATUSES:
            if why is None:
                why = (
                    f"active block {req_id} has status={st!r} (active SRS may only contain {'/'.join(ACTIVE_STATUSES)})"
                )
            # still count it under its status if recognised, so numbers are honest
            if st in status_counts:
                status_counts[st] += 1
            continue
        status_counts[st] += 1
        cat = _category(req_id)
        bucket = categories.setdefault(cat, {"Must": 0, "Should": 0, "Could": 0, "Total": 0})
        bucket[_block_priority(block)] += 1
        bucket["Total"] += 1

    # --- archive blocks (implemented-archive.md) ---
    for req_id, block in _iter_blocks(arc_text):
        archive_ids.append(req_id)
        st = _block_status(block)
        if st != "implemented" and why is None:
            why = f"archive block {req_id} has status={st!r} (implemented-archive.md must be all implemented)"
        status_counts["implemented"] += 1

    active = status_counts["partial"] + status_counts["not_started"] + status_counts["deprecated"]
    archive = status_counts["implemented"]
    surface = active + archive

    # invariant (iii): active total equals the active block count
    if active != active_block_count and why is None:
        why = f"active sum {active} != active block count {active_block_count}"

    # invariant (iv): no duplicate IDs across the two files
    dupes = set(active_ids) & set(archive_ids)
    if dupes and why is None:
        why = f"duplicate requirement IDs across SRS.md and archive: {', '.join(sorted(dupes))}"
    # duplicates within a single file also break the contract
    if why is None:
        for label, ids in (("SRS.md", active_ids), ("implemented-archive.md", archive_ids)):
            seen: set[str] = set()
            for rid in ids:
                if rid in seen:
                    why = f"duplicate requirement ID {rid} within {label}"
                    break
                seen.add(rid)
            if why:
                break

    verdict = "FAIL" if why else "PASS"
    return {
        "categories": categories,
        "status": status_counts,
        "active": active,
        "archive": archive,
        "surface": surface,
        "verdict": verdict,
        "why": why,
    }


def _render_category_table(categories: dict[str, dict[str, int]]) -> str:
    lines = [
        "## Requirements by category (active)",
        "| Category | Must | Should | Could | Total |",
        "|----------|------|--------|-------|-------|",
    ]
    tot = {"Must": 0, "Should": 0, "Could": 0, "Total": 0}
    for cat in sorted(categories):
        b = categories[cat]
        lines.append(f"| {cat} | {b['Must']} | {b['Should']} | {b['Could']} | {b['Total']} |")
        for k in tot:
            tot[k] += b[k]
    lines.append(f"| TOTAL | {tot['Must']} | {tot['Should']} | {tot['Could']} | {tot['Total']} |")
    return "\n".join(lines)


def _render_status_table(status: dict[str, int]) -> str:
    lines = [
        "## Implementation status",
        "| Status       | Count |",
        "|--------------|-------|",
        f"| implemented  | {status['implemented']} |",
        f"| partial      | {status['partial']} |",
        f"| not_started  | {status['not_started']} |",
        f"| deprecated   | {status['deprecated']} |",
    ]
    return "\n".join(lines)


def _render_invariant(r: dict) -> str:
    s = r["status"]
    return (
        f"INVARIANT Active={r['active']} "
        f"(partial={s['partial']} + not_started={s['not_started']} + deprecated={s['deprecated']}) "
        f"| Archive={r['archive']} (implemented-archive.md) "
        f"| Surface={r['surface']} (Active+Archive) | {r['verdict']}"
    )


def render_all(r: dict) -> str:
    return "\n\n".join(
        (
            _render_category_table(r["categories"]),
            _render_status_table(r["status"]),
            _render_invariant(r),
        )
    )


def _extract_srs_stated_numbers() -> dict:
    """Parse the numbers currently pasted in §7 of the SRS (between markers if present,
    else the whole §7 region) for --audit drift comparison."""
    srs_text = SRS_PATH.read_text(encoding="utf-8") if SRS_PATH.exists() else ""
    if SRS_COUNTS_START in srs_text and SRS_COUNTS_END in srs_text:
        region = srs_text.split(SRS_COUNTS_START, 1)[1].split(SRS_COUNTS_END, 1)[0]
    else:
        # Fall back to everything from "## 7." (or "## 7 ") onward.
        m = re.search(r"^##\s*7[.\s].*$", srs_text, re.MULTILINE)
        region = srs_text[m.start() :] if m else srs_text

    stated: dict = {"status": {}, "invariant": None}
    for st in ALL_STATUSES:
        m = re.search(rf"\|\s*{st}\s*\|\s*(\d+)\s*\|", region)
        if m:
            stated["status"][st] = int(m.group(1))
    inv = re.search(r"^INVARIANT .*$", region, re.MULTILINE)
    if inv:
        stated["invariant"] = inv.group(0).strip()
    return stated


def _audit() -> int:
    r = compute()
    if r["verdict"] != "PASS":
        print(f"WHY: {r['why']}", file=sys.stderr)
        print(f"srs-counts: FAIL invariant — {_render_invariant(r)}", file=sys.stderr)
        return 1

    stated = _extract_srs_stated_numbers()
    drift: list[str] = []
    # Compare status counts (only those the SRS actually states).
    for st, want in r["status"].items():
        got = stated["status"].get(st)
        if got is not None and got != want:
            drift.append(f"status[{st}] expected {want} got {got}")
    # Compare the INVARIANT line verbatim if the SRS states one.
    want_inv = _render_invariant(r)
    if stated["invariant"] is not None and stated["invariant"] != want_inv:
        drift.append(f"INVARIANT expected:\n  {want_inv}\ngot:\n  {stated['invariant']}")

    if drift:
        print("srs-counts: DRIFT — §7 numbers do not match computed:", file=sys.stderr)
        for d in drift:
            print(f"  {d}", file=sys.stderr)
        print("Run `srs-counts.py --write` to refresh §7.", file=sys.stderr)
        return 1

    print(f"srs-counts: PASS — {want_inv}")
    return 0


def _write() -> int:
    r = compute()
    if r["verdict"] != "PASS":
        print(f"WHY: {r['why']}", file=sys.stderr)
        print("srs-counts: refusing to --write while invariant FAILs", file=sys.stderr)
        return 1
    srs_text = SRS_PATH.read_text(encoding="utf-8")
    block = f"{SRS_COUNTS_START}\n\n{render_all(r)}\n\n{SRS_COUNTS_END}"
    if SRS_COUNTS_START in srs_text and SRS_COUNTS_END in srs_text:
        pre = srs_text.split(SRS_COUNTS_START, 1)[0]
        post = srs_text.split(SRS_COUNTS_END, 1)[1]
        new_text = pre + block + post
    else:
        # Append markers under the first "## 7." heading region (after its title line).
        m = re.search(r"^##\s*7[.\s].*$", srs_text, re.MULTILINE)
        if not m:
            print("srs-counts: no §7 heading found to inject into", file=sys.stderr)
            return 1
        insert_at = srs_text.find("\n", m.end())
        insert_at = insert_at + 1 if insert_at != -1 else len(srs_text)
        new_text = srs_text[:insert_at] + "\n" + block + "\n" + srs_text[insert_at:]
    SRS_PATH.write_text(new_text, encoding="utf-8")
    print(f"srs-counts: wrote §7 tables into {SRS_PATH}")
    return 0


def main() -> int:
    if not _CFG.get("enabled"):
        print("[srs] disabled")
        return 0

    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--audit", action="store_true", help="exit nonzero if §7 numbers drift")
    group.add_argument("--write", action="store_true", help="inject fresh §7 tables (NOT in lint)")
    args = parser.parse_args()

    if args.audit:
        return _audit()
    if args.write:
        return _write()

    r = compute()
    print(render_all(r))
    if r["verdict"] != "PASS":
        print(f"WHY: {r['why']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
