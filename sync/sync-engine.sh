#!/usr/bin/env bash
# sync-engine.sh — Core sync logic for my-ai-runtime → product repos
# Called by product repo's scripts/sync-ai-runtime.sh wrapper
#
# Extends the original seed/managed/template copy engine with:
#   - Token substitution: files marked `substitute: true` in the manifest have
#     {{TOKENS}} replaced from the product's runtime.config.yaml (+ auto-detect).
#   - Profile filtering: entries with `profiles: [..]` apply only when one of the
#     listed languages is active in runtime.config.yaml `languages:`.
# Entries without those fields behave exactly as before (plain cp, always applied).
set -euo pipefail

RUNTIME_DIR="${1:?Usage: sync-engine.sh <runtime-dir> <product-dir> [--dry-run] [--force]}"
PRODUCT_DIR="${2:?Usage: sync-engine.sh <runtime-dir> <product-dir> [--dry-run] [--force]}"
DRY_RUN=false
FORCE=false

shift 2
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    *)         echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

MANIFEST="$RUNTIME_DIR/sync/manifest.yaml"
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: Manifest not found at $MANIFEST"
  exit 1
fi

# ---------------------------------------------------------------------------
# runtime.config.yaml — token values + active profiles (all optional)
# ---------------------------------------------------------------------------
CONFIG="$PRODUCT_DIR/runtime.config.yaml"

# cfg <key> <default> — read a top-level scalar key (grep/sed, no yq dependency)
cfg() {
  local key="$1" def="${2:-}" val=""
  if [[ -f "$CONFIG" ]]; then
    val="$(grep -E "^${key}:" "$CONFIG" 2>/dev/null | head -1 \
      | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//")"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
  fi
  [[ -z "$val" ]] && val="$def"
  printf '%s' "$val"
}

OS_NAME="$(cfg os linux)"
# Home dir used to expand a leading ~ in path-valued config (linux/git-bash only).
HOME_DIR="${HOME:-${USERPROFILE:-}}"
expand_tilde() {
  local v="$1"
  if [[ "$OS_NAME" != "windows" && "$v" == "~"* ]]; then
    printf '%s' "${HOME_DIR}${v:1}"
  else
    printf '%s' "$v"
  fi
}

# Auto-detected tokens
PROJECT_ROOT="$(cd "$PRODUCT_DIR" && pwd -P)"
PROJECT_NAME="$(cfg project_name "$(basename "$PROJECT_ROOT")")"

# Config-driven tokens
CBM_PROJECT="$(cfg cbm_project "")"
CBM_BIN="$(expand_tilde "$(cfg cbm_bin "~/.local/bin/codebase-memory-mcp")")"
STATE_DIR="$(cfg state_dir "/tmp/claude-workers")"
BACKEND_PATH="$(cfg backend "")"
FRONTEND_PATH="$(cfg frontend "")"
APP_PATHS="$(printf '%s %s' "$BACKEND_PATH" "$FRONTEND_PATH" | sed -E 's/^ +| +$//g')"

# Active language profiles → array
active_langs_raw="$(cfg languages "")"
active_langs_raw="${active_langs_raw#[}"; active_langs_raw="${active_langs_raw%]}"
IFS=',' read -r -a ACTIVE_LANGS <<< "$active_langs_raw"
for i in "${!ACTIVE_LANGS[@]}"; do
  ACTIVE_LANGS[$i]="$(echo "${ACTIVE_LANGS[$i]}" | tr -d '[:space:]')"
done

lang_active() {
  local want="$1" l
  # No languages declared → treat all profile entries as active (permissive default)
  [[ -z "${ACTIVE_LANGS[*]}" ]] && return 0
  for l in "${ACTIVE_LANGS[@]}"; do
    [[ "$l" == "$want" ]] && return 0
  done
  return 1
}

# entry_active <profiles_csv> — profile filter for a manifest entry
entry_active() {
  local csv="$1" p
  [[ -z "$csv" ]] && return 0            # no `profiles:` → always active
  IFS=',' read -r -a plist <<< "$csv"
  for p in "${plist[@]}"; do
    lang_active "$p" && return 0
  done
  return 1
}

