#!/usr/bin/env bash
# gate-diff-vs-base.sh — отделить regressions от pre-existing failures.
#
# Usage: bash scripts/gate-diff-vs-base.sh STORY-XXX [base-ref]
#   STORY-XXX  — нормализуется к lowercase для <state_dir>/story-xxx
#   base-ref   — default: ao.base_ref (runtime.config.yaml), обычно main
#
# Output: <state_dir>/story-XXX/gate-delta.json:
#   {"new_failures":[...], "preexisting":[...], "fixed":[...], "base_count":N, "wt_count":M}
#
# Workflow:
#   1. Снапшот текущего worktree fail-list (test-cmd прогон + tail).
#   2. git checkout <base-ref> -- .  (весь tracked tree).
#   3. Тот же test-cmd → base fail-list.
#   4. git checkout HEAD -- .  (restore).
#   5. comm -23/comm -13/comm -12 → delta JSON.
#
# ПРИМЕЧАНИЕ: test-cmd (ao.diff_test_cmd) должен быть pytest-совместимым —
# failure marker ниже (`^FAILED`) заточен под pytest output.
#
# ВНИМАНИЕ: ломает worktree state на ~2-3 минуты; не запускать параллельно с executor'ами.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?usage: gate-diff-vs-base.sh STORY-XXX [base-ref]}"
BASE_REF="${2:-$(rcfg ao.base_ref main)}"
SHORT="${STORY_ID#STORY-}"
WDIR="$(rcfg state_dir /tmp/claude-workers)/story-$(echo "$SHORT" | tr '[:upper:]' '[:lower:]')"
mkdir -p "$WDIR"

# TODO(coordinator): consider adding `ao.diff_test_cmd` to runtime.config.example.yaml
# (default below is a generic whole-repo pytest run — override per-product if tests
# live under a subdir, e.g. "python -m pytest platform/apps/backend/tests/ -n auto -q --tb=no").
read -r -a PYTEST_CMD <<< "$(rcfg ao.diff_test_cmd 'python -m pytest -q --tb=no')"

echo "[gate-diff] capturing worktree failures..."
"${PYTEST_CMD[@]}" 2>&1 | grep "^FAILED" | sort > "$WDIR/gate-wt-failures.txt" || true
WT_N=$(wc -l < "$WDIR/gate-wt-failures.txt")
echo "[gate-diff] worktree fails: $WT_N"

echo "[gate-diff] swapping to $BASE_REF source tree (worktree untouched)..."
# Сохранить SHA текущего HEAD для verify
HEAD_SHA=$(git rev-parse HEAD)
git checkout "$BASE_REF" -- . 2>/dev/null || {
  echo "[gate-diff] ERROR: cannot checkout $BASE_REF tree; aborting"
  exit 1
}

echo "[gate-diff] capturing base failures..."
"${PYTEST_CMD[@]}" 2>&1 | grep "^FAILED" | sort > "$WDIR/gate-base-failures.txt" || true
BASE_N=$(wc -l < "$WDIR/gate-base-failures.txt")

echo "[gate-diff] restoring worktree (HEAD=$HEAD_SHA)..."
git checkout HEAD -- .
[[ -z "$(git status --porcelain .)" ]] || {
  echo "[gate-diff] WARN: worktree not fully restored; manual check needed"
}

echo "[gate-diff] computing delta..."
NEW=$(comm -23 "$WDIR/gate-wt-failures.txt" "$WDIR/gate-base-failures.txt" | sed 's/^FAILED //')
FIXED=$(comm -13 "$WDIR/gate-wt-failures.txt" "$WDIR/gate-base-failures.txt" | sed 's/^FAILED //')
PRE=$(comm -12 "$WDIR/gate-wt-failures.txt" "$WDIR/gate-base-failures.txt" | sed 's/^FAILED //')

python3 - <<PY > "$WDIR/gate-delta.json"
import json
new = """$NEW""".strip().splitlines()
fixed = """$FIXED""".strip().splitlines()
pre = """$PRE""".strip().splitlines()
print(json.dumps({
  "base_ref": "$BASE_REF",
  "base_count": $BASE_N,
  "wt_count": $WT_N,
  "new_failures": [x for x in new if x],
  "fixed": [x for x in fixed if x],
  "preexisting": [x for x in pre if x],
}, indent=2))
PY

echo "[gate-diff] wrote $WDIR/gate-delta.json"
echo "[gate-diff] summary: base=$BASE_N wt=$WT_N new=$(echo "$NEW" | grep -c .) fixed=$(echo "$FIXED" | grep -c .)"
