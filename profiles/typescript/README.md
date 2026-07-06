# TypeScript profile — BUILD model

This profile is a **BUILD** profile (contrast with `profiles/csharp/`, which is
**ADOPT**): this runtime ships its own agents and gate defaults for TypeScript
outright, rather than pointing at a third-party plugin. Nothing here needs adopting
— enabling the profile is a one-line config change plus a sync.

## Files in this profile

Unlike the `csharp` ADOPT profile, a BUILD profile's actual assets live in the
runtime's shared trees, not under `profiles/typescript/` itself — this README is a
pointer into them:

| Where | Purpose |
|---|---|
| `claude/agents/_base/typescript-pro.md` | Type system issues, strict-mode compliance, shared FE/BE types, complex generics |
| `claude/agents/_base/react-specialist.md` | React optimization — performance, state management, hooks |
| `claude/agents/_base/frontend-developer.md` | Generic frontend feature work (components/pages/forms/routing) |
| `claude/agents/_base/ui-designer.md` | Design system work — tokens, component specs, a11y annotations |
| `sync/manifest.yaml` (mode: `seed`) | Pushes the four agents above into the product's `.claude/agents/` |
| `config/runtime.config.example.yaml` `gates.typescript` | Default lint/test/type commands (overridable per product) |
| `global/hooks/discovery-gate` | Guards `.ts`/`.tsx`/`.js`/`.jsx`/`.mts`/`.cts`/`.mjs`/`.cjs` as code once `typescript` is in `languages:` |

## When to use

Add `typescript` to `languages: [...]` in the product's `runtime.config.yaml` for
any repo with a TypeScript/JavaScript frontend or Node service — commonly paired
with `python` for a full-stack web repo (`languages: [python, typescript]`).

## How it plugs in

1. **`languages:`** — `discovery-gate` (Channel 2 hook) reads it and adds the
   TS/JS extensions to the guarded-extension set once `typescript` is listed; the
   deny message names `codebase-memory-mcp` (if `cbm_project` is set) or `serena`
   as the required discovery tool.
2. **Sync (Channel 1)** — `typescript-pro.md`, `react-specialist.md`,
   `frontend-developer.md`, and `ui-designer.md` sync into `.claude/agents/` (mode
   `seed` — your edits after the first sync are preserved).
3. **Gates** — `gates.typescript.{lint,test,type}` in `runtime.config.yaml` default
   to `eslint {paths}` / `vitest run` / `tsc --noEmit`; override per product,
   `{paths}` expands to the profile's target paths (`paths.frontend`, if set).
4. **Discovery** — set `cbm_project` for graph-based discovery via
   `codebase-memory-mcp` (`search_graph`/`get_code_snippet`/`trace_path`/...); leave
   it empty to fall back to `serena` (`find_symbol`/`search_for_pattern`) as the sole
   discovery backend.

## Required tooling

- Node toolchain on PATH: `tsc`, `vitest`, `eslint` (or the product's own
  `npm run {lint,test,typecheck}` scripts wired into `gates.typescript`)
- `tsserver` — used as the live LSP (Claude Code's built-in LSP tool), picks up the
  product's `tsconfig.json` automatically
- Optional: a `codebase-memory-mcp` binary (path in `cbm_bin`) for graph-based
  discovery; without it, `serena` (installed via `uv`, see the per-repo `.mcp.json`
  template) covers TypeScript discovery/edit on its own — note the tsserver caveat
  in `.claude/references/external-docs/serena-setup.md` (`find_referencing_symbols`
  can under-report in a monorepo without a root `tsconfig.json`; cross-check with
  cbm when in doubt)
