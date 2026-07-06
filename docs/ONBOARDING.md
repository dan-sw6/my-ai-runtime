# Onboarding a New Product Repo

Two walkthroughs below cover the common cases: **(A)** a Linux Python/TypeScript
repo, and **(B)** a Windows C#/WPF desktop app that also has a Python-ML component.
Both use the same two scripts (`bootstrap/init-product-repo.sh`,
`global/install-global.sh`) — only the flags differ.

## Prerequisites (both cases)

- Git repository initialized
- CLAUDE.md exists (or will be created)
- Product-specific governance docs in place (SRS, RTM, etc.)
- `bash` + `jq` on PATH (Git Bash on Windows)

---

## Case A — Linux, Python + TypeScript repo

### 1. Run bootstrap

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh . \
     --profiles python,typescript \
     --os linux \
     --cbm-project my-product
```

This creates:
- `.claude/{agents,skills,quality-gates,rules,templates,references}/` skeleton
- `runtime.config.yaml` (seed — left as-is if it already exists) with
  `languages: [python, typescript]`, `os: linux`, `cbm_project: "my-product"`
- `scripts/sync-ai-runtime.sh` wrapper (resolves the runtime path via
  `$AI_RUNTIME_PATH`, defaulting to `../mgt-ai-runtime` next to the product repo)
- Runs the initial sync (add `--no-sync` to skip and review first)

### 2. Install the machine-global discipline layer (once per machine, if not already done)

```bash
bash ../mgt-ai-runtime/global/install-global.sh --with-cbm-mcp
```

`--with-cbm-mcp` registers `codebase-memory-mcp` globally (only if the binary is
already installed at `~/.local/bin/codebase-memory-mcp` or `$CBM_BIN`) — needed for
the `cbm` discovery backend both profiles default to. Skip the flag if you'd rather
register cbm per-repo via the synced `.mcp.json` instead.

Equivalently, `--install-global` on the bootstrap command in step 1 does this inline.

### 3. Review `runtime.config.yaml`

```yaml
project_name: my-product
os: linux
languages: [python, typescript]
cbm_project: "my-product"
cbm_bin: ~/.local/bin/codebase-memory-mcp
state_dir: /tmp/claude-workers
paths:
  backend: platform/apps/backend
  frontend: platform/apps/frontend
gates:
  python:
    lint: "ruff check {paths}"
    test: "pytest {paths}"
    type: "mypy {paths}"
  typescript:
    lint: "eslint {paths}"
    test: "vitest run"
    type: "tsc --noEmit"
