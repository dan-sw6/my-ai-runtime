#!/usr/bin/env python3
"""Rebuild rtm.yaml from story files (source of truth) + SRS (canonical title/priority).

OPTIONAL module (gated by `srs.enabled` in runtime.config.yaml) — see srs/README.md.
Ported from mgt-openproject scripts/rebuild-rtm.py; parsing logic unchanged, only the
paths (srs.srs_path / srs.archive_path / srs.rtm_path / ao.story_dir) are config-driven
instead of hardcoded docs/*.

Stories live in (ao.story_dir, default docs/stories):
- <story_dir>/STORY-*.md (active drafts/in-progress)
- <story_dir>/archive/STORY-*.md (delivered)

Each story carries frontmatter (canonical `---\\n<yaml>\\n---` or legacy ```yaml ... ```)
with `requirement_refs[]`, `files_affected[]`, `tests[]`, `status`, `verified_at`.

RTM = inverted view: requirement → {title, priority, stories[], files[], tests[], verified_at, notes}.

Usage:
  python3 rebuild-rtm.py            # rewrite rtm.yaml
  python3 rebuild-rtm.py --audit    # show diff vs current rtm.yaml, exit 1 if drift
  python3 rebuild-rtm.py --check    # exit 0 only if rebuild matches current rtm.yaml byte-for-byte
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML required. pip install pyyaml\n")
    sys.exit(2)


def _repo_root() -> Path:
    """Resolve the product repo root — git toplevel, falling back to cwd.

    (Was `Path(__file__).resolve().parent.parent` in mgt-openproject, which assumed
    a fixed scripts/ layout one level under repo root. This script now lives inside
    the relocatable story-machinery/srs/ bundle, so the repo root must be discovered
    at runtime instead.)
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        )
        return Path(out.stdout.strip())
    except Exception:
        return Path.cwd()


