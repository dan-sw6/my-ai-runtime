# C# / WPF — ADOPT profile

## Why this profile is different

Every other language profile in this runtime (Python, TypeScript) is a **BUILD**
profile — `claude/agents/_base/` ships purpose-written agents for it, and
`sync/manifest.yaml` pushes them into product repos.

C#/WPF is an **ADOPT** profile: we do not write C# agents or skills here. Two mature
community Claude Code plugins already cover WPF/.NET better than anything we'd build
from scratch in-house. This document is the setup runbook for adopting one of them,
plus the small config fragment (`runtime.fragment.yaml`) that tells this runtime's
shared discipline layer (quality gates, discovery-gate, safety/secret hooks) that
`.cs`/`.xaml` files exist and which tools own them. Nothing in `claude/agents/_base/`
or `sync/manifest.yaml` changes for this profile.

## 1. Platform prerequisites

WPF builds and runs **only on native Windows** — there is no cross-platform WPF
runtime.

> **WSL warning.** Do not run this profile under WSL. Known bug
> [anthropics/claude-code#26006](https://github.com/anthropics/claude-code/issues/26006):
> the agent installs `dotnet` inside the WSL guest and then cannot build Windows-only
> MSBuild/.NET Framework targets — the WPF designer, XAML compiler, and Windows-only
> assemblies are unreachable from there. There is no workaround short of running on
> real Windows.

Install on the target Windows machine:

1. **Claude Code, native Windows.**
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   Native Windows is first-class supported — this is not the WSL install path.

2. **Git for Windows.** Provides the Bash shell Claude Code uses to run hook commands
   (the shared discipline layer's hooks are bash scripts, same as the Python/TypeScript
   profiles). https://git-scm.com/download/win

3. **.NET SDK 10.0.300 or newer.** Required by the WPF pack's hooks (build/test/format
   gates below all shell out to `dotnet`). Verify with:
   ```powershell
   dotnet --version   # expect 10.0.300+
   ```

4. **uv** (for installing serena as an MCP server — step 3 below).
   ```powershell
   irm https://astral.sh/uv/install.ps1 | iex
   ```

## 2. Install the adopt pack

Pick one. For a WPF desktop app, adopt **wpf-dev-pack** as primary. Optionally layer
**dotnet-claude-kit**'s Roslyn MCP on top for semantic C# navigation (step 4).

### Primary: wpf-dev-pack (WPF-specific)

github: `christian289/dotnet-with-claudecode` — 81 skills, 11 agents including
`wpf-architect`, `wpf-code-reviewer`, `wpf-control-designer`, plus a bundled
`HandMirrorMcp` (.NET assembly/NuGet inspection).

```
/plugin marketplace add christian289/dotnet-with-claudecode
/plugin install wpf-dev-pack@dotnet-claude-plugins
```

