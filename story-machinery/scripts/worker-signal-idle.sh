#!/usr/bin/env bash
# worker-signal-idle.sh — Claude Code Notification:idle_prompt hook helper.
#
# Fires когда TUI стоит на ❯ prompt'е без активной задачи. Это backup для
# Stop hook на случай silent-tool-stop (issue #29881 — Stop не fires когда
# Claude получил tool_result и решил молча остановиться).
#
# Поведение идентично worker-signal-done.sh: проверяет result.json complete,
# атомарно пишет done.flag. Это безопасно — idle на ❯ prompt'е после
# успешного Phase 6 close == "skill закончила, теперь TUI ждёт человека".
#
# В отличие от Stop hook, idle_prompt fires регулярно во время сессии (когда
# user уходит думать) — поэтому result.json gate ОБЯЗАТЕЛЕН, иначе мы бы
# писали done.flag при каждой паузе пользователя.

set -uo pipefail

WORKER_DIR="${1:-${CLAUDE_WORKER_DIR:-}}"
if [[ -z "${WORKER_DIR}" ]]; then
  exit 0
fi
if [[ ! -d "${WORKER_DIR}" ]]; then
  exit 0
fi

# Drain stdin (hook contract).
timeout 1 cat >/dev/null 2>&1 || true

# Delegate to done-signaller — same logic, single source of truth.
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
exec bash "${SCRIPT_DIR}/worker-signal-done.sh" "${WORKER_DIR}"
