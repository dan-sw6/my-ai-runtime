#!/usr/bin/env bash
# install-global.sh — install the machine-global discipline layer into ~/.claude/.
#
# Second delivery channel (alongside per-repo `sync/sync-engine.sh`): deploys the
# cross-stack discipline hooks, the extra-lsp plugin, the context7 rule, the
# generic global skills, and registers the hooks in ~/.claude/settings.json.
#
# Idempotent: re-running overwrites vendored files and REPLACES the managed hook
# groups (dedupe by command) — no duplicate registrations.
#
# Cross-platform: runs on Linux and on Windows via Git Bash. Uses $HOME, falling
# back to $USERPROFILE. Requires: bash, jq (for settings/MCP merge; without it the
# installer copies files and prints a snippet for manual merge).
#
# Usage:
#   bash global/install-global.sh [--dry-run] [--with-cbm-mcp] [--force-marketplace]
set -euo pipefail

DRY_RUN=false
WITH_CBM=false
FORCE_MP=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=true ;;
    --with-cbm-mcp)       WITH_CBM=true ;;
    --force-marketplace)  FORCE_MP=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_DIR="$SCRIPT_DIR"
HOME_DIR="${HOME:-${USERPROFILE:-}}"
if [[ -z "$HOME_DIR" ]]; then echo "ERROR: cannot resolve home dir (\$HOME/\$USERPROFILE)" >&2; exit 1; fi
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"

say()  { echo "  $*"; }
step() { echo; echo "== $* =="; }
run()  { if $DRY_RUN; then echo "  DRY: $*"; else eval "$*"; fi; }

echo "=== install-global — my-ai-runtime discipline layer ==="
echo "Runtime : $GLOBAL_DIR"
echo "Target  : $CLAUDE_HOME"
$DRY_RUN && echo "Mode    : DRY RUN (no changes)"

have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Discipline hooks ----------------------------------------------------
step "Hooks → $CLAUDE_HOME/hooks/"
run "mkdir -p '$CLAUDE_HOME/hooks'"
for f in "$GLOBAL_DIR"/hooks/*; do
  bn="$(basename "$f")"
  run "cp '$f' '$CLAUDE_HOME/hooks/$bn'"
  case "$bn" in package.json) : ;; *) run "chmod +x '$CLAUDE_HOME/hooks/$bn' 2>/dev/null || true" ;; esac
  say "installed hook: $bn"
done

# --- 2. context7 rule -------------------------------------------------------
step "Rule → $CLAUDE_HOME/rules/context7.md"
run "mkdir -p '$CLAUDE_HOME/rules'"
run "cp '$GLOBAL_DIR/rules/context7.md' '$CLAUDE_HOME/rules/context7.md'"

# --- 3. Generic global skills ----------------------------------------------
step "Skills → $CLAUDE_HOME/skills/"
run "mkdir -p '$CLAUDE_HOME/skills'"
for d in "$GLOBAL_DIR"/skills/*/; do
  bn="$(basename "$d")"
  run "cp -r '$d' '$CLAUDE_HOME/skills/$bn'"
  say "installed skill: $bn"
done

# --- 4. extra-lsp plugin ----------------------------------------------------
step "Plugin extra-lsp → $CLAUDE_HOME/local-plugins/"
run "mkdir -p '$CLAUDE_HOME/local-plugins/extra-lsp/.claude-plugin' '$CLAUDE_HOME/local-plugins/.claude-plugin'"
run "cp '$GLOBAL_DIR/extra-lsp/.claude-plugin/plugin.json' '$CLAUDE_HOME/local-plugins/extra-lsp/.claude-plugin/plugin.json'"
run "cp '$GLOBAL_DIR/extra-lsp/.lsp.json' '$CLAUDE_HOME/local-plugins/extra-lsp/.lsp.json'"
MP_DST="$CLAUDE_HOME/local-plugins/.claude-plugin/marketplace.json"
if [[ -f "$MP_DST" && "$FORCE_MP" != true ]]; then
  say "marketplace.json exists — left as-is (use --force-marketplace to overwrite)"
else
  run "cp '$GLOBAL_DIR/extra-lsp/marketplace.json' '$MP_DST'"
  say "installed local-extras marketplace"
fi
say "enable with: /plugin marketplace add $CLAUDE_HOME/local-plugins  then  /plugin install extra-lsp@local-extras"
say "requires in PATH: bash-language-server, yaml-language-server, vscode-json-languageserver, marksman"

# --- 5. Register hooks in settings.json (jq deep-merge, dedupe) --------------
step "Register hooks → $CLAUDE_HOME/settings.json"
SNIPPET="$GLOBAL_DIR/settings.snippet.json"
SETTINGS="$CLAUDE_HOME/settings.json"
if have jq; then
  [[ -f "$SETTINGS" ]] || { $DRY_RUN || echo '{}' > "$SETTINGS"; }
  MERGE_JQ='
    ($snippet.hooks) as $sh
    | reduce ($sh | keys_unsorted[]) as $ev (.;
        ($sh[$ev]) as $groups
        | ([$groups[].hooks[].command]) as $ourcmds
        | .hooks = (.hooks // {})
        | .hooks[$ev] = (
            (((.hooks[$ev]) // [])
              | map(.hooks |= map(.command as $c | select(($ourcmds | index($c)) | not)))
              | map(select((.hooks | length) > 0)))
            + $groups))'
  if $DRY_RUN; then
    say "DRY: would merge hook registrations (dedupe by command) into settings.json"
  else
    tmp="$(mktemp)"
    jq --argjson snippet "$(jq 'del(._comment)' "$SNIPPET")" "$MERGE_JQ" "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    say "merged hook registrations (idempotent)"
  fi
else
  say "jq not found — copy the hooks block from this file into $SETTINGS manually:"
  say "  $SNIPPET"
fi

# --- 6. Optional: global cbm MCP entry --------------------------------------
step "codebase-memory-mcp (optional)"
CBM_BIN="${CBM_BIN:-$HOME_DIR/.local/bin/codebase-memory-mcp}"
if $WITH_CBM; then
  if [[ -x "$CBM_BIN" ]] || $DRY_RUN; then
    MCP="$CLAUDE_HOME/.mcp.json"
    if have jq; then
      if $DRY_RUN; then
        say "DRY: would add codebase-memory-mcp ($CBM_BIN) to $MCP"
      else
        [[ -f "$MCP" ]] || echo '{}' > "$MCP"
        entry="$(jq 'del(._comment)' "$GLOBAL_DIR/mcp/codebase-memory.global.json" | sed "s#{{CBM_BIN}}#$CBM_BIN#")"
        tmp="$(mktemp)"
        jq --argjson e "$entry" '.mcpServers = ((.mcpServers // {}) + $e.mcpServers)' "$MCP" > "$tmp"
        mv "$tmp" "$MCP"
        say "registered cbm MCP → $MCP"
      fi
    else
      say "jq not found — add cbm manually from global/mcp/codebase-memory.global.json"
    fi
  else
    say "cbm binary not found at $CBM_BIN — skipped (set \$CBM_BIN or install cbm)"
  fi
else
  say "skipped (pass --with-cbm-mcp to register cbm for Python/TS/Go discovery)"
fi

echo
echo "=== done ==="
echo "Next:"
echo "  - Restart Claude Code so hooks/settings reload."
echo "  - Deps for hooks: jq (+ GNU grep with -P; ships with Git for Windows)."
echo "  - C#/WPF projects: see profiles/csharp/adopt.md (serena + a Roslyn MCP)."
echo "  - Per-repo assets (rules/skills/mcp template): bash scripts/sync-ai-runtime.sh in the product repo."
