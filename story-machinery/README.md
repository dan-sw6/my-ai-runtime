# story-machinery — AO closed-loop /run-stories harness (Layer B)

The reusable harness that runs a story from a spec to a merged PR through
**worktree isolation → phase-contract state machine → wave orchestration → quality
gate → review loop → merge**. Ported and generalized from the mgt-openproject AO
system; parameterized so it runs on any project (Linux or Windows/Git Bash, any
stack) via `runtime.config.yaml`.

## Hybrid design (why this shape)

The 2025–2026 spec-driven-development (SDD) ecosystem converged on one loop —
**specify → plan → tasks → implement** — with EARS acceptance criteria and
SRS.md/rtm.yaml (IEEE-830) requirements docs. Mature Claude Code plugins already
cover the *spec* side (GitHub Spec Kit, `sighup/claude-workflow`,
`lindy-orchestrator`). So this runtime does **not** reinvent that:

- **Port (unique, hard-to-replace):** the execution harness — git-worktree
  isolation, the phase-contract state machine, wave orchestration + monitoring,
  the config-driven gate registry, and the review→auto-fixup loop.
- **Standardize (don't bake mgt's parser):** the spec side stays SRS.md + rtm.yaml
  (already standard-aligned), authored with **EARS** acceptance criteria and an
  rtm.yaml shaped to the published `rtm-yaml-schema`. It is an **optional module**
  (`srs.enabled`) — the harness runs fine without any requirements doc.

Interop: the harness's loop maps 1:1 to the ecosystem's phases, so specs authored
by Spec Kit / other SDD tools can feed it.

## Layout

```
scripts/   flat bundle — shared libs + harness (~30), all siblings:
           runtime-config-read.sh   config reader (env-override, safe defaults)
           phase-log-util.sh        phase-log append + state-JSON gate
           parse-story-frontmatter.sh
           worktree/launch/phase/wave/gate/review/merge/monitor scripts
srs/       OPTIONAL SRS/RTM cluster (gated by srs.enabled) + EARS guide + rtm schema
```

Everything under `scripts/` is one flat, relocatable bundle — scripts source their
siblings via `$SCRIPT_DIR`. It syncs into a product at `scripts/ao/` (namespaced,
never clobbers the product's own `scripts/`).

## Configuration

All behaviour comes from the product's `runtime.config.yaml` `ao:` and `srs:`
blocks (see `config/runtime.config.example.yaml`). Key knobs: `ao.story_dir`,
`ao.story_skill_slug`, `ao.worker_model`/`worker_effort`, `ao.base_ref`,
`ao.worktree_root`, `ao.max_parallel`, `ao.gate_registry` (`{glob → command}`),
`ao.migrations_dir`, and the whole `srs:` block. Every key is overridable by an
env var (`ao.story_dir` → `AO_STORY_DIR`).

## Requirements

- **git** (worktrees), **bash** (Git Bash on Windows), **jq**.
- **python3 + PyYAML** — for config + story-frontmatter parsing.
- **Claude Code CLI** — the worker engine (Claude-only; the mgt gemini/codex engine
  branches are intentionally not ported).
- **tmux** — for the interactive worker view.
- Per-stack gate tooling as configured in `ao.gate_registry` / `gates.*`
  (e.g. `dotnet`, `pytest`, `vitest`) — provided by the product, not this runtime.

## Install

```bash
bash <runtime>/bootstrap/init-product-repo.sh . --with-ao [--with-srs]
```
Then run the loop from the product repo with the `run-stories` / `implement-story`
skills (synced into `.claude/skills/`).
