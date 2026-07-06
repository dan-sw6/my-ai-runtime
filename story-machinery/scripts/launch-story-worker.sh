#!/usr/bin/env bash
# launch-story-worker.sh — Launch a headless or interactive Claude Code worker for story implementation
# Usage: bash scripts/launch-story-worker.sh STORY-ID [--model MODEL] [--effort LEVEL] [--mode headless|interactive|auto]
#
# Claude-only runtime: creates git worktree, provisions MCP config, launches Claude Code.
# Worker can use Agent(), Skill(), all MCP servers.
# Results written to $(rcfg state_dir /tmp/claude-workers)/story-{id}/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

STORY_ID="${1:?Usage: $0 STORY-ID [--model MODEL] [--effort LEVEL] [--mode headless|interactive|auto]}"
MODEL="$(rcfg ao.worker_model opus)"
EFFORT="$(rcfg ao.worker_effort xhigh)"
MODE="${RUN_STORIES_MODE:-auto}"
# TODO(coordinator): multi-engine support (gemini/codex) dropped per porting contract —
# this runtime launches Claude only. ENGINE is fixed and only threaded through so
# prepare-story-worktree.sh (which still validates claude|gemini|codex for its own
# standalone callers) and launch-story-worker-interactive.sh (WRAPPER_ENGINE branch,
# left intact) resolve consistently.
ENGINE="claude"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Parse optional args. --budget and --timeout are accepted but IGNORED — upstream
# mandate: no budget caps or timeouts on workers.
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget) shift 2 ;;   # ignored
    --timeout) shift 2 ;;  # ignored
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --mode=*) MODE="${1#--mode=}"; shift ;;
    *) echo "[ERROR] Unknown arg: $1"; exit 1 ;;
  esac
done

# Resolve MODE=auto → interactive (TTY + tmux + DISPLAY) или headless fallback.
# Headless остаётся default в CI/detached-session/SSH-без-X сценариях.
if [[ "${MODE}" == "auto" ]]; then
  if [[ -t 0 ]] && command -v tmux >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    MODE="interactive"
  else
    MODE="headless"
  fi
fi

if [[ "${MODE}" != "headless" && "${MODE}" != "interactive" ]]; then
  echo "[ERROR] Invalid --mode '${MODE}' (expected: headless | interactive | auto)"
  exit 1
fi

STORY_DIR="$(rcfg ao.story_dir docs/stories)"
STORY_FILE="${REPO_ROOT}/${STORY_DIR}/${STORY_ID}.md"
if [[ ! -f "$STORY_FILE" ]]; then
  echo "[ERROR] Story file not found: $STORY_FILE"
  exit 1
fi

# ── Steps 0..3.7: idempotent worktree prep (delegated) ──
# git-hooks activate, WORKER_DIR + phase-log v1, git worktree add, .mcp.json copy,
# CLAUDE.md trim, optional background prepare-hook — все в одном helper'е.
# Helper экспортирует: WORKER_DIR, WORKTREE_PATH, BRANCH_NAME, PREPARE_HOOK_PID.
# shellcheck disable=SC2153  # variables exported by _prepare_worktree (sourced)
WORKER_DIR=""; WORKTREE_PATH=""; BRANCH_NAME=""; PREPARE_HOOK_PID=""
# shellcheck source=./prepare-story-worktree.sh
source "$SCRIPT_DIR/prepare-story-worktree.sh"
_prepare_worktree "${STORY_ID}" "${ENGINE}"

# Read story frontmatter for context
STORY_TITLE=$(grep -m1 "^title:" "$STORY_FILE" | sed 's/^title:\s*//')
STORY_CONTOUR=$(grep -m1 "^contour:" "$STORY_FILE" | sed 's/^contour:\s*//')
STORY_SP=$(grep -m1 "^story_points:" "$STORY_FILE" | sed 's/^story_points:\s*//')

