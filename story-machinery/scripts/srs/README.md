# story-machinery/srs — OPTIONAL SRS/RTM methodology (Layer B)

Gated by `srs.enabled` in `runtime.config.yaml` (default `false`). When disabled, every
script here no-ops (exit 0) and `/implement-story` / `/run-stories` skip every SRS/RTM
sync step — the harness runs fine with no requirements doc at all. When enabled, it
gives the story loop a durable, IEEE-830-aligned requirements spine: **SRS.md** (human,
markdown) + **rtm.yaml** (machine, generated, linkage-only).

## Why optional — "shape = parser"

These scripts were ported from mgt-openproject's `scripts/`, where they hardcode one
specific markdown-table requirement shape:

```
#### FR-<MOD>-NNN: <Title>

| Field | Value |
|-------|-------|
| **Status** | not_started |
| **Priority** | Must Have |
...
```

That shape — the `#### <ID>:` heading, the `| **Field** | value |` row grammar, the
4-value status vocabulary (`not_started`/`partial`/`implemented`/`deprecated`), and the
active-SRS/implemented-archive split — **is kept as the runtime's canonical (optional)
methodology, not rewritten**. The parsing logic in every script below is unchanged from
the mgt-openproject original; only three things were generalized so it runs on any
product:

1. **Paths** — `docs/SRS.md` / `docs/srs/implemented-archive.md` / `docs/rtm.yaml` are
   now read from `srs.srs_path` / `srs.archive_path` / `srs.rtm_path`.
2. **ID taxonomy** — the one place a prefix was hardcoded (`srs-counts.py`'s category
   regex, previously a literal `(?:FR|NFR|SEC)`) now builds its alternation from
   `srs.req_id_prefixes`. Every other regex in this cluster was already prefix-agnostic
   (`[A-Z]+-...`) and needed no change.
3. **Gating** — every script exits 0 no-op when `srs.enabled` is false (see the one
   deliberate exception, `merge-with-rtm-strategy.sh`, documented in its own header).

If a product wants a different spec methodology (GitHub Spec Kit's own format, BMAD,
hand-rolled), leave `srs.enabled: false` and this whole module gets out of the way.

## Scripts

| Script | Purpose |
|--------|---------|
| `rebuild-rtm.sh` / `rebuild-rtm.py` | Regenerate rtm.yaml from `ao.story_dir/**/*.md` (frontmatter `requirement_refs[]`) + the SRS (canonical title/priority). `--audit` diffs, `--check` is a CI gate. **Never hand-edit rtm.yaml.** |
| `apply-srs-pending.sh` | Coordinator single-writer sync from a worker's `srs-pending.json`: flips `Status`, and on `implemented`/`move_to_archive` moves the whole requirement block from the active SRS to the archive doc. Standalone-safe outside `/run-stories`. |
| `archive-implemented-srs.py` | Batch sweep: any `implemented` block left in the active SRS moves to the archive, plus resyncs the §6 "Not Started" table and §7 status counts. The idempotent counterpart to `apply-srs-pending.sh`'s per-story sync. |
| `srs-counts.py` | Computes the §7 summary tables + a machine-checkable `INVARIANT` line (Active = partial+not_started+deprecated, Archive = implemented, no duplicate IDs). `--audit` for lint, `--write` to refresh the tables in place. Imports `archive-implemented-srs.py`'s regexes rather than redefining them. |
| `rtm-srs-sync.sh` | Point lookup: given one or more requirement IDs, returns canonical SRS status + RTM linkage (stories/verified_at) as JSON. Read-only. |
| `merge-with-rtm-strategy.sh` | `git merge --no-ff` wrapper for wave merges — auto-resolves conflicts limited to rtm.yaml (`checkout --theirs` + `rebuild-rtm.sh` + commit); escalates anything else. |

## Typical flow

1. Author requirements in the SRS (see `shared/templates/srs.md`) — `#### FR-XXX:` blocks
   with a `Status` row and EARS-notated Acceptance Criteria.
