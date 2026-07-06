# Two-Repository AI Workflow Architecture

## Overview

The AI workflow model separates **reusable infrastructure** from **project-specific configuration** across two repositories:

1. **AI Runtime Repo** (`mgt-ai-runtime`) — a discipline layer plus composable language profiles: templates, base agents, quality gates, hooks, playbooks
2. **Product Repo** (e.g., `mgt-openproject`) — project truth, customized agents, governance

The runtime reaches a product repo (and the developer's machine) through **two
delivery channels**, and its per-language behavior is driven by **composable
profiles** the product opts into. Both are new relative to the original single-sync
model and are documented in full below.

## Separation of Concerns

### Runtime Repo Owns
- Base agent definitions (generic, parameterized)
- Reusable templates (story, task, handoff, closeout)
- Quality gate definitions (DoD, MCP matrix)
- Operational playbooks (closed-loop cycle, corrective rerun)
- Shared rules (safety, git, secrets, module scope, MCP usage, quality gates)
- Composable language profiles (`profiles/{python,typescript,csharp}/`)
- Cross-stack discipline hooks (`global/hooks/`)
- Sync manifest and engine (Channel 1)
- Machine-global installer (Channel 2, `global/install-global.sh`)
- Bootstrap scripts

### Product Repo Owns
- All project governance (CLAUDE.md, AGENTS.md)
- Requirements (SRS.md, rtm.yaml)
- Planning state (NOW.md, BACKLOG.md, DECISIONS.md)
- BMAD state (bmad/, docs/bmad/, docs/stories/)
- Task definitions (tasks/)
- Customized agent profiles (.claude/agents/, agents/)
- Custom agents not in runtime (e.g., story-planner)
- Codex skills (.codex/skills/)
- Role prompts (docs/prompts/)

## Runtime Priority Model

Product repos use two AI runtimes with clear priority:

### Claude Code (PRIMARY)
- **Closed-loop delivery** via skill-as-coordinator pattern (Variant C)
- Skill script (`/implement-story`) IS the coordinator — orchestrates phases inline
- Phases: PLAN (story-planner subagent) → IMPLEMENT (specialist subagents) → GATE (bash scripts) → VERIFY (qa-expert subagent)
- Communication: in-memory subagent delegation (no filesystem artifacts)
- Operates in developer's terminal

### Codex (SECONDARY)
- Available but not the default runtime for new work
- Automated closed-loop via FILE-HANDOFF YAML protocol in tmux sessions
- Governed by AGENTS.md
- Useful for batch/unattended execution when needed

### Shared Between Runtimes
- Quality gate scripts (lint.sh, test.sh, type.sh)
- MCP server configurations
- Definition of Done and MCP matrix
- Shared rules (safety, git, module scope, secrets)

### Boundary Rules
- Claude Code agents must never modify BMAD state or create FILE-HANDOFF artifacts
- Codex agents follow AGENTS.md governance
- Both runtimes respect module scope rules

## Two Delivery Channels

The runtime reaches its consumers through two independent channels. A product uses
Channel 1 always; Channel 2 is a one-time, per-machine step (any product repo on
that machine then benefits from it without re-running anything).

| | Channel 1 — per-repo sync | Channel 2 — machine-global install |
|---|---|---|
| Script | `sync/sync-engine.sh` (wrapped by product's `scripts/sync-ai-runtime.sh`) | `global/install-global.sh` |
| Scope | One product repo's `.claude/` | The machine's `~/.claude/` (all repos) |
| Driven by | `sync/manifest.yaml` + product's `runtime.config.yaml` | `global/settings.snippet.json` + `global/hooks/`, `global/rules/`, `global/skills/`, `global/extra-lsp/` |
| Delivers | Agents, skills, rules, quality-gates, references, templates, `.mcp.json` | Discipline hooks, `extra-lsp` plugin, `context7` rule, generic skills, hook registration in `settings.json` |
| Re-run cadence | Whenever the runtime updates (picks up `managed`/`template` changes) | Once per machine, or after a runtime hook update |
| Idempotent | Yes — `seed` preserves customizations, `managed` diffs before overwriting | Yes — hook registration merge dedupes by command |

Both channels are plain bash + `jq`, no other runtime dependency, and both run
identically on Linux and on Windows via Git Bash.

## Composable Language Profiles

A product declares which stacks it uses via `languages: [...]` in its own
`runtime.config.yaml`. That list is the single source that both channels and the
discipline hooks read to decide what applies:

- **Channel 1** filters manifest entries carrying a `profiles:` field against the
  active list (see `entry_active()` / `lang_active()` in `sync/sync-engine.sh`).
- **`discovery-gate`** (a Channel 2 hook) reads `languages:` at hook-invocation time
  to build the set of guarded code extensions and to name the right discovery MCP in
  its deny message (`global/hooks/discovery-gate`).
- **Quality gates** read `gates.<language>.*` from `runtime.config.yaml` for the
  lint/test/type(/build/format) commands to run.

Two profile *models* exist:

- **BUILD** (`python`, `typescript`) — this repo ships the agents, skills, and gate
  definitions outright (`claude/agents/_base/python-pro.md`, `typescript-pro.md`,
  etc., synced via Channel 1).
- **ADOPT** (`csharp`) — this repo does **not** build C# agents/skills. A product
  installs a mature community Claude Code plugin (`wpf-dev-pack` or
  `dotnet-claude-kit`) for the agents/skills, and only merges a config fragment
  (`profiles/csharp/runtime.fragment.yaml`) so the shared discipline layer knows
  `.cs`/`.xaml` are code and which MCP owns them. No `sync/manifest.yaml` entries
  exist for this profile — see `profiles/csharp/README.md` and `adopt.md`.

Profiles compose freely — `languages: [python, csharp]` (Python-ML backend +
WPF desktop client) is as valid as `languages: [python, typescript]`.

## Token / Config Mechanism

Manifest entries marked `substitute: true` (discipline rules, references, the
`mcp-discipline` skill, the `.mcp.json` template) contain `{{TOKEN}}` placeholders
that `sync-engine.sh` fills in at sync time from the product's `runtime.config.yaml`
(auto-detecting `{{PROJECT_ROOT}}`/`{{PROJECT_NAME}}` when omitted):

`{{PROJECT_ROOT}}`, `{{PROJECT_NAME}}`, `{{CBM_PROJECT}}`, `{{CBM_BIN}}`,
`{{STATE_DIR}}`, `{{OS}}`, `{{APP_PATHS}}` (+ `{{BACKEND_PATH}}`/`{{FRONTEND_PATH}}`).

`runtime.config.yaml` has exactly two consumers, at two different times:

1. **`sync-engine.sh`** — reads it once, at sync time, and bakes static values into
   the copied files (`apply_substitution()` — pure bash string replace, no `sed`
   escaping headaches).
2. **The discipline hooks** (Channel 2) — read it live, on every relevant tool call,
   for the *current* set of active languages/extensions/discovery tool. This is why
   `discovery-gate` can react to a `languages:` edit without re-running any sync.

See `config/runtime.config.example.yaml` for the full annotated schema, and the
README's Tokens table for the source/default of each token.

## Hook Layer

`global/hooks/` — cross-stack, profile-aware, installed by Channel 2 into
`~/.claude/hooks/` and registered in `settings.json` via `global/settings.snippet.json`:

| Hook | Event | Purpose |
|---|---|---|
| `discovery-gate` | `PreToolUse:Bash` | Blocks blind recursive `grep`/`rg`/`find` on code files (profile-aware extension set); names the right discovery MCP per active language in its deny message. `permissionDecision=deny`, never `exit 2` (works around Claude Code bugs #43407/#26923). |
| `discovery-augment` | `PreToolUse:Grep\|Glob` | Silent no-op augmenter — adds codebase-memory-mcp graph context when `cbm` is available; never blocks. |
| `discovery-session-reminder` | `SessionStart` (startup/resume/clear/compact) | Reminds the agent of the code-discovery protocol per active profile. |
| `mcp-soft-discipline` | `PreToolUse:WebFetch\|WebSearch` | Soft hint (never blocks) to prefer `context7`/`exa` for library docs — regex over ~50 popular libs across JS/Python/.NET; skips if context7/exa was used recently in-session. |
| `mcp-usage-tracker` | `PostToolUse` (all tools) | Logs every tool call to a per-session JSONL (`$CLAUDE_STATE_DIR/tool-usage/`) for usage analytics. |
| `block-dangerous-git.sh` | `PreToolUse:Bash` | Blocks force-push, `git clean -f[d]`, wholesale `git checkout .`/`git restore .` — allows normal push/reset --hard/branch -D. |
| `filter-test-output` | `PostToolUse:Bash` | Summarizes verbose test/lint/build output (pytest/vitest/mypy/ruff/eslint/tsc/`dotnet build\|test\|format`) down to failure lines when output exceeds 80 lines. |

All hooks are pure bash + `jq` (no Python dependency), read config
(`$CLAUDE_PROJECT_DIR/runtime.config.yaml`) rather than hardcoding a language, and
fall back `$HOME`→`$USERPROFILE` / `$TMPDIR`→`$TEMP` for Git-Bash-on-Windows.

## Channel 1 — Per-Repo Sync Flow

```
mgt-ai-runtime (source)
    │
    ├── sync/manifest.yaml (declares entries + modes + substitute/profiles)
    │
    └── sync/sync-engine.sh (core logic: parse manifest → filter by profile →
            │                 substitute tokens → seed/managed/template copy)
            ▼
product-repo/scripts/sync-ai-runtime.sh (wrapper, generated by bootstrap)
            │
            ▼
product-repo/.claude/agents/         (seed: create once)
product-repo/.claude/skills/         (seed: create once)
product-repo/.claude/rules/          (managed: always overwrite, tokenized)
product-repo/.claude/references/     (managed: always overwrite, tokenized)
product-repo/.claude/quality-gates/  (managed: always overwrite)
product-repo/.claude/templates/      (template: create if missing)
product-repo/.mcp.json               (template: create if missing, tokenized)
```

## Channel 2 — Machine-Global Install Flow

```
mgt-ai-runtime (source)
    │
    └── global/install-global.sh
            │
            ├── copy global/hooks/*           → ~/.claude/hooks/
            ├── copy global/rules/context7.md → ~/.claude/rules/context7.md
            ├── copy global/skills/*/         → ~/.claude/skills/
            ├── copy global/extra-lsp/*       → ~/.claude/local-plugins/extra-lsp/
            ├── jq-merge settings.snippet.json → ~/.claude/settings.json (dedupe by command)
            └── [--with-cbm-mcp] register codebase-memory-mcp → ~/.claude/.mcp.json
```

## Claude-Native Closed Loop

```
User → /implement-story STORY-ID
         │
    ┌────▼──────────────────┐
    │  SKILL (coordinator)   │  Main Claude instance
    └────┬──────────────────┘
         │
    ┌────▼─────┐
    │  PLAN     │  story-planner subagent (read-only)
    └────┬─────┘  → structured task breakdown
         │
    ┌────▼─────┐
    │ IMPLEMENT │  specialist subagents (one per task)
    └────┬─────┘  → code changes + commits
         │
    ┌────▼─────┐
    │  GATE     │  bash quality gates (auto-fix, max 3)
    └────┬─────┘  → lint + typecheck + tests
         │
    ┌────▼─────┐
    │  VERIFY   │  qa-expert subagent (adversarial)
    └────┬─────┘  → PASS / FAIL with evidence
         │
    ┌────▼─────┐
    │ DECISION  │  PASS → close
    └──────────┘  FAIL → corrective loop (max 2 cycles)
```

## Layer B — AO Story-Machinery

`story-machinery/` adds a third, **opt-in** layer on top of the two delivery channels
described above: a complete closed-loop harness ported and generalized from the
mgt-openproject `/run-stories` system. Unlike Channels 1/2, which deliver static
files, Layer B delivers an *executable process* — a state machine that carries a
story from its frontmatter to a merged PR.

### From SDD's four-phase loop to six harness phases

The 2025–2026 spec-driven-development (SDD) ecosystem converged on one loop:
**specify → plan → tasks → implement**. This runtime does not reinvent that loop — it
maps onto it and extends it with the closed-loop discipline the generic loop doesn't
specify:

| SDD phase | Harness phase(s) | Notes |
|---|---|---|
| specify | (product's own — story authored in `docs/stories/STORY-XXX.md`, optionally against SRS.md/EARS ACs) | Outside the harness; standardized but optional (`srs.enabled`) |
| plan | `0-init` + `1-plan` | `story-planner` subagent decomposes the story into tasks + an AC↔task mapping (`plan.json`) |
| tasks | (embodied in `plan.json.tasks`) | Not a separate phase — folded into `1-plan`'s output |
| implement | `2-implement` | `story-executor` subagent per task, fresh context, atomic commits |
| *(harness-added)* | `2.1.5-simplify`, `2.2-a11y`, `3-gate`, `3.3-audits`, `4-verify`, `5-close` | Not in the generic SDD loop — closed-loop-specific: pre-review cleanup, accessibility pass, quality gates, conditional audits, adversarial AC re-verification, RTM/SRS/memory close-out |

### Phase-contract state machine

Every phase transition is logged as one JSON-line to a phase-log
(`{"ts","phase","status"}`, `status ∈ {start,complete,skipped,failed,blocked}`) and,
for the six **major** phases (`0-init`…`5-close`), gated by a state-JSON file
(`context.json`, `plan.json`, `diff.json`, `gate.json`, `verify.json`, `close.json`)
carrying a `_complete: true` or `_skipped: true` flag plus phase-specific required
keys (e.g. `diff.json` requires ≥1 `changed_files` and ≥1 `commits`). `phase-guard.sh`
refuses to advance past a phase whose state-JSON is missing or incomplete — this is
what makes `--from-phase`/`--only-phase` retries safe (a corrective re-run of
`gate`+`verify`+`close` can't silently skip a step that never actually finished).
Four **micro-phases** (`0.1-mem-search`, `2.1.5-simplify`, `2.2-a11y`, `3.3-audits`)
skip the state-JSON requirement — they're conditional and cheap to re-derive.

Critically, **the coordinator does not trust a worker's own claims.** A worker
session could fabricate `gate.json` with `{"pass":true}` via a bare heredoc.
`worktree-gate.sh` — run by the coordinator, never by the worker — independently
re-verifies: every commit SHA in `diff.json` actually exists
(`git rev-parse --verify`), the working tree is clean, and the gate commands from
`ao.gate_registry` actually pass when re-run. The worker's `gate.json`/`verify.json`
are recorded for telemetry only; the merge decision is made entirely from the
coordinator's own re-check.

### Worktree isolation

Each story runs in its own `git worktree` under `ao.worktree_root` (default
`.claude/worktrees/`), as either a headless `claude -p` session or an
interactive tmux-attached session. This is what makes `run-stories`' wave
orchestration possible: N stories with non-conflicting `files_affected` execute as N
concurrent worker sessions without touching each other's working tree or the trunk,
and a crashed/killed worker leaves only its own worktree dirty, never the
coordinator's.

### Config-driven gate registry (vs. the hardcoded original)

The mgt-openproject original called fixed scripts (`lint.sh`/`test.sh`/`type.sh`) —
fine for one Python+TypeScript monorepo, not portable. The ported harness replaces
that with `ao.gate_registry`: an ordered list of
`{match: <changed-path regex>, cmd: <shell command>}` rules (`{gates.X}` tokens
expanding from the product's own per-language `gates:` block). `worktree-gate.sh`
walks the list, runs the first matching rule's command against the actual changed
files, and fails the gate on a non-zero exit. A Python-only repo, a TypeScript-only
repo, and a `[python, csharp]` mixed repo all express their own gate commands in
`runtime.config.yaml` without any change to the harness scripts themselves — the same
config-over-code principle the language `profiles:` mechanism uses elsewhere in this
runtime.

### Capability gate (delivery mechanism)

Layer B is delivered through the *same* Channel-1 mechanism as language profiles, not
a separate one: `sync-engine.sh` merges the product's `capabilities:` list into the
same active-profile set it builds from `languages:`, so a manifest entry tagged
`profiles: [ao]` is filtered exactly like one tagged `profiles: [typescript]` — active
only when the product opted in (`bootstrap --with-ao` → `capabilities: [ao]` in
`runtime.config.yaml`). This is why story-machinery needed no new sync logic:
`entry_active()`/`lang_active()` in `sync/sync-engine.sh` already generalized to "any
tag in the active set," and `ao` is just another tag — currently 74 manifest entries
carry it (46 harness scripts under `scripts/ao/` + `scripts/ao/srs/`, plus the AO
agents, skills, phase-contract rule/schema, and `rtm.schema.yaml` template).

### The hybrid decision

Layer B **ports** the execution harness — worktree isolation, the phase-contract
state machine, wave orchestration + monitoring, the config-driven gate registry, and
the review→auto-fixup loop — because that machinery is hard to replace and not
something the surrounding SDD-plugin ecosystem (GitHub Spec Kit,
`sighup/claude-workflow`, `lindy-orchestrator`) provides. It deliberately does **not**
port mgt-openproject's bespoke SRS/RTM parser wholesale; instead it **standardizes
and optionalizes** that side: the spec doc stays SRS.md + rtm.yaml (already
IEEE-830-aligned), authored with EARS acceptance criteria and an `rtm.yaml` shaped to
the published `rtm-yaml-schema`, gated entirely behind `srs.enabled` so the harness
runs with zero requirements doc if a product doesn't want one. Because the harness's
plan→implement loop maps directly onto the specify→plan→tasks→implement loop the
ecosystem converged on, specs authored by Spec Kit or another SDD tool can feed this
harness without adapters.