def _load_srs_cfg() -> dict:
    """Read runtime.config.yaml `srs:` block (+ ao.story_dir) — env override, safe defaults.

    Config resolution matches runtime-config-read.sh: $AI_RUNTIME_CONFIG, else
    ${CLAUDE_PROJECT_DIR:-.}/runtime.config.yaml. Missing file/key/PyYAML → defaults
    (the harness still runs; srs.enabled defaults to False so main() no-ops).
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
        "story_dir": "docs/stories",
    }
    try:
        data = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
    except Exception:
        return defaults
    out = {**defaults, **(data.get("srs") or {})}
    if (data.get("ao") or {}).get("story_dir"):
        out["story_dir"] = data["ao"]["story_dir"]
    return out


_CFG = _load_srs_cfg()
REPO_ROOT = _repo_root()
RTM_PATH = REPO_ROOT / _CFG["rtm_path"]
SRS_PATH = REPO_ROOT / _CFG["srs_path"]
SRS_ARCHIVE = REPO_ROOT / _CFG["archive_path"]
STORIES_DIRS = [REPO_ROOT / _CFG["story_dir"], REPO_ROOT / _CFG["story_dir"] / "archive"]

REQ_ID_RE = re.compile(r"^([A-Z]+-[A-Z0-9]+-\d+(?:[a-z])?)$")


def parse_story_frontmatter(text: str) -> dict | None:
    """Try canonical `---` markers first, then legacy ```yaml fenced block."""
    m = re.match(r"---\n(.*?)\n---", text, re.DOTALL)
    if not m:
        m = re.search(r"```yaml\n(.*?)\n```", text, re.DOTALL)
    if not m:
        return None
    try:
        data = yaml.safe_load(m.group(1))
        return data if isinstance(data, dict) else None
    except yaml.YAMLError:
        return None


def collect_stories() -> list[dict]:
    stories = []
    for sdir in STORIES_DIRS:
        if not sdir.exists():
            continue
        for f in sorted(sdir.glob("STORY-*.md")):
            text = f.read_text(encoding="utf-8")
            fm = parse_story_frontmatter(text)
            if not fm:
                continue
            sid = fm.get("id") or f.stem
            refs = fm.get("requirement_refs") or []
            if isinstance(refs, str):
                refs = [refs]
            refs = [r.strip() for r in refs if isinstance(r, str) and REQ_ID_RE.match(r.strip())]
            stories.append(
                {
                    "id": sid,
                    "status": fm.get("status", "draft"),
                    "requirement_refs": refs,
                    "files_affected": fm.get("files_affected") or [],
                    "tests": fm.get("tests") or [],
                    "verified_at": fm.get("verified_at"),
                    "priority": fm.get("priority"),
                    "title": fm.get("title", ""),
                    "_path": str(f.relative_to(REPO_ROOT)),
                }
            )
    return stories


def parse_srs_canonical() -> dict[str, dict]:
    """Read SRS + archive — extract title + priority + status per requirement ID."""
    out: dict[str, dict] = {}
    heading_re = re.compile(r"^####\s+([A-Z]+-[A-Z0-9]+-\d+(?:[a-z])?)\s*:\s*(.*)$", re.MULTILINE)
    priority_re = re.compile(r"\|\s*\*\*Priority\*\*\s*\|\s*([^\|]+?)\s*\|")
    status_re = re.compile(r"\|\s*\*\*Status\*\*\s*\|\s*([^\|]+?)\s*\|")
    notes_re = re.compile(r"\|\s*\*\*Notes\*\*\s*\|\s*([^\|]+?)\s*\|")

    priority_map = {
        "Must Have": "must_have",
        "Should Have": "should_have",
        "Could Have": "could_have",
        "Won't Have": "wont_have",
    }

    for p in (SRS_PATH, SRS_ARCHIVE):
        if not p.exists():
            continue
        text = p.read_text(encoding="utf-8")
        positions = [(m.start(), m.group(1), m.group(2).strip()) for m in heading_re.finditer(text)]
        positions.append((len(text), None, None))
        for i in range(len(positions) - 1):
            start, rid, title = positions[i]
            end = positions[i + 1][0]
            block = text[start:end]
            prio_m = priority_re.search(block)
            status_m = status_re.search(block)
            notes_m = notes_re.search(block)
            if rid not in out:
                out[rid] = {
                    "title": title,
                    "priority": priority_map.get(
                        prio_m.group(1).strip(), prio_m.group(1).strip().lower().replace(" ", "_")
                    )
                    if prio_m
                    else None,
                    "status": status_m.group(1).strip() if status_m else None,
                    "notes": notes_m.group(1).strip() if notes_m else None,
                    "in_archive": p == SRS_ARCHIVE,
                }
    return out


def build_rtm(stories: list[dict], srs: dict[str, dict]) -> dict:
    inv: dict[str, dict] = defaultdict(
        lambda: {
            "stories": [],
            "files": set(),
            "tests": set(),
            "verified_at": None,
            "notes": None,
        }
    )
    for s in stories:
        for rid in s["requirement_refs"]:
            entry = inv[rid]
            if s["id"] not in entry["stories"]:
                entry["stories"].append(s["id"])
            entry["files"].update(s.get("files_affected") or [])
            entry["tests"].update(s.get("tests") or [])
            # verified_at = max date among 'done' stories
            if s.get("status") == "done" and s.get("verified_at"):
                v = str(s["verified_at"])
                if not entry["verified_at"] or v > entry["verified_at"]:
                    entry["verified_at"] = v

    # Add requirements that exist in SRS but have no stories yet
    for rid in srs:
        if rid not in inv:
            inv[rid] = {
                "stories": [],
                "files": set(),
                "tests": set(),
                "verified_at": None,
                "notes": None,
            }

    # Build final structure
    requirements: dict[str, dict] = {}
    for rid, data in inv.items():
        srs_entry = srs.get(rid, {})
        # Sort stories naturally (STORY-051 before STORY-100)
        sorted_stories = sorted(
            data["stories"], key=lambda s: int(re.search(r"\d+", s).group()) if re.search(r"\d+", s) else 0
        )
        entry = {
            "title": srs_entry.get("title") or "",
            "priority": srs_entry.get("priority") or "should_have",
        }
        if sorted_stories:
            entry["stories"] = sorted_stories
        if data["files"]:
            entry["files"] = sorted(data["files"])
        if data["tests"]:
            entry["tests"] = sorted(data["tests"])
        if data["verified_at"]:
            entry["verified_at"] = data["verified_at"]
        if srs_entry.get("notes"):
            entry["notes"] = srs_entry["notes"]
        requirements[rid] = entry

    return {
        "schema_version": "9.0",
        "generated": str(date.today()),
        "source": f"AUTO-GENERATED from {_CFG['story_dir']}/**/*.md + {_CFG['srs_path']} "
        "(status canonical in SRS, RTM = derived linkage view). DO NOT EDIT BY HAND. Run: rebuild-rtm.sh",
        "requirements": requirements,
    }


def emit_yaml(data: dict) -> str:
    """Custom emitter producing rtm.yaml-compatible formatting."""
    lines = []
    lines.append("# AUTO-GENERATED — DO NOT EDIT BY HAND.")
    lines.append(f"# Source: {_CFG['story_dir']}/**/*.md (linkage) + {_CFG['srs_path']} (canonical title/priority).")
    lines.append("# Regenerate: rebuild-rtm.sh")
    lines.append(f"# Status field is intentionally absent — canonical lives in {_CFG['srs_path']}.")
    lines.append("")
    lines.append(f'schema_version: "{data["schema_version"]}"')
    lines.append(f'generated: "{data["generated"]}"')
    lines.append(f'source: "{data["source"]}"')
    lines.append("")
    lines.append("requirements:")

    # Group by module (FR-XXX, NFR-XXX, SEC-XXX prefix)
    grouped: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for rid, entry in data["requirements"].items():
        # Module = FR-MOD-NNN → MOD; NFR-CAT-NNN → CAT
        m = re.match(r"^([A-Z]+)-([A-Z0-9]+)-", rid)
        module = m.group(2) if m else "OTHER"
        grouped[module].append((rid, entry))

    for module in sorted(grouped.keys()):
        lines.append(f"  # --- {module} ---")
        # Sort by numeric suffix within module
        items = sorted(
            grouped[module], key=lambda x: int(re.search(r"-(\d+)", x[0]).group(1)) if re.search(r"-(\d+)", x[0]) else 0
        )
        for rid, entry in items:
            lines.append(f"  {rid}:")
            for key in ("title", "priority", "stories", "files", "tests", "verified_at", "notes"):
                if key not in entry:
                    continue
                val = entry[key]
                if key == "title":
                    # YAML-safe quote
                    safe = val.replace('"', '\\"')
                    lines.append(f'    title: "{safe}"')
                elif key == "priority":
                    lines.append(f"    priority: {val}")
                elif key in ("stories",):
                    if val:
                        lines.append(f"    stories: [{', '.join(val)}]")
                elif key in ("files", "tests"):
                    if val:
                        # Block-list for readability when long
                        if len(val) <= 3:
                            joined = ", ".join(f'"{x}"' for x in val)
                            lines.append(f"    {key}: [{joined}]")
                        else:
                            lines.append(f"    {key}:")
                            for v in val:
                                lines.append(f'      - "{v}"')
                elif key == "verified_at":
                    lines.append(f'    verified_at: "{val}"')
                elif key == "notes":
                    safe = str(val).replace('"', '\\"')
                    lines.append(f'    notes: "{safe}"')
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if not _CFG.get("enabled"):
        print("[srs] disabled")
        return 0

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", action="store_true", help="Show drift vs current rtm.yaml without writing")
    parser.add_argument("--check", action="store_true", help="Exit 1 if rebuild differs from current rtm.yaml")
    args = parser.parse_args()

    stories = collect_stories()
    srs = parse_srs_canonical()
    rtm = build_rtm(stories, srs)
    new_text = emit_yaml(rtm)

    if args.check or args.audit:
        current = RTM_PATH.read_text(encoding="utf-8") if RTM_PATH.exists() else ""
        if current.strip() == new_text.strip():
            print(
                f"[rebuild-rtm] verdict=clean reason=rtm_matches_stories stories={len(stories)} requirements={len(rtm['requirements'])}"
            )
            return 0
        if args.audit:
            import difflib

            diff = list(
                difflib.unified_diff(
                    current.splitlines(keepends=True),
                    new_text.splitlines(keepends=True),
                    fromfile="current rtm.yaml",
                    tofile="rebuilt from stories",
                    n=3,
                )
            )
            sys.stdout.write("".join(diff[:200]))  # cap output
            print(
                f"\n[rebuild-rtm] verdict=drift reason=rtm_stale_vs_stories diff_lines={sum(1 for l in diff if l.startswith(('+', '-')) and not l.startswith(('+++', '---')))}"
            )
        else:
            print(
                "[rebuild-rtm] verdict=drift reason=rtm_stale_vs_stories — run rebuild-rtm.sh", file=sys.stderr
            )
        return 1

    RTM_PATH.parent.mkdir(parents=True, exist_ok=True)
    RTM_PATH.write_text(new_text, encoding="utf-8")
    print(
        f"[rebuild-rtm] verdict=ok stories={len(stories)} requirements={len(rtm['requirements'])} rtm_path={RTM_PATH.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
