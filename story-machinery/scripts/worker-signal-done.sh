#!/usr/bin/env bash
# worker-signal-done.sh — Claude Code Stop hook helper.
#
# Fires when Claude finishes a turn (Phase 6 close или раньше). Writes a
# `done.flag` file in the worker dir AS SOON AS skill has produced result.json
# with a finished_at field. wait-wave.sh watches for done.flag (or result.json
# update) and signals WORKER_DONE without waiting for TUI exit_code.
#
# Background: interactive Claude TUI never auto-exits after a skill — control
# returns to the user prompt. Pre-2026-05-10 wait-wave.sh polled exit_code
# (written only on TUI exit), so coordinator was blind to completed workers
# for hours. Stop hook + done.flag closes that gap (industry-standard pattern,
# cf. samleeney/tmux-agent-status, pablobfonseca/claude-session-manager).
#
# Invariant: NEVER write done.flag if result.json is missing/empty/incomplete.
# A premature done.flag would let coordinator merge a half-finished worktree.
#
# Activation: hook is registered via .claude/settings.json в worktree (injected
# by prepare-story-worktree.sh). The hook reads $CLAUDE_WORKER_DIR (exported by
# launch-story-worker.sh).
#
# Hook contract (per Claude Code Stop hook):
#   - stdin: JSON {session_id, transcript_path, cwd, hook_event_name, ...}
#   - exit 0: silent approval
#   - exit 2: block Claude from stopping (NOT used here — we just observe)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

WORKER_DIR="${1:-${CLAUDE_WORKER_DIR:-}}"
if [[ -z "${WORKER_DIR}" ]]; then
  # No worker context — silent exit (hook lives in worktree, may fire outside
  # of orchestrator launches in dev sessions).
  exit 0
fi
if [[ ! -d "${WORKER_DIR}" ]]; then
  exit 0
fi

# Read stdin (Claude Code passes hook input as JSON). We don't strictly need
# it but draining stdin keeps the hook well-behaved.
STDIN_BUF="$(timeout 1 cat 2>/dev/null || true)"

RESULT_JSON="${WORKER_DIR}/result.json"
DONE_FLAG="${WORKER_DIR}/done.flag"

# Already signalled — idempotent no-op.
if [[ -s "${DONE_FLAG}" ]]; then
  exit 0
fi

# Verify result.json exists and looks complete.
# Skill writes result.json в начале Phase 6 close (через Bash). We require:
#   - file size > 10 bytes (non-trivial JSON)
#   - parseable JSON
#   - has `.finished_at` OR `.status:"done"` OR `.status:"ok"` field
if [[ ! -s "${RESULT_JSON}" ]]; then
  # Skill еще не дошла до Phase 6. Stop hook fires также на промежуточных
  # turn-end'ах (silent тула, idle prompt, и т.д.) — это нормально, не пишем
  # флаг.
  exit 0
fi

if ! jq -e '
  (.finished_at != null and .finished_at != "")
  or (.status == "done")
  or (.status == "ok")
' "${RESULT_JSON}" >/dev/null 2>&1; then
  # result.json есть, но нет признаков завершения — skill ещё пишет.
  exit 0
fi

# Atomic write: tmp file then rename. inotify_close_write of done.flag fires
# exactly once for the listener.
TMP_FLAG="$(mktemp -p "${WORKER_DIR}" .done-flag.XXXXXX 2>/dev/null || true)"
if [[ -z "${TMP_FLAG}" ]]; then
  # mktemp не сработал (RO fs?) — fallback на прямую запись.
  printf '%s\n' "$(date -Iseconds)" > "${DONE_FLAG}" 2>/dev/null || exit 0
  exit 0
fi
{
  printf 'signalled_at=%s\n' "$(date -Iseconds)"
  printf 'source=stop-hook\n'
  printf 'session_id=%s\n' "$(printf '%s' "${STDIN_BUF}" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)"
} > "${TMP_FLAG}"
mv -f "${TMP_FLAG}" "${DONE_FLAG}" 2>/dev/null || true

exit 0
