#!/usr/bin/env bash
# preflight-gate.sh STORY-ID [--skip-fetch] [--skip-cbm] [--allow-stale-ref]
#
# Pre-launch readiness checks for a story. Catches obviously-doomed runs
# (missing files_affected, stale base ref, malformed frontmatter, dead worker
# already running) BEFORE the launcher spends $4-7 of budget on them.
#
# Output: JSON {pass,reason,details,checks} on stdout.
# Exit 0 on pass, 1 on fail (matches worktree-gate.sh contract).
set -uo pipefail

STORY_ID="${1:?Usage: $0 STORY-ID [--skip-fetch] [--skip-cbm] [--allow-stale-ref]}"
shift || true
SKIP_FETCH=0
SKIP_CBM=0
ALLOW_STALE_REF=0
WORKER_MODE="tmux"  # tmux | agent — controls how active-worker is detected (PID file vs running.json marker)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-fetch) SKIP_FETCH=1 ;;
    --skip-cbm) SKIP_CBM=1 ;;
    --allow-stale-ref) ALLOW_STALE_REF=1 ;;
    --worker-mode) WORKER_MODE="$2"; shift ;;
    --worker-mode=*) WORKER_MODE="${1#--worker-mode=}" ;;
    *) printf '{"pass":false,"reason":"unknown-arg","details":"%s"}\n' "$1"; exit 1 ;;
  esac
  shift
done
case "$WORKER_MODE" in
  tmux|agent) ;;
  *) printf '{"pass":false,"reason":"invalid-worker-mode","details":"%s"}\n' "$WORKER_MODE"; exit 1 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"pass":false,"reason":"not-a-git-repo"}'
  exit 1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

# Config-driven knobs (runtime.config.yaml, env-override via rcfg) — see
# config/runtime.config.example.yaml `ao:` block for defaults/docs.
BASE_REF="$(rcfg ao.base_ref main)"
MIG_DIR="$(rcfg ao.migrations_dir "")"
STORY_FILE="${REPO_ROOT}/$(rcfg ao.story_dir docs/stories)/${STORY_ID}.md"
ID_LC=$(echo "${STORY_ID#STORY-}" | tr '[:upper:]' '[:lower:]')
WORKER_DIR_LC="$(rcfg state_dir /tmp/claude-workers)/story-${ID_LC}"

CHECKS='{}'
mark() {
  local name="$1" status="$2" detail="${3:-}"
  if [[ -n "$detail" ]]; then
    CHECKS=$(jq --arg n "$name" --arg s "$status" --arg d "$detail" '.[$n]={status:$s,detail:$d}' <<< "$CHECKS")
  else
    CHECKS=$(jq --arg n "$name" --arg s "$status" '.[$n]={status:$s}' <<< "$CHECKS")
  fi
}
fail() {
  local reason="$1" details="${2:-}"
  jq -n --arg r "$reason" --arg d "$details" --argjson c "$CHECKS" \
    '{pass:false, reason:$r, details:$d, checks:$c}'
  exit 1
}
ok() {
  local details="${1:-all-checks-passed}"
  jq -n --arg d "$details" --argjson c "$CHECKS" \
    '{pass:true, reason:"preflight-ok", details:$d, checks:$c}'
  exit 0
}

# --- 1. story-file-exists ---
if [[ ! -f "$STORY_FILE" ]]; then
  mark "story-file-exists" fail "$STORY_FILE"
  fail "story-not-found" "$STORY_FILE"
fi
mark "story-file-exists" pass

# --- 2. frontmatter-parse ---
FM=$(bash "$SCRIPT_DIR/parse-story-frontmatter.sh" "$STORY_FILE" 2>/dev/null) || {
  mark "frontmatter-parse" fail "parser exit nonzero"
  fail "frontmatter-malformed" "parse-story-frontmatter.sh failed"
}
ERR=$(echo "$FM" | jq -r '.error // empty')
if [[ -n "$ERR" ]]; then
  mark "frontmatter-parse" fail "$ERR"
  fail "frontmatter-malformed" "$ERR"
fi
mark "frontmatter-parse" pass

