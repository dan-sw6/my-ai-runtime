> ## ⚠ DEPRECATED — do NOT use
>
> This multi-story `general-purpose` worktree-dispatch mode is **rejected and deprecated**.
> Backgrounding `general-purpose` agents with `isolation: "worktree"` from inside the skill
> hit Claude Code harness bugs (background-agent worktree isolation / dispatch races) and
> never delivered reliable multi-story parallelism.
>
> **Use `/run-stories` instead** for batch / parallel delivery. `/run-stories` builds dependency
> waves and dispatches each story through its own `/implement-story` worker (tmux `wait-wave.sh`
> by default, or the opt-in agent-view engine — see SKILL.md). `/implement-story`
> itself should be invoked **single-story** only.
>
> The content below is retained for historical context only. It is NOT a supported execution path.

## Parallel Execution (Multi-Story Mode) — DEPRECATED

When multiple STORY-IDs are provided (e.g. `/implement-story STORY-120 STORY-121 STORY-122`):

### Pre-flight

1. Read all story files and check for dependency conflicts (shared files/modules)
2. If conflicts detected → execute sequentially in dependency order
3. If independent → launch in parallel

### Parallel Launch

For each independent story, launch as background Agent:

```
Agent(
  subagent_type="general-purpose",
  isolation: "worktree",
  mode: "auto",
  run_in_background: true,
  name: "story-{ID}",
  prompt="""
  Execute /implement-story for STORY-{ID}.

  [Full skill content above — the agent executes the entire Phase 0-5 loop independently]

  IMPORTANT:
  - You are running in an isolated worktree
  - Use file-based progress for shared state:
    echo "in-progress" > ${CLAUDE_WORKER_DIR}/status
  - On completion:
    echo "complete" > ${CLAUDE_WORKER_DIR}/status
  - On failure:
    echo "failed" > ${CLAUDE_WORKER_DIR}/status
    echo "[reason]" > ${CLAUDE_WORKER_DIR}/blocker
  """
)
```

### Orchestrator Monitoring

While stories execute in background, orchestrator periodically checks:
```bash
cat <state_dir>/story-*/status 2>/dev/null
```

When all stories complete → collect results, merge worktrees, produce combined report.
