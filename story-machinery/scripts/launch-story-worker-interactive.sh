#!/usr/bin/env bash
# launch-story-worker-interactive.sh — helper для interactive mode.
#
# Запускает Claude Code TUI в новом tmux window внутри сессии wave-${WAVE_ID}.
# Initial prompt отправляется через `tmux send-keys` после короткой задержки.
# Native AskUserQuestion работает из коробки — пользователь attach'ит в паню
# и отвечает в TUI.
#
# Вызывается из launch-story-worker.sh (source + _launch_interactive).
# Зависит от переменных окружения, выставленных parent скриптом:
#   STORY_ID, WORKTREE_PATH, WORKER_DIR, MODEL, EFFORT, BUDGET, TIMEOUT
#   CLAUDE_WAVE_ID (опц., default "wave-current")
# Пишет:
#   ${WORKER_DIR}/pid            — PID bash-обёртки (не claude-TUI напрямую)
#   ${WORKER_DIR}/started_at     — ISO timestamp
#   ${WORKER_DIR}/tmux-target    — `${WAVE_SESSION}:${WINDOW_NAME}` для attach
#   ${WORKER_DIR}/stderr.log     — лог запуска (не содержит Claude stdout)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

_launch_interactive() {
  # Если coordinator сам в tmux — переиспользуем его session (worker становится
  # обычным window рядом с coordinator'ом, пользователь переключается Ctrl+b n/p
  # в той же session без detach'а). Иначе — создаём отдельную `wave-current`.
  local WAVE_SESSION
  if [[ -n "${TMUX:-}" ]]; then
    WAVE_SESSION="$(tmux display-message -p '#S' 2>/dev/null)"
  fi
  WAVE_SESSION="${WAVE_SESSION:-${CLAUDE_WAVE_ID:-wave-current}}"

  local WINDOW_NAME="story-${STORY_ID#STORY-}"
  WINDOW_NAME="${WINDOW_NAME,,}"
  local TMUX_TARGET="${WAVE_SESSION}:${WINDOW_NAME}"

  local SLUG
  SLUG="$(rcfg ao.story_skill_slug implement-story)"

  # Подготовим bash-обёртку, которая будет исполняться внутри tmux window.
  # Она:
  #   1) экспортирует env для hooks (CLAUDE_WORKER_MODE, CLAUDE_STORY_ID, CLAUDE_WAVE_ID)
#   2) запускает CLI TUI (claude, gemini или codex в зависимости от ENGINE)
  #   3) после exit'а TUI — если result.json ещё пуст, пишет stub
  #   4) collect-worker-stats.sh (как в headless)
  local WRAPPER_ENGINE="${ENGINE:-claude}"
  # Budget/timeout caps не поддерживаются — user mandate. Worker runs unbounded.
  local CLI_CMDLINE
  if [[ "${WRAPPER_ENGINE}" == "gemini" ]]; then
    # gemini: --approval-mode yolo вместо --dangerously-skip-permissions
    CLI_CMDLINE="gemini \\
  -m '${MODEL}' \\
  --approval-mode yolo \\
  --skip-trust"
  elif [[ "${WRAPPER_ENGINE}" == "codex" ]]; then
    CLI_CMDLINE="'${CODEX_BIN:-codex}' \\
  -m '${MODEL}' \\
  -c 'model_reasoning_effort=\"${EFFORT}\"' \\
  -c 'approval_policy=\"never\"' \\
  -s workspace-write \\
  --no-alt-screen"
  else
    CLI_CMDLINE="claude \\
  --model '${MODEL}' \\
  --effort '${EFFORT}' \\
  --dangerously-skip-permissions"
  fi
  local WRAPPER="${WORKER_DIR}/tmux-wrapper.sh"
  local PROMPT_MARKER="/${SLUG} ${STORY_ID}"
  if [[ "${WRAPPER_ENGINE}" == "codex" ]]; then
    PROMPT_MARKER="\$${SLUG} ${STORY_ID}"
  fi
  cat > "${WRAPPER}" <<WRAPPER_EOF
#!/usr/bin/env bash
set -uo pipefail
export CLAUDE_WORKER_MODE=interactive
export CLAUDE_STORY_ID='${STORY_ID}'
export CLAUDE_WAVE_ID='${WAVE_SESSION}'
export CLAUDE_WORKER_DIR='${WORKER_DIR}'
export WORKER_ENGINE='${WRAPPER_ENGINE}'
if [[ '${WRAPPER_ENGINE}' == 'codex' && -n '${CODEX_WORKER_HOME:-}' ]]; then
  export CODEX_HOME='${CODEX_WORKER_HOME:-}'
fi
# Включаем task-budgets beta header. При unsupported — игнор.
export ANTHROPIC_BETA='task-budgets-2026-03-13'
# Leak-guard pin: post-tool-use-write-guard.sh смотрит CLAUDE_FORCED_CWD.
# Обязательно ЗДЕСЬ — tmux new-window может не проксировать env родителя.
# Без этого hook видит пустую переменную и тихо exit 0 — worker утекает
# в main repo без записи.
export CLAUDE_FORCED_CWD='${WORKTREE_PATH}'
cd '${WORKTREE_PATH}'

echo '[INFO] Interactive ${WRAPPER_ENGINE} TUI for ${STORY_ID}'
echo '[INFO] Worktree: ${WORKTREE_PATH}'
echo '[INFO] Prompt will be sent via tmux send-keys after 3s delay.'
echo ''

# Initial prompt — через send-keys от launcher'а после старта.
# Auto-approve включён (claude: --dangerously-skip-permissions, gemini: --approval-mode yolo) —
# routine Bash/Edit tool-calls не требуют approve. AskUserQuestion блокирует через native TUI.
${CLI_CMDLINE}
EXIT_CODE=\$?

echo ''
echo "[DONE] Claude TUI exited with code \${EXIT_CODE}"
echo "\$(date -Iseconds)" > '${WORKER_DIR}/finished_at'
echo "\${EXIT_CODE}" > '${WORKER_DIR}/exit_code'

# В interactive mode скилл (Phase 5) обязан писать result.json через Bash.
# Если он этого не сделал — синтезируем fallback. Если worker сделал коммиты
# в своей ветке worktree-* — это partial-success (worker полезный код оставил,
# но Phase 5 close недописал). Иначе — terminal failure.
if [[ ! -s '${WORKER_DIR}/result.json' ]]; then
  WORKTREE_COMMITS=\$(git -C '${WORKTREE_PATH}' log --format=%H 'main..HEAD' 2>/dev/null | head -10 | jq -R . | jq -sc .)
  COMMIT_COUNT=\$(echo "\${WORKTREE_COMMITS}" | jq 'length' 2>/dev/null || echo 0)
  if [[ "\${COMMIT_COUNT}" -gt 0 ]]; then
    # Synth partial-done result.json — coordinator увидит commits и сможет
    # принять решение (merge vs re-launch для довода Phase 5/AC).
    printf '{"is_error":false,"status":"partial-done","mode":"interactive","exit_code":%s,"commits":%s,"note":"result.json synthesized by tmux-wrapper — skill did not write Phase 5 close, but %s commits exist in worktree. Coordinator: review diff and decide merge vs re-launch."}\\n' \\
      "\${EXIT_CODE}" "\${WORKTREE_COMMITS}" "\${COMMIT_COUNT}" > '${WORKER_DIR}/result.json'
  else
    printf '{"is_error":true,"terminal_reason":"no-result-json","exit_code":%s,"mode":"interactive","note":"TUI exited without Phase 5 writing result.json AND no commits in worktree branch — skill never finished implementation."}\\n' "\${EXIT_CODE}" > '${WORKER_DIR}/result.json'
  fi
fi

# Stats collection DISABLED — broken collector, see launch-story-worker.sh.
echo '[STATS] disabled (broken collector)' >> '${WORKER_DIR}/stderr.log'

echo ''
echo '[INFO] Pane will remain open for post-hoc review. Close manually or via wave cleanup.'
# Держим bash, чтобы tmux window не закрылась автоматически (удобно для review).
exec bash
WRAPPER_EOF
  chmod +x "${WRAPPER}"

  # Убедимся что tmux session существует, с control-dashboard окном.
  if ! tmux has-session -t "${WAVE_SESSION}" 2>/dev/null; then
    echo "[INFO] Creating tmux session: ${WAVE_SESSION}" >&2
    # _control pane — live dashboard (обновляется каждые 3с, показывает pid/alive/result/waiting).
    tmux new-session -d -s "${WAVE_SESSION}" -n "_control" "bash '${SCRIPT_DIR}/wave-dashboard.sh'" 2>&1 | tee -a "${WORKER_DIR}/stderr.log"
  fi

  # Создаём window для этой story.
  if tmux list-windows -t "${WAVE_SESSION}" -F '#{window_name}' 2>/dev/null | grep -qx "${WINDOW_NAME}"; then
    echo "[WARN] Window ${TMUX_TARGET} already exists — killing before relaunch." >&2
    tmux kill-window -t "${TMUX_TARGET}" 2>/dev/null || true
  fi

  echo "[INFO] Opening tmux window: ${TMUX_TARGET}" >&2
  tmux new-window -t "${WAVE_SESSION}" -n "${WINDOW_NAME}" "bash '${WRAPPER}'"

  # pipe-pane: всё визуально в пане копируется в live.log → coordinator делает
  # `tail -f ${WORKER_DIR}/live.log` чтобы следить за прогрессом real-time
  # БЕЗ tmux attach. Это критично когда coordinator сам не в tmux (типичный
  # случай: Claude Code запущен в обычном терминале).
  tmux pipe-pane -t "${TMUX_TARGET}" -o "cat >> '${WORKER_DIR}/live.log'" 2>/dev/null || true

  # Получаем PID оболочки внутри pane (wrapper bash). Это то, что мы poll'им.
  local PANE_PID
  PANE_PID="$(tmux list-panes -t "${TMUX_TARGET}" -F '#{pane_pid}' | head -1)"
  echo "${PANE_PID}" > "${WORKER_DIR}/pid"
  echo "$(date -Iseconds)" > "${WORKER_DIR}/started_at"
  echo "${TMUX_TARGET}" > "${WORKER_DIR}/tmux-target"

  echo "[INFO] Wrapper PID: ${PANE_PID}" >&2
  echo "[INFO] Output: ${WORKER_DIR}/result.json (written by skill Phase 5 via Bash)" >&2
  echo "[INFO] Tmux target: ${TMUX_TARGET}" >&2
  echo "[INFO] Attach: tmux attach -t ${WAVE_SESSION} (then Ctrl+b ${WINDOW_NAME})" >&2

  # Шлём initial prompt после задержки (TUI должен успеть запуститься).
  # ОДНИМ блоком (не построчно): весь prompt через -l literal (newlines как символы),
  # затем ОДИН Enter для submit. Построчный подход = N отдельных submit'ов = Claude
  # обрабатывает только первый и замирает на остальных в очереди.
  #
  # Verification logic: проверяем landing prompt в TUI input bar через capture-pane.
  # Длинный paste (>5 строк) сворачивается в placeholder `❯ [Pasted text #N +K lines]`
  # (paste detection). Сам текст в input buffer'е, но `grep -F "/implement-story"` его
  # не найдёт. Поэтому маркер landing — ИЛИ literal текст ИЛИ placeholder `Pasted text #N`.
  # Empirical: без placeholder check retry проваливались — Ctrl-U очищал buffer перед
  # каждым retry → Enter ни разу не нажат → workers стартовали TUI без prompt
  # (Cost=$0 forever). См. memory: feedback_tmux_send_keys_paste_collapse.md.
  (
    PROMPT_FILE="${WORKER_DIR}/prompt.txt"
    MARKER="${PROMPT_MARKER}"
    PLACEHOLDER_RE='Pasted text #[0-9]+ \+[0-9]+ lines'
    sleep 8  # initial wait — banner + MCP init + skill discovery
    for attempt in 1 2 3 4 5 6; do
      tmux send-keys -t "${TMUX_TARGET}" -l "$(cat "${PROMPT_FILE}")"
      sleep 1
      # Verify prompt landed: literal marker ИЛИ placeholder для свернутых paste'ов.
      PANE=$(tmux capture-pane -t "${TMUX_TARGET}" -p 2>/dev/null || echo "")
      if grep -qF "${MARKER}" <<<"${PANE}" || grep -qE "${PLACEHOLDER_RE}" <<<"${PANE}"; then
        tmux send-keys -t "${TMUX_TARGET}" "Enter"
        echo "[send-keys-ok] ${STORY_ID} prompt delivered (attempt ${attempt})" >> "${WORKER_DIR}/stderr.log"
        exit 0
      fi
      echo "[send-keys-retry] ${STORY_ID} attempt ${attempt} — neither marker nor paste-placeholder found, retry in 4s" >> "${WORKER_DIR}/stderr.log"
      # Drain stuck input before retry: Ctrl-U очищает строку.
      tmux send-keys -t "${TMUX_TARGET}" "C-u" 2>/dev/null || true
      sleep 4
    done
    echo "[send-keys-failed] ${STORY_ID} prompt NOT delivered after 6 attempts — manual send required" >> "${WORKER_DIR}/stderr.log"
  ) </dev/null >/dev/null 2>&1 &
  disown

  echo "${PANE_PID}"
}
