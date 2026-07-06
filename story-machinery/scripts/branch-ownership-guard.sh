#!/usr/bin/env bash
# branch-ownership-guard.sh — detect foreign changes on the dev branch that
# would break a story merge, surfaced BEFORE the merge attempt (not after abort).
#
# Problem: a concurrent process committed to the base branch AND left an
# unrelated staged changeset in the working tree mid-run.
# `merge-with-rtm-strategy.sh` aborted only AFTER the gate passed — the
# coordinator had to diagnose reactively. /run-stories silently assumed
# exclusive ownership of the dev branch and never verified it.
#
# Modes:
#   snapshot <branch>   — record baseline (HEAD sha) at Phase B.0
#   check <branch>      — compare before each merge (Phase B.1.4)
#
# Allowlist (expected dirty, NOT foreign): the RTM file (auto-regenerated
# per-story) and story-brief drafts (create-story drafts / worker-authoritative).
#
# Output (check): compact JSON
#   {"clean":true,"reason":"owned"}
#   {"clean":false,"reason":"foreign-uncommitted-or-staged","foreign":["..."]}
#   {"clean":true,"reason":"owned","note":"head-moved:<n>-commits-since-baseline"}
#
# Exit: 0 = clean (safe to merge), 1 = foreign change present (STOP, AskUser).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

MODE="${1:?Usage: $0 snapshot|check <branch>}"
BRANCH="${2:?Usage: $0 ${MODE} <branch>}"

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
RUNTIME_DIR="$(dirname "$STATE_DIR")/run-stories-runtime"
BASELINE="${RUNTIME_DIR}/branch-baseline.json"
mkdir -p "$RUNTIME_DIR"

RTM_PATH="$(rcfg srs.rtm_path docs/rtm.yaml)"
STORY_DIR="$(rcfg ao.story_dir docs/stories)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"clean":false,"reason":"not-a-git-repo"}'; exit 1
}
cd "$REPO_ROOT" || { echo '{"clean":false,"reason":"cd-failed"}'; exit 1; }

# Tracked/untracked paths that are legitimately dirty during a run.
is_allowlisted() {
  case "$1" in
    "${RTM_PATH}") return 0 ;;
    "${STORY_DIR}"/STORY-*.md) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "$MODE" == "snapshot" ]]; then
  HEAD_SHA="$(git rev-parse "$BRANCH" 2>/dev/null || echo unknown)"
  printf '{"branch":%s,"head_sha":%s,"ts":%s}\n' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$BRANCH")" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$HEAD_SHA")" \
    "$(python3 -c 'import json,time;print(json.dumps(time.strftime("%Y-%m-%dT%H:%M:%S%z")))')" \
    > "$BASELINE"
  echo "{\"snapshot\":true,\"branch\":\"${BRANCH}\",\"head_sha\":\"${HEAD_SHA}\"}"
  exit 0
fi

if [[ "$MODE" != "check" ]]; then
  echo "{\"clean\":false,\"reason\":\"unknown-mode:${MODE}\"}"; exit 1
fi

# Foreign dirty detection — the actual merge-blocker.
FOREIGN=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # porcelain: XY <path>  (rename = "R  old -> new")
  xy="${line:0:2}"
  path="${line:3}"
  path="${path##* -> }"   # rename → take destination
  # Unmerged state (UU/AA/DD/AU/UA/DU/UD) blocks ANY git op — flag regardless
  # of allowlist (allowlisted UU rtm.yaml reported clean while cherry-pick
  # refused with "unmerged files").
  case "$xy" in
    U?|?U|AA|DD) FOREIGN+="${path}(unmerged);"; continue ;;
  esac
  is_allowlisted "$path" && continue
  FOREIGN+="${path};"
done < <(git status --porcelain 2>/dev/null)

# Informational: did the dev branch HEAD move since baseline? (Coordinator's own
# merges legitimately move it — so this is a note, not the blocking decision.)
NOTE=""
if [[ -f "$BASELINE" ]]; then
  BASE_SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("head_sha",""))' "$BASELINE" 2>/dev/null)"
  CUR_SHA="$(git rev-parse "$BRANCH" 2>/dev/null || echo unknown)"
  if [[ -n "$BASE_SHA" && "$BASE_SHA" != "$CUR_SHA" && "$BASE_SHA" != "unknown" ]]; then
    N="$(git rev-list --count "${BASE_SHA}..${CUR_SHA}" 2>/dev/null || echo '?')"
    NOTE="head-moved:${N}-commits-since-baseline"
  fi
fi

if [[ -n "$FOREIGN" ]]; then
  printf '{"clean":false,"reason":"foreign-uncommitted-or-staged","foreign":%s%s}\n' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1].rstrip(";").split(";")))' "$FOREIGN")" \
    "$([[ -n "$NOTE" ]] && printf ',"note":%s' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTE")")"
  exit 1
fi

printf '{"clean":true,"reason":"owned"%s}\n' \
  "$([[ -n "$NOTE" ]] && printf ',"note":%s' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTE")")"
exit 0
