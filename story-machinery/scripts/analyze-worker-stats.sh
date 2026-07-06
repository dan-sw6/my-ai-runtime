#!/usr/bin/env bash
# analyze-worker-stats.sh — Analyze worker-stats.csv, produce summary and recommendations
# Usage: bash scripts/analyze-worker-stats.sh [--contour CONTOUR] [--sp SP] [--json]
#
# Options:
#   --contour CONTOUR   Filter by contour (frontend|backend|full-stack)
#   --sp SP             Filter by story points
#   --json              Output JSON instead of human-readable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/runtime-config-read.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "[ERROR] not a git repo" >&2; exit 1; }
CSV_FILE="${REPO_ROOT}/docs/project/worker-stats.csv"

FILTER_CONTOUR=""
FILTER_SP=""
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contour) FILTER_CONTOUR="$2"; shift 2 ;;
    --sp) FILTER_SP="$2"; shift 2 ;;
    --json) JSON_OUTPUT=1; shift ;;
    *) echo "[WARN] Unknown arg: $1"; shift ;;
  esac
done

if [[ ! -f "$CSV_FILE" ]]; then
  echo "[ERROR] No stats file: $CSV_FILE"
  exit 1
fi

CSV_FILE="$CSV_FILE" FILTER_CONTOUR="$FILTER_CONTOUR" FILTER_SP="$FILTER_SP" JSON_OUTPUT="$JSON_OUTPUT" \
python3 << 'PYEOF'
import csv, sys, json, os
from collections import defaultdict

csv_file = os.environ.get("CSV_FILE", "")
filter_contour = os.environ.get("FILTER_CONTOUR", "")
filter_sp = os.environ.get("FILTER_SP", "")
json_output = os.environ.get("JSON_OUTPUT", "0") == "1"

rows = []
with open(csv_file) as f:
    reader = csv.DictReader(f)
    for row in reader:
        # Apply filters
        if filter_contour and row.get("contour", "") != filter_contour:
            continue
        if filter_sp and row.get("sp", "") != filter_sp:
            continue
        rows.append(row)

if not rows:
    print("[INFO] No data matching filters")
    sys.exit(0)

def safe_float(v, default=0):
    try: return float(v) if v else default
    except: return default

def safe_int(v, default=0):
    try: return int(float(v)) if v else default
    except: return default

# ── Aggregate ──
total = len(rows)
done = sum(1 for r in rows if r.get("status") == "done")
failed = sum(1 for r in rows if r.get("status") == "failed")
partial = total - done - failed

# Filter out $0/empty costs — stories without result.json data skew averages
costs = [safe_float(r["total_cost_usd"]) for r in rows if safe_float(r.get("total_cost_usd")) > 0]
turns = [safe_int(r["num_turns"]) for r in rows if safe_int(r.get("num_turns")) > 0]
durations = [safe_int(r["duration_ms"]) for r in rows if safe_int(r.get("duration_ms")) > 0]
cache_effs = [safe_float(r["cache_efficiency_pct"]) for r in rows if safe_float(r.get("cache_efficiency_pct")) > 0]

avg = lambda lst: sum(lst) / len(lst) if lst else 0

# ── By contour ──
by_contour = defaultdict(list)
for r in rows:
    c = r.get("contour", "unknown") or "unknown"
    by_contour[c].append(r)

# ── By model ──
by_model = defaultdict(list)
for r in rows:
    m = r.get("model", "unknown") or "unknown"
    by_model[m].append(r)

# ── Budget alignment ──
under = sum(1 for r in rows if safe_float(r.get("budget_util_pct")) > 0 and safe_float(r["budget_util_pct"]) < 80)
optimal = sum(1 for r in rows if 80 <= safe_float(r.get("budget_util_pct", 0)) <= 100)
over = sum(1 for r in rows if safe_float(r.get("budget_util_pct", 0)) > 100)

# ── Recommendations ──
recommendations = []
recommended_budgets = {}  # {contour: {sp: {avg, rec_from_history, floor, recommended}}}

# Static floor table — matches the run-stories skill's budget-floor rule
# actual_budget = max(static_floor[sp], history_avg*1.3)
STATIC_FLOOR = {
    "2": 4.50,
    "3": 4.50,
    "5": 7.50,
    "8": 12.00,
    "13": 18.00,
}

# Helper: classify model name into "opus" | "sonnet" | "haiku" | "unknown"
def model_class_of(model_str):
    m = (model_str or "").lower()
    if "opus" in m: return "opus"
    if "sonnet" in m: return "sonnet"
    if "haiku" in m: return "haiku"
    return "unknown"

