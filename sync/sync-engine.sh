#!/usr/bin/env bash
# sync-engine.sh — Core sync logic for mgt-ai-runtime → product repos
# Called by product repo's scripts/sync-ai-runtime.sh wrapper
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

# Counters (use let...||: to avoid set -e tripping on 0→1 increment)
created=0
updated=0
skipped=0
warnings=0
inc() { eval "$1=\$(( $1 + 1 ))"; }

# Parse manifest entries using grep/sed (no yq dependency)
# Format: source, target, mode extracted from YAML
parse_entries() {
  local in_entry=false
  local source="" target="" mode=""

  while IFS= read -r line; do
    # Detect entry start
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*source: ]]; then
      source=$(echo "$line" | sed 's/.*source:[[:space:]]*//')
      in_entry=true
      continue
    fi
    if $in_entry && [[ "$line" =~ ^[[:space:]]*target: ]]; then
      target=$(echo "$line" | sed 's/.*target:[[:space:]]*//')
      continue
    fi
    if $in_entry && [[ "$line" =~ ^[[:space:]]*mode: ]]; then
      mode=$(echo "$line" | sed 's/.*mode:[[:space:]]*//')
      in_entry=false
      echo "$source|$target|$mode"
      source="" target="" mode=""
    fi
  done < "$MANIFEST"
}

sync_file() {
  local source="$1" target="$2" mode="$3"
  local src_path="$RUNTIME_DIR/$source"
  local tgt_path="$PRODUCT_DIR/$target"

  if [[ ! -f "$src_path" ]]; then
    echo "  WARN: source missing: $source"
    inc warnings
    return
  fi

  local tgt_exists=false
  [[ -f "$tgt_path" ]] && tgt_exists=true

  case "$mode" in
    seed)
      if $tgt_exists && ! $FORCE; then
        echo "  SKIP [seed]: $target (exists, preserving customization)"
        inc skipped
        return
      fi
      if $tgt_exists && $FORCE; then
        echo "  FORCE [seed]: $target (overwriting)"
      else
        echo "  CREATE [seed]: $target"
      fi
      ;;
    managed)
      if $tgt_exists; then
        if diff -q "$src_path" "$tgt_path" >/dev/null 2>&1; then
          echo "  SKIP [managed]: $target (unchanged)"
          inc skipped
          return
        fi
        echo "  UPDATE [managed]: $target"
      else
        echo "  CREATE [managed]: $target"
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
        echo "  CREATE [template]: $target"
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

  # Create target directory and copy
  mkdir -p "$(dirname "$tgt_path")"
  cp "$src_path" "$tgt_path"
  if [[ "$mode" == "seed" ]] && ! $FORCE && ! $tgt_exists; then
    inc created
  elif [[ "$mode" == "managed" ]]; then
    if $tgt_exists; then
      inc updated
    else
      inc created
    fi
  else
    inc created
  fi
}

echo "=== AI Runtime Sync ==="
echo "Runtime: $RUNTIME_DIR"
echo "Product: $PRODUCT_DIR"
$DRY_RUN && echo "Mode: DRY RUN (no files will be changed)"
$FORCE && echo "Mode: FORCE (seed files will be overwritten)"
echo ""

# Process all entries
while IFS='|' read -r source target mode; do
  sync_file "$source" "$target" "$mode"
done < <(parse_entries)

echo ""
echo "=== Summary ==="
echo "Created: $created"
echo "Updated: $updated"
echo "Skipped: $skipped"
echo "Warnings: $warnings"
$DRY_RUN && echo "(dry-run — no changes applied)"