# --- 3. story-status — must be draft(ed) or in_progress ---
# `drafted` is the canonical decompose-srs output; treat as actionable draft.
STATUS=$(echo "$FM" | jq -r '.status // "draft"')
case "$STATUS" in
  draft|drafted|in_progress)
    mark "story-status" pass "$STATUS" ;;
  *)
    mark "story-status" fail "$STATUS"
    fail "story-already-closed" "status=$STATUS" ;;
esac

# --- 4. ac-present — accept either frontmatter list OR body heading ---
AC_LEN=$(echo "$FM" | jq -r '(.acceptance_criteria // []) | length')
if [[ "$AC_LEN" == "0" ]]; then
  # Fallback: look for "## Acceptance Criteria" heading in body
  if grep -qiE '^##[[:space:]]+(acceptance criteria|критерии приёмки)' "$STORY_FILE"; then
    mark "ac-present" pass "body heading"
  else
    mark "ac-present" fail "no frontmatter list and no '## Acceptance Criteria' heading"
    fail "ac-empty" "story has neither acceptance_criteria frontmatter list nor '## Acceptance Criteria' heading"
  fi
else
  mark "ac-present" pass "$AC_LEN frontmatter items"
fi

# --- 5. files-affected-exist ---
FILES_RAW=$(echo "$FM" | jq -r '(.files_affected // []) | .[]')
MISSING=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Skip entries marked as future-created — worker creates them.
  # Match hints anywhere in the entry, not only in parentheses. Story specs often
  # use "NEW ..." or "00XX_..." placeholders before the exact file name exists.
  if echo "$f" | grep -qiE '(^|[^[:alnum:]_])(new|новый|новая|новое|skeleton)([^[:alnum:]_]|$)'; then
    continue
  fi
  # Migration placeholder entries (e.g. "00XX_add_foo.py") only make sense when
  # a migrations dir is configured (ao.migrations_dir); otherwise there's nothing to match against.
  if [[ -n "$MIG_DIR" ]] && echo "$f" | grep -qE "^${MIG_DIR}/(00XX|00NN)[^[:space:]]*"; then
    continue
  fi
  # Ellipsis entries are route/module hints, not literal filesystem paths:
  # "src/...", "routes/.../rbac roles", etc.
  if echo "$f" | grep -q '\.\.\.'; then
    continue
  fi
  # Skip glob/wildcard entries (e.g., "routes/**/*.py", "src/**/*.{ts,tsx}") — coverage hints, not exact paths
  if echo "$f" | grep -qE '\*|\{.*,.*\}'; then
    continue
  fi
  # Strip parenthetical hints (e.g., "  (new)") and trailing whitespace
  clean=$(echo "$f" | sed -E 's/[[:space:]]*\(.*$//; s/[[:space:]]+$//')
  # Keep only the first concrete path in descriptive alternatives/composite hints.
  # Examples:
  #   "foo.ts + bar.ts" -> "foo.ts"
  #   "foo.py или routes/core/foo.py" -> "foo.py"
  #   "foo.py / test_foo.py" -> "foo.py"
  clean="${clean%% + *}"
  clean="${clean%% или *}"
  clean="${clean%% or *}"
  clean="${clean%% / *}"
  clean=$(echo "$clean" | sed -E 's/[[:space:]]+$//')
  # Skip directory entries (ending with /) — they're contour markers
  [[ "$clean" == */ ]] && continue
  full="${REPO_ROOT}/${clean}"
  [[ -e "$full" ]] || MISSING+=("$clean")