# Budget recommendations by contour+SP (legacy flat output)
# AND by contour+model_class+SP — opus low может стоить дороже sonnet high,
# единый avg вводит в заблуждение (см. memory feedback_worker_model_choice).
# AND by contour+channel+SP — inline дешевле tmux на 2-5×, ОДИН avg по обоим
# каналам перекрывает экономию inline (см. /run-stories 2-tier routing).
recommended_budgets_by_model = {}
recommended_budgets_by_channel = {}
for contour, crows in by_contour.items():
    sp_groups = defaultdict(list)
    sp_model_groups = defaultdict(lambda: defaultdict(list))
    sp_channel_groups = defaultdict(lambda: defaultdict(list))
    for r in crows:
        sp = r.get("sp", "?")
        cost = safe_float(r.get("total_cost_usd"))
        mc = model_class_of(r.get("model", ""))
        ch = (r.get("channel") or "tmux").strip() or "tmux"
        sp_groups[sp].append(cost)
        sp_model_groups[sp][mc].append(cost)
        sp_channel_groups[sp][ch].append(cost)
    for sp, sp_costs in sp_groups.items():
        sp_costs = [c for c in sp_costs if c > 0]
        if not sp_costs:
            continue
        avg_cost = avg(sp_costs)
        if avg_cost > 0:
            rec_from_history = round(avg_cost * 1.3, 2)
            floor = STATIC_FLOOR.get(str(sp), 0)
            final_budget = round(max(floor, rec_from_history), 2)
            recommended_budgets.setdefault(contour, {})[str(sp)] = {
                "avg_cost": round(avg_cost, 2),
                "history_rec": rec_from_history,
                "static_floor": floor,
                "recommended": final_budget,
                "sample_size": len(sp_costs),
            }
        for mc, mc_costs in sp_model_groups[sp].items():
            mc_costs = [c for c in mc_costs if c > 0]
            if not mc_costs:
                continue
            mc_avg = avg(mc_costs)
            mc_rec = round(mc_avg * 1.3, 2)
            mc_final = round(max(STATIC_FLOOR.get(str(sp), 0), mc_rec), 2)
            recommended_budgets_by_model.setdefault(contour, {}).setdefault(mc, {})[str(sp)] = {
                "avg_cost": round(mc_avg, 2),
                "history_rec": mc_rec,
                "recommended": mc_final,
                "sample_size": len(mc_costs),
            }
            source = "floor" if floor >= rec_from_history else "history"
            recommendations.append(
                f"{contour} {sp}SP: avg ${avg_cost:.2f}, floor ${floor:.2f}, hist×1.3 ${rec_from_history:.2f} → USE ${final_budget:.2f} ({source})"
            )
        for ch, ch_costs in sp_channel_groups[sp].items():
            ch_costs = [c for c in ch_costs if c > 0]
            if not ch_costs:
                continue
            ch_avg = avg(ch_costs)
            ch_rec = round(ch_avg * 1.3, 2)
            # Inline может не достигать static floor (там budget неприменим
            # как hard cap); храним hist-based rec без принудительного max.
            ch_final = round(ch_rec if ch == "inline" else max(STATIC_FLOOR.get(str(sp), 0), ch_rec), 2)
            recommended_budgets_by_channel.setdefault(contour, {}).setdefault(ch, {})[str(sp)] = {
                "avg_cost": round(ch_avg, 2),
                "history_rec": ch_rec,
                "recommended": ch_final,
                "sample_size": len(ch_costs),
            }

# Model recommendation
for model, mrows in by_model.items():
    model_costs = [safe_float(r.get("total_cost_usd")) for r in mrows if safe_float(r.get("total_cost_usd"))]
    model_done = sum(1 for r in mrows if r.get("status") == "done")
    success_rate = model_done / len(mrows) * 100 if mrows else 0
    if model_costs:
        recommendations.append(
            f"Model {model}: avg ${avg(model_costs):.2f}/story, {success_rate:.0f}% success ({len(mrows)} stories)"
        )

# Failure analysis
if failed > 0:
    fail_rows = [r for r in rows if r.get("status") == "failed"]
    fail_phases = [r.get("phase_reached", "?") for r in fail_rows]
    recommendations.append(f"Failed stories: {failed}/{total} — phases: {', '.join(fail_phases)}")

