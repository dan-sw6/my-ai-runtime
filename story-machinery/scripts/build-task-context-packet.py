#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml
from extract_markdown_context_lib import extract_refs_from_markdown


SECTION_RE = re.compile(r"^##\s+(.*\S)\s*$")
HEADER_ITEM_RE = re.compile(r"^-\s+`([^`]+)`:\s+`([^`]*)`\s*$")
LIST_ITEM_RE = re.compile(r"^\s*(?:[-*]|\d+\.)\s+(.*\S)\s*$")


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


def _load_runtime_config() -> dict[str, Any]:
    """Load runtime.config.yaml the same way scripts/runtime-config-read.sh
    does — $AI_RUNTIME_CONFIG, else <repo>/runtime.config.yaml. Missing
    file/keys are not fatal; callers pass their own default (rcfg below)."""
    config_path = os.environ.get("AI_RUNTIME_CONFIG") or str(
        Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())) / "runtime.config.yaml"
    )
    path = Path(config_path)
    if not path.is_file():
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return {}
    return data if isinstance(data, dict) else {}


_RUNTIME_CONFIG = _load_runtime_config()


def rcfg(key: str, default: str) -> str:
    """Dotted-key lookup into runtime.config.yaml, env-var override — mirrors
    runtime-config-read.sh::rcfg so bash and python callers agree on values."""
    env_name = re.sub(r"[.\-]", "_", key).upper()
    if os.environ.get(env_name):
        return os.environ[env_name]
    cur: Any = _RUNTIME_CONFIG
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return str(cur) if cur is not None else default


# TODO(coordinator): only srs.srs_path is documented in
# config/runtime.config.example.yaml today. decisions_path/plan_path are read
# here for symmetry but aren't in the schema yet — add them to the srs: block
# if DECISIONS.md/PLAN.md stay part of the packet, or drop PLAN_PATH entirely
# (it isn't part of AO's canonical doc set: SRS.md/rtm.yaml/NOW.md/BACKLOG.md/
# DECISIONS.md — see docs/ARCHITECTURE.md "Product Repo Owns").
SRS_PATH = rcfg("srs.srs_path", "docs/SRS.md")
DECISIONS_PATH = rcfg("srs.decisions_path", "docs/DECISIONS.md")
PLAN_PATH = rcfg("srs.plan_path", "docs/PLAN.md")


