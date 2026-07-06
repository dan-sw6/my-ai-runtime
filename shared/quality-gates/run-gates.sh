#!/usr/bin/env bash
# run-gates.sh — portable quality-gate runner (my-ai-runtime core).
#
# The config-driven replacement for a product's hand-written lint.sh/test.sh/type.sh.
# Reads `gates.<language>.<kind>` commands from runtime.config.yaml and runs them for
# every active language profile, so a Python repo, a TypeScript repo, and a mixed
# [python, csharp] repo each express their own gate commands in config without any
# change to this script.
#
# Usage:
#   bash scripts/run-gates.sh [all|<kind>]
#     all         run every gate kind defined under each active language (default)
#     <kind>      run just that kind (lint | type | test | build | format | …)
#                 for each active language that defines it
#
# Language selection: `languages:` in runtime.config.yaml; if unset, falls back to
# whatever languages have a `gates.<lang>` block. `{paths}` in a gate command expands
# to that language's target paths (python→paths.backend, typescript→paths.frontend,
# else paths.<lang>, else "."). `{gates.X}` tokens expand from the config too.
#
# Exit: non-zero if any gate command fails. Missing/empty command for a kind → skipped
# (informational), never a failure. No python/PyYAML → every lookup returns its default
# and the runner no-ops gracefully.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- locate the shared config reader (product: scripts/lib; runtime repo: ../lib) ----
_LIB=""
for c in "$SCRIPT_DIR/lib/runtime-config-read.sh" \
         "$SCRIPT_DIR/../lib/runtime-config-read.sh" \
         "$SCRIPT_DIR/../scripts/lib/runtime-config-read.sh"; do
  [[ -f "$c" ]] && { _LIB="$c"; break; }
done
[[ -n "$_LIB" ]] || { echo "ERROR: runtime-config-read.sh not found next to run-gates.sh (expected scripts/lib/)" >&2; exit 2; }
# shellcheck source=/dev/null
source "$_LIB"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

WHICH="${1:-all}"
# Static checks before tests; whichever kinds a language actually defines get run.
KINDS_ALL=(lint format type build test)

# --- active languages --------------------------------------------------------
mapfile -t LANGS < <(rcfg_list languages)
if [[ ${#LANGS[@]} -eq 0 ]]; then
  # No `languages:` declared → derive from the gate blocks that exist (minus `default`).
  mapfile -t LANGS < <(rcfg_json gates null | python3 -c '
import sys, json
try: d = json.load(sys.stdin) or {}
except Exception: d = {}
if isinstance(d, dict):
    [print(k) for k in d if k != "default"]
' 2>/dev/null)
fi
[[ ${#LANGS[@]} -gt 0 ]] || { echo "run-gates: no languages and no gate blocks configured — nothing to do." ; exit 0; }

# --- target paths for a language --------------------------------------------
paths_for() {
  local lang="$1" p
  case "$lang" in
    python)     p="$(rcfg paths.backend "")" ;;
    typescript) p="$(rcfg paths.frontend "")" ;;
    *)          p="$(rcfg "paths.$lang" "")" ;;
  esac
  [[ -n "$p" ]] || p="."
  printf '%s' "$p"
}

# --- run one gate ------------------------------------------------------------
FAILED=()
RAN=0
run_gate() {
  local lang="$1" kind="$2" cmd
  cmd="$(rcfg "gates.${lang}.${kind}" "")"
  [[ -n "$cmd" ]] || return 0                       # kind not defined for this lang → skip
  cmd="$(rcfg_expand "$cmd")"                        # {gates.X}
  local paths; paths="$(paths_for "$lang")"
  cmd="${cmd//\{paths\}/$paths}"                     # {paths}
  echo ""
  echo "▶ [$lang:$kind] $cmd"
  RAN=$((RAN + 1))
  if bash -c "$cmd"; then
    echo "✓ [$lang:$kind] passed"
  else
    echo "✗ [$lang:$kind] FAILED" >&2
    FAILED+=("$lang:$kind")
  fi
}

echo "run-gates: languages=[${LANGS[*]}] which=$WHICH  (repo=$REPO_ROOT)"
for lang in "${LANGS[@]}"; do
  if [[ "$WHICH" == "all" ]]; then
    for kind in "${KINDS_ALL[@]}"; do run_gate "$lang" "$kind"; done
  else
    run_gate "$lang" "$WHICH"
  fi
done

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "run-gates: ${#FAILED[@]} gate(s) FAILED — ${FAILED[*]}" >&2
  exit 1
fi
[[ $RAN -gt 0 ]] && echo "run-gates: all $RAN gate(s) passed." || echo "run-gates: no matching gate commands configured (nothing ran)."
exit 0
