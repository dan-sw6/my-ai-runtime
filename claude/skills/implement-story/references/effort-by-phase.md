## Effort Override by Phase

Story-level effort (из `/run-stories` model routing, `ao.worker_model`/`ao.worker_effort`) — это **верхняя граница**. Каждая фаза может понижать effort, если её работа не требует reasoning.

**Правило**: если фаза состоит из «запусти скрипт + распарси output + обнови файл/JSON» — effort=low. Если фаза требует анализа кода, выбора между альтернативами, генерации новой логики — effort соответствует story-level.

### Per-phase table

| Phase | Effort | Rationale |
|-------|--------|-----------|
| 0-init | low | source helper, init phase-log — пустая работа |
| 0.1-mem-search | low | Skill вызов + интеграция результата, не reasoning |
| 1.0-prior-work | low | search queries + digest, не анализ |
| 1.1+1.2-codebase-analysis | low | discovery-MCP graph queries, формирование context.json |
| 1.3-task-decomposition | **story-level** | планирование требует reasoning |
| 1.4-design (contract exists) | low | read contract + положить путь в context.json |
| 1.4-design (new page, no contract) | **story-level** | генерация дизайна — full reasoning |
| 1.5-pre-checks | low | MCP queries + state findings |
| 2.1-implement | **story-level** | core work, не понижать |
| 2.1.5-simplify | medium | dedup требует понимания, но не full reasoning |
| 2.2-code-review | **story-level** | review = reasoning by definition |
| 2.2-a11y (inline spot-check) | low | bash spot-check, не анализ |
| 2.2-a11y (full agent) | medium | audit требует знаний, но не deep reasoning |
| 3.1-gates-inline | low | run scripts, diff against baseline |
| 3.1-gates-escalated | medium | deep-dive analytics |
| 3.2-architect-review | medium | architectural reasoning, но не creative |
| 3.3-audits | medium | structured audit, шаблонная работа |
| 3.4-corrective | **story-level** | требует понимания root cause |
| 4.1-ac-verify-inline | low | grep + evidence lookup |
| 4.1-ac-verify-escalated | medium | call-chain trace требует reasoning |
| 4.2-visual-verify | low | run script + парсинг delta-table |
| 5.0-result-json | low | bash heredoc |
| 5.1-rtm-srs-sync | low | structural file edits |
| 5.2-report | low | template fill |
| 5.3-summary | medium | качество summary критично — нужно мини-reasoning для извлечения insights |
| 5.4-progress-close | low | bash + JSON write |
| 5.5-tmux-close | low | bash one-liner |

### How to apply

**Inline coordinator** (фазы которые делает сам coordinator): перед стартом фазы установить thinking budget через API параметр или API call:
- low → отключить thinking или 1024 token budget
- medium → 4096 budget
- high → default (16K+)

**Subagent dispatch**: при запуске Agent() передавать effort через prompt:
```
Agent(subagent_type="...", effort="low", prompt="...")
```

Если subagent_type не поддерживает effort param напрямую — добавить в prompt:
```
## Reasoning budget
Use minimal thinking for this task. Goal: ${EFFORT_GOAL}.

low: skip thinking unless absolutely needed
medium: brief thinking on decisions, none on mechanics
high: full reasoning chain
```

### Anti-patterns

- НЕ повышать effort выше story-level (это нарушает `/run-stories` budget allocation).
- НЕ применять low effort к Phase 2.1 main implementation, даже если story простая — нужен code reasoning.
- НЕ применять low effort к Phase 3.4 corrective — это место где модель должна думать о root cause.
