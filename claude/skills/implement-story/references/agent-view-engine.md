## Agent-view engine (optional, requires a recent Claude Code CLI)

> **Research preview. Local-only. Opt-in.** This is a native alternative to the
> tmux + `wait-wave.sh` orchestration. **The DEFAULT remains tmux / wait-wave** — the
> agent-view engine is opt-in and changes nothing unless explicitly selected.
> **Rate-limit warning:** each backgrounded agent consumes its own quota, so N parallel
> agents = **N× your normal rate-limit / quota** burn. Available only on recent Claude Code
> versions (`claude --version` to confirm); on older versions this section does not apply.

Drop this subsection into BOTH `run-stories` and `implement-story` as an optional execution
backend. When selected, it replaces tmux panes + `wait-wave.sh` polling with Claude Code's
native background-agent surface.

### Dispatch (instead of launch-story-worker / tmux)

Background one agent per story. Model/effort policy unchanged from tmux workers
(`ao.worker_model`/`ao.worker_effort` from `runtime.config.yaml`):

```bash
claude --bg --name <story-id> \
  --agent <type> \
  --model "$(rcfg ao.worker_model opus)" --effort "$(rcfg ao.worker_effort xhigh)" \
  "<worker-prompt>"
```

- `--bg` backgrounds the agent immediately (non-blocking dispatch).
- `--name <story-id>` is the stable handle for poll/attach/logs/stop (e.g. `STORY-431`).
- `--agent <type>` selects the worker agent type.
- One `claude --bg …` per story in the wave (the parallel-bucket grouping from wave
  planning is preserved — just N background agents instead of N tmux panes).

### Poll (instead of wait-wave.sh)

```bash
claude agents --json --cwd "$(git rev-parse --show-toplevel)"
```

Returns one record per agent with fields: `pid`, `cwd`, `sessionId`, `name`, `status`.
Poll this on an interval; a wave is done when every dispatched `name` reports a terminal
`status`. This is the native substitute for `wait-wave.sh` + Monitor-loop. PR-status rows
(per-story PR state) surface alongside the agent rows for at-a-glance wave health.

### Manage (lifecycle)

```bash
claude attach  <story-id>   # attach to a live background agent (interactive takeover)
claude logs    <story-id>   # stream / dump that agent's output
claude stop    <story-id>   # stop a running agent
claude respawn <story-id>   # restart a stopped/failed agent (re-dispatch same handle)
claude rm      <story-id>   # remove the agent record after harvest
```

`/bg` (slash command inside a live interactive session) backgrounds the current session so
it joins the agent-view surface — useful to convert an attached/interactive run back into a
background agent without losing it.

### Worktree isolation (native)

The agent-view engine provides native git-worktree isolation under
`ao.worktree_root` (default `.claude/worktrees/`) — one worktree per background agent,
gated by the `worktree.bgIsolation` setting. When enabled, each `--bg` agent gets its own
worktree automatically — the manual worktree-create / worktree-gate dance from the tmux
path is handled natively. Confirm `worktree.bgIsolation` is on before relying on
per-agent isolation.

### When to use

Opt-in only, on a recent CLI, when you want native lifecycle/attach/logs and native worktree
isolation instead of tmux panes. Otherwise — and by default — keep using
tmux + `wait-wave.sh`. Do not switch a whole wave to the agent-view engine without
accounting for the N× rate-limit cost.
