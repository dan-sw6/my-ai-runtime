> **Effort**: см. `references/effort-by-phase.md` — для подфаз этого файла применяются индивидуальные effort overrides. Перед стартом каждой подфазы coordinator устанавливает соответствующий thinking budget.

## Phase 4: AC VERIFY

```bash
# Phase-guard перед стартом 4-verify (проверяет gate.json от Phase 3). БЛОКИРУЕТ при invalid state.
bash scripts/ao/phase-guard-or-exit.sh STORY-{ID} verify || exit 1
```

Launch verification agents **in parallel** (single message) when more than one is needed.

### 4.1 AC Verification — coordinator inline by default

**Pre-step — cross-check followups из прошлых stories** (до AC lookup, если memory-плагин настроен):
```
Skill("claude-mem:mem-search", args="followup {changed file} OR {module}")
```
Если прошлые workers оставили известный followup для файла/модуля — зафиксировать в `verify.json.review_findings` как `deferred_from: STORY-YYY` если не закрыто. Предотвращает drift "работаем в файле, но не убираем старые TODO".

**Default (token economy)**: for stories where AC evidence is mechanically checkable (e.g. testid-based UI hooks, a fixed API contract), coordinator верифицирует inline:
```bash
grep -n "data-testid=\"<selector>\"" <file>    # AC testid presence, if applicable
# or an equivalent structural check per AC — file:line or JSON evidence
```
Каждое AC получает PASS/PARTIAL/FAIL + evidence reference (file:line или JSON path). Inline дешевле, чем эскалация в agent для типовой story.

**Escalate to `qa-expert` agent ONLY if**: backend/full-stack story (ACs требуют call-chain trace), story is large, or ACs are phrased in behavior-not-testid terms.

> **AC evidence of record**: если `solo-reviewer` (2.2, после финального re-review) вернул `ac_verification:[{ac,status,note}]` со status для ВСЕХ AC + file:line evidence И gate (Phase 3) green — это **authoritative AC evidence**, coordinator переносит его в `verify.json.ac_results` inline. `qa-expert` re-verify запускать ТОЛЬКО если solo-reviewer verdict=concerns/block ИМЕННО по AC-категории (не security/quality/a11y). Иначе `qa-expert` = redundant re-pass.

**Legacy agent launch (conditional):**

```
Agent(subagent_type="qa-expert", model="sonnet", description="Verify ACs STORY-{ID}", prompt="""
Verify acceptance criteria for STORY-{ID}.
Story file: {ao.story_dir}/STORY-{ID}.md
Changed files: [list]

For each AC:
- Use this project's code-discovery MCP to find implementation evidence (PRIMARY — ranked, token-efficient)
- Use its trace/impact tool to verify call chains if AC involves data flow
- Use its snippet-read tool for deep body inspection
- Use the DB-verification MCP (if configured) to verify DB state for backend ACs
- Check that tests exist covering each criterion

MANDATORY: Use this project's code-discovery MCP for code navigation. Do NOT use recursive Grep/Glob.

Each AC MUST have explicit status: PASS | PARTIAL | FAIL with evidence.
Produce the standard verification report format.
""")
```

### 4.1.5 DB Verify (CONDITIONAL — only if this story touches a DB and a DB-verification MCP is configured)

Запускается если frontmatter story содержит `db_impact ∈ {schema, data, both}` AND this project has a DB-verification MCP configured. Иначе пропустить.

Кратко: через DB-MCP подтвердить (a) миграционная история находится на ожидаемом head, (b) новые колонки/таблицы из `db_impact_details` существуют, (c) backfill корректен (нет строк, нарушающих новые NOT NULL constraints). При FAIL любого — `verify.json: db_verify.pass=false`, overall AC verify FAIL.

### 4.2 Visual Verification (OPTIONAL — only if this product's frontend profile has a browser-verification tool configured)

If this project has no such tool configured for its frontend profile, this entire
subsection does not apply — skip straight to 4.3 with `verify.json.visual` omitted (not
a silent skip: state explicitly that no browser-verification tool is configured for this
product).

If it does (e.g. Playwright wired into a `qa-expert`/`accessibility-tester`-equivalent agent):

Before launching, ensure the dev stack this project defines is running and serving the
worktree's code — the exact health-check/startup command is project-specific
(`ao.*`/`gates.*` in `runtime.config.yaml`); this runtime doesn't prescribe one.

> **4.2.0 Backend-staleness probe (recommended before visual verify, if backend runs in a container/build-context separate from the frontend)**: a bind-mounted frontend dev server can be live while a containerized backend is on a stale image built before this story's code. Probe a new endpoint from the diff; if it 404s/405s but the route exists in the diff, rebuild the backend service before running visual/browser verification.

> **4.2.1 Env-limited PARTIAL-defer — first-class verify outcome (codified pattern)**: some environments (thin seed data, missing project-scoped role assignments, etc.) can make an authenticated, project-scoped UI flow unreproducible in the browser even though the code is correct. This is an **environment limitation, not a story regression**. A `PARTIAL` verdict from the browser-verification agent is accepted as **PASS-equivalent for close** when ALL of these hold:
> 1. Backend-staleness probe (4.2.0) ran (ruled out "stale code").
> 2. A real env-blocker is demonstrated: an auth/permission or 404 on the project-scoped surface under valid auth, OR a proven seed gap.
> 3. Static UI evidence is captured on whatever surface IS reachable (screenshot).
> 4. A behavioural test substitute exists and is green for the uncovered flow (e.g. a component/unit test exercising the same navigation + mutation-call + gate logic).
> 5. Record `verify.json.visual.status="partial-env-limited"` + `evidence` (what's covered live, what's substitute, why).
> Without all 5 conditions this is an ordinary FAIL, not a codified PARTIAL.

