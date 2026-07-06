#### B.1.5 Post-Merge Review (via a `solo-reviewer` Agent — NOT a separate launcher script)

> **Mandate: review runs ONLY through `Agent()` subagents inside the coordinator's own session.** Do not launch a separate review-worker CLI process for this — that's an unnecessary extra spawn with its own token budget, MCP init, and file-based handoff. An `Agent(...)` subagent is cheaper, synchronous, and returns findings directly into the coordinator's context so auto-fixup decisions can be made inline.
>
> **Review agent = a single `solo-reviewer` pass (Sonnet)** — security + code quality + accessibility + AC verification in one structured-JSON pass, replacing a 4-5 agent fan-out (`code-reviewer` ‖ `silent-failure-hunter` ‖ `type-design-analyzer` ‖ `accessibility-tester` ‖ `qa-expert`) at roughly 3× less system-prompt overhead. The one conditional addition is a `migration-reviewer` **if present in the product's `.claude/agents/`** and the diff touches the product's migrations directory (`ao.migrations_dir`) — a schema-migration review (downgrade reversibility, lock time, FK/NOT NULL backfills) isn't one of `solo-reviewer`'s four categories.

<!-- TODO(coordinator): `solo-reviewer` (and `migration-reviewer`, optional) are not yet ported into this runtime's `claude/agents/` — see the TODO in SKILL.md's Phase A header for the sibling `code-explorer` gap. Until `solo-reviewer` exists, substitute `Agent({subagent_type:"code-reviewer", model:"sonnet"})` (already in `claude/agents/_base/`) for the security/quality portion and accept that accessibility + AC-verification won't be covered by that single pass — call them out as a known reduction in reviewed surface area until the real `solo-reviewer` lands. -->

After merging each story, the coordinator runs **one** `solo-reviewer` Agent (+ optionally `migration-reviewer` in parallel in the same message, if migration files are present):

```
BEFORE_SHA=$(git rev-parse <merge-sha>^)   # commit before the story's own commits
AFTER_SHA=<merge-sha>
DIFF_STAT=$(git diff $BEFORE_SHA..$AFTER_SHA --stat)
git diff --unified=5 $BEFORE_SHA..$AFTER_SHA > "<state_dir>/story-${ID}-diff.txt"

# Main review — ALWAYS, regardless of SP/contour:
Agent({
  subagent_type: "solo-reviewer",
  model: "sonnet",
  description: "Solo review STORY-XXX",
  prompt: "Review diff $BEFORE_SHA..$AFTER_SHA for STORY-XXX. Story spec: <ao.story_dir>/STORY-XXX.md (AC + module boundaries). Diff stats: <DIFF_STAT>. Full diff: <state_dir>/story-${ID}-diff.txt (Read with offset/limit, not whole-file if >2000 lines). Return structured JSON per the solo-reviewer agent's schema: 4 categories (security / code-quality / accessibility / AC-verification), per-finding {category,severity,file,line,issue,suggested_fix}, overall_verdict ∈ {pass|concerns|block}."
})

# Conditional parallel addition (same message as solo-reviewer):
# if `git diff --name-only $BEFORE_SHA..$AFTER_SHA | grep -q "<ao.migrations_dir>/"` AND
#    `.claude/agents/migration-reviewer.md` exists →
#   Agent({subagent_type:"migration-reviewer", model:"sonnet", description:"Migration review STORY-XXX",
#          prompt:"Review the migration in diff $BEFORE_SHA..$AFTER_SHA: downgrade reversibility, lock
#                   time under load, FK/NOT NULL backfills, head conflicts. JSON:
#                   {findings:[...], verdict:pass|concerns|block}."})
```

The coordinator aggregates the Agent result(s) and writes `review.json` via **`scripts/ao/write-review-json.sh`** (not a heredoc — a positional/quoting bug in a heredoc write once produced an empty `findings[]`, silently degrading Phase C's report to scraping `summary.md`). The helper validates the JSON schema itself and computes `blocking_count`/`followup_count`; a malformed input exits 2 (fail loud, not silent):

```bash
echo '<findings-json-array>' | bash scripts/ao/write-review-json.sh \
  "STORY-${ID}" "<verdict>" "solo-reviewer[,migration-reviewer]" \
  '<ac_verification-json-array>'
# → <state_dir>/story-<id-lc>/review.json (path on stdout)
```

Result schema (the helper builds it — don't hand-write it):

```json
{
  "story": "STORY-xxx", "ts": "<ISO>",
  "agents": ["solo-reviewer", "migration-reviewer"],
  "overall_verdict": "pass|concerns|block",
  "blocking_count": N, "followup_count": N,
  "findings": [
    {"agent":"solo-reviewer","category":"security","severity":"high","file":"...","line":N,"issue":"...","status":"open|fixed_inline:<sha>|deferred:STORY-NNN|accepted-debt:<reason>"}
  ],
  "ac_verification": [{"ac":"AC1","status":"met|partial|missing","note":"..."}]
}
```

`findings[].severity` ∈ {critical,high,medium,low} — the helper derives `blocking_count` (critical+high) / `followup_count` (medium+low) itself.

**FORBIDDEN**:
- Launching a separate review-worker CLI process for this step (see the mandate above).
- The old 4-5 agent fan-out — `solo-reviewer` covers all of it in one pass.
- Background-process review — the coordinator can't re-Agent inline from a backgrounded process.

#### B.1.5.1 Inline fix-up findings (ALL severities — never create fixup-stories)

> **Mandate: every review finding (high/medium/low) and every pre-existing red gate failure gets fixed INLINE in the coordinator session before moving to Wave N+1.** Do not create a separate `<ao.story_dir>/STORY-<id>-fixup.md` from `/run-stories`; do not invoke an auto-fixup-from-review script from this skill.

Once the coordinator has `review.json` (from the Agent result above):

```bash
REVIEW="<state_dir>/story-${ID}/review.json"
ALL=$(jq -r '.findings | length' "$REVIEW")
HIGH=$(jq -r '[.findings[] | select(.severity=="high")] | length' "$REVIEW")
if [ "$ALL" -gt 0 ]; then
  # The coordinator applies fixes directly (Edit/Write + the product's discovery
  # MCP, if configured). Each fix is its own atomic commit on the base branch:
  #   fix(<area>): <issue> — STORY-XXX followup
  #
  # After each commit, update review.json:
  #   jq '.findings[<i>].status = "fixed_inline:<sha>"' review.json > tmp && mv tmp review.json
  #
  # Severity application order:
  # 1. high (security/correctness) — blocks Wave N+1
  # 2. medium (reusability/quality) — should be fixed before Wave N+1 if feasible
  # 3. low (nits/test gaps) — fix if simple; otherwise record as accepted-debt in review.json
  :
fi
```

**Pre-existing red gate failures** (a base gate command fails on the base-ref commit itself, before the wave's own changes) — the coordinator diagnoses root cause via the discovery layer + Read, fixes inline through the same flow. Don't proceed to Wave N+1 while the gate is red, even if the regression predates this wave.

Severity policy (for tracking, NOT for creating separate stories):
- `high` → must-fix inline before Wave N+1
- `medium` → should-fix inline (if simple) or accepted-debt with a reason
- `low` → fix if trivially small; otherwise accepted-debt