done <<< "$FILES_RAW"
if (( ${#MISSING[@]} > 0 )); then
  joined=$(IFS=,; echo "${MISSING[*]}")
  if [[ "${PREFLIGHT_STRICT_FILES:-0}" == "1" ]]; then
    mark "files-affected-exist" fail "$joined"
    fail "missing-files-affected" "$joined"
  fi
  mark "files-affected-exist" warn "$joined"
else
  mark "files-affected-exist" pass
fi

# --- 6. no-active-worker — detection differs by mode ---
# tmux mode: kill -0 the pid file (background launcher process / pane PID)
# agent mode: presence of running.json marker (Agent harness owns lifecycle, no PID to ping)
if [[ "$WORKER_MODE" == "tmux" ]]; then
  if [[ -f "$WORKER_DIR_LC/pid" ]]; then
    PID=$(cat "$WORKER_DIR_LC/pid" 2>/dev/null || echo "")
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
      mark "no-active-worker" fail "pid=$PID"
      fail "worker-already-running" "pid=$PID at $WORKER_DIR_LC"
    fi
  fi
else  # agent mode
  if [[ -f "$WORKER_DIR_LC/running.json" ]]; then
    AGENT_NAME=$(jq -r '.agent_name // "unknown"' "$WORKER_DIR_LC/running.json" 2>/dev/null || echo "unknown")
    mark "no-active-worker" fail "agent=$AGENT_NAME"
    fail "worker-already-running" "agent=$AGENT_NAME at $WORKER_DIR_LC (remove running.json if abandoned)"
  fi
fi
mark "no-active-worker" pass

# --- 7. base-ref-fresh — local base ref vs origin ---
if (( ALLOW_STALE_REF == 0 )); then
  if (( SKIP_FETCH == 0 )); then
    git -C "$REPO_ROOT" fetch origin "$BASE_REF" --quiet 2>/dev/null || true
  fi
  LOCAL=$(git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF" 2>/dev/null || echo "")
  ORIGIN=$(git -C "$REPO_ROOT" rev-parse --verify "origin/$BASE_REF" 2>/dev/null || echo "")
  if [[ -n "$LOCAL" && -n "$ORIGIN" && "$LOCAL" != "$ORIGIN" ]]; then
    BEHIND=$(git -C "$REPO_ROOT" rev-list --count "${LOCAL}..${ORIGIN}" 2>/dev/null || echo "?")
    if [[ "$BEHIND" != "0" && "$BEHIND" != "?" ]]; then
      mark "base-ref-fresh" fail "behind=$BEHIND"
      fail "stale-base-ref" "local $BASE_REF is $BEHIND commits behind origin; run: git fetch origin $BASE_REF:$BASE_REF"
    fi
  fi
  mark "base-ref-fresh" pass "${LOCAL:0:8}"
else
  mark "base-ref-fresh" skip "explicit --allow-stale-ref"
fi

# --- 9. context-loaded — coordinator should inject context hits before launch ---
MEM_CTX="${WORKER_DIR_LC}/mem-context.json"
if [[ -f "$MEM_CTX" ]]; then
  N=$(jq -r '(.observations // []) | length' "$MEM_CTX" 2>/dev/null || echo 0)
  if [[ "$N" =~ ^[0-9]+$ ]] && (( N > 0 )); then
    mark "mem-context-loaded" pass "$N observations"
  else
    mark "mem-context-loaded" warn "file present but empty"
  fi
else
  mark "mem-context-loaded" warn "no mem-context.json — coordinator should run mem-search before launch"
fi

# --- 8. cbm-index-fresh — file-based signal (bash cannot query MCP directly) ---
# cbm is optional (runtime.config.yaml `cbm_project: ""` disables it entirely).
if (( SKIP_CBM == 1 )); then
  mark "cbm-index-fresh" skip "explicit --skip-cbm"
else
  PROJECT_KEY="$(rcfg cbm_project "")"
  if [[ -z "$PROJECT_KEY" ]]; then
    mark "cbm-index-fresh" skip "cbm_project not configured"
  elif [[ ! -x "$SCRIPT_DIR/cbm-freshness.sh" ]]; then
    mark "cbm-index-fresh" skip "cbm-freshness.sh not present"
  else
    CBM_STATUS=$(bash "$SCRIPT_DIR/cbm-freshness.sh" check "$PROJECT_KEY" --max-age=86400 2>/dev/null || echo '{"fresh":false}')
    CBM_FRESH=$(echo "$CBM_STATUS" | jq -r '.fresh')
    CBM_AGE=$(echo "$CBM_STATUS" | jq -r '.age_sec // "null"')
    if [[ "$CBM_FRESH" == "true" ]]; then
      mark "cbm-index-fresh" pass "age=${CBM_AGE}s"
    else
      mark "cbm-index-fresh" fail "age=${CBM_AGE}s (max=86400)"
      fail "cbm-stale" "cbm index is stale or never marked; coordinator must reindex (cbm:index_repository) and run cbm-freshness.sh mark"
    fi
  fi
fi

# --- 9b. db-liveness — if db_impact != none, ensure Postgres reachable (STORY-D17 lesson) ---
# postgres_ro ECONNREFUSED at Phase 1.5 cost a mid-flight manual stack start.
# Best-effort: if db-touching story and PG down, try to start the DB compose service (if
# configured); otherwise this check is fully optional and never blocks — emit skip so the
# coordinator knows to bring the stack up manually in Phase 0.
# TODO(coordinator): add `ao.db_compose_service` to runtime.config.yaml if auto-start via
# `docker compose up -d <service>` is desired for this product; empty/unset = skip auto-start.
DB_IMPACT=$(jq -r '.db_impact // "none"' <<< "$FM" 2>/dev/null || echo none)
if [[ "$DB_IMPACT" != "none" && "$DB_IMPACT" != "null" ]]; then
  if ! command -v pg_isready >/dev/null 2>&1; then
    mark "db-liveness" skip "pg_isready not available — cannot verify DB reachability"
  else
    PG_HOST="${PGHOST:-127.0.0.1}"; PG_PORT="${PGPORT:-5432}"
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; then
      mark "db-liveness" pass "pg_isready ${PG_HOST}:${PG_PORT}"
    else
      DB_COMPOSE_SERVICE="$(rcfg ao.db_compose_service "")"
      if [[ -n "$DB_COMPOSE_SERVICE" ]] && command -v docker >/dev/null 2>&1 && (cd "$REPO_ROOT" && docker compose up -d "$DB_COMPOSE_SERVICE" >/dev/null 2>&1); then
        sleep 4
        if pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; then
          mark "db-liveness" warn "PG was down — auto-started $DB_COMPOSE_SERVICE (verify migrations applied)"
        else
          mark "db-liveness" warn "PG down — docker compose up -d $DB_COMPOSE_SERVICE issued but not ready; coordinator must verify in Phase 0"
        fi
      else
        mark "db-liveness" skip "PG unreachable and no db_compose_service configured (db_impact=${DB_IMPACT}) — coordinator must ensure DB reachable"
      fi
    fi
  fi
else
  mark "db-liveness" skip "db_impact=none"
fi

# --- 10. migration-smoke — if story touches migrations, smoke-upgrade to head ---
# Triggers:
#   (a) any file in files_affected lives under ${MIG_DIR}
#   (b) runtime.json declares pre_flight_smokes contains "migrations_check"
#       (set by resolve-story-runtime.sh when frontmatter db_impact: migration)
# Default smoke target = `head` (catches drift bugs at the latest revision —
# 0001 default of migrations_check.sh is too shallow for stories that trog
# the head). Failure blocks story (reason=migration-smoke-failed).
# Entirely skipped when `ao.migrations_dir` is unset — no migrations dir means
# nothing to smoke-test.
if [[ -z "$MIG_DIR" ]]; then
  mark "migration-smoke" skip "ao.migrations_dir not configured"
elif [[ ! -d "$REPO_ROOT/$MIG_DIR" ]]; then
  mark "migration-smoke" skip "migrations dir not found: $MIG_DIR"
else
  NEEDS_MIG_SMOKE=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    clean=$(echo "$f" | sed -E 's/[[:space:]]*\(.*$//; s/[[:space:]]+$//')
    if [[ "$clean" == "$MIG_DIR"/* ]]; then
      NEEDS_MIG_SMOKE=1
      break
    fi
  done <<< "$FILES_RAW"
  RUNTIME_JSON="${WORKER_DIR_LC}/runtime.json"
  if (( NEEDS_MIG_SMOKE == 0 )) && [[ -f "$RUNTIME_JSON" ]]; then
    if jq -e '(.pre_flight_smokes // []) | index("migrations_check")' "$RUNTIME_JSON" >/dev/null 2>&1; then
      NEEDS_MIG_SMOKE=1
    fi
  fi
  if (( NEEDS_MIG_SMOKE == 1 )); then
    if [[ ! -x "$SCRIPT_DIR/migrations_check.sh" ]]; then
      mark "migration-smoke" skip "migrations_check.sh not present"
    else
      # Smoke-target adaptive:
      #   * MIGRATIONS_CHECK_DATABASE_URL set (real Postgres) → smoke to head
      #     (catches dialect-specific bugs — e.g. jsonb operator cast в 0078,
      #     ARRAY(SELECT…) в USING в 0079; именно эти ловили только на Postgres).
      #   * Otherwise → SQLite default (revision 0001). SQLite chokes mid-chain
      #     on `op.create_unique_constraint` без batch mode (NotImplementedError
      #     на 0002), поэтому глубокий smoke без Postgres физически не работает.
      #     Эмитим WARN, не block — структурная проверка single-head + baseline
      #     всё равно срабатывает.
      SMOKE_ARGS=()
      SMOKE_NOTE="sqlite-baseline-0001"
      if [[ -n "${MIGRATIONS_CHECK_DATABASE_URL:-}" ]]; then
        SMOKE_ARGS=(--smoke-revision head)
        SMOKE_NOTE="postgres-head"
      fi
      if ! MIG_LOG=$(bash "$SCRIPT_DIR/migrations_check.sh" "${SMOKE_ARGS[@]}" 2>&1); then
        mark "migration-smoke" fail "$SMOKE_NOTE"
        fail "migration-smoke-failed" "$(echo "$MIG_LOG" | tail -5 | tr '\n' ';')"
      fi
      if [[ "$SMOKE_NOTE" == "postgres-head" ]]; then
        mark "migration-smoke" pass "$SMOKE_NOTE"
      else
        mark "migration-smoke" warn "$SMOKE_NOTE — export MIGRATIONS_CHECK_DATABASE_URL=postgres://... for head smoke"
      fi
    fi
  else
    mark "migration-smoke" skip "no migration files in files_affected"
  fi
fi

# --- 11. migration-head-freshness — WARN if story body cites stale revision ---
# Сравнивает revision-id'ы, упомянутые в story body (русский «миграция 0076»
# и английский «migration 0076»), с реальным max numeric prefix
# в ${MIG_DIR}/*.py. Mismatch → WARN, не block —
# story spec мог замёрзнуть во времени, но AC всё равно валидны.
# Entirely skipped when `ao.migrations_dir` is unset (same condition as check 10).
if [[ -z "$MIG_DIR" ]]; then
  mark "migration-head-freshness" skip "ao.migrations_dir not configured"
elif [[ ! -d "$REPO_ROOT/$MIG_DIR" ]]; then
  mark "migration-head-freshness" skip "migrations dir not found: $MIG_DIR"
else
  HEAD_REV=$(find "$REPO_ROOT/$MIG_DIR" -maxdepth 1 -name '*.py' -printf '%f\n' 2>/dev/null \
    | sed -E 's|^([0-9]+)_.*|\1|' \
    | grep -E '^[0-9]+$' \
    | sort -n \
    | tail -1)
  SPEC_REVS=$(grep -oiE '\b(миграц[а-яё]+|migration)[[:space:]_-]+[0-9]{4}\b' "$STORY_FILE" 2>/dev/null \
    | grep -oE '[0-9]{4}' \
    | sort -u)
  STALE_REVS=()
  if [[ -n "$HEAD_REV" && -n "$SPEC_REVS" ]]; then
    while IFS= read -r rev; do
      [[ -z "$rev" ]] && continue
      if (( 10#$rev < 10#$HEAD_REV )); then
        STALE_REVS+=("$rev")
      fi
    done <<< "$SPEC_REVS"
  fi
  if (( ${#STALE_REVS[@]} > 0 )); then
    joined=$(IFS=,; echo "${STALE_REVS[*]}")
    mark "migration-head-freshness" warn "spec=$joined head=$HEAD_REV"
    mkdir -p "$WORKER_DIR_LC"
    jq -n --arg head "$HEAD_REV" --arg story "$STORY_ID" \
          --argjson stale "$(printf '%s\n' "${STALE_REVS[@]}" | jq -R . | jq -s .)" \
          '{story:$story, head:$head, stale_revs_in_spec:$stale, note:"spec body cites old revision-ids; worker should target head"}' \
          > "$WORKER_DIR_LC/spec-bump.json" 2>/dev/null || true
  else
    mark "migration-head-freshness" pass "${HEAD_REV:-no-revs-detected}"
  fi
fi

# --- 12. schema-gap — verify field/model mentions in story body match реальную схему ---
# Helper file-system-грепит SQLAlchemy/Pydantic классы (cbm недоступен в worker
# bash-окружении). Поймал бы STORY-297 source_kind: AC говорил «поле X в модели Y»,
# но field в коде отсутствовал → mid-session full-stack rescue. Detection не идеален
# (rename'ы ломают), но catch-net до launch экономит ~30% бюджета.
# Product-specific helper — optional, skip cleanly if not synced into this repo.
if [[ -x "$SCRIPT_DIR/schema-gap-check.sh" ]]; then
  SCHEMA_GAP_OUT=$(bash "$SCRIPT_DIR/schema-gap-check.sh" "$STORY_ID" 2>/dev/null || echo '{"error":"helper-failed"}')
  SG_ERROR=$(echo "$SCHEMA_GAP_OUT" | jq -r '.error // empty')
  if [[ -n "$SG_ERROR" ]]; then
    mark "schema-gap" warn "helper-error:$SG_ERROR"
  else
    SG_BLOCKING=$(echo "$SCHEMA_GAP_OUT" | jq -r '.blocking')
    SG_COUNT_BLOCK=$(echo "$SCHEMA_GAP_OUT" | jq -r '.count_blocking')
    SG_COUNT_UNK=$(echo "$SCHEMA_GAP_OUT" | jq -r '.count_unknown')
    if [[ "$SG_BLOCKING" == "true" ]]; then
      SG_MISSING=$(echo "$SCHEMA_GAP_OUT" | jq -r '[.checked[] | select(.status=="missing") | "\(.model).\(.field)"] | join(",")')
      mark "schema-gap" fail "missing:$SG_MISSING"
      fail "schema-gap" "$SG_MISSING"
    elif (( SG_COUNT_UNK > 0 )); then
      SG_UNKNOWN=$(echo "$SCHEMA_GAP_OUT" | jq -r '[.checked[] | select(.status=="model-unknown") | "\(.model).\(.field)"] | join(",")')
      mark "schema-gap" warn "model-unknown:$SG_UNKNOWN"
    else
      mark "schema-gap" pass "${SG_COUNT_BLOCK:-0}-blocking,${SG_COUNT_UNK:-0}-unknown"
    fi
  fi
else
  mark "schema-gap" skip "schema-gap-check.sh not present"
fi

# --- 13. security-premise — WARN-only heuristic (devcycle-audit #4, 2026-05-29) ---
# STRUCTURAL checks above cannot catch a semantically-dangerous AC (STORY-439/NFR-SEC-009
# AC3: "remove manual filter" that was a distinct finer security layer → would have leaked).
# Surfaces remove-of-security patterns for HUMAN verification. NEVER blocking.
# Product-specific helper — optional, skip cleanly if not synced into this repo.
if [[ -x "$SCRIPT_DIR/security-premise-check.sh" ]]; then
  SEC_PREMISE=$(bash "$SCRIPT_DIR/security-premise-check.sh" "$STORY_ID" 2>/dev/null || echo '{"flagged":false}')
  if [[ "$(echo "$SEC_PREMISE" | jq -r '.flagged')" == "true" ]]; then
    SP_HITS=$(echo "$SEC_PREMISE" | jq -r '[.hits[] | "\(.verb)+\(.term)@L\(.line)"] | join(",")')
    mark "security-premise" warn "REMOVE-of-security pattern — HUMAN verify AC premise vs code before impl: $SP_HITS"
  else
    mark "security-premise" pass "no remove-of-security pattern"
  fi
else
  mark "security-premise" skip "security-premise-check.sh not present"
fi

ok "passed all blocking checks"