echo "[INFO] Launching worker for ${STORY_ID}: ${STORY_TITLE}"
echo "[INFO] Mode: ${MODE} | Contour: ${STORY_CONTOUR} | SP: ${STORY_SP} | Model: ${MODEL} | Effort: ${EFFORT} | Budget/Timeout: NONE (no caps)"

# ── Step 4: Build worker prompt (minimal — slash-form, skill owns all phase logic) ──
# Interactive mode: добавляем явную no-ask policy чтобы low-effort модель не генерировала
# свой "Хотите оформить commit?"-prompt в Phase 5.
# Headless mode не нуждается — там нет TUI и AskUserQuestion и так не работает.
INTERACTIVE_POLICY=""
if [[ "${MODE}" == "interactive" ]]; then
  INTERACTIVE_POLICY=$'\n\nCRITICAL POLICY (interactive mode):\n- Phase 5 MUST auto-commit + write result.json через Bash, БЕЗ AskUserQuestion.\n- Coordinator уже одобрил wave plan — не спрашивать пользователя про commit/merge.\n- Phase contract: phase-5-close.md Section 5.0 — write result.json FIRST через Bash, потом git commit.\n- ВСЕ Bash-операции исполнять ВНУТРИ '"${WORKTREE_PATH}"' — никаких cd в main repo.'
fi

SLUG="$(rcfg ao.story_skill_slug implement-story)"
cat > "${WORKER_DIR}/prompt.txt" <<PROMPT_EOF
/${SLUG} ${STORY_ID}

Worktree: ${WORKTREE_PATH} (branch ${BRANCH_NAME})${INTERACTIVE_POLICY}
PROMPT_EOF

PROMPT=$(cat "${WORKER_DIR}/prompt.txt")

# ── Step 5: Launch worker (branch on MODE) ──
unset PHASE_COMPLETE_WRAPPER  # defense-in-depth: not inherited from parent env.

if [[ "${MODE}" == "interactive" ]]; then
  echo "[INFO] Starting interactive Claude Code TUI in tmux window..."
  # Export shared worker-dir path so skill + hooks гарантированно смотрят в
  # один и тот же dir (case-insensitive). Без этого skill мог писать state в
  # `story-ITEST2` (uppercase от STORY_ID) а launcher/hooks — в `story-itest2`.
  export CLAUDE_WORKER_DIR="${WORKER_DIR}"
  # Serena MCP cold-start (LS download + first index) can exceed default MCP timeout.
  export MCP_TIMEOUT="${MCP_TIMEOUT:-60000}"
  # Leak-detection: post-tool-use-write-guard.sh checks Write/Edit paths against
  # this. Workers must write only into worktree (or /tmp/, claude memory).
  export CLAUDE_FORCED_CWD="${WORKTREE_PATH}"
  export ENGINE
  # shellcheck source=launch-story-worker-interactive.sh
  source "$SCRIPT_DIR/launch-story-worker-interactive.sh"
  WORKER_PID="$(_launch_interactive)"
  # Interactive path does NOT run the headless stats/detection tail — wrapper
  # (inside tmux) handles finished_at/exit_code/stats collection itself.
  echo "${WORKER_PID}"
  exit 0
fi

echo "[INFO] Starting Claude Code (headless) in worktree directory..."

# Run CLI FROM the worktree directory, NOT with --worktree flag.
# --worktree causes auto-merge on success, bypassing orchestrator's gate→merge flow.
# Orchestrator (run-stories) controls: worktree gate → merge → cleanup.
# Export env так чтобы и headless worker-процесс видел (hooks в worker-процессе
# тоже получают эти переменные — mark-waiting.sh exit'ит 0 при MODE=headless).
export CLAUDE_WORKER_MODE=headless
export CLAUDE_STORY_ID="${STORY_ID}"
# Leak-detection: same as interactive branch.
export CLAUDE_FORCED_CWD="${WORKTREE_PATH}"
export CLAUDE_WORKER_DIR="${WORKER_DIR}"
# Serena MCP cold-start (LS download + first index) can exceed default MCP timeout.
export MCP_TIMEOUT="${MCP_TIMEOUT:-60000}"

