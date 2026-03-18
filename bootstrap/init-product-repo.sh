#!/usr/bin/env bash
# init-product-repo.sh — Bootstrap Claude Code infrastructure in a product repo
# Usage: bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh /path/to/product-repo
set -euo pipefail

PRODUCT_DIR="${1:?Usage: init-product-repo.sh <product-repo-path>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Bootstrapping Claude Code infrastructure ==="
echo "Product repo: $PRODUCT_DIR"
echo "Runtime repo: $RUNTIME_DIR"
echo ""

# Create directory structure
mkdir -p "$PRODUCT_DIR/.claude/agents"
mkdir -p "$PRODUCT_DIR/.claude/skills"
mkdir -p "$PRODUCT_DIR/.claude/quality-gates"
mkdir -p "$PRODUCT_DIR/.claude/rules"
mkdir -p "$PRODUCT_DIR/.claude/templates"

echo "Created .claude/ directory structure"

# Copy sync script
if [[ ! -f "$PRODUCT_DIR/scripts/sync-ai-runtime.sh" ]]; then
  mkdir -p "$PRODUCT_DIR/scripts"
  cat > "$PRODUCT_DIR/scripts/sync-ai-runtime.sh" << 'SYNCEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${AI_RUNTIME_PATH:-$PRODUCT_DIR/../mgt-ai-runtime}"
if [[ ! -d "$RUNTIME_DIR" ]]; then
  echo "ERROR: AI runtime repo not found at $RUNTIME_DIR"
  exit 1
fi
exec bash "$RUNTIME_DIR/sync/sync-engine.sh" "$RUNTIME_DIR" "$PRODUCT_DIR" "$@"
SYNCEOF
  chmod +x "$PRODUCT_DIR/scripts/sync-ai-runtime.sh"
  echo "Created scripts/sync-ai-runtime.sh"
fi

# Run initial sync (seed mode — won't overwrite existing files)
echo ""
echo "Running initial sync..."
bash "$RUNTIME_DIR/sync/sync-engine.sh" "$RUNTIME_DIR" "$PRODUCT_DIR"

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps:"
echo "1. Customize agents in .claude/agents/ for your project"
echo "2. Customize skills in .claude/skills/ for your project"
echo "3. Update CLAUDE.md with agents/skills documentation"
echo "4. Run: bash scripts/sync-ai-runtime.sh --dry-run"
