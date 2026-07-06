#!/usr/bin/env bash
# prepare-story-worktree.sh — Idempotent worktree preparation для story.
#
# Usage:
#   bash scripts/prepare-story-worktree.sh STORY-ID [--engine claude|gemini|codex]
#       Standalone JSON output: {worktree_path, worker_dir, branch, prepare_hook_pid?}
#       Используется coordinator'ом для subagent-канала /run-stories.
#
#   source scripts/prepare-story-worktree.sh && _prepare_worktree STORY-ID claude
#       Sourcable: экспортирует переменные WORKTREE_PATH, WORKER_DIR, BRANCH_NAME
#       (+ PREPARE_HOOK_PID если был запущен). Используется launch-story-worker.sh.
#
# Что делает (идентично launch-story-worker.sh Steps 0..3.7):
#   - Активирует .githooks pre-commit (если install-git-hooks.sh присутствует)
#   - WORKER_DIR + phase-log v1 init
#   - git worktree add (идемпотентно: переиспользует существующий или recreate'ит ветку)
#   - .mcp.json copy (claude only; gemini/codex use global MCP config)
#   - Trimmed CLAUDE.md для worktree
#   - Optional background prepare-hook (ao.prepare_hook), если настроен

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

_prepare_worktree() {
  local STORY_ID="$1"
  local ENGINE="${2:-claude}"

  if [[ -z "${STORY_ID:-}" ]]; then
    echo "[ERROR] STORY-ID required" >&2; return 1
  fi
  # TODO(coordinator): launch-story-worker.sh (Claude-only per porting contract)
  # никогда больше не вызовет этот helper с engine != claude. Валидация ниже
  # оставлена для standalone/subagent-канала (--engine flag внизу файла) — решить,
  # нужно ли тримать gemini/codex и здесь для консистентности.
  if [[ "${ENGINE}" != "claude" && "${ENGINE}" != "gemini" && "${ENGINE}" != "codex" ]]; then
    echo "[ERROR] Invalid engine '${ENGINE}' (expected: claude | gemini | codex)" >&2; return 1
  fi

  local REPO_ROOT
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  local STORY_DIR
  STORY_DIR="$(rcfg ao.story_dir docs/stories)"
  local STORY_FILE="${REPO_ROOT}/${STORY_DIR}/${STORY_ID}.md"
  if [[ ! -f "$STORY_FILE" ]]; then
    echo "[ERROR] Story file not found: $STORY_FILE" >&2; return 1
  fi

  # ── Step 0: Ensure pre-commit hook active (если install-git-hooks.sh есть) ──
  local CURRENT_HOOKS
  CURRENT_HOOKS=$(git -C "${REPO_ROOT}" config --get core.hooksPath 2>/dev/null || echo "")
  if [[ "$CURRENT_HOOKS" != ".githooks" ]] && [[ -f "$SCRIPT_DIR/install-git-hooks.sh" ]]; then
    bash "$SCRIPT_DIR/install-git-hooks.sh" >&2
  fi

  # ── Step 1: WORKER_DIR (lowercase canonical) + phase-log v1 init ──
  local STATE_DIR STORY_SUFFIX_LC
  STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
  STORY_SUFFIX_LC="$(printf '%s' "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')"
  WORKER_DIR="${STATE_DIR}/story-${STORY_SUFFIX_LC}"
  local PRESERVE_DIR=""
  if [[ -d "$WORKER_DIR" ]]; then
    PRESERVE_DIR="$(mktemp -d "${STATE_DIR}-preserve-${STORY_SUFFIX_LC}.XXXXXX")"
    for artifact in runtime.json preflight.json preflight.md mem-context.json; do
      [[ -f "${WORKER_DIR}/${artifact}" ]] && cp "${WORKER_DIR}/${artifact}" "${PRESERVE_DIR}/${artifact}"
    done
  fi
  rm -rf "$WORKER_DIR"
  rm -rf "${STATE_DIR}/${STORY_ID}"  # legacy uppercase
  mkdir -p "$WORKER_DIR"
  if [[ -n "$PRESERVE_DIR" ]]; then
    cp "${PRESERVE_DIR}/"* "$WORKER_DIR"/ 2>/dev/null || true
    rm -rf "$PRESERVE_DIR"
  fi

  # shellcheck source=./phase-log-util.sh
  source "$SCRIPT_DIR/phase-log-util.sh"
  log_phase_init "${WORKER_DIR}" "${STORY_ID}"

  local WORKTREE_ROOT
  WORKTREE_ROOT="$(rcfg ao.worktree_root .claude/worktrees)"
  WORKTREE_PATH="${REPO_ROOT}/${WORKTREE_ROOT}/${STORY_ID}"
  BRANCH_NAME="worktree-${STORY_ID}"

  # ── Step 2: Create git worktree (idempotent) ──
  if [[ -d "${WORKTREE_PATH}" ]]; then
    echo "[INFO] Worktree already exists: ${WORKTREE_PATH}" >&2
  else
    echo "[INFO] Creating worktree: ${WORKTREE_PATH} (branch: ${BRANCH_NAME})" >&2
    if ! git -C "${REPO_ROOT}" worktree add "${WORKTREE_PATH}" -b "${BRANCH_NAME}" HEAD 2>&1 >&2; then
      git -C "${REPO_ROOT}" branch -D "${BRANCH_NAME}" 2>/dev/null || true
      if ! git -C "${REPO_ROOT}" worktree add "${WORKTREE_PATH}" -b "${BRANCH_NAME}" HEAD 2>&1 >&2; then
        echo "[WARN] git worktree add failed; falling back to local clone (main .git may be read-only)" >&2
        rm -rf "${WORKTREE_PATH}"
        git clone --shared --no-hardlinks "${REPO_ROOT}" "${WORKTREE_PATH}" 2>&1 >&2
        git -C "${WORKTREE_PATH}" checkout -b "${BRANCH_NAME}" HEAD 2>&1 >&2
      fi
    fi
  fi

  # ── Step 2.5: Bot git identity (scoped per-worktree, optional) ──
  # Worker-коммиты атрибутируются боту, не разработчику — только если ao.worker_bot_name
  # задан в runtime.config.yaml. Если не задан — identity репозитория по умолчанию
  # (никаких hardcoded имён). Per-worktree config (extensions.worktreeConfig) — НЕ трогает
  # identity главного чекаута: `--worktree` пишет в config.worktree линкованного worktree,
  # shared-config (где живёт identity main-репо) не меняется. Fallback на plain
  # `git config` для clone-пути (см. выше) где config и так свой, изолированный.
  local BOT_NAME
  BOT_NAME="$(rcfg ao.worker_bot_name "")"
  if [[ -n "$BOT_NAME" ]] && git -C "${WORKTREE_PATH}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local BOT_EMAIL
    BOT_EMAIL="$(rcfg ao.worker_bot_email "")"
    git -C "${REPO_ROOT}" config extensions.worktreeConfig true 2>/dev/null || true
    git -C "${WORKTREE_PATH}" config --worktree user.name "${BOT_NAME}" 2>/dev/null \
      || git -C "${WORKTREE_PATH}" config user.name "${BOT_NAME}" 2>/dev/null || true
    if [[ -n "$BOT_EMAIL" ]]; then
      git -C "${WORKTREE_PATH}" config --worktree user.email "${BOT_EMAIL}" 2>/dev/null \
        || git -C "${WORKTREE_PATH}" config user.email "${BOT_EMAIL}" 2>/dev/null || true
    fi
  fi

  # ── Step 3: MCP config (claude only) — worker-scoped: CBM(discovery)+Serena(editing)+postgres ──
  # Workers get a purpose-built MCP set instead of the full team .mcp.json:
  #   codebase-memory-mcp (graph discovery) + serena (symbol nav/edit, replaces native LSP) + postgres_ro.
  #   UI servers (magicui/stitch/shadcn) dropped — noise for story workers. Also writes a worker-only
  #   settings.local.json: native LSP off (Serena replaces it) + claude-mem plugin off (no capture/inject
  #   in ephemeral worktrees). main session is untouched (these files live only inside the worktree).
  if [[ "${ENGINE}" == "claude" ]]; then
    local CBM_BIN
    CBM_BIN="$(rcfg cbm_bin "${HOME:-$USERPROFILE}/.local/bin/codebase-memory-mcp")"
    python3 - "${REPO_ROOT}" "${WORKTREE_PATH}" "${CBM_BIN}" <<'MCPPY' >&2
import json, pathlib, sys
repo_root, wt, cbm_bin = sys.argv[1], sys.argv[2], sys.argv[3]
mcp = {"mcpServers": {
    "codebase-memory-mcp": {"command": cbm_bin},
    "serena": {
        "command": "uvx",
        "args": ["--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server", "--context", "claude-code", "--project-from-cwd", "--mode", "editing"],
    },
}}
src = pathlib.Path(repo_root + "/.mcp.json")
if src.exists():
    team = json.loads(src.read_text()).get("mcpServers", {})
    if "postgres_ro" in team:
        mcp["mcpServers"]["postgres_ro"] = team["postgres_ro"]
pathlib.Path(wt + "/.mcp.json").write_text(json.dumps(mcp, indent=2))
cdir = pathlib.Path(wt + "/.claude")
cdir.mkdir(exist_ok=True)
(cdir / "settings.local.json").write_text(json.dumps({
    "env": {"ENABLE_LSP_TOOL": "0"},
    "enabledPlugins": {"claude-mem@thedotmack": False},
}, indent=2))
MCPPY
  fi

  # ── Step 3.4: Serena per-worker language scoping ──
  # Serena --project-from-cwd auto-detects ONE language; on a mixed-language monorepo it can
  # consistently pick the wrong one — even for a pure-backend story, which then gets a useless
  # LS and NO backing server for its actual language ("serena doesn't work"). Worse: N parallel
  # workers each spinning up the same wrong LS indexing the whole monorepo can OOM it. Pre-write
  # .serena/project.yml in the worktree (read by --project-from-cwd) with languages scoped to the
  # story contour, so each worker starts exactly ONE relevant LS. `.serena/` is gitignored → no
  # worktree-gate dirty-tree impact.
  rm -rf "${HOME}/.serena/projects/${STORY_ID}"   # drop stale auto-gen registration (worktree names reused across runs)
  python3 - "${STORY_FILE}" "${WORKTREE_PATH}" "${STORY_ID}" <<'SERENAPY' >&2
import pathlib, re, sys
story_file, wt, story_id = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(story_file).read_text()
m = re.search(r'^contour:\s*"?([^"\n]+)"?\s*$', text, re.MULTILINE)
contour = (m.group(1).strip().lower() if m else "")
has_py = bool(re.search(r'\.py\b', text))
has_ts = bool(re.search(r'\.(ts|tsx|js|jsx)\b', text))
if contour == "frontend":
    langs = ["typescript"]
elif contour in ("backend", "infra"):
    langs = ["python"]
else:  # unknown/mixed → infer from files_affected extensions
    if has_py and has_ts: langs = ["python", "typescript"]
    elif has_ts:          langs = ["typescript"]
    else:                 langs = ["python"]
sdir = pathlib.Path(wt + "/.serena")
sdir.mkdir(exist_ok=True)
yml = 'project_name: "%s"\nlanguages:\n%signore_all_files_in_gitignore: true\nread_only: false\n' % (
    story_id, "".join(f"- {l}\n" for l in langs))
(sdir / "project.yml").write_text(yml)
print(f"[serena] {story_id}: languages={langs} (contour={contour or 'n/a'})")
SERENAPY

  # ── Step 3.5: Trimmed CLAUDE.md (defensive — no-op if root CLAUDE.md is absent) ──
  python3 - "$REPO_ROOT" "$WORKTREE_PATH" <<'PY' >&2
import re, pathlib, sys
repo_root = sys.argv[1]; wt_path = sys.argv[2]
src_path = pathlib.Path(f"{repo_root}/CLAUDE.md")
if not src_path.exists():
    sys.exit(0)
src = src_path.read_text()
# TODO(coordinator): секции ниже — из мгт-openproject CLAUDE.md; на репо без них это
# просто no-op (ни одна не совпадёт). Если разным продуктам нужны разные секции для
# тримминга — вынести список в rcfg_list(ao.claude_md_trim_sections).
remove = [
    'Session Start Protocol', 'BMAD Governance Workflow',
    r'Vendored Skills.*', r'Claude Code Agents.*', r'Claude Code Skills.*',
    'Operating Model', 'AI Runtime Sync',
]
pattern = '|'.join(remove)
parts = re.split(r'(^## .+$)', src, flags=re.MULTILINE)
out, skip = [], False
for part in parts:
    if re.match(r'^## ', part):
        skip = bool(re.match(r'^## (' + pattern + r')', part))
    if not skip:
        out.append(part)
pathlib.Path(f"{wt_path}/CLAUDE.md").write_text(''.join(out))
PY

  # ── Step 3.6: Serena editing-layer routing note (worker-only CLAUDE.md) ──
  cat >> "${WORKTREE_PATH}/CLAUDE.md" <<'SERENA_ROUTING'

## Worker Tool Routing (Serena editing layer)
Ephemeral worktree worker: native LSP tool is OFF, claude-mem is OFF (isolation).
- Discovery / call-graph / impact -> CBM (search_graph / trace_path / get_code_snippet). Unchanged.
- Editing / symbol nav / diagnostics -> Serena MCP: find_symbol, find_referencing_symbols,
  get_symbols_overview, replace_symbol_body, insert_after_symbol, insert_before_symbol, rename_symbol,
  get_diagnostics_for_file. Prefer Serena symbol-tools for precise edits
  over large Read+Edit; run get_diagnostics_for_file after edits (replaces native LSP).
- Grep/Glob authority unchanged (CBM gate). Do not blind-grep code.
SERENA_ROUTING

  # ── Step 3.7: Optional background prepare-hook (product-specific setup) ──
  # This generic runtime does not assume any particular stack (npm/pip/etc) — configure
  # a post-worktree setup command via ao.prepare_hook in runtime.config.yaml (shell string,
  # run from the worktree root, backgrounded, failures are non-fatal to worktree prep).
  PREPARE_HOOK_PID=""
  local PREPARE_HOOK
  PREPARE_HOOK="$(rcfg ao.prepare_hook "")"
  if [[ -n "$PREPARE_HOOK" ]]; then
    echo "[INFO] Running prepare hook in background: ${PREPARE_HOOK}" >&2
    (cd "${WORKTREE_PATH}" && eval "$PREPARE_HOOK" > "${WORKER_DIR}/prepare-hook.log" 2>&1) &
    PREPARE_HOOK_PID="$!"
    echo "${PREPARE_HOOK_PID}" > "${WORKER_DIR}/prepare-hook.pid"
  fi

  export WORKER_DIR WORKTREE_PATH BRANCH_NAME PREPARE_HOOK_PID
  return 0
}

# Standalone vs sourced detection.
# When sourced — caller invokes _prepare_worktree directly, gets exported vars.
# When executed — emit JSON for subagent-channel callers.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  STORY_ID_ARG="${1:?Usage: $0 STORY-ID [--engine claude|gemini|codex]}"
  ENGINE_ARG="claude"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --engine) ENGINE_ARG="$2"; shift 2 ;;
      --engine=*) ENGINE_ARG="${1#--engine=}"; shift ;;
      *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  _prepare_worktree "${STORY_ID_ARG}" "${ENGINE_ARG}"
  jq -nc \
    --arg wt "${WORKTREE_PATH}" \
    --arg wd "${WORKER_DIR}" \
    --arg br "${BRANCH_NAME}" \
    --arg hpid "${PREPARE_HOOK_PID:-}" \
    '{worktree_path: $wt, worker_dir: $wd, branch: $br, prepare_hook_pid: (if $hpid == "" then null else ($hpid|tonumber) end)}'
fi