def git_sha_for(relative_path: str) -> str:
    import subprocess

    result = subprocess.run(
        ["git", "rev-parse", f"HEAD:{relative_path}"],
        cwd=repo_root(),
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return "working-tree"
    return result.stdout.strip()


def parse_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = "_preamble"
    sections[current] = []
    for line in text.splitlines():
        match = SECTION_RE.match(line)
        if match:
            current = match.group(1).strip()
            sections[current] = []
            continue
        sections[current].append(line)
    return sections


def parse_execution_header(lines: list[str]) -> dict[str, str]:
    header: dict[str, str] = {}
    for line in lines:
        match = HEADER_ITEM_RE.match(line.strip())
        if match:
            header[match.group(1)] = match.group(2)
    return header


def parse_list(lines: list[str]) -> list[str]:
    items: list[str] = []
    for line in lines:
        match = LIST_ITEM_RE.match(line)
        if match:
            value = match.group(1).strip()
            if value.startswith("`") and value.endswith("`"):
                value = value[1:-1].strip()
            items.append(value)
    return items


def parse_paragraph(lines: list[str]) -> str:
    return "\n".join(line.rstrip() for line in lines).strip()


def normalize_string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        items = value
    elif isinstance(value, str):
        items = [value]
    else:
        return []
    result: list[str] = []
    for item in items:
        text = str(item).strip()
        if text:
            result.append(text)
    return result


def unique_keep_order(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        result.append(item)
    return result


def first_nonempty(*values: Any) -> str:
    for value in values:
        if isinstance(value, str):
            clean = value.strip()
            if clean:
                return clean
    return ""


def parse_task_brief_structured(payload: dict[str, Any], task_file: str) -> dict[str, Any]:
    execution_header = payload.get("execution_header")
    if not isinstance(execution_header, dict):
        execution_header = {}
    task_block = payload.get("task")
    if not isinstance(task_block, dict):
        task_block = {}
    execution_block = payload.get("execution")
    if not isinstance(execution_block, dict):
        execution_block = {}
    context_block = payload.get("context")
    if not isinstance(context_block, dict):
        context_block = {}
    scope_block = payload.get("scope")
    if not isinstance(scope_block, dict):
        scope_block = {}
    acceptance_block = payload.get("acceptance")
    if not isinstance(acceptance_block, dict):
        acceptance_block = {}
    requirements_block = payload.get("requirements")
    if not isinstance(requirements_block, dict):
        requirements_block = {}

    header = {
        "task_id": first_nonempty(
            execution_header.get("task_id"),
            payload.get("task_id"),
            task_block.get("id"),
        ),
        "title": first_nonempty(
            execution_header.get("title"),
            payload.get("title"),
            task_block.get("title"),
        ),
        "base_ref": first_nonempty(
            execution_header.get("base_ref"),
            payload.get("base_ref"),
            execution_block.get("base_ref"),
        ),
        "branch": first_nonempty(
            execution_header.get("branch"),
            payload.get("branch"),
            execution_block.get("branch"),
        ),
    }

    requirement_refs_raw = payload.get("requirement_refs")
    requirement_refs: list[str] = []
    if isinstance(requirement_refs_raw, dict):
        requirement_refs.extend(normalize_string_list(requirement_refs_raw.get("primary")))
        requirement_refs.extend(normalize_string_list(requirement_refs_raw.get("subrequirements")))
        requirement_refs.extend(normalize_string_list(requirement_refs_raw.get("all")))
    else:
        requirement_refs.extend(normalize_string_list(requirement_refs_raw))

    requirement_refs.extend(normalize_string_list(requirements_block.get("refs")))
    requirement_refs.extend(normalize_string_list(requirements_block.get("primary")))
    requirement_refs.extend(normalize_string_list(requirements_block.get("subrequirements")))
    requirement_refs.extend(normalize_string_list(requirements_block.get("fr")))
    requirement_refs.extend(normalize_string_list(requirements_block.get("nfr")))
    requirement_refs.extend(normalize_string_list(requirements_block.get("sec")))
    requirement_refs = unique_keep_order(requirement_refs)

    scope_allowlist = normalize_string_list(payload.get("scope_allowlist"))
    if not scope_allowlist:
        scope_allowlist = normalize_string_list(scope_block.get("allowlist"))

    acceptance_criteria = normalize_string_list(payload.get("acceptance_criteria"))
    if not acceptance_criteria:
        acceptance_criteria = normalize_string_list(acceptance_block.get("criteria"))
    if not acceptance_criteria:
        acceptance_criteria = normalize_string_list(payload.get("acceptance_checks"))

    repo_facts = normalize_string_list(payload.get("repo_facts_to_preserve"))
    if not repo_facts:
        repo_facts = normalize_string_list(payload.get("repo_facts"))

    goal = first_nonempty(
        payload.get("goal"),
        context_block.get("goal"),
        payload.get("business_goal"),
    )
    why_this_task_now = first_nonempty(
        payload.get("why_this_task_now"),
        payload.get("why_this_pack_first"),
        payload.get("why_now"),
        context_block.get("why_now"),
        context_block.get("rationale"),
    )

    return {
        "header": header,
        "goal": goal,
        "why_this_task_now": why_this_task_now,
        "requirement_refs": requirement_refs,
        "repo_facts": repo_facts,
        "scope_allowlist": scope_allowlist,
        "acceptance_criteria": acceptance_criteria,
        "non_goals": normalize_string_list(payload.get("non_goals")),
        "task_file": task_file,
    }


def parse_task_brief_markdown(task_text: str, task_file: str) -> dict[str, Any]:
    sections = parse_sections(task_text)
    return {
        "header": parse_execution_header(sections.get("0.1 Execution Header", [])),
        "goal": parse_paragraph(sections.get("Goal", [])),
        "why_this_task_now": parse_paragraph(sections.get("Why This Pack First", [])),
        "requirement_refs": parse_list(sections.get("Requirement Refs", [])),
        "repo_facts": parse_list(sections.get("Repo Facts To Preserve", [])),
        "scope_allowlist": parse_list(sections.get("Scope Allowlist", [])),
        "acceptance_criteria": parse_list(sections.get("Acceptance Criteria", [])),
        "non_goals": parse_list(sections.get("Non-Goals", [])),
        "task_file": task_file,
    }


def parse_task_brief(task_path: Path, task_file: str) -> dict[str, Any]:
    suffix = task_path.suffix.lower()
    text = task_path.read_text(encoding="utf-8")

    if suffix in {".yaml", ".yml"}:
        payload = yaml.safe_load(text)
        if not isinstance(payload, dict):
            raise ValueError("yaml_task_brief_top_level_must_be_mapping")
        return parse_task_brief_structured(payload, task_file)

    if suffix == ".json":
        payload = json.loads(text)
        if not isinstance(payload, dict):
            raise ValueError("json_task_brief_top_level_must_be_mapping")
        return parse_task_brief_structured(payload, task_file)

    return parse_task_brief_markdown(text, task_file)


def derive_module(scope_allowlist: list[str]) -> str:
    if not scope_allowlist:
        return "general"
    first = scope_allowlist[0]
    if "/" not in first:
        return first.replace("*", "").strip() or "general"
    return first.split("/", 1)[0]


def format_list_block(items: list[str], fallback: str = "N/A") -> str:
    if not items:
        return f"- {fallback}\n"
    return "".join(f"- {item}\n" for item in items)


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_equal(left: Any, right: list[str]) -> bool:
    if not isinstance(left, list):
        return False
    return [str(item) for item in left] == right


def cached_extract_payload(
    previous_payload: dict[str, Any] | None,
    payload_key: str,
    requested_refs: list[str],
    source_key: str,
    expected_source_sha: str,
) -> dict[str, Any] | None:
    if not previous_payload:
        return None
    cache = previous_payload.get(payload_key)
    if not isinstance(cache, dict):
        return None
    requested = cache.get("requested_refs")
    if not list_equal(requested, requested_refs):
        return None
    previous_snapshot = previous_payload.get("source_snapshot")
    if not isinstance(previous_snapshot, dict):
        return None
    if str(previous_snapshot.get(source_key, "")).strip() != expected_source_sha:
        return None
    matches = cache.get("matches")
    missing_refs = cache.get("missing_refs")
    source = cache.get("source")
    if not isinstance(matches, list) or not isinstance(missing_refs, list) or not isinstance(source, str):
        return None
    return cache


def build_markdown(
    task_file: str,
    header: dict[str, str],
    goal: str,
    why_this_task_now: str,
    requirement_refs: list[str],
    requirement_payload: dict[str, object],
    decision_refs: list[str],
    decision_payload: dict[str, object],
    repo_facts: list[str],
    scope_allowlist: list[str],
    acceptance_criteria: list[str],
    non_goals: list[str],
    files_to_read_first: list[str],
    commands: list[str],
    ui_task: bool,
    design_master: str | None,
    design_pages: list[str],
    runtime_notes: list[str],
    mcp_summary: list[str],
    source_snapshot: dict[str, str],
    generated_at: str,
    build_mode: str,
    previous_context_json: str | None,
    project: str,
) -> str:
    task_id = header.get("task_id", "UNKNOWN")
    title = header.get("title", Path(task_file).stem)
    base_ref = header.get("base_ref", "HEAD")
    branch = header.get("branch", "N/A")
    # No assumed base-ref naming convention (e.g. legacy "next/vX.Y" version
    # lines) — the packet just echoes whatever base_ref the task brief carries.
    version_line = base_ref

    lines: list[str] = []
    lines.append(f"# TASK_CONTEXT: {task_id}")
    lines.append("")
    lines.append("## 1. Task Summary")
    lines.append("")
    lines.append(f"- `task_id`: `{task_id}`")
    lines.append(f"- `title`: `{title}`")
    lines.append("- `role_target`: `implementer|controller`")
    lines.append(f"- `base_ref`: `{base_ref}`")
    lines.append(f"- `branch`: `{branch}`")
    lines.append(f"- `task_file`: `{task_file}`")
    lines.append("")
    lines.append("## 2. Why This Task Now")
    lines.append("")
    if goal:
        lines.append("### Goal")
        lines.append("")
        lines.append(goal)
        lines.append("")
    if why_this_task_now:
        lines.append("### Why Now")
        lines.append("")
        lines.append(why_this_task_now)
        lines.append("")
    lines.append("## 3. Source Snapshot")
    lines.append("")
    lines.append(f"- `srs_sha`: `{source_snapshot['srs_sha']}`")
    lines.append(f"- `decisions_sha`: `{source_snapshot['decisions_sha']}`")
    lines.append(f"- `plan_sha`: `{source_snapshot['plan_sha']}`")
    lines.append(f"- `task_sha`: `{source_snapshot['task_sha']}`")
    lines.append(f"- `generated_at`: `{generated_at}`")
    lines.append("- `generated_by`: `build-task-context-packet.py`")
    lines.append(f"- `build_mode`: `{build_mode}`")
    if previous_context_json:
        lines.append(f"- `previous_context_json`: `{previous_context_json}`")
    lines.append("")
    lines.append("## 4. Requirement Refs")
    lines.append("")
    lines.append("### Primary")
    lines.append("")
    lines.append(format_list_block(requirement_refs).rstrip())
    lines.append("")
    lines.append("## 5. Requirement Excerpts")
    lines.append("")
    for match in requirement_payload["matches"]:
        ref = match["ref"]
        section_path = " > ".join(match["section_path"]) if match["section_path"] else "-"
        lines.append(f"### `{ref}`")
        lines.append("")
        lines.append(f"- `source`: `{match['source']}`:{match['line_number']}")
        lines.append(f"- `section_path`: `{section_path}`")
        lines.append(f"- `match_kind`: `{match['match_kind']}`")
        lines.append("- `excerpt`:")
        lines.append("")
        lines.append("```text")
        lines.append(match["excerpt"])
        lines.append("```")
        lines.append("")
    if requirement_payload["missing_refs"]:
        lines.append("### Missing Requirement Refs")
        lines.append("")
        lines.append(format_list_block(requirement_payload["missing_refs"]).rstrip())
        lines.append("")
    lines.append("## 6. Relevant Decisions")
    lines.append("")
    if decision_refs:
        for match in decision_payload["matches"]:
            ref = match["ref"]
            section_path = " > ".join(match["section_path"]) if match["section_path"] else "-"
            lines.append(f"### `{ref}`")
            lines.append("")
            lines.append(f"- `source`: `{match['source']}`:{match['line_number']}")
            lines.append(f"- `section_path`: `{section_path}`")
            lines.append(f"- `match_kind`: `{match['match_kind']}`")
            lines.append("- `excerpt`:")
            lines.append("")
            lines.append("```text")
            lines.append(match["excerpt"])
            lines.append("```")
            lines.append("")
        if decision_payload["missing_refs"]:
            lines.append("### Missing Decision Refs")
            lines.append("")
            lines.append(format_list_block(decision_payload["missing_refs"]).rstrip())
            lines.append("")
    else:
        lines.append("- N/A")
        lines.append("")
    lines.append("## 7. Relevant Planning Constraints")
    lines.append("")
    if repo_facts:
        lines.append("### Repo Facts To Preserve")
        lines.append("")
        lines.append(format_list_block(repo_facts).rstrip())
        lines.append("")
    if acceptance_criteria:
        lines.append("### Acceptance Criteria")
        lines.append("")
        lines.append(format_list_block(acceptance_criteria).rstrip())
        lines.append("")
    if non_goals:
        lines.append("### Non-Goals")
        lines.append("")
        lines.append(format_list_block(non_goals).rstrip())
        lines.append("")
    lines.append("## 8. Scope")
    lines.append("")
    lines.append("### Allowed Paths")
    lines.append("")
    lines.append(format_list_block(scope_allowlist).rstrip())
    lines.append("")
    lines.append("### Forbidden Paths")
    lines.append("")
    lines.append("- planning files beyond planner-owned scope")
    lines.append("- out-of-scope contours and unrelated modules")
    lines.append("- shared contracts not explicitly included in the task")
    lines.append("")
    lines.append("## 9. Files To Read First")
    lines.append("")
    read_first = files_to_read_first or [task_file, SRS_PATH, DECISIONS_PATH]
    for index, item in enumerate(read_first, start=1):
        lines.append(f"{index}. `{item}`")
    lines.append("")
    lines.append("## 10. Commands To Run")
    lines.append("")
    lines.append("```bash")
    lines.append(f'cd "{repo_root()}"')
    for command in commands or [
        f'bash scripts/test.sh --changed --base-ref "{base_ref}"',
        "bash scripts/lint.sh",
        "bash scripts/type.sh",
    ]:
        lines.append(command)
    lines.append("```")
    lines.append("")
    lines.append("## 11. MCP Plan Summary")
    lines.append("")
    for item in mcp_summary:
        lines.append(f"- {item}")
    lines.append("")
    lines.append("## 12. DB / Runtime Notes")
    lines.append("")
    lines.append(format_list_block(runtime_notes).rstrip())
    lines.append("")
    lines.append("## 13. UI / Design-System Notes")
    lines.append("")
    if ui_task:
        lines.append(f"- `design_system.master`: `{design_master or 'docs/design-system/MASTER.md'}`")
        if design_pages:
            lines.append(f"- `design_system.page_overrides`: `{design_pages}`")
        else:
            lines.append("- `design_system.page_overrides`: `[]`")
    else:
        lines.append("- N/A")
    lines.append("")
    lines.append("## 14. Evidence Expectations")
    lines.append("")
    lines.append("- implementer должен вернуть changed files, checks и docs evidence")
    lines.append("- controller должен проверить scope, canonical checks и MCP evidence")
    if acceptance_criteria:
        lines.append("- acceptance criteria ниже являются обязательным verification baseline")
    lines.append("")
    lines.append("## 15. Stop Conditions")
    lines.append("")
    lines.append("- packet противоречит handoff или task brief")
    lines.append("- source refs не сходятся с SoT")
    lines.append("- scope не бьётся с allowlist")
    lines.append("- отсутствует обязательный source excerpt")
    lines.append("- execution order dependency ещё не закрыта")
    lines.append("")
    lines.append("## 16. Memory Ingestion Hints")
    lines.append("")
    lines.append(f"- `project`: `{project}`")
    lines.append(f"- `task_id`: `{task_id}`")
    lines.append(f"- `version_line`: `{version_line}`")
    lines.append(f"- `module`: `{derive_module(scope_allowlist)}`")
    lines.append("- `topics`: `[scope-guard, pass-gate, task-context]`")
    lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build TASK_CONTEXT packet (json primary, markdown optional) from a task brief and refs.")
    parser.add_argument("--task-file", required=True, help="Task brief path relative to repo root.")
    parser.add_argument("--output", help="Optional output TASK_CONTEXT.md path (legacy human-readable sidecar).")
    parser.add_argument("--json-output", help="Output TASK_CONTEXT.json path (canonical packet).")
    parser.add_argument("--previous-json", help="Optional previous TASK_CONTEXT.json for cache-aware rerun rebuild.")
    parser.add_argument("--decision-refs", nargs="*", default=[], help=f"Decision refs to extract from {DECISIONS_PATH}.")
    parser.add_argument("--files-to-read-first", nargs="*", default=[], help="Ordered file list for worker startup.")
    parser.add_argument("--command", action="append", default=[], help="Command to include in Commands To Run.")
    parser.add_argument("--runtime-note", action="append", default=[], help="Runtime/DB note to include.")
    parser.add_argument("--mcp-item", action="append", default=[], help="Explicit MCP summary line.")
    parser.add_argument("--ui-task", action="store_true", help="Mark packet as UI/design-system relevant.")
    parser.add_argument("--design-master", help="Path to design-system master doc.")
    parser.add_argument("--design-page", action="append", default=[], help="Path to design-system page override.")
    parser.add_argument("--project", help="Project name for memory-ingestion hints. Defaults to the current directory's basename.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not args.output and not args.json_output:
        parser.error("at least one output is required: --json-output and/or --output")

    task_path = (repo_root() / args.task_file).resolve()
    if not task_path.is_file():
        parser.error(f"task file not found: {args.task_file}")

    try:
        task_brief = parse_task_brief(task_path, args.task_file)
    except (OSError, ValueError, json.JSONDecodeError, yaml.YAMLError) as exc:
        parser.error(f"task brief parse failed for {args.task_file}: {exc}")

    header = task_brief["header"]
    requirement_refs = task_brief["requirement_refs"]
    if not requirement_refs:
        parser.error("task brief must contain at least one requirement ref (yaml/json primary, md legacy)")

    project = args.project or os.path.basename(os.getcwd())

    generated_at = datetime.now(timezone.utc).isoformat()
    source_snapshot = {
        "srs_sha": git_sha_for(SRS_PATH),
        "decisions_sha": git_sha_for(DECISIONS_PATH),
        "plan_sha": git_sha_for(PLAN_PATH),
        "task_sha": git_sha_for(args.task_file),
    }

    previous_json_path = str(Path(args.previous_json).resolve()) if args.previous_json else ""
    previous_payload = read_json(Path(args.previous_json).resolve()) if args.previous_json else None

    build_mode_tokens: list[str] = []
    requirement_payload = cached_extract_payload(
        previous_payload=previous_payload,
        payload_key="requirement_payload",
        requested_refs=requirement_refs,
        source_key="srs_sha",
        expected_source_sha=source_snapshot["srs_sha"],
    )
    if requirement_payload is None:
        srs_doc = repo_root() / SRS_PATH
        if not srs_doc.is_file():
            parser.error(f"requirement refs given but SRS doc not found: {SRS_PATH} (check srs.srs_path in runtime.config.yaml)")
        requirement_payload = extract_refs_from_markdown(
            doc_path=srs_doc,
            refs=requirement_refs,
            max_lines=12,
        )
        build_mode_tokens.append("fresh_requirement_extract")
    else:
        build_mode_tokens.append("reused_requirement_extract")

    decision_payload = cached_extract_payload(
        previous_payload=previous_payload,
        payload_key="decision_payload",
        requested_refs=args.decision_refs,
        source_key="decisions_sha",
        expected_source_sha=source_snapshot["decisions_sha"],
    )
    if decision_payload is None:
        decisions_doc = repo_root() / DECISIONS_PATH
        if not args.decision_refs:
            # No decision refs requested — don't require the (optional) decisions
            # doc to even exist. Pre-port, this unconditionally opened the file
            # and crashed with an unhandled traceback whenever DECISIONS.md was
            # absent, which is the common case for products that skip that doc.
            decision_payload = {
                "source": DECISIONS_PATH,
                "requested_refs": [],
                "matches": [],
                "missing_refs": [],
            }
        elif not decisions_doc.is_file():
            parser.error(f"--decision-refs given but decisions doc not found: {DECISIONS_PATH} (check srs.decisions_path in runtime.config.yaml)")
        else:
            decision_payload = extract_refs_from_markdown(
                doc_path=decisions_doc,
                refs=args.decision_refs,
                max_lines=12,
            )
        build_mode_tokens.append("fresh_decision_extract")
    else:
        build_mode_tokens.append("reused_decision_extract")

    build_mode = "+".join(build_mode_tokens)
    payload = {
        "task_file": args.task_file,
        "header": header,
        "goal": task_brief["goal"],
        "why_this_task_now": task_brief["why_this_task_now"],
        "requirement_refs": requirement_refs,
        "requirement_payload": requirement_payload,
        "decision_refs": args.decision_refs,
        "decision_payload": decision_payload,
        "repo_facts": task_brief["repo_facts"],
        "scope_allowlist": task_brief["scope_allowlist"],
        "acceptance_criteria": task_brief["acceptance_criteria"],
        "non_goals": task_brief["non_goals"],
        "files_to_read_first": args.files_to_read_first,
        "commands": args.command,
        "runtime_notes": args.runtime_note,
        "mcp_summary": args.mcp_item
        or [
            "filesystem: открыть task brief, source docs и реальные repo paths",
            "context7: подтвердить library/framework details перед реализацией",
            "postgres_ro: использовать только для data/runtime-contract задач",
            "github: использовать только если задача зависит от remote repo state",
            "magicui / ui-ux-pro-max: использовать только для UI-задач",
            "openaiDeveloperDocs: использовать только для OpenAI API/SDK задач",
        ],
        "ui_task": args.ui_task,
        "design_master": args.design_master,
        "design_pages": args.design_page,
        "source_snapshot": source_snapshot,
        "generated_at": generated_at,
        "build_mode": build_mode,
        "previous_context_json": previous_json_path or None,
        "project": project,
    }

    if args.output:
        markdown = build_markdown(**payload)
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(markdown, encoding="utf-8")

    if args.json_output:
        json_path = Path(args.json_output)
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    missing_refs = payload["requirement_payload"]["missing_refs"] or payload["decision_payload"]["missing_refs"]
    return 1 if missing_refs else 0


if __name__ == "__main__":
    raise SystemExit(main())
