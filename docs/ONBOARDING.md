# Onboarding a New Product Repo

## Prerequisites

- Git repository initialized
- CLAUDE.md exists (or will be created)
- Product-specific governance docs in place (SRS, RTM, etc.)

## Steps

### 1. Run Bootstrap

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh .
```

This creates:
- `.claude/agents/` with base subagent files
- `.claude/skills/` with base skill files
- `scripts/sync-ai-runtime.sh` wrapper

### 2. Customize Agents

Edit each `.claude/agents/*.md` file to add project-specific context:
- Update `read_first` paths to match your project structure
- Adjust `avoid` rules for your governance model
- Set `mcp_servers` to match your `.claude/settings.json`

### 3. Customize Skills

Edit each `.claude/skills/*.md` to reference your project's:
- SRS/requirements file paths
- Story/task directory paths
- Quality gate scripts
- RTM file path

### 4. Update CLAUDE.md

Add a section documenting your Claude agents and skills. See `mgt-openproject/CLAUDE.md` for reference.

### 5. Verify

```bash
bash scripts/sync-ai-runtime.sh --dry-run
```

### 6. Ongoing Sync

Run periodically to pick up runtime improvements:

```bash
bash scripts/sync-ai-runtime.sh
```

Only `managed` files are overwritten. Your customizations to `seed` files are preserved.
