#!/usr/bin/env bash
# worktree-gate.sh — coordinator-side independent gate for a story worktree.
#
# The worker's own gate.json is untrusted (a worker can fabricate pass values via
# `cat > gate.json`). So the coordinator re-verifies independently: worktree exists,
# branch has real commits, diff.json commit SHAs actually exist (anti-fabrication),
# clean tree, base auto-merge, and the CONFIGURED gate commands actually pass.
#
# Gate commands come from `ao.gate_registry` in runtime.config.yaml — a list of
# {match: <changed-path regex>, cmd: <shell command>} rules (lindy-orchestrator
# qa_gates style). For each rule whose regex matches any changed file (base..HEAD),
# its command runs; {gates.X} tokens expand from the gates: block. This replaces the
# platform/-hardcoded frontend/backend routing of the original.
#
# Usage: bash worktree-gate.sh STORY-ID [--base-ref BRANCH] [--skip-gates]
# Output: compact JSON {"pass":bool,"reason":str,"details":str}. Exit 0 pass / 1 fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID [--base-ref BRANCH] [--skip-gates]}"
BASE_REF="$(rcfg ao.base_ref main)"
SKIP_GATES=0
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --skip-gates|--skip-tests) SKIP_GATES=1; shift ;;
    *) echo "{\"pass\":false,\"reason\":\"unknown-arg:$1\"}"; exit 1 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "{\"pass\":false,\"reason\":\"not-a-git-repo\"}"; exit 1
}
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WORKTREE_ROOT="$(rcfg ao.worktree_root .claude/worktrees)"
WORKTREE="${REPO_ROOT}/${WORKTREE_ROOT}/${STORY_ID}"
# Lowercase the story suffix — worker dirs are created as `story-<lc>`. Alpha-suffix
# IDs (STORY-D01) would otherwise miss the real story-d01/diff.json and skip the
# anti-fabrication SHA verification.
WORKER_DIR="${STATE_DIR}/story-$(printf '%s' "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"

# --- Pre-check 0: prune stale/zombie worker PIDs (best-effort) ---
[[ -x "$SCRIPT_DIR/cleanup-stale-pids.sh" ]] && bash "$SCRIPT_DIR/cleanup-stale-pids.sh" >/dev/null 2>&1 || true

_json() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
fail() {
  local reason="$1" details="${2:-}"
  if [[ -n "$details" ]]; then
    printf '{"pass":false,"reason":%s,"details":%s}\n' "$(_json "$reason")" "$(_json "$details")"
  else
    printf '{"pass":false,"reason":%s}\n' "$(_json "$reason")"
  fi
  exit 1
}
pass() { printf '{"pass":true,"reason":"gate-ok","details":%s}\n' "$(_json "$1")"; exit 0; }

# --- Check 1: worktree exists ---
[[ -d "$WORKTREE" ]] || fail "worktree-missing" "$WORKTREE"
cd "$WORKTREE"

# --- Check 2: branch has commits beyond base ---
BASE_SHA=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || fail "base-ref-missing" "$BASE_REF"
COMMITS_AHEAD=$(git log --oneline "${BASE_SHA}..HEAD" 2>/dev/null | wc -l)
[[ "$COMMITS_AHEAD" -lt 1 ]] && fail "no-commits-on-branch" "0 commits beyond $BASE_REF"

# --- Check 3: diff.json commit SHAs exist on branch (anti-fabrication) ---
DIFF_JSON="${WORKER_DIR}/diff.json"
if [[ -f "$DIFF_JSON" ]]; then
  INVALID_SHAS=$(python3 - "$DIFF_JSON" "$WORKTREE" <<'PY'
import json, re, subprocess, sys
diff_json, worktree = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(diff_json))
except Exception as e:
    sys.exit(f"diff-json-unparseable:{e}")
bad = []
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
for c in d.get("commits", []):
    sha = c.get("sha", "") if isinstance(c, dict) else (c if isinstance(c, str) else "")
    if not sha:
        bad.append("empty-sha"); continue
    if not SHA_RE.match(sha):
        bad.append(f"non-hex-sha:{sha}"); continue
    r = subprocess.run(["git", "rev-parse", "--verify", f"{sha}^{{commit}}"],
                       capture_output=True, cwd=worktree)
    if r.returncode != 0:
        bad.append(sha)