# Budget caps removed upstream — SIGKILL was breaking result.json (cost stayed 0,
# downstream stats collectors filtered these records out and recommended stale
# budgets to future waves — a closed partial-done loop). Hard cap now only via
# --max-budget-usd (native Claude) if the caller wants one. Wallclock fallback —
# wait-wave.sh (soft). ANTHROPIC_BETA enables the task-budgets beta if supported;
# an unsupported header is ignored, --max-budget-usd still works.
export ANTHROPIC_BETA="${ANTHROPIC_BETA:-task-budgets-2026-03-13}"

# --max-budget-usd omitted deliberately — no budget caps; worker runs unbounded.
# shellcheck disable=SC2001
bash -c "cd '${WORKTREE_PATH}' && claude \
  --print \
  --model '${MODEL}' \
  --effort '${EFFORT}' \
  --output-format json \
  --dangerously-skip-permissions \
  -p '$(echo "${PROMPT}" | sed "s/'/'\\\\''/g")'" \
  > "${WORKER_DIR}/result.json" \
  2> "${WORKER_DIR}/stderr.log" &

WORKER_PID=$!
echo "${WORKER_PID}" > "${WORKER_DIR}/pid"
date -Iseconds > "${WORKER_DIR}/started_at"

echo "[INFO] Worker PID: ${WORKER_PID}"
echo "[INFO] Output: ${WORKER_DIR}/result.json"
echo "[INFO] Stderr: ${WORKER_DIR}/stderr.log"
echo "[INFO] Prompt: ${WORKER_DIR}/prompt.txt"

# Background: collect stats on exit. NO worktree cleanup — orchestrator handles it.
#
# Fully detach stdin/stdout/stderr from parent shell. Previously the subshell
# inherited stdout, which kept a pipe `bash launch-story-worker.sh X | tail -N`
# open until the worker died. Coordinator would block and possibly launch a
# duplicate worker → race in worker-dir → phase-log fabrication + dirty worktree.
# `</dev/null >/dev/null 2>&1` closes all fds before backgrounding; `disown`
# removes it from parent's job table so SIGHUP does not propagate.
(
  while kill -0 "${WORKER_PID}" 2>/dev/null; do sleep 5; done
  wait "${WORKER_PID}" 2>/dev/null; EXIT_CODE=$?
  date -Iseconds > "${WORKER_DIR}/finished_at"
  echo "${EXIT_CODE}" > "${WORKER_DIR}/exit_code"

  # Silent-death detection: if result.json is empty AND exit_code != 0, worker
  # was likely SIGKILL'd (budget cap, timeout, OOM). Write a stub result.json
  # with terminal_reason=sigkilled so downstream tooling distinguishes it from
  # a graceful success. Coordinator-gate will still independently verify the
  # worktree regardless.
  if [[ ! -s "${WORKER_DIR}/result.json" && "${EXIT_CODE}" -ne 0 ]]; then
    printf '{"is_error":true,"terminal_reason":"sigkilled","exit_code":%s,"note":"result.json was empty at worker exit — likely budget-cap/timeout/OOM"}\n' "${EXIT_CODE}" > "${WORKER_DIR}/result.json"
  fi

  # Stats collection DISABLED upstream: the collector has a Python heredoc bug +
  # interactive workers write a custom result.json schema (not the headless
  # usage/modelUsage shape). Falling back to static_floor budgets in
  # resolve-story-runtime.sh.
  echo "[STATS] disabled (broken collector)" >> "${WORKER_DIR}/stderr.log"

  echo "[DONE] ${STORY_ID} finished (exit=${EXIT_CODE}). Worktree preserved for orchestrator gate." >> "${WORKER_DIR}/stderr.log"
) </dev/null >/dev/null 2>&1 &
disown

echo "${WORKER_PID}"
