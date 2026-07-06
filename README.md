# mgt-ai-runtime

Reusable AI workflow infrastructure for MGT projects.

## Purpose

This repository is a **discipline layer plus composable language profiles**: shared
agents, skills, quality gates, hooks, and playbooks, delivered through two channels
into product repositories. It is the **template/runtime source** — product repos are
the **source of truth** for project-specific artifacts (SRS, RTM, stories, governance
docs).

## Architecture at a glance

Two delivery channels, cross-platform (Linux and Windows via Git Bash):

```
                        mgt-ai-runtime (this repo)
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                        ▼
   Channel 1 — per-repo sync                Channel 2 — machine-global install
   sync/sync-engine.sh                      global/install-global.sh
   (reads sync/manifest.yaml +              (deploys discipline hooks, extra-lsp
    product's runtime.config.yaml)            plugin, context7 rule, generic skills;
              │                               jq-merges hooks into settings.json)
              ▼                                        ▼
   product-repo/.claude/                     ~/.claude/
   agents · skills · rules ·                 hooks/ · rules/context7.md ·
   quality-gates · references ·              skills/ · local-plugins/extra-lsp/ ·
   templates · .mcp.json                     settings.json (hooks registered)
```

A product declares which stacks it uses in its own `runtime.config.yaml`
(`languages: [...]`) — that selection drives both channels: which manifest entries
sync, which code extensions the discovery hooks guard, and which quality-gate
commands run.

```
runtime.config.yaml: languages: [python, typescript]         or: [csharp]   or: [python, csharp]
                              │                                      │
              ┌────────────────┴────────────────┐                    │
              ▼                                  ▼                    ▼
           python                           typescript              csharp
           (BUILD profile)                  (BUILD profile)         (ADOPT profile)
           pyright LSP                      tsserver LSP            community plugin
           ruff / pytest / mypy gates       tsc / vitest / eslint   (wpf-dev-pack /
           discovery: cbm | serena          discovery: cbm | serena  dotnet-claude-kit)
                                                                     dotnet build/test/format
                                                                     discovery: serena(csharp) |
                                                                     Roslyn MCP
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design (token/config
mechanism, hook layer, closed-loop delivery model).

## Structure

```
claude/                    Claude Code runtime (PRIMARY)
├── agents/_base/          Base subagent definitions (12 agents, VoltAgent-sourced)
├── skills/                Base skill definitions (closed-loop coordinator, mcp-discipline, etc.)
├── rules/                 Shared safety, git, scope, secret, MCP-usage, quality-gates rules
├── references/            MCP tool inventory/matrix, external-docs (serena, claude-mem)
└── settings/              Base settings templates

profiles/                  Composable language profiles
├── python/                BUILD — pyright, ruff/pytest/mypy gates, cbm|serena discovery
├── typescript/            BUILD — tsserver, tsc/vitest/eslint gates, cbm|serena discovery
└── csharp/                ADOPT — community plugin + serena(csharp)|Roslyn MCP + dotnet gates

global/                    Machine-global discipline layer (Channel 2)
├── install-global.sh      Installer — hooks, extra-lsp plugin, context7 rule, skills, settings.json merge
├── hooks/                 Cross-stack discipline hooks (discovery-gate, mcp-usage-tracker, etc.)
├── rules/context7.md      Global context7 rule
├── skills/                Generic global skills (codebase-memory, context7-mcp, diagnose)
├── extra-lsp/             LSP plugin (bash/yaml/json/markdown language servers)
├── mcp/                   Optional global cbm MCP entry
└── settings.snippet.json  Hook registrations merged into ~/.claude/settings.json

config/                    runtime.config.example.yaml — per-product config schema (tokens, gates, profiles)
mcp/                       Per-repo .mcp.json template (synced, tokenized)
shared/                    Shared resources
├── quality-gates/         Definition of Done, MCP matrix
├── playbooks/             Operational playbooks (closed-loop, corrective, setup)
└── templates/             Story, task, handoff, closeout templates

codex/                     Codex runtime (SECONDARY, legacy)
├── agents/                Base Codex agent profiles
├── prompts/               Base Codex role prompts
└── templates/             Governance templates (AGENTS.md, bmad)