2. Stories reference requirements via `requirement_refs[]` in their frontmatter.
3. `rebuild-rtm.sh` regenerates rtm.yaml from stories + SRS.
4. As a story completes, `apply-srs-pending.sh` (invoked by `/implement-story`'s close
   phase) flips `Status` and archives requirements the story delivered.
5. `archive-implemented-srs.py --dry-run` / (no flag) is the batch equivalent — catches
   anything `apply-srs-pending.sh` missed and keeps §6/§7 in sync.
6. `srs-counts.py --audit` is a lint-time invariant check (wire into `scripts/lint.sh`
   equivalent); `--write` refreshes the §7 tables after a real change.
7. `merge-with-rtm-strategy.sh` wraps the wave-merge step so two stories that both
   touched rtm.yaml don't produce a spurious conflict.

## Configuration

All paths + taxonomy come from the `srs:` block in `runtime.config.yaml` (see
`config/runtime.config.example.yaml`): `enabled`, `srs_path`, `archive_path`, `rtm_path`,
`req_id_prefixes`, `ac_notation`. Every key is env-overridable via the
`runtime-config-read.sh` convention (dots/dashes → underscores, uppercased) — e.g.
`srs.enabled` → `SRS_ENABLED`, `srs.rtm_path` → `SRS_RTM_PATH`.

The `.py` scripts read `runtime.config.yaml` directly via a small inline
`_load_srs_cfg()` (PyYAML; degrades to defaults if the file/library is missing). The
`.sh` scripts source the shared `../scripts/runtime-config-read.sh`.

## Interop

- **GitHub Spec Kit / other SDD tools** — this module is one implementation of the
  "spec" side of the harness's `specify → plan → tasks → implement` loop (see
  `story-machinery/README.md` § Hybrid design). A product already using Spec Kit's own
  spec format can leave `srs.enabled: false` and let that tool own specs; the execution
  harness (worktrees, phase-contract, waves, gates) doesn't care which spec format fed
  the story.
- **rtm-yaml-schema** — `shared/templates/rtm.schema.yaml` documents the published
  `TestAny-io/rtm-yaml-schema` shape (`info:` + `requirement:` array of
  `{id, summary, description, type, priority, srs_info: {acceptance_criteria[]}}`) so a
  hand-authored or imported rtm.yaml from another tool has a target to map against. This
  harness's native rtm.yaml (`rebuild-rtm.py`'s output) is a narrower, flatter shape
  optimized for its one job — requirement→{stories,files,tests} linkage, status kept
  exclusively in the SRS. No adapter between the two shapes exists yet; the schema file
  documents the field mapping for writing one.

## Requirements

- **PyYAML** — for the three `.py` scripts' config load + story-frontmatter parsing.
- **jq** — `apply-srs-pending.sh` reads `review.json`'s verdict.
- **git** — repo-root resolution (`git rev-parse --show-toplevel`) and
  `merge-with-rtm-strategy.sh`'s merge itself.

## Install

Synced alongside `story-machinery/scripts/` by
`bash <runtime>/bootstrap/init-product-repo.sh . --with-ao --with-srs`.

## Known coupling left as-is (intentional — not a bug)

- `srs-counts.py`'s `--write` falls back to inserting the `<!-- srs-counts:start -->` /
  `<!-- srs-counts:end -->` markers under the first heading matching `## 7` when no
  markers exist yet — that section number is not config-driven. Pre-seed the markers
  under whichever section actually tracks implementation-status counts to sidestep this
  (documented in `shared/templates/srs.md`).
- `apply-srs-pending.sh` reads worker artifacts (`srs-pending.json`, `review.json`) from
  `<state_dir>/story-<id>/` — `state_dir` now comes from `runtime.config.yaml` (was a
  hardcoded `/tmp/claude-workers`), consistent with the rest of story-machinery, but the
  broader `{{STATE_DIR}}` sync-time token substitution used elsewhere in this runtime
  hasn't been wired for this file — TODO(coordinator) when the sync manifest for
  `story-machinery/srs/` is authored (W-B10).