```

Fill in `paths.backend`/`paths.frontend` if your gate commands need `{{APP_PATHS}}`
(see `config/runtime.config.example.yaml` for the full schema). If `cbm_project` is
left empty, `discovery-gate` relaxes for languages with no other discovery backend
configured — customize `gates.*` to match your repo's actual lint/test/type commands.

### 4. Customize agents & skills

Edit each `.claude/agents/*.md` and `.claude/skills/*.md` file synced in step 1:
update `read_first` paths, `avoid` rules, and story/SRS/RTM/quality-gate paths to
match your project structure. Add a section to `CLAUDE.md` documenting your agents
and skills (see `mgt-openproject/CLAUDE.md` for reference).

### 5. Verify and sync going forward

```bash
bash scripts/sync-ai-runtime.sh --dry-run   # preview
bash scripts/sync-ai-runtime.sh             # apply
```

Only `managed`/`template` files are overwritten; your customizations to `seed`
files are preserved. Run this periodically to pick up runtime improvements.

---

## Case B — Windows, C#/WPF + Python-ML repo

This case mixes a **BUILD** profile (`python`, for an ML/data component) with the
**ADOPT** `csharp` profile (for the WPF client) — read
[`profiles/csharp/README.md`](../profiles/csharp/README.md) and
[`adopt.md`](../profiles/csharp/adopt.md) first; they explain the ADOPT model in
full and this section only summarizes the parts specific to wiring it up.

> **Native Windows only, never WSL.** WPF does not build under WSL — see the
> `adopt.md` WSL warning (`anthropics/claude-code#26006`). Run Claude Code on native
> Windows with Git for Windows installed; that's what supplies the Bash shell the
> runtime's hooks and scripts need.

### 1. Platform prerequisites (target Windows machine)

Follow `profiles/csharp/adopt.md` §1 in full:
1. Claude Code, native Windows install (`irm https://claude.ai/install.ps1 | iex`)
2. Git for Windows (Bash shell for hooks)
3. .NET SDK 10.0.300+ (`dotnet --version`)
4. `uv` (for installing `serena` as an MCP server)

### 2. Run bootstrap

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh . \
     --profiles python,csharp \
     --os windows \
     --project-name my-wpf-app
```

`--os windows` makes the generated `runtime.config.yaml` use `%TEMP%\claude-workers`
and `%USERPROFILE%\.local\bin\codebase-memory-mcp` defaults instead of the Linux
`/tmp`/`~` paths.

### 3. Merge the csharp config fragment

Copy the keys from
[`profiles/csharp/runtime.fragment.yaml`](../profiles/csharp/runtime.fragment.yaml)
into the `runtime.config.yaml` bootstrap just wrote — at minimum `extensions:`,
`discovery:`, `lsp:`, and `gates.csharp`:

```yaml
project_name: my-wpf-app
os: windows
languages: [python, csharp]
cbm_project: ""              # cbm has no C# support — leave empty or set for the Python side only
cbm_bin: '%USERPROFILE%\.local\bin\codebase-memory-mcp'
state_dir: '%TEMP%\claude-workers'
extensions: [.cs, .xaml, .axaml, .csproj, .sln, .props, .targets]
discovery: serena
lsp: csharp                  # csharp_omnisharp instead, if targeting .NET Framework 4.8
gates:
  python:
    lint: "ruff check {paths}"
    test: "pytest {paths}"
    type: "mypy {paths}"
  csharp:
    build: "dotnet build"
    test: "dotnet test"
    format: "dotnet format --verify-no-changes"
```

`discovery-gate` reads `extensions:`/`discovery:` at hook time — no changes to the
shared hooks themselves are needed.

### 4. Adopt the WPF community plugin

```
/plugin marketplace add christian289/dotnet-with-claudecode
/plugin install wpf-dev-pack@dotnet-claude-plugins
```

This installs the agents/skills for WPF (`wpf-architect`, `wpf-code-reviewer`,
`wpf-control-designer`, etc.) — this runtime does **not** ship or sync any C# agents
(no `sync/manifest.yaml` entries exist for the `csharp` profile). Also install
`context7`, `microsoft-docs`, and `csharp-lsp` alongside it per `adopt.md` §2.

### 5. Install serena as an MCP server (not a plugin)

```bash
uvx --from serena-agent serena start-mcp-server --context claude-code --project-from-cwd --mode editing
```

Set `language: csharp` (or `csharp_omnisharp` for .NET Framework 4.8 WPF apps) in
serena's `project.yml` — see `adopt.md` §3 for the full rationale (installing serena
as a plugin biases the model away from its tools; install it as a plain MCP server
instead, same as this runtime does for Python/TypeScript).

### 6. Install the machine-global discipline layer

```bash
bash ../mgt-ai-runtime/global/install-global.sh --with-cbm-mcp
```

Same command as Case A — the hooks are cross-stack. `discovery-gate` will now guard
`.cs`/`.xaml` for this repo (via the `extensions:`/`discovery:` keys from step 3) in
addition to `.py` (via `cbm`/`languages:`).

### 7. Verify and sync going forward

```bash
bash scripts/sync-ai-runtime.sh --dry-run
bash scripts/sync-ai-runtime.sh
```

Sync only touches the `python` BUILD profile's agents/skills/gates — the `csharp`
ADOPT profile has nothing in `sync/manifest.yaml` to sync; its agents/skills come
from the plugin installed in step 4, and its config lives in `runtime.config.yaml`
(step 3), not in `.claude/`.

---

## Run /run-stories in your project

Adds the opt-in AO story-machinery (Layer B) closed-loop harness — a full
worktree-isolated `/implement-story` / `/run-stories` cycle — on top of a repo
already onboarded via Case A or Case B above. **Claude Code CLI only** (no
gemini/codex worker option for this layer) and needs a **real git repository**
(the harness runs each story in its own `git worktree`).

### 1. Prerequisites

Everything from Case A/B, plus:
- `jq`, `python3` + PyYAML (config + story-frontmatter parsing)
- `tmux` (the default worker view — interactive mode)
- Per-stack gate tooling for whatever `gates.*` commands the product configures
  (`pytest`/`vitest`/`dotnet`/etc.)

### 2. Run bootstrap with `--with-ao`

```bash
bash ../mgt-ai-runtime/bootstrap/init-product-repo.sh . --with-ao [--with-srs]
```

`--with-ao` sets `capabilities: [ao]` in `runtime.config.yaml`; `--with-srs` also
sets `srs.enabled: true` for the optional SRS.md/rtm.yaml requirements module (seed
templates: `.claude/templates/srs.md`, `.claude/templates/rtm.schema.yaml`). This
syncs, in addition to whatever Case A/B already synced:
- `scripts/ao/*.sh`/`*.py` (harness) + `scripts/ao/srs/*` (if `--with-srs`)
- `.claude/agents/{story-executor,story-planner,story-auditor,solo-reviewer}.md`
- `.claude/skills/{implement-story,run-stories}/`
- `.claude/rules/phase-contract.md` + `.claude/references/phase-contract-schemas.md`

### 3. Review `ao:` / `gate_registry` in `runtime.config.yaml`

Bootstrap only writes `capabilities: [ao]` (+ `srs.enabled` if requested) — it does
**not** write the full `ao:` block. Copy the relevant keys from
`config/runtime.config.example.yaml`, at minimum `ao.story_dir`,
`ao.worker_model`/`worker_effort`, `ao.base_ref`, `ao.gate_registry`:

```yaml
ao:
  story_dir: docs/stories
  worker_model: opus
  worker_effort: xhigh
  base_ref: main
  gate_registry:
    - { match: '.*', cmd: '{gates.default}' }
```

Every `ao.*` key you omit falls back to the default baked into each
`scripts/ao/*.sh` call site (see `config/runtime.config.example.yaml` for the
documented default of each) — a bare `capabilities: [ao]` with no `ao:` block still
runs, just against generic defaults.

### 4. Sync

```bash
bash scripts/sync-ai-runtime.sh --dry-run
bash scripts/sync-ai-runtime.sh
```

### 5. Author a story

Create `docs/stories/STORY-101.md`. Frontmatter keys the harness itself reads (via
`resolve-story-runtime.sh`): `story_points` (diagnostics/routing only — model/effort
come from `ao.worker_model`/`worker_effort`, not story size), `contour` (module/epic
tag — surfaces in wave-plan tables and `route_reason` diagnostics), `files_affected`
(scope lock — the worker may only touch these), `db_impact` (`none` | `migration` —
`migration` forces the tmux route plus a migrations preflight smoke), `rbac_changes`
(`true` forces the tmux route regardless of `story_points`):

```yaml
---
id: STORY-101
title: "Add CSV export to the reports page"
status: draft
priority: P2
story_points: 3
contour: frontend
depends_on: []
blocked_by: []
files_affected:
  - src/reports/ExportButton.tsx
  - src/reports/useExport.ts
db_impact: none
rbac_changes: false
requirement_refs: [FR-REPORT-014]   # only if srs.enabled
---
```

If `srs.enabled: true`, write acceptance criteria in EARS notation (WHEN/IF/THEN) and
link them to `docs/SRS.md` entries via `requirement_refs`.

### 6. Run the harness

```bash
/implement-story STORY-101              # single story, full phase-0..5 cycle
/run-stories STORY-101 STORY-102         # batch — dependency/conflict waves
```

---

## Validate structure (either case)

```bash
bash ../mgt-ai-runtime/bootstrap/validate-structure.sh .
```

Checks for `CLAUDE.md`, `.claude/agents/`, `.claude/skills/`,
`scripts/sync-ai-runtime.sh`, and counts synced agents/skills.