print(",".join(bad) if bad else "")
PY
)
  EXIT=$?
  [[ $EXIT -ne 0 ]] && fail "diff-json-corrupt" "$INVALID_SHAS"
  [[ -n "$INVALID_SHAS" ]] && fail "diff-json-fabricated-sha" "invalid:$INVALID_SHAS"
fi

# --- Check 4: working tree clean (exclude prep-provisioned worktree-local files) ---
DIRTY=$(git status --porcelain 2>/dev/null \
  | grep -vE '^.{2} (\.mcp\.json|CLAUDE\.md|\.claude/settings\.local\.json)$|^.{2} \.serena/' \
  || true)
[[ -n "$DIRTY" ]] && fail "dirty-working-tree" "$(echo "$DIRTY" | head -5 | tr '\n' ';')"

# --- Check 4.5: auto-merge updated base ref into worktree ---
ORIG_BASE_TIP=$(git -C "${REPO_ROOT}" rev-parse "${BASE_REF}" 2>/dev/null)
WT_MERGE_BASE=$(git merge-base HEAD "${BASE_REF}" 2>/dev/null)
if [[ "${WT_MERGE_BASE}" != "${ORIG_BASE_TIP}" ]]; then
  echo "[gate] base ref ahead of worktree — auto-merging ${BASE_REF}..." >&2
  if ! git merge "${BASE_REF}" --no-ff --no-edit -m "Merge ${BASE_REF} into worktree (gate auto-rebase)" >/tmp/wtg-merge.log 2>&1; then
    CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null)
    # Docs-only conflict auto-resolve — ONLY when the SRS module is enabled (its
    # reconcile writes SRS/RTM/story docs to base before worktrees merge). Otherwise
    # any conflict aborts. Policy (merge base→worktree): story docs keep --ours
    # (done-status/closeout); srs/rtm/report docs take --theirs (base authoritative);
    # rtm.yaml is rebuilt.
    if rcfg_bool srs.enabled; then
      STORY_DIR="$(rcfg ao.story_dir docs/stories)"
      SRS_PATH="$(rcfg srs.srs_path docs/SRS.md)"
      ARCHIVE_PATH="$(rcfg srs.archive_path docs/srs/implemented-archive.md)"
      RTM_PATH="$(rcfg srs.rtm_path docs/rtm.yaml)"
      ARCHIVE_DIR="$(dirname "$ARCHIVE_PATH")"
      NON_DOCS=$(echo "${CONFLICTED}" | grep -vE "^(${SRS_PATH//./\\.}|${ARCHIVE_DIR}/|docs/audit/|docs/reports/|docs/backlog/|${RTM_PATH//./\\.}|${STORY_DIR}/STORY-[0-9A-Za-z-]+\.md)$" || true)
      if [[ -n "${CONFLICTED}" && -z "${NON_DOCS}" ]]; then
        echo "[gate] docs-only rebase conflict — auto-resolving by policy" >&2
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          case "$f" in
            "${STORY_DIR}"/STORY-*.md) git checkout --ours -- "$f" ;;
            "${RTM_PATH}")             : ;;
            *)                         git checkout --theirs -- "$f" ;;
          esac
          git add -- "$f"
        done <<< "${CONFLICTED}"
        if echo "${CONFLICTED}" | grep -qF "${RTM_PATH}"; then
          [[ -x "$SCRIPT_DIR/../srs/rebuild-rtm.sh" ]] && ( cd "${REPO_ROOT}" && bash "$SCRIPT_DIR/../srs/rebuild-rtm.sh" >/dev/null 2>&1 ) || true
          git add -- "${RTM_PATH}" 2>/dev/null || true
        fi
        git commit --no-edit >/tmp/wtg-merge.log 2>&1 || fail "auto-rebase-conflict" "docs-resolve commit failed"
        echo "[gate] docs-only conflict resolved" >&2
      else
        git merge --abort 2>/dev/null || true
        fail "auto-rebase-conflict" "non-docs conflict: ${NON_DOCS:-?}"
      fi
    else
      git merge --abort 2>/dev/null || true
      fail "auto-rebase-conflict" "conflict on: $(echo "${CONFLICTED}" | tr '\n' ' ')"
    fi
  fi
  echo "[gate] auto-merge OK" >&2
