### 1.7 Interactive Checkpoints (when CLAUDE_WORKER_MODE=interactive)

> **⚠ МЕТА-ПРАВИЛО для interactive mode**: ВСЕГДА используй `${CLAUDE_WORKER_DIR}` (env экспортируется launcher'ом) когда нужен worker-dir. НЕ вычисляй путь сам через `story-${STORY_ID#STORY-}` или `story-${CLAUDE_STORY_ID}` — это приводит к split-brain (`story-story-999`, `story-STORY-ITEST2` и пр.). Единственный canonical источник пути — `${CLAUDE_WORKER_DIR}`.

Переменная окружения `CLAUDE_WORKER_MODE` выставляется launcher'ом (`launch-story-worker.sh` / `launch-story-worker-interactive.sh`):
- `interactive` — worker в tmux TUI; `AskUserQuestion` работает нативно, user отвечает в пане. PreToolUse hook пишет `${CLAUDE_WORKER_DIR}/blocked-waiting.json`, coordinator шлёт notify.
- `headless` — classic `claude -p` background; `AskUserQuestion` не доступно → при неоднозначности логировать `blocked` в phase-log и выходить.

**Canonical checkpoints в interactive mode** — worker ОБЯЗАН вызвать `AskUserQuestion` (вместо тихой догадки) в этих случаях:

1. **Phase 1 (PLAN) — ambiguous AC**: два+ одинаково валидных интерпретации acceptance criteria; выбор меняет файлы/API/UX. Вопрос: «AC допускает N трактовок — какую реализовать?».
2. **Phase 2 (IMPLEMENT) — missing/renamed dependency**: ожидаемый файл/функция/API не найден на месте (rename, removal, merge в параллельной story). Вопрос: «X не найден. Обновить импорт на Y / использовать альтернативу Z / прервать?».
3. **Phase 3 (GATE) — corrective loop после 2-й неудачи**: та же гейт-ошибка повторяется 2 раза подряд после fix-попыток. Вопрос: «Гейт не стабилизируется после 2 итераций — продолжить 3-ю, откатить изменения, или запросить manual help?».
4. **Phase 4 (AC VERIFY) — partial pass после 2-й итерации**: часть AC PASS, часть FAIL после двух corrective циклов. Вопрос: «AC частично выполнены. Считать done / откатить / продолжить 3-ю итерацию?».

**В headless mode те же самые точки** → `log_phase_event ${phase} blocked reason=<kebab-case-reason>` и завершение. Это сохраняет совместимость с текущим batch-поведением.

**Ветвление на практике** (псевдокод для Phase 1):
```
if env.CLAUDE_WORKER_MODE == "interactive":
    answer = AskUserQuestion(questions=[{
        "question": "AC неоднозначны: (A) ... vs (B) ...",
        "header": "AC выбор",
        "options": [{"label": "A: ...", "description": "..."},
                    {"label": "B: ...", "description": "..."}],
        "multiSelect": False,
    }])
    # продолжить с выбором пользователя
else:
    # headless: блокируем фазу, coordinator увидит status=blocked
    Bash("source scripts/ao/phase-log-util.sh && log_phase_event 1-plan blocked ambiguous-criteria")
    # exit skill
```