bootstrap/                 Scripts to scaffold new product repos (init-product-repo.sh, validate-structure.sh)
sync/                      Sync manifest and engine (Channel 1)
docs/                      Architecture and onboarding guides
```

## Language Profiles

| Profile | Model | LSP | Gates | Discovery | Docs |
|---|---|---|---|---|---|
| `python` | BUILD (this repo ships the agents/gates) | pyright | ruff / pytest / mypy | cbm \| serena | [`profiles/python/README.md`](profiles/python/README.md) |
| `typescript` | BUILD | tsserver | tsc / vitest / eslint | cbm \| serena | [`profiles/typescript/README.md`](profiles/typescript/README.md) |
| `csharp` | ADOPT (a community plugin covers it, this repo only wires config) | Roslyn LS / OmniSharp (via serena) | dotnet build / test / format | serena(csharp) \| Roslyn MCP (`CWM.RoslynNavigator`) | [`profiles/csharp/README.md`](profiles/csharp/README.md), [`profiles/csharp/adopt.md`](profiles/csharp/adopt.md) |

A product enables profiles by listing them in `languages:` in its own
`runtime.config.yaml` — see `config/runtime.config.example.yaml` for the full schema.
Multiple profiles combine freely (e.g. `[python, typescript]` for a full-stack web
repo, `[python, csharp]` for a Python-ML + WPF-client repo).

## Sync Model (Channel 1 — per-repo)

Sync is **one-way**: runtime → product. Three modes, plus two optional per-entry
manifest fields:

| Mode | Behavior |
|---|---|
| `seed` | Create target only if it does not exist. Project customizations preserved. |
| `managed` | Always overwrite target. Runtime owns these files. |
| `template` | Create if missing, warn if source is newer than target. |

| Manifest field | Effect |
|---|---|
| `substitute: true` | `sync-engine.sh` replaces `{{TOKENS}}` in the copied file using values from the product's `runtime.config.yaml` (see Tokens below). Entries without this field are copied byte-for-byte. |
| `profiles: [lang, ...]` | Entry only syncs when one of the listed languages is in the product's active `languages:`. Entries without this field always sync. |

Product-specific files (SRS, RTM, AGENTS.md, stories, tasks, BMAD state) are **never synced**
(see `exclusions:` in `sync/manifest.yaml`).

### Tokens

Files marked `substitute: true` (rules, references, the mcp-discipline skill, the
`.mcp.json` template) may contain these tokens, filled from the product's
`runtime.config.yaml` at sync time:

| Token | Source | Default |
|---|---|---|
| `{{PROJECT_ROOT}}` | auto: `git rev-parse --show-toplevel` of the product repo | — |
| `{{PROJECT_NAME}}` | `project_name:` | basename of the product repo dir |
| `{{CBM_PROJECT}}` | `cbm_project:` | `""` (cbm disabled) |
| `{{CBM_BIN}}` | `cbm_bin:` (`~` expanded) | `~/.local/bin/codebase-memory-mcp` |
| `{{STATE_DIR}}` | `state_dir:` | `/tmp/claude-workers` |
| `{{OS}}` | `os:` | `linux` |
| `{{APP_PATHS}}` | `paths.backend` + `paths.frontend` (space-joined) | `""` |

## Quick Start

### 1. Bootstrap a new product repo

```bash
bash <runtime>/bootstrap/init-product-repo.sh /path/to/product-repo \
     --profiles python,typescript \
     --os linux \
     [--project-name NAME] [--cbm-project ID] [--install-global] [--no-sync]
```

Creates the `.claude/` skeleton, writes `runtime.config.yaml` (seed — left as-is if
already present), installs `scripts/sync-ai-runtime.sh`, optionally runs
`global/install-global.sh` (`--install-global`), then runs the initial sync
(skip with `--no-sync`).

### 2. Install the machine-global discipline layer (once per machine)

```bash
bash <runtime>/global/install-global.sh [--dry-run] [--with-cbm-mcp] [--force-marketplace]
```

Deploys the cross-stack hooks, the `extra-lsp` plugin, the `context7` rule, and the
generic global skills into `~/.claude/`, and merges hook registrations into
`~/.claude/settings.json` (idempotent — dedupes by command). `--with-cbm-mcp`
additionally registers a global `codebase-memory-mcp` entry (if the binary is found
at `$CBM_BIN` or `~/.local/bin/codebase-memory-mcp`). `--force-marketplace`
overwrites an existing `local-plugins` marketplace.json.

### 3. Ongoing per-repo sync

From a product repo:

```bash
bash scripts/sync-ai-runtime.sh              # Apply sync
bash scripts/sync-ai-runtime.sh --dry-run    # Preview changes only
bash scripts/sync-ai-runtime.sh --force      # Overwrite even seed files
```

Only `managed`/`template` files (and `seed` files under `--force`) are overwritten;
`seed` files preserve project customizations by default.

## Windows & Git Bash

Both channels run on Windows via **Git for Windows (Git Bash)** — the hooks and
scripts are plain bash, not WSL-specific. Set `os: windows` in `runtime.config.yaml`
(or pass `--os windows` to bootstrap): this switches path tokens to
`$USERPROFILE`/`%TEMP%` conventions and is required for the `csharp` profile.

**WPF builds only on native Windows.** Run Claude Code natively on Windows with Git
for Windows installed, never under WSL — see
[`profiles/csharp/adopt.md`](profiles/csharp/adopt.md) for the specific bug this
avoids (`anthropics/claude-code#26006`: dotnet installed inside the WSL guest can't
build Windows-only MSBuild/.NET Framework targets).

## Requirements

- `bash` (Git Bash on Windows)
- `jq` — required by `global/install-global.sh` for the `settings.json` hook merge
  and the optional cbm MCP registration (falls back to printing a manual-merge
  snippet if missing); required by the discipline hooks themselves
  (`discovery-gate`, `mcp-soft-discipline`, `mcp-usage-tracker`, `filter-test-output`)
- GNU `grep -P` — used by `discovery-gate`; ships with Git for Windows
- `uv` — for installing `serena` as an MCP server (`uvx --from serena-agent serena ...`)
- Per-stack toolchains for whichever profiles are active: Python (ruff, pytest, mypy),
  Node/TypeScript (tsc, vitest, eslint), .NET SDK 10.0.300+ (csharp profile)

## Closed-Loop Delivery

The primary delivery model is Claude-native closed loop (Variant C — skill-as-coordinator):

```
/implement-story STORY-ID
  → PLAN (story-planner, read-only)
  → IMPLEMENT (specialist subagents)
  → GATE (bash quality gates, auto-fix)
  → VERIFY (qa-expert, adversarial)
  → PASS / corrective loop
```

See `shared/playbooks/closed-loop-cycle.md` and `docs/ARCHITECTURE.md` for details.