fi
BASE_SHA=$(git merge-base HEAD "$BASE_REF" 2>/dev/null)

# --- Check 5: run CONFIGURED gate commands for matched changed files ---
CHANGED=$(git diff --name-only "${BASE_SHA}..HEAD")
GATE_DETAILS=""
if [[ "$SKIP_GATES" -eq 1 ]]; then
  GATE_DETAILS+="gates:skipped;"
elif [[ -z "$CHANGED" ]]; then
  GATE_DETAILS+="no-changes;"
else
  GATE_JSON="$(rcfg_json ao.gate_registry '[]')"
  # Collect the deduped list of gate commands whose match-regex hits a changed file.
  # (Program via heredoc on stdin; data via argv — can't use both stdin channels.)
  CMDS=$(python3 - "$GATE_JSON" "$CHANGED" <<'PY'
import json, re, sys
rules = json.loads(sys.argv[1] or "[]")
changed = sys.argv[2].splitlines()
seen = []
for r in rules:
    if not isinstance(r, dict):
        continue
    m, c = r.get("match", ""), r.get("cmd", "")
    if not c:
        continue
    try:
        rx = re.compile(m)
    except re.error:
        continue
    if any(rx.search(f) for f in changed) and c not in seen:
        seen.append(c)
print("\n".join(seen))
PY
)
  if [[ -z "$CMDS" ]]; then
    GATE_DETAILS+="no-matching-gate;"
  else
    while IFS= read -r raw; do
      [[ -z "$raw" ]] && continue
      cmd="$(rcfg_expand "$raw")"
      echo "[gate] running: $cmd" >&2
      if ! bash -c "$cmd" >/tmp/wtg-gate.log 2>&1; then
        fail "gate-command-failed" "cmd='$cmd' :: $(tail -20 /tmp/wtg-gate.log | tr '\n' ' ')"
      fi
      GATE_DETAILS+="ok:$(printf '%s' "$cmd" | cut -c1-40);"
    done <<< "$CMDS"
  fi
fi

# --- Check 5.5: governance scope-leak (informational warn, not blocking) ---
GOV_LEAK=""
STORY_DIR="$(rcfg ao.story_dir docs/stories)"
STORY_FILE="${REPO_ROOT}/${STORY_DIR}/${STORY_ID}.md"
GOV_CHANGED=$(echo "$CHANGED" | grep -E '^\.claude/(agents|skills)/' || true)
if [[ -n "$GOV_CHANGED" && -f "$STORY_FILE" ]]; then
  FA=$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$STORY_FILE" 2>/dev/null \
        | awk '/^files_affected:/{f=1;next} /^[a-z_]+:/{f=0} f' | tr -d ' "-')
  while IFS= read -r gf; do
    [[ -z "$gf" ]] && continue
    grep -qF "$gf" <<<"$FA" || GOV_LEAK+="${gf};"
  done <<<"$GOV_CHANGED"
fi

# --- Check 6: worker state-JSON claims (informational) ---
WORKER_CLAIMS="absent"
if [[ -f "${WORKER_DIR}/gate.json" ]]; then
  WORKER_CLAIMS=$(python3 -c "
import json
d = json.load(open('${WORKER_DIR}/gate.json'))
print('lint=',d.get('lint',{}).get('pass'),'tsc=',d.get('typecheck',{}).get('pass'),'tests=',d.get('tests',{}).get('pass'))
" 2>/dev/null || echo "unparseable")
fi

GATE_DETAILS+="commits:${COMMITS_AHEAD};worker_claimed:${WORKER_CLAIMS}"
[[ -n "$GOV_LEAK" ]] && GATE_DETAILS+=";WARN_governance_scope_leak:${GOV_LEAK}"
pass "$GATE_DETAILS"
