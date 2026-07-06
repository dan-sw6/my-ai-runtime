#!/usr/bin/env bash
# wave-status.sh — live dashboard for /run-stories wave monitoring.
#
# Contract: .claude/rules/phase-contract.md
# Modes:
#   wave-status.sh                  # table: all active stories in ${STATE_DIR}/
#   wave-status.sh STORY-214        # per-story timeline
#   wave-status.sh --stuck          # only stuck stories
#   wave-status.sh --json           # compact JSON for coordinator parsing
#
# Output: human-readable table (default) or JSON (--json).
#
# Threshold config (optional):
#   ${STATE_DIR}/wave-thresholds.json — user override
#   defaults embedded below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

WORKERS_DIR="$(rcfg state_dir /tmp/claude-workers)"
THRESHOLDS_FILE="${WORKERS_DIR}/wave-thresholds.json"

MODE="table"
TARGET_STORY=""
case "${1:-}" in
  "")           MODE="table" ;;
  --json)       MODE="json" ;;
  --stuck)      MODE="stuck" ;;
  STORY-*)      MODE="per-story"; TARGET_STORY="$1" ;;
  *)            echo "usage: wave-status.sh [STORY-ID | --stuck | --json]" >&2; exit 2 ;;
esac

python3 - "${WORKERS_DIR}" "${THRESHOLDS_FILE}" "${MODE}" "${TARGET_STORY}" << 'PY'
import json, os, sys, time
from pathlib import Path
from datetime import datetime, timezone

workers_dir = Path(sys.argv[1])
thresholds_file = Path(sys.argv[2])
mode = sys.argv[3]
target_story = sys.argv[4]

# --- Defaults (seconds): warn + stuck per phase ---
DEFAULT_THRESHOLDS = {
    "0-init":          {"warn": 300,  "stuck": 900},
    "0.1-mem-search":  {"warn": 120,  "stuck": 300},
    "1-plan":          {"warn": 600,  "stuck": 1500},
    "2-implement":     {"warn": 1800, "stuck": 3600},
    "2.1.5-simplify":  {"warn": 300,  "stuck": 900},
    "2.2-a11y":        {"warn": 300,  "stuck": 900},
    "3-gate":          {"warn": 600,  "stuck": 1200},
    "3.3-audits":      {"warn": 300,  "stuck": 900},
    "4-verify":        {"warn": 300,  "stuck": 900},
    "5-close":         {"warn": 180,  "stuck": 600},
    "_default_multiplier": 1.0,
    "_first_story_multiplier": 1.5,
}

thresholds = DEFAULT_THRESHOLDS.copy()
if thresholds_file.exists():
    try:
        user_cfg = json.loads(thresholds_file.read_text())
        thresholds.update(user_cfg)
    except Exception:
        pass  # игнорим кривой конфиг, используем defaults

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None

