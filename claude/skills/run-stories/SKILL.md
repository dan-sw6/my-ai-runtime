---
name: run-stories
description: "Orchestrate story delivery — analyze dependencies and file conflicts, build parallel execution waves, launch each story through the `ao.story_skill_slug` worker (default `implement-story`) in an isolated git worktree + tmux session, gate/merge/review each result, then render a deterministic wave report. Claude-only, config-driven via runtime.config.yaml `ao:`/`srs:`. Flags: [STORY-ID...] [--max-parallel N] [--wave-only] [--resume]."
argument-hint: "[STORY-ID ...] [--max-parallel N] [--wave-only] [--resume]"
---

## Role

You are the **story orchestrator**. You analyze story dependencies and file conflicts, build execution waves, and launch stories through the `<ao.story_skill_slug>` skill (default `implement-story`) running as full Claude Code worker sessions in tmux. You NEVER implement code yourself.

This is the coordinator half of **story-machinery** (Layer B): the leaf scripts it calls live at `scripts/ao/` in the product repo (synced from this runtime's `story-machinery/scripts/` + `story-machinery/srs/`) and read the product's `runtime.config.yaml` `ao:`/`srs:` blocks via `runtime-config-read.sh` (`rcfg <key> <default>`, env-override `AO_FOO`/`SRS_FOO`). Nothing here is hardcoded to one stack — gate commands (`ao.gate_registry`), story paths (`ao.story_dir`), worker model (`ao.worker_model`/`worker_effort`), wave size (`ao.max_parallel`), and the whole SRS/RTM sync step are config-driven; see `config/runtime.config.example.yaml` for the full schema.

> **Changelog / decision log**: `references/changelog-followups.md` — which Claude Code CLI features were adopted into this skill vs deliberately skipped, and why. Update it when a new CLI release ships a feature relevant to wave orchestration.

## Arguments

| Arg | Default | Description |
|---|---|---|
| `STORY-ID ...` | all draft | Story IDs to process (files under `ao.story_dir`, default `docs/stories`). If omitted — all stories with `status: draft`. |
| `--max-parallel N` | `ao.max_parallel` (default 3) | Max concurrent stories per wave (parallel tmux workers). **Hard cap 5** regardless of config — values above 5 clamp to 5; never launch more than 5 concurrent workers. |
| `--wave-only` | false | Only show the wave plan, don't execute. |
| `--resume` | false | Resume incomplete stories from file-based state under `<state_dir>/story-*/`. |

**Claude-only, single launcher.** Every story runs `/<ao.story_skill_slug>` (default `/implement-story`) inside a Claude Code worker session, launched via `scripts/ao/launch-story-worker.sh` into a tmux window. There is no engine choice (no gemini/codex) and no launcher choice (no coordinator-native background-agent mode) — one worker CLI, one launch mechanism. If a future need for those re-emerges, treat it as a new design, not a flag on this skill.

---

## Phase 0: CONTEXT LOADING (BLOCKING CHECKPOINT)

> **CHECKPOINT 0**: переход к Phase A запрещён, пока не выполнены:
> 1. Обзор story frontmatter в `ao.story_dir`
> 2. (только если `srs.enabled`) `srs.rtm_path` + `srs.srs_path` — canonical linkage + Status
> 3. (опц.) wave/sprint-plan файл, если продукт его ведёт
> 4. (только если `cbm_project` настроен) `cbm:get_architecture()` — packages/services overview
> 5. `mem-search` — prior wave results, конфликты, partial work
>
> Пропуск любого доступного шага делает wave plan основанным на неполных данных.

### 0.1 Read project state (MANDATORY)

```
Read("<ao.story_dir>/STORY-*.md")   # frontmatter: id/title/status/contour/priority/story_points/depends_on/blocked_by/files_affected
```

**Если `srs.enabled`** (проверить через `rcfg_bool srs.enabled` или чтение `runtime.config.yaml`):
```
Read("<srs.srs_path>")              # canonical Status (partial/not_started — активный scope)
Read("<srs.rtm_path>")              # auto-generated linkage requirements ↔ stories ↔ files (never hand-edit — scripts/srs/rebuild-rtm.sh regenerates)
```
Используется чтобы: отсечь stories, чей requirement уже `implemented`; проверить `blocked_by` на уровне requirement, не только story; найти tests, которые уже покрывают scope.

**Если `srs.enabled: false`** — пропустить оба Read. Wave plan строится только из story-frontmatter (`depends_on`/`blocked_by`/`files_affected`+`status`) — это полностью рабочий режим, просто без отдельного канонического источника Status поверх самого story-файла.

**Если `cbm_project` непуст** (codebase-memory-mcp настроен):
```
cbm:get_architecture(project="<cbm_project>", aspects=["packages","services"])
cbm:detect_changes(project="<cbm_project>", since="HEAD~10")
```
`get_architecture` — плотность графа по модулям одним запросом; story, затрагивающая модуль с большим числом узлов — кандидат на split/сериализацию. `detect_changes` ловит конфликт с недавно тронутыми файлами, которые ещё не попали в `files_affected`.

**Если `cbm_project` пуст** — discovery в этой фазе деградирует до discovery-tool активного профиля (serena / per-language LSP, см. `.claude/rules/mcp-usage.md`); Phase A.3 cross-check (ниже) ограничивается `files_affected`-overlap.

### 0.2 Load claude-mem context

```
Skill("claude-mem:mem-search", args="run-stories orchestration waves {story_ids}")
```

Интегрировать найденный контекст: предыдущие wave-планы, конфликты, результаты, решения.

### 0.3 cbm reindex check (только если `cbm_project` настроен)

```bash
FLAG="$HOME/.cache/cbm-needs-reindex-$(rcfg project_name "$(basename "$(git rev-parse --show-toplevel)")")"
if [[ -f "$FLAG" ]]; then
  echo "[cbm] reindex flag detected — triggering cbm:index_repository(mode=fast)"
  # coordinator (эта сессия) вызывает MCP: cbm:index_repository(project="<cbm_project>", mode="fast")
  [[ -x scripts/ao/cbm-freshness.sh ]] && bash scripts/ao/cbm-freshness.sh mark "<cbm_project>"
  rm -f "$FLAG"
fi
```

Применимо только если продукт-репо завёл post-commit hook на trunk, создающий этот flag-файл при каждом merge волны (namespaced по `project_name`, чтобы не коллизировать между продуктами на одной машине). Без такого hook'а — шаг no-op, файла никогда не будет. Зачем нужен вообще: свежий граф перед новой волной — иначе Phase A.3 cbm cross-check и `preflight-gate.sh` check `cbm-index-fresh` работают на устаревших данных.

### 0.4 Env preconditions (документация, не runtime-check)

Координатор-сессия для `/run-stories` обычно работает часами на одну волну. Рекомендуемые Claude Code project-settings (если harness это поддерживает):
- `env.ENABLE_PROMPT_CACHING_1H=1` — кэш растягивается с 5 мин до 1 часа; multi-hour координаторы не теряют кэш на каждом long-running Monitor-ожидании.
- `worktree.baseRef: "fresh"` — worktree для новой волны стартует с актуального HEAD, а не устаревшего origin.

Проверяются один раз при настройке проекта, не runtime-checkpoint — их отсутствие не роняет skill, но жжёт токены впустую.

---

## Phase A: ANALYZE

> **Delegate A.1–A.4 to a `code-explorer` subagent (Sonnet).** Дескрипторный read-only граф-анализ stories + cbm-запросы — Sonnet справляется, Opus-координатор экономит токены на verbose I/O.
>
> <!-- TODO(coordinator): `code-explorer` (here) and `solo-reviewer` (Phase B.1.5, see references/post-merge-review.md) are referenced by name below but are NOT YET ported into this runtime's `claude/agents/` — only `claude/agents/_base/*` exists today (frontend-developer, python-pro, qa-expert, code-reviewer, etc.), none named code-explorer/solo-reviewer/migration-reviewer. Port them from mgt-openproject's `.claude/agents/{code-explorer,solo-reviewer,migration-reviewer}.md` as part of W-B7/B8's agent generalization, or — until they land — substitute `Agent({subagent_type:"general-purpose", model:"sonnet"})` with the identical prompt below. Do not silently skip the delegation; it is what keeps this phase cheap. -->
>
> **Spawn**: `Agent({subagent_type: "code-explorer", model: "sonnet", description: "Wave plan: deps + conflicts + topo", prompt: "<см. ниже>"})`
>
> **Prompt template**:
> ```
> Read frontmatter из `<ao.story_dir>/<STORY-ID>.md` для каждой ID:
> {STORY_IDS_LIST}
>
> Поля: id, title, status, contour, priority, story_points, depends_on, blocked_by, files_affected.
>
> 1. Build dependency graph (depends_on + blocked_by; satisfied=done remove edge; unsatisfied external = BLOCKED).
> 2. Build conflict graph (files_affected ∩; directory-prefix entries; ЕСЛИ cbm настроен — cbm:query_graph
>    для пар без file-overlap, depth=3, чтобы найти hidden shared module).
> 3. Merge → DAG: A→B if A in deps(B) OR (conflict(A,B) AND priority(A)>priority(B)) OR equal-priority+smaller-SP-first.
> 4. Topological sort → waves: no incoming edges = Wave 0, далее по слоям. --max-parallel={N} (hard cap 5):
>    split в sub-waves если волна больше.
>
> ВЫХОД: один JSON-блок (не markdown!), точно по этой схеме:
>
> {
>   "waves": [
>     [{"id":"STORY-XXX","title":"...","sp":N,"contour":"...","priority":"P1","reason":""}, ...],
>     ...
>   ],
>   "blocked": [{"id":"STORY-YYY","title":"...","reason":"unsatisfied dep STORY-ZZZ (status=draft)"}],
>   "conflicts": [{"a":"STORY-A","b":"STORY-B","shared_files":["..."],"resolution":"A first (priority)"}]
> }
>
> cbm-индекс может быть stale: при <3 hits на query_graph сделать `cbm:index_repository(mode="fast")` и retry один раз.
> ```
>
> **Coordinator** получает JSON, парсит, идёт в A.5.1 (per-story model/effort resolve), A.6 (presentation). Read-only фаза — никаких записей в файлы, кроме `<state_dir>/run-stories-runtime/*.json` в A.5.1.

### A.1 Collect Stories

Read frontmatter from each target story file (`<ao.story_dir>/STORY-{ID}.md`).

If no STORY-IDs provided — glob `<ao.story_dir>/STORY-*.md` (active dir only — if the product archives `done` stories to a sibling `archive/` directory, exclude it) and filter `status: draft`.

### A.2 Build Dependency Graph

For each story, collect edges:
1. **Explicit dependencies**: `depends_on` and `blocked_by` fields.
2. **Check dependency status**: if a dependency has `status: done` — it's satisfied, remove edge.
3. **Unsatisfied external deps**: if a dependency is NOT in the target set and NOT done — mark story as BLOCKED.

### A.3 Build Conflict Graph

For each pair of stories in the target set, check `files_affected` intersection:
```
conflict(A, B) = files_affected(A) ∩ files_affected(B) ≠ ∅
```
Directory-level entries (ending with `/`) conflict if either story touches files under that directory.

**cbm cross-check (only if `cbm_project` is configured)** — for pairs not caught by `files_affected`:
```
cbm:query_graph(query="
  MATCH (fa:File)-[:TOUCHED_BY]-(a:Story {id:'STORY-A'}),
        (fb:File)-[:TOUCHED_BY]-(b:Story {id:'STORY-B'})
  MATCH p = shortestPath((fa)-[*..3]-(fb))
  RETURN p, length(p) AS hops
")
```
If a path shorter than 3 hops exists through a shared module/type/endpoint — add to the conflict graph even without `files_affected` overlap. Log the reason (`shared: module Z / symbol W`).

**Fallback**: if the cbm index is stale (check via `index_status`), first `cbm:index_repository(mode="fast")` then cross-check. If `cbm_project` is empty entirely — this cross-check is skipped; conflict detection is `files_affected`-only.

### A.4 Merge Graphs → Execution Order

```
edge(A → B) if:
  - A in depends_on(B), OR
  - A in blocked_by(B), OR
  - conflict(A, B) AND priority(A) > priority(B), OR
  - conflict(A, B) AND priority(A) == priority(B) AND story_points(A) < story_points(B)
```
For conflicts between equal-priority stories: smaller SP goes first (faster feedback).

### A.5 Topological Sort → Waves

1. Topological sort the DAG.
2. Assign wave numbers: no incoming edges = Wave 0, etc.
3. Within each wave, respect `--max-parallel N` (**hard cap 5** — clamp any higher value; never launch more than 5 concurrent tmux workers) — split into sub-waves if needed.
4. Sort within wave: P0 > P1 > P2 > P3, then smaller SP first.

### A.5.1 Per-story runtime resolve

All stories run through the **same** channel — a tmux worker. Resolver persists model/effort/diagnostics per story:

```bash
source scripts/ao/runtime-config-read.sh
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
mkdir -p "${STATE_DIR}/run-stories-runtime"
for STORY_ID in {all_target_stories}; do
  RUNTIME=$(bash scripts/ao/resolve-story-runtime.sh "$STORY_ID")
  echo "$RUNTIME" > "${STATE_DIR}/run-stories-runtime/${STORY_ID}.json"
done
```

`resolve-story-runtime.sh` reads `ao.worker_model`/`ao.worker_effort` from `runtime.config.yaml` — **uniform across all stories** (workers are full Claude Code sessions, not subagents, so there is no SP/file-size-based model tiering; the resolver still computes `largest_file_loc`/`total_loc` and a human-readable `route_reason` for diagnostics, but they don't change model selection). It also emits `pre_flight_smokes` (currently only `["migrations_check"]`, triggered when a story's `db_impact: migration` — gated further by `ao.migrations_dir` being non-empty).

### A.6 Present Plan

Show the user the execution plan and wait for confirmation:

```markdown
## Story Execution Plan

**Target:** {N} stories, {total_SP} SP
**Waves:** {W}
**Max parallel:** {max_parallel}

### Wave 0 — {N} stories, {SP} SP (can start now)
| Story | Title | SP | Contour | Priority | Why |
|-------|-------|----|---------|----------|-----|

### Wave 1 — {N} stories, {SP} SP (after Wave 0)
| Story | Title | SP | Contour | Priority | Why | Waits for |
|-------|-------|----|---------|----------|-----|-----------|

> **Why**: `route_reason` from `resolve-story-runtime.sh` (e.g. `migration-smoke`, `file-size-override(largest=620,total=1840)`).

### Conflicts detected
| Story A | Story B | Shared files | Resolution |
|---------|---------|---------------|------------|

### Blocked (cannot execute)
| Story | Blocked by | Reason |
|-------|------------|--------|

Proceed? [y/n]
```

If `--wave-only` — stop here, don't execute.

---

## Phase B: EXECUTE

### B.0 Pre-flight Checks (before first wave)

```bash
source scripts/ao/runtime-config-read.sh
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"

# Resolve worker MODE (interactive | headless).
# Interactive is the recommended default for a human-attended run — each worker
# opens its own tmux window, AskUserQuestion works natively via the worker
# attaching, and a background watcher notifies on blocked workers.
# Headless is the CI/overnight fallback (no TTY needed, no notifications).
RUN_STORIES_MODE="${RUN_STORIES_MODE:-interactive}"
if [[ "${RUN_STORIES_MODE}" == "auto" ]]; then
  if command -v tmux >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    RUN_STORIES_MODE="interactive"
  else
    echo "[ERROR] auto mode: tmux/DISPLAY missing. Ask the user how to proceed (set RUN_STORIES_MODE=headless explicitly) rather than falling back silently." >&2
    exit 1
  fi
fi
[[ "${RUN_STORIES_MODE}" == "interactive" ]] && { command -v tmux >/dev/null || { echo "[ERROR] interactive mode requires tmux"; exit 1; }; }
echo "[INFO] Worker mode: ${RUN_STORIES_MODE}"

# Interactive mode: start the background notification watcher (one per wave).
if [[ "${RUN_STORIES_MODE}" == "interactive" ]]; then
  command -v tmux >/dev/null || { echo "[ERROR] tmux required for interactive mode"; exit 1; }
  command -v notify-send >/dev/null || echo "[WARN] notify-send not found — watcher will be a no-op"
  bash scripts/ao/watch-waiting-workers.sh > "${STATE_DIR}/watcher.log" 2>&1 &
  echo "$!" > "${STATE_DIR}/watcher.pid"
  echo "[INFO] Notification watcher started (PID $(cat "${STATE_DIR}/watcher.pid"))"
fi

# Branch-ownership baseline — a concurrent process could commit to the trunk
# (ao.base_ref) or leave a dirty tree mid-run; snapshot HEAD now so B.1.4 can
# detect a foreign dirty tree BEFORE attempting a merge, not reactively after abort.
bash scripts/ao/branch-ownership-guard.sh snapshot "$(git branch --show-current)"

# LAUNCH-TIME dirty-tree check. `snapshot` only records HEAD SHA — it does NOT
# detect a dirty working tree. Foreign uncommitted work present at launch
# silently blocks the merge hours later (B.1.4). Surface it now:
OWN0=$(bash scripts/ao/branch-ownership-guard.sh check "$(git branch --show-current)")
if [[ "$(echo "$OWN0" | jq -r .clean)" != "true" ]]; then
  echo "[ownership] dirty foreign tree at LAUNCH: $(echo "$OWN0" | jq -rc '.foreign')"
  # AskUserQuestion (blocking): foreign uncommitted work on the dev branch.
  #   (a) user commits it first (coordinator waits) — cleanest;
  #   (b) coordinator `git stash push -m parked-<wave>` up front, restores via
  #       `git stash pop` after ALL merges — only safe if zero overlap with
  #       any wave story's files_affected (verify before choosing);
  #   (c) abort wave.
  # Do NOT silently proceed — a worker touching a dirty file makes the pop
  # conflict, risking the user's uncommitted work.
fi
```

### B.1 Wave Execution Loop

For each wave (0, 1, 2, ...):

#### B.1.1 Launch Stories

> **CHECKPOINT B.1.1**: launching a worker is forbidden without pre-flight analysis. Each story MUST pass a graph-query + claude-mem observation pass BEFORE `launch-story-worker.sh`. A worker without pre-flight wastes 30-40% of its budget re-deriving context the coordinator already has.

For each story in the wave, build a pre-flight context saved to disk so the worker's own Phase 0 doesn't repeat it:

```
# 0. Cross-wave related-stories check
Skill("claude-mem:mem-search", args="STORY-{ID} OR {module}")
# (если cbm_project настроен) cbm:detect_changes(project="<cbm_project>", since="HEAD~20")
→ related stories already running in parallel worktrees → if overlap, demote priority or serialize (next wave)

# 1. Scope analysis (если cbm_project настроен: cbm:search_code(project, pattern, mode="files"); иначе — обычный Grep на конкретный каталог из files_affected)
→ count matches per module directory; if files_affected > 10 — WARN user, suggest splitting into sub-stories

# 2. Save pre-flight artifact + mem-context.json to <state_dir>/story-{id-lc}/
mkdir -p "<state_dir>/story-{id-lc}"
cat > "<state_dir>/story-{id-lc}/preflight.md" << 'EOF'
# Pre-flight: STORY-{ID} scope analysis
## Scope
- Files: {N} across {modules}
## Prior work / decisions (from mem-search)
- {1-line summary per relevant observation, if any}
## Known gotchas / followups to honor
- {from prior observations — quote}
EOF

# mem-context.json — preflight-gate.sh check `mem-context-loaded` reads exactly
# this file; without it the check WARNs (not blocking) every launch.
cat > "<state_dir>/story-{id-lc}/mem-context.json" << 'EOF'
{"story":"STORY-{ID}","searched":"{today}","observations":[{"id":<obs-id>,"t":"<1-line takeaway>"}]}
EOF
```

**Every story MUST launch via the tmux channel.** A story goes `preflight-gate.sh` → tmux worker → `worktree-gate.sh` → merge → post-merge review. There is no other legitimate path:

> **FORBIDDEN**: inline execution in the coordinator (writing code yourself) — bypasses every closed-loop phase. Any worker launched without `Skill("<ao.story_skill_slug>")` — no phase tracking, no review, no AC verification.

```bash
source scripts/ao/runtime-config-read.sh
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
export RUN_STORIES_MODE CLAUDE_WAVE_ID="wave-current"
for STORY_ID in {wave_stories}; do
  ROUT=$(bash scripts/ao/resolve-story-runtime.sh "${STORY_ID}")
  MODEL=$(echo "$ROUT"  | jq -r .model)
  EFFORT=$(echo "$ROUT" | jq -r .effort)
  # .budget/.timeout are emitted for backward-compat only — NOT enforced, NOT
  # passed to launch-story-worker.sh (workers run unbounded by design).

  # ALWAYS lowercase the story-id suffix for worker-dir naming — the launcher
  # and every downstream script (worktree-gate.sh, wait-wave.sh, ...) key off
  # `story-<lc>`; an uppercase mismatch (ext4 is case-sensitive) makes phase-log
  # reads miss the schema-v1 header and the story looks "blocked" for no reason.
  SID_LC=$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')
  mkdir -p "${STATE_DIR}/story-${SID_LC}"
  echo "$ROUT" > "${STATE_DIR}/story-${SID_LC}/runtime.json"

  # --- Pre-flight readiness gate (13 checks, see preflight-gate.sh) ---
  # story-file-exists, frontmatter-parse, story-status, ac-present,
  # files-affected-exist, no-active-worker, base-ref-fresh, mem-context-loaded,
  # cbm-index-fresh (skipped if cbm_project unset), db-liveness (skipped if
  # db_impact=none), migration-smoke + migration-head-freshness + schema-gap
  # (all skipped if ao.migrations_dir is empty or the story touches no migrations).
  PRE=$(bash scripts/ao/preflight-gate.sh "${STORY_ID}")
  if [ "$(echo "$PRE" | jq -r .pass)" != "true" ]; then
    REASON=$(echo "$PRE" | jq -r .reason)
    echo "$PRE" > "${STATE_DIR}/story-${SID_LC}/preflight.json"
    echo "[preflight] ${STORY_ID} BLOCKED: ${REASON}"
    source scripts/ao/phase-log-util.sh
    log_phase_event "${STATE_DIR}/story-${SID_LC}" 0-init blocked "preflight:${REASON}"
    continue
  fi
  echo "$PRE" > "${STATE_DIR}/story-${SID_LC}/preflight.json"

  bash scripts/ao/launch-story-worker.sh "${STORY_ID}" \
    --model "${MODEL}" --effort "${EFFORT}" --mode "${RUN_STORIES_MODE}" &
done
```

> **Interactive mode note**: each tmux worker gets its own window (name = `story-NNN`). The session name is inherited from whatever `tmux display-message -p '#S'` returns at launch time — don't assume a literal session name. On `AskUserQuestion` inside a worker — desktop notification via `notify-send`. To attach: `tmux list-sessions` → `tmux attach -t <session>:story-NNN`.

**Model / effort / route — single source of truth: `scripts/ao/resolve-story-runtime.sh`**, which reads `ao.worker_model`/`ao.worker_effort` from `runtime.config.yaml`. This SKILL.md does not duplicate the resolver's logic — change the config, not this file, to retune worker model/effort.

**Budget/timeout are not enforced** — workers run unbounded by design; the coordinator can interrupt via manual kill / `TaskStop` if needed.

Workers write progress to `<state_dir>/story-{id-lc}/phase` (current phase name) and `.../status` (running/complete/failed).

**Verification after launch**: check each worker's `prompt.txt` contains `/<ao.story_skill_slug>`. If not — kill the worker and re-launch via the script.

**MCP verification**: check that the worktree's `.mcp.json` (copied by `prepare-story-worktree.sh`) contains the discovery MCP server configured for this product (e.g. `codebase-memory-mcp` when `cbm_project` is set). Workers must have the same discovery layer as the coordinator for token-efficient code navigation across every phase.

#### B.1.2 Monitor Wave Progress

Workers are external tmux processes; monitor them through `wait-wave.sh` under the Monitor tool:

```bash
WAVE_STORIES="${wave_stories[*]}"

if [[ -n "$WAVE_STORIES" ]]; then
  # Monitor tool hard-caps timeout_ms at 3600000 (1h) — re-arm the SAME call in
  # a loop until a terminal signal fires. wait-wave.sh is idempotent (pre-loop
  # sweep) — a re-armed Monitor immediately sees any workers that finished
  # while it was re-arming.
  Monitor(
    description="Wave {N}: ${WAVE_STORIES}",
    timeout_ms=3600000,
    persistent=false,
    command="bash scripts/ao/wait-wave.sh ${WAVE_STORIES} --interval 180"
  )
  # On '[Monitor timed out]' without WAVE_COMPLETE/PARTIAL → re-issue the SAME
  # Monitor call. Multi-hour opus/xhigh stories routinely exceed 1h — expect
  # 1-3 re-arms per wave.
fi
```

- Interval = 180s (3 min) — frequent enough without spamming.
- Each stdout line surfaces as a notification.
- Monitor's 1h timeout WITHOUT a final signal ⇒ **re-arm the same call**, do NOT proceed to B.1.3 (the wave is still running). Only `WAVE_COMPLETE` / `WAVE_PARTIAL` / `WAVE_TIMEOUT` are terminal.
- `WAVE_COMPLETE` (all exit_code=0), `WAVE_PARTIAL` (≥1 worker exit_code != 0), or `WAVE_TIMEOUT` (soft wallclock cap inside `wait-wave.sh`, workers keep running) → final signal.
- **FORBIDDEN**: manual polling via Bash, parallel background bash, duplicate Monitors.
- After the monitor completes — proceed to B.1.3 (gate).

> **Fallback (if the Monitor tool is unavailable)**: replace the Monitor call with a synchronous Bash loop — `wait-wave.sh` supports `--timeout N` for a finite-block wait and emits the final JSON on stdout:
> ```bash
> while true; do
>   out=$(bash scripts/ao/wait-wave.sh ${WAVE_STORIES} --timeout 600)
>   echo "$out" | tail -20
>   ws=$(echo "$out" | python3 -c "import sys,json; lines=sys.stdin.read().splitlines(); s=next((i for i,l in enumerate(lines) if l.startswith('{')), -1); print(json.loads('\n'.join(lines[s:]))['wave_status'] if s>=0 else 'UNKNOWN')")
>   [[ "$ws" != "TIMEOUT" ]] && break
> done
> ```
> Only use this when Monitor is genuinely unavailable — no live notifications, and the coordinator can't field user input mid-wait.

**Live phase dashboard (diff-only, token-economical)** — after each Monitor tick, refresh the per-story phase table via `scripts/ao/wave-status.sh` (reads phase-log, engine-agnostic to interactive/headless):
```bash
bash scripts/ao/wave-status.sh --json > "${STATE_DIR}/wave-state.current.json"
# print the human table only if any story's current phase changed vs. the
# previous tick's snapshot — on stable phases, print one "no change" line instead.
```
**Stuck-alert**: if `bash scripts/ao/wave-status.sh --json | jq -r .any_stuck` is `true`:
```bash
echo "⚠ STUCK detected. Drill-down: bash scripts/ao/wave-status.sh <STORY-ID>"
bash scripts/ao/wave-status.sh --stuck
```
Per-story drill-down: `bash scripts/ao/wave-status.sh STORY-XXX`.

#### B.1.3 Coordinator-Side Worktree Gate (BEFORE merge)

> **CHECKPOINT**: merge is forbidden without passing the coordinator gate. A worker's own `gate.json`/`verify.json` is **NOT TRUSTED** — a worker could fabricate `{"pass":true,"_complete":true}` via a direct `cat > gate.json <<EOF` (see `.claude/rules/phase-contract.md` → Coordinator trust model).

```bash
bash scripts/ao/worktree-gate.sh STORY-ID --base-ref "$(git branch --show-current)"
```

The script (see `story-machinery/scripts/worktree-gate.sh`):
1. Worktree exists and the branch has ≥1 commit beyond base.
2. Every `diff.json` `commits[].sha` actually exists via `git rev-parse --verify {sha}^{commit}` (anti-fabrication).
3. Working tree is clean; auto-merges the base ref into the worktree (docs-only conflicts auto-resolve **only if `srs.enabled`**, per a fixed policy: story files keep `--ours`, SRS/RTM/report docs take `--theirs` + rebuild; any non-docs conflict aborts and fails the gate).
4. **Configured gate commands run by default** — pulled from `ao.gate_registry` (a list of `{match: <changed-path regex>, cmd: <shell command>}` rules; the first rule whose regex matches any changed file runs its command, `{gates.X}` tokens expand from the `gates:` block). Pass `--skip-gates` to trust the worker's own Phase 3 result instead (only do this for low-risk stories where re-running the full suite per-merge is wasteful — the config-driven default is to actually run gates, not skip them).

Output — compact JSON `{"pass":bool,"reason":str,"details":str}`:
```json
{"pass":true,"reason":"gate-ok","details":"commits:2;worker_claimed:lint=True tsc=True tests=True"}
{"pass":false,"reason":"diff-json-fabricated-sha","details":"invalid:a8affb94"}
{"pass":false,"reason":"gate-command-failed","details":"cmd='pytest src/' :: ..."}
{"pass":false,"reason":"no-commits-on-branch","details":"branch has 0 commits beyond main"}
{"pass":false,"reason":"dirty-working-tree","details":"M src/foo.tsx;M src/bar.tsx;"}
```

> **`pass:false reason=diff-json-fabricated-sha` — do NOT auto-override.** Two classes by `details`: `non-hex-sha:<v>` (placeholder/abbreviated) may be a false positive; a **bare 40-char hex** (`invalid:<40charsha>`) means the object genuinely does not exist — a TRUE positive, never override. Common cause: the worker amended a commit during a self-review/simplify phase and never regenerated `diff.json` → stale sha. If verifying manually, always use the full 40-char sha (`git rev-parse --verify "<full-sha>^{commit}"`) — a short prefix can collide with a different real commit and give false confidence.

Decision rules:
- `pass:true` → proceed to merge (B.1.4).
- `pass:false` → DO NOT merge, report `reason`+`details` to the user.
- The worker's own `gate.json` is only recorded in telemetry (`details.worker_claimed`) — never used for the merge decision.

#### B.1.4 Merge Worktrees

**Pre-step**: clean stale worker PIDs — an alive-looking PID from a crashed worker can make a branch-protection hook reject the merge. `worktree-gate.sh` already calls `scripts/ao/cleanup-stale-pids.sh` at its own start (Pre-check 0), so an explicit call here is only needed before a batch of merges or when suspicious of hung panes from a previous session:
```bash
bash scripts/ao/cleanup-stale-pids.sh
# {"cleaned_stale":N,"killed_zombie":N,"preserved_alive":N}
# preserved_alive > 0 — a worker is still genuinely running; don't merge that story.
```

**Pre-step 2 (BLOCKING)** — branch-ownership check BEFORE any merge attempt (`worktree-gate.sh`'s auto-rebase only catches this reactively, after the gate has already run):
```bash
OWN=$(bash scripts/ao/branch-ownership-guard.sh check "$(git branch --show-current)")
if [ "$(echo "$OWN" | jq -r .clean)" != "true" ]; then
  echo "[ownership] FOREIGN changes on dev branch: $(echo "$OWN" | jq -rc .foreign)"
  # STOP — do not merge. AskUserQuestion: (a) user commits it first if they own
  # it, (b) stash + merge + report stash-ref, (c) pause — a concurrent session
  # owns the branch. Do NOT silently proceed.
fi
```

> ### Merge safety contract
> On a base-catchup conflict, **forbidden**:
> - `git checkout --theirs <non-rtm-file>` — takes the base's version and discards the story's own commits, creating an empty merge that silently loses work.
> - `git commit --no-edit` right after that same mistake.
> - `git merge --abort && git merge --no-ff <branch>` retry without analyzing the cause (same conflict recurs).
>
> **Allowed recovery paths**:
> 1. **Co-anchor append resolution** — conflict markers show "added X vs added Y" with no real overlap → spawn a `general-purpose` Sonnet agent to resolve keep-both **inside the worktree**, then retry the merge.
> 2. **Cherry-pick range**: `git log <base>..<worktree-branch> --oneline` → `git cherry-pick <first>^..<last>` (ALL of the story's commits) when the merge is structurally more complex than a simple append.
> 3. **AskUserQuestion escalation** if neither fits: (a) reset + manual resolve, (b) cherry-pick range, (c) abort and leave the worktree branch unmerged.

```bash
source scripts/ao/runtime-config-read.sh
cd "${REPO_ROOT}"
# Code lands on the base branch THROUGH a PR, not a local merge (decisions: merge
# by local gate, remote CI not awaited — it runs async as an async drift-detector;
# the pipeline auto-merges on --auto-merge; SRS/RTM — if enabled — are coordinator
# single-writer, not committed by the worker, so there's no rtm.yaml conflict on
# the server-side squash).
WORKTREE_ROOT="$(rcfg ao.worktree_root .claude/worktrees)"
WT="${REPO_ROOT}/${WORKTREE_ROOT}/STORY-${STORY_ID#STORY-}"
BASE_REF="$(rcfg ao.base_ref main)"

# Step 1 — catch the worktree branch up to origin/<base>. In a serial wave,
# earlier stories already squash-merged into origin — merge origin/<base> into
# the branch first or the server-side squash will conflict.
git fetch origin "${BASE_REF}" >/dev/null 2>&1 || true
if ! git -C "$WT" merge --no-ff --no-edit "origin/${BASE_REF}" >/dev/null 2>&1; then
  CONFLICTS=$(git -C "$WT" diff --name-only --diff-filter=U)
  echo "[CONFLICT] base-catchup in worktree ($WT): $CONFLICTS"
  echo "[HINT] Co-anchor append (added X vs added Y, no overlap) → spawn a general-purpose"
  echo "       Sonnet agent: 'resolve co-anchor conflicts in <files>, KEEP BOTH SIDES,"
  echo "       dedupe imports' INSIDE $WT, then git add + git commit --no-edit, retry."
  echo "[HINT] Dual-head migration conflict (both took the same revision id) → renumber"
  echo "       the second migration's revision/down_revision."
  echo "[HINT] Otherwise AskUserQuestion: (a) reset+manual resolve, (b) cherry-pick range,"
  echo "       (c) abort without merging."
  echo "[HINT] FORBIDDEN: git checkout --theirs <non-rtm> + commit --no-edit — empty merge, data loss."
  exit 1
fi

# Step 2 — push → PR → squash-merge (idempotent, doesn't wait on remote CI).
PR_RESULT=$(bash scripts/ao/pr-merge-story.sh "${STORY_ID}" --base "${BASE_REF}" --auto-merge)
echo "$PR_RESULT"
case $(jq -r .status <<<"$PR_RESULT") in
  merged)  echo "[OK] $(jq -r .details <<<"$PR_RESULT")" ;;
  pr-open) echo "[WARN] PR opened but not auto-merged — inspect and merge manually before B.1.5" ;;
  skipped) echo "[WARN] $(jq -r .details <<<"$PR_RESULT") — nothing merged, inspect the branch" ;;
  *) echo "[ERROR] PR-merge failed — see details, do NOT proceed to B.1.5"; exit 1 ;;
esac

# Step 3 — ff-sync local base with the server-side squash.
git fetch origin "${BASE_REF}" >/dev/null 2>&1
if ! GIT_ALLOW_WORKER_COMMIT=1 git merge --ff-only "origin/${BASE_REF}"; then
  echo "[ERROR] ff-only merge failed — local base has diverged (unpushed commits?). Resolve before B.1.5."
  exit 1
fi

# Optional post-merge hook (e.g. reinstall deps / restart a dev container after
# a dependency-manifest change) — product-specific, config-driven, not hardcoded
# here. See `ao.prepare_hook` in runtime.config.yaml if the product needs one;
# there is no built-in "package.json changed → restart container" step in this
# generic skill (that was mgt-openproject-specific).
```

Verify the merge: `git log --oneline -5` to confirm the story's commits landed.

**Leak detection**: if `git status --porcelain` at repo root shows unrelated files (not from this story's merge) — check `<state_dir>/story-*/leak.log` (populated by a write-guard hook, if the product has one). If a worker wrote outside its worktree — abort merge, investigate.

#### B.1.5 Post-Merge Review — see [`references/post-merge-review.md`](references/post-merge-review.md)

> Per-wave review via a `solo-reviewer` Agent (Sonnet, single pass). Findings are fixed inline (B.1.5.1, no fixup-stories). Full protocol + verdict handling in the reference.

#### B.1.6 SRS/RTM status sync (only if `srs.enabled`) — see [`references/srs-status-sync.md`](references/srs-status-sync.md)

> Coordinator single-writer sync from each worker's `srs-pending.json` via `scripts/srs/apply-srs-pending.sh`. **If `srs.enabled: false` — skip this whole step entirely**; there is no SRS/RTM to sync, and the worker never wrote `srs-pending.json` in the first place.

#### B.1.7 Wave Gate

Before proceeding to the next wave:
- All stories in the current wave must be merged or failed.
- If any story failed — report to the user, ask whether to continue with the next wave.
- **Default: run incremental tests** — per-story `worktree-gate.sh` already ran the configured gate commands in each worktree; a redundant full run on the base branch after every wave is usually wasted time. Use whatever changed-only mode the product's gate scripts support (e.g. `bash scripts/test.sh --changed --base-ref <ao.base_ref>`).
- **Full suite only when**: cross-cutting refactor (≥2 modules / shared code), new DB migrations, or shared-kit changes. Run the product's full gate command set.
- **Before pushing to remote** — full suite is mandatory regardless (see `.claude/rules/quality-gates.md`).
- If tests fail — STOP, report the regression.
- **Reindex the knowledge graph after merge** (only if `cbm_project` is configured), so the next wave's workers see the merged code:
  ```
  cbm:index_repository(project="<cbm_project>", mode="fast")
  ```

#### B.1.8 Cleanup (MANDATORY after each wave)

```bash
source scripts/ao/runtime-config-read.sh
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
WORKTREE_ROOT="$(rcfg ao.worktree_root .claude/worktrees)"

# 0. PRESERVE report inputs BEFORE worktree removal — summary/closeout artifacts
#    live INSIDE the worktree and safe-worktree-cleanup deletes it; copy them
#    into the state dir (survives cleanup) before removing the worktree.
for STORY_ID in {wave_stories}; do
  SID_LC=$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')
  WT="${WORKTREE_ROOT}/STORY-${STORY_ID#STORY-}"
  for art in summary.md closeout.md; do
    [[ -f "${WT}/.worker/${art}" ]] && cp -f "${WT}/.worker/${art}" "${STATE_DIR}/story-${SID_LC}/${art}" 2>/dev/null || true
  done
done

# 1. Worktree cleanup for every story in the wave — safe-worktree-cleanup.sh
#    stashes any uncommitted work before removing (never force-remove directly;
#    a timed-out worker can leave real uncommitted Phase-2 code behind).
for STORY_ID in {wave_stories}; do
  bash scripts/ao/safe-worktree-cleanup.sh "${STORY_ID}" 2>&1 | tail -3
done
git worktree prune
# If the product synced git-worktree-hygiene.sh, `--dry-run` (default) then
# `--apply` sweeps any additional stale worktree-STORY-* branches left behind
# by aborted runs — never the base branch, current branch/worktree, or an
# unmerged/dirty one.

# 2. Clean worker dirs — KEEP result.json (needed for Phase C), drop large logs.
for STORY_ID in {wave_stories}; do
  SID_LC=$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')
  rm -f "${STATE_DIR}/story-${SID_LC}/stderr.log" 2>/dev/null
done

# 3. Interactive mode teardown.
if [[ "${RUN_STORIES_MODE}" == "interactive" ]]; then
  if [[ -f "${STATE_DIR}/watcher.pid" ]]; then
    kill "$(cat "${STATE_DIR}/watcher.pid")" 2>/dev/null || true
    rm -f "${STATE_DIR}/watcher.pid"
  fi
  # Leave the tmux session up until the user confirms — a post-hoc review pane
  # may still be open there. To kill manually: `tmux list-sessions` → `tmux kill-session -t <name>`.
fi
```

**Failure to clean up causes**: dangling worktrees, branch conflicts on re-run, disk exhaustion on long runs.

Then proceed to the next wave (B.1.1).

### B.2 Resume Mode (`--resume`)

1. Scan `<state_dir>/story-*/status` for all story worker directories.
2. For each directory, read `status` — classify as "complete", "failed", or "incomplete" (missing/other).
3. Read `<state_dir>/story-{id-lc}/phase` for the last completed phase of incomplete stories.
4. Skip stories with status "complete".
5. Re-launch incomplete stories via `bash scripts/ao/launch-story-worker.sh` (NEVER via a bare `Agent()` call — same rule as B.1.1).
6. Check `<state_dir>/story-{id-lc}/result.json` for completed stories to avoid re-running.

---

## Phase C: REPORT

### C.0 Render stub (mechanical, no agent)

```bash
bash scripts/ao/render-wave-report.sh "wave-${WAVE_ID}" "${STORY_IDS[@]}"
# → docs/reports/wave-<id>-report.md
```

Stub contains: header (date, branch, HEAD SHA), a stories table (id/title/sp/contour/AC summary/verdict from each `result.json`), the commit list (`git log <base>..HEAD`), file-change stats, requirement refs per story (if `srs.enabled`), and `<!-- TODO -->` placeholders for executive summary / lessons learned / next waves.

### C.1 Narrative (deterministic — no report-agent)

> **Do not spawn a `general-purpose` report-agent for this.** A report-agent launched AFTER B.1.8 cleanup reads artifacts from an already-removed worktree, degrades to scraping whatever's left, and burns tokens on a useless summary. The report is built deterministically from stable paths (`<state_dir>/` survives cleanup; B.1.8 step 0 explicitly preserves `summary.md`/`closeout.md`) + git + claude-mem (per-story observations are already recorded automatically).

`render-wave-report.sh` (C.0) already aggregates `result.json` + `review.json` + git log into a full report (tables filled in, narrative = TODO). The coordinator then fills in the narrative sections itself — cheap, since the context is already loaded after the wave:

```bash
# 1. Deterministic report (stable state-dir + git, no agent, no worktree dependency).
bash scripts/ao/render-wave-report.sh "wave-${WAVE_ID}" "${STORY_IDS[@]}"
# → docs/reports/wave-<id>-report.md (tables filled, narrative = TODO)

# 2. (opt.) narrative facts from claude-mem — observations are written automatically per story.
Skill("claude-mem:mem-search", args="STORY-<wave-ids> merged review")
# → 2-3 lines of lessons/decisions, write into the TODO sections by hand (Edit).
```

The report should cover: Results-by-Story (from the stub), Failed/Partial, Merged commits, Follow-ups (spawned backlog + accepted-debt from `review.json`'s `status` fields), and Known-debt (pre-existing failures classified in B.1.5.1). A missing JSON → mark `missing-result-json`, don't fail the report. **No `Agent()` calls in Phase C.**

---

## Decision Rules

| Situation | Action |
|-----------|--------|
| Circular dependency detected | STOP, report to user |
| Story depends on non-existent story | STOP, report to user |
| All stories in wave failed | STOP, don't proceed to next wave |
| Some stories in wave failed | Ask user: continue next wave or stop? |
| `--wave-only` | Show plan, don't execute |
| `--resume` | Scan `<state_dir>/story-*/` for incomplete stories, relaunch via tmux |
| Test regression between waves | STOP, report regression |
| Single story provided | Run through tmux channel (single-story = single-wave) |

## Invariant Rules

1. **Never implement code** — the orchestrator only dispatches and monitors.
2. **Wave gate is mandatory** — incremental tests between waves; full suite only for cross-cutting changes (≥2 modules, shared code, DB migrations).
3. **Conflict = sequential** — stories sharing files NEVER run in the same wave.
4. **User confirms the plan** — always show the plan before executing (unless a single story).
5. **Resumable** — all state lives under `<state_dir>/` (status, phase, result.json).
6. **Tmux channel only** — `bash scripts/ao/launch-story-worker.sh` → Claude Code worker in tmux → `/<ao.story_skill_slug>`. The coordinator never writes code itself, never calls `Agent(mode:"auto")` without a Skill(), never bypasses routing "to go faster."
7. **Post-wave verification** — confirm `prompt.txt` contains `/<ao.story_skill_slug>` and `result.json` exists at `<state_dir>/story-{id-lc}/`.
8. **The product's discovery MCP is mandatory for every worker** — if `cbm_project` is configured, every worker's worktree `.mcp.json` must include it; workers use graph queries as their primary code-navigation tool over blind grep/Read.
9. **Mandatory cleanup after each wave** — B.1.8 MUST run after every wave. Dangling worktrees cause branch conflicts and disk exhaustion on re-runs.
10. **Phase 0 is BLOCKING** — story-frontmatter review, (if `srs.enabled`) SRS/RTM reads, and `mem-search` MUST complete before Phase A. No exceptions.
11. **Pre-flight analysis is BLOCKING** — graph queries + claude-mem observation for each story MUST complete before `launch-story-worker.sh`. Workers without pre-flight waste 30-40% of their budget on redundant analysis.
12. **Interactive mode is the default** (`RUN_STORIES_MODE=interactive`). Each worker gets its own tmux window in the session inherited at launch time; `AskUserQuestion` works natively via the worker's own attach. If tmux/DISPLAY are unavailable — STOP and ask the user (don't fall back to headless silently).
13. **AskUserQuestion in auto-mode** — the coordinator uses `AskUserQuestion` in A.6 (plan confirm), B.1.4 (conflict resolve), B.1.7 (failure decision). Don't strip these calls out because auto-mode "seems to hang" on them — that would be an auto-mode bug to report, not a reason to remove the call.
14. **Subagent stall handling** — if a spawned review/analysis subagent (e.g. `solo-reviewer` in B.1.5, `code-explorer` in Phase A) stalls or fails outright, retry the same `Agent(...)` call once. If it fails a second time, mark the step `missing-review`/`missing-analysis` with a warning to the user and proceed rather than blocking the whole wave indefinitely.
