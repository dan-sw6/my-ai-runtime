## Gate: `srs.enabled` (optional SRS/RTM module)

This whole reference applies **only when `srs.enabled: true`** in `runtime.config.yaml`.
The SRS/RTM methodology (`docs/SRS.md`-style requirements doc + generated `rtm.yaml`
linkage) is an **optional module** of this runtime — see `story-machinery/srs/README.md`.
When `srs.enabled: false`, none of the workflow below applies; Phase 5.1 collapses to a
single no-op write (see "When the module is disabled" below) and the harness runs with
no requirements doc at all.

## Контракт (single SRS writer, when enabled)

**SRS изменяет ТОЛЬКО `/run-stories` coordinator после merge** (или пользователь вручную, при standalone-вызове).

`/implement-story` worker (через любой канал: tmux/inline/headless) **никогда не редактирует** the active SRS (`srs.srs_path`) или the archive doc (`srs.archive_path`) directly.

Причины:
- worker-Edit'ы SRS постоянно конфликтуют с parallel coordinator-writes и требуют ручного reconcile.
- два writer'а на один canonical файл = drift; один writer = invariant.
- coordinator уже агрегирует review.json (AC verification) от всех stories волны — у него полный контекст для consistent batch-update.

Worker по-прежнему:
1. обновляет frontmatter story (`status: done`, `requirement_refs`, `verified_at`);
2. пишет structured **`srs-pending.json`** в worker-dir — предложение для coordinator: какой Status выставить, перемещать ли в archive, какие Notes добавить.

> **RTM: worker НЕ запускает rebuild-скрипт и НЕ коммитит `srs.rtm_path`.**
> RTM — coordinator-single-writer (как SRS): код приземляется через squash-merge, который
> не auto-resolve'ит параллельные RTM-правки. Coordinator регенерирует RTM из frontmatter
> merged stories post-merge (`rebuild-rtm.sh`).

## Phase 5.1 — Алгоритм (worker, when `srs.enabled: true`)

### Шаг 1 — Update story frontmatter (RTM — coordinator-owned)

1. В `${AO_STORY_DIR}/STORY-NNN.md` frontmatter: `status: done` (canonical terminal state — НЕ `in_review` / `closed` / `merged`). При необходимости `verified_at: <ISO date>`.
2. `git add ${AO_STORY_DIR}/STORY-NNN.md` (ТОЛЬКО frontmatter). **НЕ трогать `srs.rtm_path`** — worker не запускает rebuild и не коммитит RTM. Coordinator регенерирует RTM post-merge из этого frontmatter.

### Шаг 2 — Write srs-pending.json (предложение для coordinator)

Для каждого `requirement_ref` из frontmatter story сформировать запись и записать массив в `${CLAUDE_WORKER_DIR}/srs-pending.json`:

```bash
cat > "${CLAUDE_WORKER_DIR}/srs-pending.json" <<JSON
{
  "story": "STORY-NNN",
  "ts": "$(date -Iseconds)",
  "proposed": [
    {
      "req_id": "FR-XYZ-001",
      "current_status": "partial",
      "proposed_status": "implemented",
      "move_to_archive": true,
      "verified_at": "2026-05-21",
      "ac_verification": [
        {"ac": "AC1", "status": "met", "evidence": "test_xyz::test_happy_path"},
        {"ac": "AC2", "status": "met", "evidence": "migration NNNN applied"}
      ],
      "notes_delta": "AC5-10 closed; lifecycle states formalized via ADR"
    }
  ]
}
JSON
```

Правила формирования `proposed_status`:
- **Все AC `met`** + чистая история тестов → `implemented` + `move_to_archive: true` + `verified_at`.
- **Часть AC `met`** → `partial` + `move_to_archive: false` + `notes_delta` с описанием остатка.
- **Ничего не закрыто** → НЕ записывать запись (worker не должен закрывать story с ничем не реализованным — отдельный debug).

Если requirement не найден ни в active SRS, ни в archive — записать запись с `current_status: "missing"` и `proposed_status: "needs-extend-srs"`. Coordinator выдаст warning и не будет применять флип.

### Шаг 3 — Quick-check (НЕ обязателен, информационно)

```bash
for id in <each requirement_ref>; do
  bash rtm-srs-sync.sh "$id" | python3 -m json.tool
done
```

Output ожидаем в worker-сессии:
- `rtm_stories` уже содержит `STORY-NNN` (Шаг 1 RTM rebuild).
- `srs_status` ещё указывает на pre-Phase-5 значение (coordinator не отработал) — это нормально.

## When the module is disabled (`srs.enabled: false`)

Steps 1-3 above don't apply — there is no SRS/RTM doc in this project. The worker still
has to satisfy the `close.json` schema (`phase-complete.sh` requires one of
`{srs_pending, srs_updated}` to be `true`, regardless of whether the module is enabled).
Write a no-op placeholder:

```bash
cat > "${CLAUDE_WORKER_DIR}/srs-pending.json" <<JSON
{"story":"STORY-NNN","srs_disabled":true,"proposed":[]}
JSON
```

and set `srs_pending: true` in `close.json` (see `references/phase-5-close.md` §5.4).
`apply-srs-pending.sh` itself also no-ops (`{"skipped":"srs-disabled","applied":false}`)
if it's ever invoked against a project with the module off — this placeholder just
satisfies the phase-contract schema without implying the module is active.

## Взаимодействие с `/run-stories`

Coordinator post-merge:
1. Читает `${CLAUDE_WORKER_DIR}/srs-pending.json` для каждой merged story.
2. Сверяет с `review.json` (overall verdict + ac_verification массив) — skip'ает флип если verdict = block.
3. Запускает `apply-srs-pending.sh STORY-NNN --apply` — флипает `Status` в active SRS, ИЛИ (при `move_to_archive: true`) переносит блок целиком в archive doc + rebuild'ит RTM.
4. Коммитит одним коммитом: `docs(srs): wave-N status sync — STORY-NNN..MMM`.

## Standalone `/implement-story` (без /run-stories)

Если пользователь вызвал `/implement-story STORY-NNN` напрямую без последующего `/run-stories`:
- Worker всё равно пишет `srs-pending.json` (не пытается сам обновить SRS), когда `srs.enabled: true`.
- В Phase 5.2 report worker явно указывает: «SRS Status НЕ обновлён — coordinator's job. См. `${CLAUDE_WORKER_DIR}/srs-pending.json`».
- Пользователь либо запускает `/run-stories STORY-NNN` (SRS-reconcile применится), либо вручную `apply-srs-pending.sh STORY-NNN --apply`.

## Anti-patterns

- ❌ Worker НЕ редактирует the active SRS doc через Edit/Write. Любой такой коммит = bug.
- ❌ Worker НЕ редактирует the archive doc.
- ❌ Worker НЕ пишет status-поля в `srs.rtm_path` (RTM has no status field — status lives exclusively in the SRS).
- ❌ Не оставлять `Status: implemented` entry в active SRS — coordinator перенесёт в archive.
- ❌ Не дублируй AC из SRS в story; story ссылается через `requirement_refs[]`.
- ❌ Не закрывай story (Phase 5 close) без `srs-pending.json` artifact, даже с `srs.enabled: false` — the placeholder from "When the module is disabled" above is still required by the phase-contract schema.
