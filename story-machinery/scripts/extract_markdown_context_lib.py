#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


HEADING_RE = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
REF_RE = re.compile(r"\b([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)\b")
LIST_RE = re.compile(r"^\s*([-*]|\d+\.)\s+")


@dataclass
class MatchRecord:
    ref: str
    line_number: int
    match_kind: str
    section_path: list[str]
    excerpt: str


def repo_root() -> Path:
    """Repo root — resolved via git, not directory depth. This file ships as
    part of a relocatable bundle (synced into a product repo at scripts/ao/),
    so its location relative to the repo root isn't fixed the way a fixed
    parent-count assumes."""
    import subprocess

    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        out = ""
    return Path(out) if out else Path.cwd()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_refs(args_refs: list[str], refs_file: str | None) -> list[str]:
    refs: list[str] = []
    if args_refs:
        refs.extend(args_refs)
    if refs_file:
        for raw_line in Path(refs_file).read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            refs.append(line)
    unique_refs: list[str] = []
    seen: set[str] = set()
    for ref in refs:
        if ref not in seen:
            unique_refs.append(ref)
            seen.add(ref)
    return unique_refs


def build_heading_context(lines: list[str]) -> list[list[str]]:
    stack: list[tuple[int, str]] = []
    result: list[list[str]] = []
    for line in lines:
        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            title = heading.group(2).strip()
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, title))
        result.append([title for _, title in stack])
    return result


def line_kind(line: str) -> str:
    stripped = line.strip()
    if HEADING_RE.match(line):
        return "heading"
    if stripped.startswith("|") and stripped.endswith("|"):
        return "table"
    if LIST_RE.match(line):
        return "list"
    return "plain"


def collapse_block(lines: list[str]) -> str:
    trimmed = list(lines)
    while trimmed and not trimmed[0].strip():
        trimmed.pop(0)
    while trimmed and not trimmed[-1].strip():
        trimmed.pop()
    return "\n".join(trimmed).strip()


def extract_heading_block(lines: list[str], index: int, max_lines: int) -> str:
    current = HEADING_RE.match(lines[index])
    if not current:
        return lines[index].strip()
    current_level = len(current.group(1))
    end = index + 1
    while end < len(lines):
        heading = HEADING_RE.match(lines[end])
        if heading and len(heading.group(1)) <= current_level:
            break
        end += 1
    return collapse_block(lines[index : min(end, index + max_lines)])


def extract_list_block(lines: list[str], index: int, max_lines: int) -> str:
    end = index + 1
    while end < len(lines) and end < index + max_lines:
        candidate = lines[end]
        if not candidate.strip():
            break
        if HEADING_RE.match(candidate):
            break
        if line_kind(candidate) in {"list", "table"} and candidate[:1] not in {" ", "\t"}:
            break
        end += 1
    return collapse_block(lines[index:end])


def parse_table_cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def extract_table_block(lines: list[str], index: int) -> str:
    block_start = index
    while block_start > 0 and lines[block_start - 1].strip().startswith("|"):
        block_start -= 1
    header_line = lines[block_start] if block_start < len(lines) else ""
    header_cells = parse_table_cells(header_line)
    row_cells = parse_table_cells(lines[index])
    if len(header_cells) != len(row_cells):
        return lines[index].strip()
    pairs = [f"{key}: {value}" for key, value in zip(header_cells, row_cells)]
    return "\n".join(pairs)


def extract_excerpt(lines: list[str], index: int, max_lines: int) -> tuple[str, str]:
    kind = line_kind(lines[index])
    if kind == "heading":
        return kind, extract_heading_block(lines, index, max_lines)
    if kind == "list":
        return kind, extract_list_block(lines, index, max_lines)
    if kind == "table":
        return kind, extract_table_block(lines, index)
    return kind, collapse_block(lines[max(0, index - 1) : min(len(lines), index + 2)])


