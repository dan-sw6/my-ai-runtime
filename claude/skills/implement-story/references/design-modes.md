## Frontend design workflow — not part of the core loop

This runtime does not ship a design-contract/mock-anchoring mechanism (that was a
product-specific methodology in the system this skill was ported from). Design and
visual verification are an **optional capability of a product's frontend profile**, not
a core-loop requirement — if this project's `typescript`/frontend profile defines one
(a contract format, a fingerprint/visual-diff tool, a mock-anchoring convention), wire
it in here and in `references/phase-2-implement.md` / `references/phase-4-verify.md`;
otherwise Phase 1.4 degrades to a lightweight review against `.claude/agents/ui-designer.md`
(if present) and skips the rest of this file's concerns entirely.