Requires these plugins/MCPs, install alongside it:
- `context7` (library docs — already part of this runtime's MCP set)
- `microsoft-docs` (MCP for Microsoft/.NET docs)
- `csharp-lsp` (`razzmatazz/csharp-language-server`)
- **serena** — install as an MCP server directly (step 3), **not** through the plugin
  marketplace.

> **Unverified**: the exact marketplace plugin/entry slugs above
> (`dotnet-claude-plugins`, `microsoft-docs`, `csharp-lsp`) come from the pack's own
> docs as researched — confirm they still resolve at install time; marketplace slugs
> can drift between pack releases.

### Alternative: dotnet-claude-kit (general .NET, backend/web-API leaning)

github: `codewithmukesh/dotnet-claude-kit` — 47 skills, 10 agents, 15 slash commands,
Roslyn-powered MCP (`CWM.RoslynNavigator`) with 15 semantic tools (find_symbol,
find_references, find_callers, find_implementations, get_diagnostics,
get_type_hierarchy, dead-code detection, etc.) — MCP-first philosophy, the C#
analogue of a code-graph MCP. Leans toward Clean Architecture / Vertical Slice /
EF Core / minimal APIs rather than desktop UI, but its Roslyn MCP is stack-agnostic
C# navigation and works fine standalone or alongside wpf-dev-pack.

```
/plugin marketplace add codewithmukesh/dotnet-claude-kit
/plugin install dotnet-claude-kit
```

## 3. Install serena as an MCP server (not a plugin)

Install serena directly via `uv`, not through `/plugin install` — Claude Code's
built-in tool descriptions bias the model away from Serena's tools when Serena is
registered through the plugin path (see oraios/serena's own Claude Code setup docs).
This mirrors how this runtime already runs serena for Python/TypeScript in product
repos (`mgt-openproject`'s own `.mcp.json` registers serena as a plain MCP server for
the same reason).

```bash
uvx --from serena-agent serena start-mcp-server --context claude-code --project-from-cwd --mode editing
```

Then set the language in serena's `project.yml` for this project:

```yaml
language: csharp             # Roslyn LS — default, fast, needs .NET 10 runtime present
# language: csharp_omnisharp # OmniSharp — experimental, use for .NET Framework 4.8 WPF apps
```

> **.NET Framework 4.8 vs modern .NET.** If the WPF app targets classic .NET
> Framework 4.8 (not .NET 6/8/10), use `csharp_omnisharp` — Roslyn LS's default
> project-loading assumes modern SDK-style projects and is less reliable against
> old-style `.csproj`/`packages.config` Framework projects. `csharp_omnisharp` is
> slower to start but handles Framework 4.8 project files correctly. Either way, the
> Roslyn LS runtime is a parallel install — it does not change or upgrade the
> project's own target framework.

Standalone LSP alternatives exist if a product wants Serena's editing tools without
Serena itself: Roslyn LS (`Microsoft.CodeAnalysis.LanguageServer`), `csharp-ls`
(razzmatazz, Roslyn-based, supports .NET Framework 4.8 / Core 3), or OmniSharp
directly. Serena is the recommended path here because it's the same discovery/edit
tool this runtime already standardizes on for Python and TypeScript — one mental
model across all three languages.

## 4. Optional: CWM.RoslynNavigator as discovery MCP

If dotnet-claude-kit's Roslyn MCP is wanted in addition to (or instead of) serena for
discovery:

```bash
dotnet tool install -g CWM.RoslynNavigator
```

Set `discovery: roslyn-navigator` in `runtime.fragment.yaml` / the product's
`runtime.config.yaml` instead of `discovery: serena` if this becomes the sole
discovery backend. It is fine to have both installed — the `discovery:` key just
tells the discovery-gate which one is mandatory before Read/Edit on `.cs`/`.xaml`
files.

## 5. How this composes with the runtime's shared discipline

Nothing about the shared discipline layer's hooks changes for this profile — they
read config, they don't hardcode Python/TypeScript. Once `runtime.fragment.yaml`'s
keys are merged into the product's `runtime.config.yaml`:

- **discovery-gate** reads `extensions:` to know `.cs`/`.xaml`/`.csproj`/`.sln` count
  as "code", and reads `discovery:` to know which MCP (`serena` or
  `roslyn-navigator`) it should require before an ungated Read/Edit on those files —
  the same mechanism that requires cbm for Python/TypeScript in this runtime's other
  profiles.
- **quality gates** (`gates.csharp.build` / `.test` / `.format`) plug into the same
  gate-runner contract as `gates.python` / `gates.typescript` — `dotnet build`,
  `dotnet test`, `dotnet format --verify-no-changes`.
- **safety, secret-handling, and git-workflow rules apply as-is**, unmodified — they
  are language-agnostic (no committing secrets, no force-push, atomic commits, confirm
  before destructive ops). Nothing in `claude/rules/` needs a C#-specific variant.

In short: adopting this profile is a config-and-install exercise (steps 1-4 above +
merging `runtime.fragment.yaml`), not a code change to this runtime.
