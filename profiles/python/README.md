# Python profile — BUILD model

This profile is a **BUILD** profile (contrast with `profiles/csharp/`, which is
**ADOPT**): this runtime ships its own agents and gate defaults for Python outright,
rather than pointing at a third-party plugin. Nothing here needs adopting — enabling
the profile is a one-line config change plus a sync.

## Files in this profile

Unlike the `csharp` ADOPT profile, a BUILD profile's actual assets live in the
runtime's shared trees, not under `profiles/python/` itself — this README is a
pointer into them:

| Where | Purpose |
|---|---|
| `claude/agents/_base/python-pro.md` | Type-safe async patterns, Pydantic/SQLAlchemy models, mypy-strict compliance |
| `claude/agents/_base/backend-developer.md` | Generic backend feature work (routers/services/migrations) |
| `sync/manifest.yaml` (mode: `seed`) | Pushes the two agents above into the product's `.claude/agents/` |
| `config/runtime.config.example.yaml` `gates.python` | Default lint/test/type commands (overridable per product) |
| `global/hooks/discovery-gate` | Guards `.py`/`.pyi` as code once `python` is in `languages:` |

## When to use

Add `python` to `languages: [...]` in the product's `runtime.config.yaml` for any
repo with a Python component — a pure-Python backend, or a Python-ML component
alongside another profile (e.g. `languages: [python, csharp]` for an ML + WPF-client
repo).

## How it plugs in

1. **`languages:`** — `discovery-gate` (Channel 2 hook) reads it and adds `py`/`pyi`
   to the guarded-extension set once `python` is listed; the deny message names
   `codebase-memory-mcp` (if `cbm_project` is set) or `serena` as the required
   discovery tool.
2. **Sync (Channel 1)** — `python-pro.md` and `backend-developer.md` sync into
   `.claude/agents/` (mode `seed` — your edits after the first sync are preserved).
3. **Gates** — `gates.python.{lint,test,type}` in `runtime.config.yaml` default to
   `ruff check {paths}` / `pytest {paths}` / `mypy {paths}`; override per product,
   `{paths}` expands to the profile's target paths (`paths.backend`, if set).
4. **Discovery** — set `cbm_project` for graph-based discovery via
   `codebase-memory-mcp` (`search_graph`/`get_code_snippet`/`trace_path`/...); leave
   it empty to fall back to `serena` (`find_symbol`/`search_for_pattern`) as the sole
   discovery backend.

## Required tooling

- Python toolchain on PATH (or in the product's venv): `ruff`, `pytest`, `mypy`
- `pyright` — used as the live LSP (Claude Code's built-in LSP tool), venv-aware via
  a `pyrightconfig.json` in the product repo
- Optional: a `codebase-memory-mcp` binary (path in `cbm_bin`) for graph-based
  discovery; without it, `serena` (installed via `uv`, see the per-repo `.mcp.json`
  template) covers Python discovery/edit on its own