def read_phase_log(story_dir):
    """Parse phase-log JSON-lines. Return (schema, events, corrupted_count)."""
    log_path = story_dir / "phase-log"
    if not log_path.exists():
        return ("missing", [], 0)
    events = []
    corrupted = 0
    schema = "legacy"
    for i, line in enumerate(log_path.read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            corrupted += 1
            continue
        if i == 0 and obj.get("schema"):
            schema = obj.get("schema")
            continue
        events.append(obj)
    return (schema, events, corrupted)

def current_phase(events):
    """From events, derive current phase + its start time + its status."""
    if not events:
        return (None, None, None, None)
    # find last 'start' event without a matching complete/skipped/failed/blocked after it
    current = None
    current_start = None
    current_status = None
    last_terminal = None
    for ev in events:
        ph = ev.get("phase")
        st = ev.get("status")
        if st == "start":
            current = ph
            current_start = parse_ts(ev.get("ts"))
            current_status = "in-progress"
        elif st in ("complete", "skipped", "failed", "blocked"):
            if ph == current:
                current_status = st
                last_terminal = ev
    # Если последний event — complete на 5-close, вся story завершена.
    last = events[-1]
    if last.get("phase") == "5-close" and last.get("status") == "complete":
        return ("5-close", parse_ts(last.get("ts")), "complete", None)
    return (current, current_start, current_status, last_terminal)

def elapsed_seconds(started_at):
    if started_at is None:
        return None
    now = datetime.now(started_at.tzinfo or timezone.utc)
    return int((now - started_at).total_seconds())

def format_elapsed(sec):
    if sec is None:
        return "-"
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"

def stuck_level(phase, elapsed, is_first_story):
    """Return 'ok' | 'warn' | 'stuck' based on thresholds."""
    if phase is None or elapsed is None:
        return "ok"
    cfg = thresholds.get(phase)
    if not cfg or not isinstance(cfg, dict):
        return "ok"
    mult = thresholds.get("_first_story_multiplier", 1.5) if is_first_story else thresholds.get("_default_multiplier", 1.0)
    warn = cfg.get("warn", 0) * mult
    stuck = cfg.get("stuck", 0) * mult
    if stuck and elapsed >= stuck:
        return "stuck"
    if warn and elapsed >= warn:
        return "warn"
    return "ok"

# --- Scan all story-dirs ---
stories = []
if not workers_dir.exists():
    print(json.dumps({"error": f"workers-dir-missing:{workers_dir}"}) if mode == "json" else f"workers-dir missing: {workers_dir}")
    sys.exit(0)

story_dirs = sorted([d for d in workers_dir.iterdir() if d.is_dir() and d.name.startswith("story-")])

# First-story detection: earliest started timestamp wins
first_story_id = None
earliest_start = None
for d in story_dirs:
    schema, events, _ = read_phase_log(d)
    if schema != "v1" or not events:
        continue
    # first line (schema marker) has started; events start from line 2
    log_path = d / "phase-log"
    try:
        first_obj = json.loads(log_path.read_text().splitlines()[0])
        started = parse_ts(first_obj.get("started"))
        if started and (earliest_start is None or started < earliest_start):
            earliest_start = started
            first_story_id = d.name
    except Exception:
        pass

for d in story_dirs:
    schema, events, corrupted = read_phase_log(d)
    story_id = d.name.replace("story-", "STORY-")
    if schema == "missing":
        continue
    if schema != "v1":
        stories.append({
            "story": story_id,
            "schema": schema,
            "phase": None,
            "status": "legacy",
            "elapsed_sec": None,
            "elapsed_str": "-",
            "stuck_level": "ok",
            "corrupted_lines": corrupted,
            "events_count": len(events),
        })
        continue
    phase, started, status, _ = current_phase(events)
    elapsed = elapsed_seconds(started)
    is_first = (d.name == first_story_id)
    lvl = stuck_level(phase, elapsed, is_first) if status == "in-progress" else "ok"
    stories.append({
        "story": story_id,
        "schema": schema,
        "phase": phase,
        "status": status,
        "elapsed_sec": elapsed,
        "elapsed_str": format_elapsed(elapsed),
        "stuck_level": lvl,
        "corrupted_lines": corrupted,
        "events_count": len(events),
        "is_first_story": is_first,
    })

# --- Output modes ---
def output_json():
    all_complete = all(
        s["phase"] == "5-close" and s["status"] == "complete"
        for s in stories if s["schema"] == "v1"
    ) and len([s for s in stories if s["schema"] == "v1"]) > 0
    any_stuck = any(s["stuck_level"] == "stuck" for s in stories)
    any_blocked = any(s["status"] == "blocked" for s in stories)
    any_failed = any(s["status"] == "failed" for s in stories)
    print(json.dumps({
        "checked_at": datetime.now().isoformat(),
        "total": len(stories),
        "all_complete": all_complete,
        "any_stuck": any_stuck,
        "any_blocked": any_blocked,
        "any_failed": any_failed,
        "stories": stories,
    }, ensure_ascii=False, separators=(",", ":")))

def output_table(filter_stuck=False):
    if not stories:
        print(f"(no worker-dirs found under {workers_dir}/)")
        return
    rows = stories
    if filter_stuck:
        rows = [s for s in stories if s["stuck_level"] == "stuck"]
        if not rows:
            print("(no stuck stories)")
            return
    # Header
    print(f"{'STORY-ID':<14} | {'current-phase':<18} | {'status':<12} | {'elapsed':>8} | stuck?")
    print(f"{'-' * 14}-+-{'-' * 18}-+-{'-' * 12}-+-{'-' * 8}-+-{'-' * 12}")
    for s in rows:
        stuck_str = "-"
        if s["stuck_level"] == "warn":
            stuck_str = "WARN (soft)"
        elif s["stuck_level"] == "stuck":
            stuck_str = "STUCK (hard)"
        phase = s["phase"] or "-"
        status = s["status"] or "-"
        print(f"{s['story']:<14} | {phase:<18} | {status:<12} | {s['elapsed_str']:>8} | {stuck_str}")
    # Footer summary
    legacy_count = sum(1 for s in stories if s["schema"] != "v1")
    if legacy_count:
        print(f"\nNote: {legacy_count} legacy worker-dir(s) excluded from phase-guard checks.")

def output_per_story():
    # normalize: STORY-D01 → story-d01 (lowercase, ext4 case-sensitive) — devcycle-audit #16, 2026-05-29
    target_dir = workers_dir / f"story-{target_story.replace('STORY-', '').replace('story-', '').lower()}"
    if not target_dir.exists():
        print(f"(story-dir not found: {target_dir})")
        sys.exit(1)
    schema, events, corrupted = read_phase_log(target_dir)
    print(f"STORY: {target_story}")
    print(f"Schema: {schema}")
    print(f"Worker dir: {target_dir}")
    print(f"Events: {len(events)}, Corrupted: {corrupted}\n")
    if schema != "v1":
        print("(legacy phase-log, timeline not available)")
        return
    print(f"{'#':>3} | {'timestamp':<25} | {'phase':<18} | {'status':<10} | reason")
    print(f"{'-' * 3}-+-{'-' * 25}-+-{'-' * 18}-+-{'-' * 10}-+-{'-' * 40}")
    for i, ev in enumerate(events, 1):
        ts = ev.get("ts", "")[:25]
        ph = ev.get("phase", "-")
        st = ev.get("status", "-")
        rs = ev.get("reason", "-")
        print(f"{i:>3} | {ts:<25} | {ph:<18} | {st:<10} | {rs}")
    # Summary
    phase, started, status, _ = current_phase(events)
    el = elapsed_seconds(started)
    print(f"\nCurrent: {phase} ({status}), elapsed: {format_elapsed(el)}")

if mode == "json":
    output_json()
elif mode == "stuck":
    output_table(filter_stuck=True)
elif mode == "per-story":
    output_per_story()
else:
    output_table()
PY
