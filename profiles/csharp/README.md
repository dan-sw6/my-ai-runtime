# C# / WPF profile — ADOPT model

This profile is different from the other language profiles in this repo. Python and
TypeScript are **BUILD** profiles: the runtime ships its own agents, skills, and gates
for them (`claude/agents/_base/python-pro.md`, `typescript-pro.md`, etc.).

C#/WPF is an **ADOPT** profile: we do not build or maintain C# skills/agents here.
Instead, a product installs a mature community Claude Code plugin (`wpf-dev-pack` or
`dotnet-claude-kit`) that already covers WPF/.NET end to end — architecture agents,
code review, control design, Roslyn-powered code intelligence. The runtime's job is
just to make the shared discipline layer (quality gates, discovery-gate, safety/secret
hooks) aware that `.cs`/`.xaml` files exist and which tools own them.

## Files in this profile

| File | Purpose |
|---|---|
| `adopt.md` | Step-by-step setup: prerequisites, pack install, serena(csharp) MCP, optional Roslyn MCP, how it plugs into the shared discipline layer. |
| `runtime.fragment.yaml` | YAML fragment to merge into a product's `runtime.config.yaml` — adds `csharp` to `languages:`, sets `os: windows`, declares `.cs`/`.xaml` extensions, and points `discovery:`/`gates.csharp:` at the adopted tooling. |

## When to use

Use this profile when a product repo (or a new product repo) targets a C#/WPF desktop
app. It assumes native Windows — WPF does not build under WSL (see the WSL warning in
`adopt.md`).

## How it plugs in

1. Read `adopt.md` and follow the install steps once, on the target Windows machine.
2. Copy the relevant keys from `runtime.fragment.yaml` into the product's
   `runtime.config.yaml` (see `config/runtime.config.example.yaml` for the full
   per-product config shape — it already has commented-out `csharp` entries mirroring
   this fragment).
3. The discovery-gate and quality gates read `languages:`, `discovery:`, and
   `gates.csharp:` from that config at runtime — no changes to the shared hooks
   themselves are needed.

No entries are added to `sync/manifest.yaml` for this profile — there is nothing here
for `sync-engine.sh` to push into a product repo's `.claude/` tree. `adopt.md` and
`runtime.fragment.yaml` are references a human (or the product's setup story) copies
from manually.
