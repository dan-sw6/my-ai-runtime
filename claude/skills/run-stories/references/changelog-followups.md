# Changelog follow-ups (Claude Code CLI releases)

Running log of which Claude Code CLI features are applicable to `/run-stories`, and why the rest are **SKIP/DEFER**. Adopted items are in SKILL.md (Invariants 12/13/14, Phase 0.4); this file records the reasoning for the rejections so it doesn't get re-litigated on the next changelog pass.

## Adopted

| Item | Implementation | Where |
|---|---|---|
| `ENABLE_PROMPT_CACHING_1H` | project Claude Code settings `env` block | SKILL.md Phase 0.4 |
| `worktree.baseRef: fresh` | project Claude Code settings `worktree` block | SKILL.md Phase 0.4 |
| AskUserQuestion in auto-mode | documented invariant | SKILL.md Invariant 13 |
| Subagent stall handling | documented retry-once | SKILL.md Invariant 14 |
| Single-engine / single-launcher simplification | multi-CLI-engine and coordinator-native background-agent branches removed | this port (see below) |
| `<state_dir>/story-{id-lc}/` paths | unified via `runtime-config-read.sh` (`rcfg state_dir`) | SKILL.md throughout |

## Porting note (this runtime, vs. the original)

The originating product's `/run-stories` supported three worker engines (Claude/Gemini/Codex CLI) and two launch mechanisms (tmux vs. a coordinator-native background-agent mode). Both axes were **deliberately dropped** in this port — this runtime launches Claude Code only, via tmux only. If a genuine need for multi-engine or a native-background-agent launcher resurfaces, treat it as a fresh design (informed by the SKIP/DEFER entries below, which still apply), not a flag bolted onto this skill.

## SKIP — mechanism mismatch

### Agent frontmatter `mcpServers`

Idea: instead of copying `.mcp.json` into the worktree (`prepare-story-worktree.sh`), declare `mcpServers` in an agent's frontmatter and have the worker pick it up via `--agent`.

**Doesn't fit**: a story worker is not launched as `claude --agent foo` — it's a plain `claude` CLI invocation of `/<ao.story_skill_slug>`. Skills and agents are different entities; skill frontmatter has no `mcpServers` field. Frontmatter `mcpServers` only applies to main-thread invocations via `--agent <name>`, which doesn't apply to story workers.

The `.mcp.json` copy in `prepare-story-worktree.sh` is the correct path. Don't touch it.

### PostToolUse `updatedToolOutput` for worker JSON normalization

Idea: a hook normalizes a worker's `result.json`/`gate.json` BEFORE the coordinator reads it.

**Doesn't fit**: `updatedToolOutput` operates on tool output **in the current session**. The coordinator reads worker JSON via `jq` from a file — that's not the coordinator's own tool output, it's a file-based handoff between sessions. A PostToolUse hook in the worker's session would only affect the worker's own copy, which nobody reads.

If normalization is wanted, do it worker-side when the skill writes `result.json` at close — that's an ordinary schema-cleanup change, not a changelog feature to adopt here.

## DEFER — needs a deeper redesign

### `terminalSequence` hook as a `notify-send` replacement

Idea: `worker-mark-waiting.sh` (the `AskUserQuestion` PreToolUse hook, worker-side) emits a `terminalSequence` (OSC 9 / BEL) → desktop notification without a shell-exec to `notify-send`.

**Doesn't fit as a drop-in**: the hook fires inside the **worker's** session (a separate tmux pane the user isn't watching). `terminalSequence` would land in the worker's own TUI, not the coordinator's. The current path — worker writes a `blocked-waiting.json` marker → `watch-waiting-workers.sh` (background daemon in the coordinator) polls markers and calls `notify-send` — is the correct cross-session notification mechanism.

A real replacement needs a Remote Control / push-notification tool, a materially larger change. Not a current-wave candidate.

### `mcp_tool` hook for discovery-index reindex

Idea: an `mcp_tool` hook automatically triggers a graph reindex post-commit on the trunk, so Phase 0.3's flag-file ritual (read flag → invoke MCP → delete flag) disappears.

**Doesn't fit as a drop-in**: a PostToolUse:Bash matcher fires on EVERY Bash call — there's no content-match on "was this a `git commit`". A conditional hook needs a bash-wrapper, which just re-implements the current flag-file pattern (post-commit git hook → flag file → coordinator reads + invokes MCP). Works today; not broken enough to redesign.

## Open POC notes

### `/goal` for wave-completion tracking

`/goal` — a completion condition Claude tracks across turns. Attractive as a replacement for the `Monitor + wait-wave.sh` re-arm loop ("wave done when all workers exit").

**But**: `/goal` tracks a condition in the **current session**, while workers are external tmux processes. `/goal "wave done when <state_dir>/*/done.flag exists for all N stories"` might work, but needs a POC on: (1) can `/goal` reference external file-state, (2) how does it interact with the Monitor tool if both are watching the same condition, (3) what does the user see. Not a plan-time replacement — build a story only if a concrete gap in the current Monitor flow shows up.

### `claude agents --json` as a secondary worker-status signal

Attractive as a canonical status API to complement `wait-wave.sh`'s 3-signal fallback (`done.flag` → `result.json` → `exit_code`).

**But**: the API is comparatively new and its schema may still shift. The 3-signal fallback is proven. Replacing the *primary* signal is a regression risk for a marginal win (completion is already detected correctly).

**Verdict**: add `claude agents --json` as a **secondary** verification signal in `wait-wave.sh` (log a discrepancy if it disagrees with `done.flag`); promote to primary only after several waves show no disagreement. Not plan-time — pick it up the next time `wait-wave.sh` is touched for another reason.

### Push notification tool (Remote Control)

Replace `notify-send` with a push notification to a phone. Requires Remote Control setup (separate infrastructure). High install footprint for a marginal win. **DEFER** until Remote Control is needed for something else anyway.

## What to watch

- Auto-mode + `AskUserQuestion` interaction — if a future release changes how auto-mode surfaces blocking questions, re-check SKILL.md A.6 / B.1.4 / B.1.7 against the new changelog entry.
- `claude agents` API schema stabilization — once stable, re-evaluate the "secondary signal" POC above.
- An OTEL exporter for skill-invocation metrics — if the product ever stands up a local OTEL collector, wire it in for `/run-stories` invocation-rate / wave-size-distribution metrics.