# apply_substitution <file> — replace {{TOKENS}} in place (pure bash, no sed escaping)
apply_substitution() {
  local file="$1" content
  content="$(cat "$file")"
  content="${content//"{{PROJECT_ROOT}}"/$PROJECT_ROOT}"
  content="${content//"{{PROJECT_NAME}}"/$PROJECT_NAME}"
  content="${content//"{{CBM_PROJECT}}"/$CBM_PROJECT}"
  content="${content//"{{CBM_BIN}}"/$CBM_BIN}"
  content="${content//"{{STATE_DIR}}"/$STATE_DIR}"
  content="${content//"{{OS}}"/$OS_NAME}"
  content="${content//"{{BACKEND_PATH}}"/$BACKEND_PATH}"
  content="${content//"{{FRONTEND_PATH}}"/$FRONTEND_PATH}"
  content="${content//"{{APP_PATHS}}"/$APP_PATHS}"
  printf '%s\n' "$content" > "$file"
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
created=0
updated=0
skipped=0
warnings=0
filtered=0
inc() { eval "$1=\$(( $1 + 1 ))"; }

# Parse manifest entries (grep/sed, no yq). Emits:
#   source|target|mode|substitute|profiles_csv
# substitute defaults to "false"; profiles_csv defaults to "" (always active).
parse_entries() {
  local source="" target="" mode="" substitute="false" profiles=""
  flush() {
    [[ -n "$source" ]] && echo "$source|$target|$mode|$substitute|$profiles"
    source="" target="" mode="" substitute="false" profiles=""
  }
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*source: ]]; then
      flush
      source=$(echo "$line" | sed 's/.*source:[[:space:]]*//')
    elif [[ -n "$source" && "$line" =~ ^[[:space:]]*target: ]]; then
      target=$(echo "$line" | sed 's/.*target:[[:space:]]*//')
    elif [[ -n "$source" && "$line" =~ ^[[:space:]]*mode: ]]; then
      mode=$(echo "$line" | sed 's/.*mode:[[:space:]]*//')
    elif [[ -n "$source" && "$line" =~ ^[[:space:]]*substitute: ]]; then
      substitute=$(echo "$line" | sed 's/.*substitute:[[:space:]]*//')
    elif [[ -n "$source" && "$line" =~ ^[[:space:]]*profiles: ]]; then
      profiles=$(echo "$line" | sed 's/.*profiles:[[:space:]]*//; s/^\[//; s/\]$//; s/[[:space:]]//g')
    elif [[ "$line" =~ ^[^[:space:]#-] ]]; then
      # A new top-level key (e.g. `exclusions:`) ends the entries block
      flush
    fi
  done < "$MANIFEST"
  flush
}

sync_file() {
  local source="$1" target="$2" mode="$3" substitute="$4"
  local src_path="$RUNTIME_DIR/$source"
  local tgt_path="$PRODUCT_DIR/$target"

  if [[ ! -f "$src_path" ]]; then
    echo "  WARN: source missing: $source"
    inc warnings
    return
  fi

  local tgt_exists=false
  [[ -f "$tgt_path" ]] && tgt_exists=true
  local sub_tag=""
  [[ "$substitute" == "true" ]] && sub_tag=" +subst"

  case "$mode" in
    seed)
      if $tgt_exists && ! $FORCE; then
        echo "  SKIP [seed]: $target (exists, preserving customization)"
        inc skipped
        return
      fi
      if $tgt_exists && $FORCE; then
        echo "  FORCE [seed]: $target (overwriting)${sub_tag}"
      else
        echo "  CREATE [seed]: $target${sub_tag}"
      fi
      ;;
    managed)
      # For substituted files, compare against the SUBSTITUTED source, not raw.
      if $tgt_exists; then
        if [[ "$substitute" == "true" ]]; then
          local tmp; tmp="$(mktemp)"
          cp "$src_path" "$tmp"; apply_substitution "$tmp"
          if diff -q "$tmp" "$tgt_path" >/dev/null 2>&1; then
            echo "  SKIP [managed]: $target (unchanged)"; rm -f "$tmp"; inc skipped; return
          fi
          rm -f "$tmp"
        elif diff -q "$src_path" "$tgt_path" >/dev/null 2>&1; then
          echo "  SKIP [managed]: $target (unchanged)"; inc skipped; return
        fi
        echo "  UPDATE [managed]: $target${sub_tag}"
      else
        echo "  CREATE [managed]: $target${sub_tag}"
      fi
      ;;
    template)
      if $tgt_exists && ! $FORCE; then
        if [[ "$src_path" -nt "$tgt_path" ]]; then
          echo "  WARN [template]: $target exists but source is newer — consider updating"
          inc warnings
        else
          echo "  SKIP [template]: $target (exists)"
        fi
        inc skipped
        return
      fi
      if ! $tgt_exists; then
        echo "  CREATE [template]: $target${sub_tag}"
      fi
      ;;
    *)
      echo "  ERROR: unknown mode '$mode' for $target"
      return
      ;;
  esac

  if $DRY_RUN; then
    return
  fi

  mkdir -p "$(dirname "$tgt_path")"
  cp "$src_path" "$tgt_path"
  [[ "$substitute" == "true" ]] && apply_substitution "$tgt_path"

  if [[ "$mode" == "seed" ]] && ! $FORCE && ! $tgt_exists; then
    inc created
  elif [[ "$mode" == "managed" ]]; then
    if $tgt_exists; then inc updated; else inc created; fi
  else
    inc created
  fi
}

echo "=== AI Runtime Sync ==="
echo "Runtime: $RUNTIME_DIR"
echo "Product: $PRODUCT_DIR"
if [[ -f "$CONFIG" ]]; then
  echo "Config:  $CONFIG"
  echo "         project=$PROJECT_NAME os=$OS_NAME languages=[${ACTIVE_LANGS[*]}]"
else
  echo "Config:  (none — using auto-detect + defaults; all profile entries active)"
fi
$DRY_RUN && echo "Mode: DRY RUN (no files will be changed)"
$FORCE && echo "Mode: FORCE (seed files will be overwritten)"
echo ""

# Process all entries
while IFS='|' read -r source target mode substitute profiles; do
  if ! entry_active "$profiles"; then
    echo "  FILTER: $target (profiles=[$profiles] not in active languages)"
    inc filtered
    continue
  fi
  sync_file "$source" "$target" "$mode" "$substitute"
done < <(parse_entries)

echo ""
echo "=== Summary ==="
echo "Created:  $created"
echo "Updated:  $updated"
echo "Skipped:  $skipped"
echo "Filtered: $filtered"
echo "Warnings: $warnings"
$DRY_RUN && echo "(dry-run — no changes applied)"