# Cache efficiency
if cache_effs:
    low_cache = [r for r in rows if safe_float(r.get("cache_efficiency_pct")) < 90 and safe_float(r.get("cache_efficiency_pct")) > 0]
    if low_cache:
        ids = [r["story_id"] for r in low_cache[:3]]
        recommendations.append(f"Low cache efficiency (<90%): {', '.join(ids)} — check CLAUDE.md size or cold start")

if json_output:
    result = {
        "total_stories": total,
        "done": done,
        "failed": failed,
        "partial": partial,
        "avg_cost": round(avg(costs), 2) if costs else 0,
        "avg_turns": round(avg(turns)) if turns else 0,
        "avg_duration_min": round(avg(durations) / 60000, 1) if durations else 0,
        "avg_cache_efficiency": round(avg(cache_effs), 1) if cache_effs else 0,
        "by_contour": {
            c: {
                "count": len(crows),
                "avg_cost": round(avg([safe_float(r.get("total_cost_usd")) for r in crows if safe_float(r.get("total_cost_usd")) > 0]), 2),
                "success_rate": round(sum(1 for r in crows if r.get("status") == "done") / len(crows) * 100, 0),
            }
            for c, crows in by_contour.items()
        },
        "recommended_budgets": recommended_budgets,
        "recommended_budgets_by_model": recommended_budgets_by_model,
        "recommended_budgets_by_channel": recommended_budgets_by_channel,
        "static_floor_table": STATIC_FLOOR,
        "recommendations": recommendations,
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))
else:
    print(f"=== Worker Stats Summary ===")
    print(f"Stories: {total} | Done: {done} | Failed: {failed} | Partial: {partial}")
    if costs:
        print(f"Avg cost: ${avg(costs):.2f} | Avg turns: {avg(turns):.0f} | Avg duration: {avg(durations)/60000:.1f}min")
    if cache_effs:
        print(f"Avg cache efficiency: {avg(cache_effs):.1f}%")
    print()

    print("=== By Contour ===")
    for c, crows in sorted(by_contour.items()):
        c_costs = [safe_float(r.get("total_cost_usd")) for r in crows if safe_float(r.get("total_cost_usd")) > 0]
        c_sp = [safe_float(r.get("sp")) for r in crows if safe_float(r.get("sp"))]
        c_done = sum(1 for r in crows if r.get("status") == "done")
        cost_per_sp = avg(c_costs) / avg(c_sp) if c_sp and avg(c_sp) > 0 else 0
        print(f"  {c}: {len(crows)} stories, avg ${avg(c_costs):.2f}/story, ${cost_per_sp:.2f}/SP, {c_done}/{len(crows)} success")
    print()

    print("=== By Model ===")
    for m, mrows in sorted(by_model.items()):
        m_costs = [safe_float(r.get("total_cost_usd")) for r in mrows if safe_float(r.get("total_cost_usd")) > 0]
        m_turns = [safe_int(r.get("num_turns")) for r in mrows if safe_int(r.get("num_turns"))]
        print(f"  {m}: {len(mrows)} stories, avg ${avg(m_costs):.2f}, avg {avg(m_turns):.0f} turns")
    print()

    # Tool usage summary
    mcp_counts = [safe_int(r.get("mcp_calls")) for r in rows if safe_int(r.get("mcp_calls"))]
    skill_counts = [safe_int(r.get("skill_calls")) for r in rows if safe_int(r.get("skill_calls"))]
    builtin_counts = [safe_int(r.get("builtin_calls")) for r in rows if safe_int(r.get("builtin_calls"))]
    if mcp_counts or skill_counts:
        print("=== Tool Usage ===")
        if mcp_counts:
            print(f"  MCP calls: avg {avg(mcp_counts):.0f}/story (range {min(mcp_counts)}-{max(mcp_counts)})")
        if skill_counts:
            print(f"  Skill calls: avg {avg(skill_counts):.0f}/story")
        if builtin_counts:
            print(f"  Builtin calls: avg {avg(builtin_counts):.0f}/story")
        # Top MCP servers across stories
        all_servers = {}
        for r in rows:
            top = r.get("top_mcp_servers", "")
            if not top:
                continue
            for entry in top.split(";"):
                if ":" in entry:
                    srv, cnt = entry.rsplit(":", 1)
                    all_servers[srv] = all_servers.get(srv, 0) + safe_int(cnt)
        if all_servers:
            print("  Top MCP servers (total calls):")
            for srv, cnt in sorted(all_servers.items(), key=lambda x: -x[1])[:5]:
                print(f"    {srv}: {cnt}")
        print()

    if recommendations:
        print("=== Recommendations ===")
        for r in recommendations:
            print(f"  • {r}")

PYEOF
