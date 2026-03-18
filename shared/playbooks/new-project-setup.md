# New Project Setup Playbook

## Prerequisites

- Git repository exists
- CLAUDE.md exists or will be created
- Project documentation (SRS or equivalent) exists
- MCP servers configured in `.claude/settings.json`

## Steps

### 1. Clone or Link Runtime Repo

```bash
# If not already available
cd /path/to/projects
git clone <runtime-repo-url> mgt-ai-runtime
```

### 2. Bootstrap

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh .
```

### 3. Customize Agent Profiles

For each agent in `.claude/agents/`:
- Set `read_first` to your project's key files
- Set `avoid` rules matching your governance model
- Set `mcp_servers` to your configured servers

### 4. Customize Skills

For each skill in `.claude/skills/`:
- Update file path references (SRS, RTM, stories, tasks)
- Update quality gate commands to match your scripts

### 5. Update CLAUDE.md

Add sections for:
- Claude agents table
- Claude skills table
- Dual-runtime model (if using both Codex and Claude)

### 6. Set Up Sync

```bash
bash scripts/sync-ai-runtime.sh --dry-run  # Verify
bash scripts/sync-ai-runtime.sh            # Apply
```

### 7. Commit

```bash
git add .claude/ scripts/sync-ai-runtime.sh docs/WORKFLOW_CLAUDE.md
git commit -m "feat: add Claude Code AI workflow infrastructure"
```
