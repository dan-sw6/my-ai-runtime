#!/usr/bin/env bash
# runtime-config-read.sh — sourced helper for the AO story-machinery.
#
# Centralises reading of the product's runtime.config.yaml so every harness script
# resolves paths/slugs/models/gates the same way, with env-var override and a safe
# default when the key, file, python, or PyYAML is missing.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/runtime-config-read.sh"
#   STORY_DIR="$(rcfg ao.story_dir docs/stories)"     # env AO_STORY_DIR wins
#   rcfg_bool srs.enabled       && echo "srs on"
#   rcfg_list ao.gh_labels                            # one item per line
#   CMD="$(rcfg_expand "$(rcfg gates.default echo)")" # expand {gates.X} tokens
#
# Config file resolution (first hit): $AI_RUNTIME_CONFIG, else
# ${CLAUDE_PROJECT_DIR:-$PWD}/runtime.config.yaml.
# Requires python3 + PyYAML for parsing (same dependency as parse-story-frontmatter.sh);
# without them every lookup falls back to its default — the harness still runs.

[[ -n "${_RCFG_SOURCED:-}" ]] && return 0
_RCFG_SOURCED=1

: "${RCFG_FILE:=${AI_RUNTIME_CONFIG:-${CLAUDE_PROJECT_DIR:-$PWD}/runtime.config.yaml}}"

_rcfg_py() {
  local key="$1" def="${2:-}"
  [[ -f "$RCFG_FILE" ]] || { printf '%s' "$def"; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf '%s' "$def"; return 0; }
  python3 - "$RCFG_FILE" "$key" "$def" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
default = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    import yaml
except Exception:
    print(default); sys.exit(0)
try:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print(default); sys.exit(0)
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default); sys.exit(0)
if cur is None:
    print(default)
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (list, dict)):
    import json
    print(json.dumps(cur))
else:
    print(cur)
PY
}

# rcfg <dotted.key> [default] — scalar value; env var (AO_STORY_DIR for ao.story_dir) wins.
rcfg() {
  local key="$1" def="${2:-}" env_name
  env_name="$(printf '%s' "$key" | tr 'a-z.-' 'A-Z__')"
  if [[ -n "${!env_name:-}" ]]; then printf '%s' "${!env_name}"; return 0; fi
  _rcfg_py "$key" "$def"
}

# rcfg_bool <dotted.key> [default] — exit 0 if truthy.
rcfg_bool() {
  local v; v="$(rcfg "$1" "${2:-false}")"
  [[ "$v" == "true" || "$v" == "1" || "$v" == "yes" ]]
}

# rcfg_list <dotted.key> — YAML/JSON list → one item per line (config-only, no env override).
rcfg_list() {
  local json; json="$(_rcfg_py "$1" "[]")"
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "$json" | python3 -c 'import sys,json
try: v=json.load(sys.stdin)
except Exception: v=[]
[print(x) for x in (v or [])]' 2>/dev/null || true
}

# rcfg_json <dotted.key> — raw JSON for containers (e.g. ao.gate_registry list-of-maps).
rcfg_json() { _rcfg_py "$1" "${2:-null}"; }

# rcfg_expand <string> — substitute {gates.NAME} tokens using config values.
rcfg_expand() {
  local s="$1"
  while [[ "$s" =~ \{gates\.([a-zA-Z0-9_]+)\} ]]; do
    local m="${BASH_REMATCH[1]}" v
    v="$(rcfg "gates.${m}" "")"
    s="${s//\{gates.${m}\}/$v}"
  done
  printf '%s' "$s"
}
