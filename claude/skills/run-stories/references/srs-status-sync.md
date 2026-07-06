#### B.1.6 SRS/RTM status sync (post-merge) — entire section applies ONLY if `srs.enabled`

> **If `srs.enabled: false` — skip this whole phase.** The harness runs fine with no requirements doc; `/<ao.story_skill_slug>` workers never write `srs-pending.json` when the SRS module is off, so there is nothing for the coordinator to reconcile. Go straight from B.1.5 to B.1.7.

This section documents the SRS/RTM sync step from this runtime's `story-machinery/srs/` (synced into the product repo as `scripts/srs/` — sibling of `scripts/ao/`, matching how `worktree-gate.sh` itself resolves `$SCRIPT_DIR/../srs/...`; see that directory's own `README.md` for the full script inventory and the "shape = parser" rationale for why the markdown-table requirement shape is kept as-is rather than rewritten).

<!-- TODO(coordinator): the sync-manifest entries that actually copy `story-machinery/srs/*` into a product repo's `scripts/srs/` haven't been authored yet (`story-machinery/srs/README.md`'s own "Known coupling left as-is" section flags this as W-B10 work). The `scripts/srs/...` paths below are the intended target per the scripts' own relative references, not yet a wired reality — verify against the sync manifest once W-B10 lands. -->

## Coordinator is the single writer

The coordinator — **not** the `/<ao.story_skill_slug>` worker — is the only writer of `srs.srs_path` and `srs.archive_path`. Workers never edit the SRS; they write a proposal to `${CLAUDE_WORKER_DIR}/srs-pending.json` at close (see the product's `implement-story` skill / `story-machinery/srs` reference for the exact worker-side contract). The coordinator applies that pending proposal, gated on the review verdict, after **every** merged story — there's no "worktree-gate auto-resolved it" escape hatch; since the worker never touches the SRS, there's no conflict to resolve by construction.

**Worker SRS edit = bug.** If a merge commit touches `srs.srs_path` or `srs.archive_path`, the worker violated the single-writer contract. Detect via:
```bash
source scripts/ao/runtime-config-read.sh
git diff <merge>^ <merge> --name-only | grep -E "$(rcfg srs.srs_path):|$(dirname "$(rcfg srs.archive_path)")/"
```
If it fires, don't ignore it — revert the worker's SRS edits to the pre-reconcile state before applying the pending proposal.

## Per-merged-story algorithm (background — the real tool below supersedes hand-rolling this)

```bash
for STORY_ID in {merged_stories}; do
  SID_LC=$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')
  PENDING="<state_dir>/story-${SID_LC}/srs-pending.json"
  REVIEW="<state_dir>/story-${SID_LC}/review.json"

  # 1. Pending is mandatory — its absence means the worker didn't close correctly.
  if [[ ! -s "$PENDING" ]]; then
    echo "[srs-reconcile] ${STORY_ID}: srs-pending.json missing — story wasn't closed correctly"
    continue
  fi

  # 2. Cross-check the review verdict — a block verdict does NOT flip Status to implemented.
  VERDICT=$(jq -r .overall_verdict "$REVIEW" 2>/dev/null || echo "pass")
  if [[ "$VERDICT" == "block" ]]; then
    echo "[srs-reconcile] ${STORY_ID}: review verdict=block — Status not flipped; stays partial/not_started"
    continue
  fi

  # 3. Per pending entry: flip Status, and on implemented/move_to_archive, relocate
  #    the whole requirement block from the active SRS to the archive doc, adding
  #    Verified-At + Story rows and appending any notes_delta.
done
```

## Automated apply — `scripts/srs/apply-srs-pending.sh` (the real tool — use this, not a hand-rolled version of the algorithm above)

```bash
bash scripts/srs/apply-srs-pending.sh STORY-ID            # dry-run
bash scripts/srs/apply-srs-pending.sh STORY-ID --apply    # write + rebuild RTM
```

Per `srs-pending.json` entry, gated on `review.json` verdict != `block`: flips `Status` in the active SRS detail block; on `implemented`/`move_to_archive` injects `Verified At` + `Story` rows and moves the whole block to `srs.archive_path`; appends `notes_delta`; deletes the stale summary-table row; updates the "Delivered requirements" pointer section; rebuilds the RTM. Idempotent (an already-archived requirement is a no-op) and standalone-safe outside `/run-stories` too (a solo `/<ao.story_skill_slug>` run leaves `srs-pending.json` for the user to apply by hand, or for a later `/run-stories <ID>` invocation to pick up).

## Auto-archive policy

Any Status flip to `implemented`, or any pre-existing `implemented` block still sitting in the active SRS, gets moved to `srs.archive_path`. The active SRS should contain **only** `partial`/`not_started`/`deprecated` entries — this is what keeps Phase A's story-collection glob and any requirement discovery from being shadowed by closed-out requirements. `archive-implemented-srs.py` is the idempotent batch sweep for this (run with no flags, or `--dry-run` to preview) — it also resyncs the "Not Started" summary table and the §-level status-count tables.

```bash
python3 scripts/srs/archive-implemented-srs.py --dry-run   # preview
python3 scripts/srs/archive-implemented-srs.py             # apply
python3 scripts/srs/srs-counts.py --audit                  # lint-time invariant check
python3 scripts/srs/srs-counts.py --write                  # refresh the §-level count tables in place
```

## Final wave-level commit + push (once, after ALL stories in the wave)

```bash
source scripts/ao/runtime-config-read.sh
bash scripts/srs/rebuild-rtm.sh
git add "$(rcfg srs.srs_path)" "$(rcfg srs.archive_path)" "$(rcfg srs.rtm_path)"
# [skip ci]: generated bookkeeping — no need to run CI on it (CI already gates the code-PR itself).
GIT_ALLOW_WORKER_COMMIT=1 git commit -m "docs(srs): wave-${WAVE_ID} status sync — ${STORY_IDS_LIST} [skip ci]"
# Push is mandatory: the first story of the next wave does a `git merge --ff-only
# origin/<ao.base_ref>` (SKILL.md B.1.4 Step 3) — this bookkeeping commit must be
# on origin or that ff-only merge diverges.
GIT_ALLOW_WORKER_COMMIT=1 git push origin "$(rcfg ao.base_ref main)"
```

**Anti-patterns**:
- Rebuilding the RTM before applying the SRS Status flips — the order is SRS first, then rebuild.
- Applying a pending proposal without checking `review.json`'s verdict — a `block` verdict hides real AC gaps that a Status flip would paper over.
- Standalone `/<ao.story_skill_slug>` runs (outside `/run-stories`) leave `srs-pending.json` unapplied by design — that's a hint for the user to apply by hand or to run `/run-stories <ID>`, which will reconcile it even for a single-story wave.

## `merge-with-rtm-strategy.sh` — status

`scripts/srs/merge-with-rtm-strategy.sh` is a `git merge --no-ff` wrapper that auto-resolves conflicts limited to the RTM file (`checkout --theirs` + rebuild + commit; anything else escalates). Per its own header, `pr-merge-story.sh` (SKILL.md B.1.4) **replaces it on the active path** — code lands via a GitHub PR + squash-merge, not a local `git merge`, so the RTM-conflict class this script targets mostly doesn't arise there anymore. It's kept for a non-PR / local-merge fallback if a product doesn't use the PR flow.
