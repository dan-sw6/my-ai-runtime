#!/usr/bin/env bash
# launch-review-worker.sh — Launch a headless Claude Code worker for post-merge code review
# Usage: bash scripts/launch-review-worker.sh STORY-ID BEFORE_SHA AFTER_SHA [--budget USD] [--model MODEL]
#
# Runs the configured review agents (ao.review_agents, default: code-reviewer only)
# on the diff between two commits.
# Results written to $(rcfg state_dir /tmp/claude-workers)/review-{STORY-ID}/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID BEFORE_SHA AFTER_SHA [--model MODEL]}"
BEFORE_SHA="${2:?Missing BEFORE_SHA}"
AFTER_SHA="${3:?Missing AFTER_SHA}"
MODEL="sonnet"

# 2026-05-08: --budget принимается но игнорируется — user mandate, no caps.
shift 3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget) shift 2 ;;  # ignored
    --model) MODEL="$2"; shift 2 ;;
    *) echo "[ERROR] Unknown arg: $1"; exit 1 ;;
  esac
done

STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WORKER_DIR="${STATE_DIR}/review-${STORY_ID}"
mkdir -p "$WORKER_DIR"

# Capture diff
DIFF=$(git diff "${BEFORE_SHA}..${AFTER_SHA}" 2>/dev/null)
DIFF_STATS=$(git diff --stat "${BEFORE_SHA}..${AFTER_SHA}" 2>/dev/null)
CHANGED_FILES=$(git diff --name-only "${BEFORE_SHA}..${AFTER_SHA}" 2>/dev/null)

if [[ -z "$DIFF" ]]; then
  echo "[WARN] No diff between ${BEFORE_SHA} and ${AFTER_SHA}. Skipping review."
  echo '{"status":"skipped","reason":"no_diff"}' > "${WORKER_DIR}/result.json"
  exit 0
fi

echo "[INFO] Reviewing ${STORY_ID}: ${BEFORE_SHA:0:8}..${AFTER_SHA:0:8}"
echo "[INFO] Changed files: $(echo "$CHANGED_FILES" | wc -l)"

# Review agents — configurable via ao.review_agents (default: code-reviewer only).
# Upstream (mgt-openproject) hardcoded code-reviewer + silent-failure-hunter +
# type-design-analyzer; the latter two are project-specific agent defs that may
# not exist in every product's `_base` agent set, so они теперь opt-in через config.
REVIEW_AGENTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && REVIEW_AGENTS+=("$line")
done < <(rcfg_list ao.review_agents)
[[ ${#REVIEW_AGENTS[@]} -eq 0 ]] && REVIEW_AGENTS=(code-reviewer)

# Numbered "MUST spawn Agent(...)" instructions block. Known agents keep their
# upstream-specific checklist; unrecognised names get a generic instruction.
AGENT_INSTRUCTIONS=""
STEP=1
for AGENT in "${REVIEW_AGENTS[@]}"; do
  case "$AGENT" in
    code-reviewer)
      AGENT_INSTRUCTIONS+="${STEP}. MUST spawn Agent(subagent_type='code-reviewer') to review this diff for:
   - Security vulnerabilities (OWASP top 10)
   - Code quality issues
   - Missing error handling
   - Type safety problems

"
      ;;
    silent-failure-hunter)
      AGENT_INSTRUCTIONS+="${STEP}. MUST spawn Agent(subagent_type='silent-failure-hunter') to check for:
   - Silent failures in catch blocks
   - Inadequate error handling
   - Inappropriate fallback behavior

"
      ;;
    type-design-analyzer)
      AGENT_INSTRUCTIONS+="${STEP}. If any new types are introduced, spawn Agent(subagent_type='type-design-analyzer').

"
      ;;
    *)
      AGENT_INSTRUCTIONS+="${STEP}. MUST spawn Agent(subagent_type='${AGENT}') to review this diff.

"
      ;;
  esac
  STEP=$((STEP + 1))
done
REPORT_STEP=$STEP
VERDICT_STEP=$((STEP + 1))

PROMPT="You are a post-merge code reviewer for ${STORY_ID}.

## Diff Stats
${DIFF_STATS}

## Changed Files
${CHANGED_FILES}

## Full Diff
${DIFF}

## Instructions

${AGENT_INSTRUCTIONS}${REPORT_STEP}. Report your findings as structured JSON:
{
  \"status\": \"APPROVE\" or \"REQUEST_CHANGES\",
  \"story_id\": \"${STORY_ID}\",
  \"findings\": [{\"severity\": \"high|medium|low\", \"file\": \"path\", \"line\": N, \"finding\": \"desc\", \"suggestion\": \"fix\"}],
  \"summary\": \"one line summary\"
}

${VERDICT_STEP}. Write verdict to file:
   echo 'APPROVE' > ${WORKER_DIR}/verdict   (or 'REQUEST_CHANGES')"

echo "[INFO] Starting review worker..."

claude \
  --print \
  --model "${MODEL}" \
  --output-format text \
  --dangerously-skip-permissions \
  --permission-mode bypassPermissions \
  -p "${PROMPT}" \
  > "${WORKER_DIR}/result.json" \
  2> "${WORKER_DIR}/stderr.log" &

WORKER_PID=$!
echo "${WORKER_PID}" > "${WORKER_DIR}/pid"
echo "$(date -Iseconds)" > "${WORKER_DIR}/started_at"

echo "[INFO] Review worker PID: ${WORKER_PID}"
echo "${WORKER_PID}"

# Schedule auto-fixup async (waits for review-worker exit, then parses result.json
# для severity=high findings → spawns STORY-${id}-fixup story). Inert при
# отсутствии blocking findings или malformed JSON. Disable via NO_AUTO_FIXUP=1.
if [[ "${NO_AUTO_FIXUP:-0}" != "1" ]]; then
  bash "$SCRIPT_DIR/auto-fixup-from-review.sh" "${STORY_ID}" \
    --wait-for-pid="${WORKER_PID}" --max-wait=600 \
    > "${WORKER_DIR}/auto-fixup.json" 2>> "${WORKER_DIR}/stderr.log" &
fi