```
Agent(subagent_type="accessibility-tester", model="haiku", description="Visual verify STORY-{ID}", prompt="""
Visual verification for STORY-{ID}.
Affected routes: [list]
Frontend ACs: [list frontend-specific ACs]
Contract: {{contract_path}} | Fingerprint: {{fingerprint_path}}   (only if this product's frontend profile defines these — see references/design-modes.md)

1. **Visual-diff (PRIMARY evidence if a fingerprint/contract mechanism is configured for this product)**:
   run this product's configured visual-diff tool against the live route, compare to baseline.
   → PASS iff `0 deltas`. Delta table — главное evidence по визуальным AC.
2. Browser screenshots для state variants (empty, error, mobile) — сохранить в файлы, в отчёт класть ТОЛЬКО пути
3. Привязать каждый frontend AC к: (a) delta-таблице (если покрыт visual-diff) или (b) пути к screenshot файлу

Produce: delta table (if applicable) + screenshot URI list + AC→evidence mapping.
Verdict: PASS только при `0 deltas` (if applicable) и всех AC с evidence.
""")
```

> **4.2.2 visual outcome `n/a-no-standalone-route` — first-class**: if the change is a shared sub-component with no route of its own (mounted inside existing pages), AND there's a green behavioural test (render/empty/mutation-called/variants), AND there's no visual baseline for it (greenfield — nothing to diff against) → visual evidence = the behavioural test + diff-review; browser verification is **structurally inapplicable** (no URL for the component by itself). Record `verify.json.visual.status="n/a-no-standalone-route"` + a reference to the substitute test. This differs from `partial-env-limited` (which is about a seed-gated live flow): here it's an absence of a standalone surface, not an env-blocker.

> **CHECKPOINT — browser verification REQUIRED for frontend, only if the capability exists**:
> If story contour = `frontend` | `full-stack` | `ui-design` | `react` OR `ui_surface` != `none` AND this project has a browser-verification tool configured:
> - [ ] browser-verification agent ЗАПУЩЕН
> - [ ] navigate вызван для КАЖДОЙ затронутой страницы
> - [ ] Screenshots сделаны для ключевых состояний (loaded, empty, error)
> - [ ] Каждый frontend AC верифицирован со screenshot evidence
>
> **СТОП если хотя бы один пункт не выполнен, когда the tool IS configured.** Story НЕ может получить PASS без browser visual verification in that case. Нет скриншотов = FAIL, даже если код работает и тесты проходят. If the tool is simply not configured for this product, this checkpoint doesn't apply.

### 4.3 AC Decision Rules

- **All ACs PASS** → proceed to 4.4 (optional smoke check) → Phase 5 (CLOSE)
- **Any AC is PARTIAL or FAIL (1st or 2nd attempt)** → corrective cycle (coordinator assembles corrective prompt → subagent → GATE → AC)
- **AC still failing after 3rd attempt** → STOP, report to user with full evidence

### 4.4 Configured smoke/verify check (OPTIONAL, project-specific)

Unit tests + typecheck don't catch every class of bug — a non-idempotent migration
chain on a fresh DB, a reverse-proxy routing mismatch, a bootstrap/role-assignment gap,
etc. only show up when the actual stack is spun up cold and driven end-to-end.

This runtime does **not** ship a smoke-test script — it's inherently product-specific
(what "the stack" means, how to reset it, what a healthy boot looks like). If this
project defines one (e.g. a `gates.smoke` / `ao.smoke_cmd`-style command in
`runtime.config.yaml`, or a dedicated script under `scripts/`), run it here, after 4.3
PASS and before Phase 5:

```bash
# Illustrative only — substitute this project's actual smoke command, if it has one:
bash "$(rcfg ao.smoke_cmd '')" "STORY-${ID}" 2>/dev/null || echo "[4.4] no smoke command configured for this project — skipping"
```

**Decision** (if a smoke command IS configured and ran):
- pass → продолжить Phase 5.
- fail → корректирующий цикл (as Phase 4.3 FAIL).
- not configured → no blocker, continue.

> **4.4 Complete**: if a smoke command ran, record a stub `smoke.json`
> (`{"_complete":true,"status":"<script-output>","_ts":"<ISO>"}`) before `verify.json`.

> **4.3 Complete**: после верификации всех AC — записать `verify.json` через wrapper (валидирует ac_results{} non-empty + mode непустая строка):
> ```bash
> cat > /tmp/verify-{ID}.json <<JSON
> {"ac_results":{"AC1":{"status":"pass","evidence":"..."},"AC2":{"status":"pass","evidence":"..."}},"review_findings":[],"mode":"inline"}
> JSON
> bash scripts/ao/phase-complete.sh STORY-{ID} 4-verify /tmp/verify-{ID}.json
> ```