def best_match_for_ref(ref: str, lines: list[str], heading_context: list[list[str]], max_lines: int) -> MatchRecord | None:
    candidates: list[tuple[int, MatchRecord]] = []
    for index, line in enumerate(lines):
        found_refs = REF_RE.findall(line)
        if ref not in found_refs:
            continue
        kind, excerpt = extract_excerpt(lines, index, max_lines)
        rank = {"heading": 0, "list": 1, "table": 1, "plain": 2}[kind]
        candidates.append(
            (
                rank,
                MatchRecord(
                    ref=ref,
                    line_number=index + 1,
                    match_kind=kind,
                    section_path=heading_context[index],
                    excerpt=excerpt,
                ),
            )
        )
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1].line_number))
    return candidates[0][1]


def extract_refs_from_markdown(doc_path: Path, refs: list[str], max_lines: int) -> dict[str, object]:
    text = read_text(doc_path)
    lines = text.splitlines()
    heading_context = build_heading_context(lines)
    matches: list[dict[str, object]] = []
    missing: list[str] = []
    for ref in refs:
        match = best_match_for_ref(ref, lines, heading_context, max_lines)
        if match is None:
            missing.append(ref)
            continue
        matches.append(
            {
                "ref": match.ref,
                "source": str(doc_path.relative_to(repo_root())),
                "line_number": match.line_number,
                "match_kind": match.match_kind,
                "section_path": match.section_path,
                "excerpt": match.excerpt,
            }
        )
    return {
        "source": str(doc_path.relative_to(repo_root())),
        "requested_refs": refs,
        "matches": matches,
        "missing_refs": missing,
    }


def render_markdown(payload: dict[str, object]) -> str:
    lines: list[str] = []
    source = payload["source"]
    lines.append(f"# Extracted Context: {source}")
    lines.append("")
    for match in payload["matches"]:
        match_obj = match  # type: ignore[assignment]
        lines.append(f"## {match_obj['ref']}")
        lines.append("")
        lines.append(f"- source: `{match_obj['source']}`:{match_obj['line_number']}")
        lines.append(f"- match_kind: `{match_obj['match_kind']}`")
        section_path = " > ".join(match_obj["section_path"]) if match_obj["section_path"] else "-"
        lines.append(f"- section_path: `{section_path}`")
        lines.append("- excerpt:")
        lines.append("")
        lines.append("```text")
        lines.append(match_obj["excerpt"])
        lines.append("```")
        lines.append("")
    missing = payload["missing_refs"]
    if missing:
        lines.append("## Missing Refs")
        lines.append("")
        for ref in missing:
            lines.append(f"- `{ref}`")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def build_parser(default_doc: str, description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--doc", default=default_doc, help="Markdown source file relative to repo root.")
    parser.add_argument("--refs", nargs="+", help="Refs to extract, e.g. FR-ID-001 DEC-007.")
    parser.add_argument("--refs-file", help="File with one ref per line.")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--output", help="Output file path. Defaults to stdout.")
    parser.add_argument("--max-lines", type=int, default=12, help="Max excerpt lines for heading/list blocks.")
    parser.add_argument("--allow-missing", action="store_true", help="Do not fail if some refs are absent.")
    return parser


def run(default_doc: str, description: str) -> int:
    parser = build_parser(default_doc=default_doc, description=description)
    args = parser.parse_args()
    refs = parse_refs(args.refs or [], args.refs_file)
    if not refs:
        parser.error("at least one ref must be provided via --refs or --refs-file")
    doc_path = (repo_root() / args.doc).resolve()
    if not doc_path.is_file():
        parser.error(f"document not found: {args.doc}")

    payload = extract_refs_from_markdown(doc_path=doc_path, refs=refs, max_lines=args.max_lines)
    if args.format == "markdown":
        content = render_markdown(payload)
    else:
        content = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"

    if args.output:
        Path(args.output).write_text(content, encoding="utf-8")
    else:
        sys.stdout.write(content)

    if payload["missing_refs"] and not args.allow_missing:
        return 1
    return 0


__all__ = ["run", "extract_refs_from_markdown", "render_markdown"]
