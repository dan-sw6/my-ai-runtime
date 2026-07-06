#!/usr/bin/env bash
# write-review-json.sh — schema-safe writer for /run-stories B.1.5 review.json.
#
# The old "coordinator writes review.json via heredoc" pattern is bug-prone
# (this session: shift/positional bug → empty findings[]; Phase C report agent
# then scraped summary.md instead). This helper validates with jq so a
# malformed review.json fails loudly, not silently.
#
# Usage:
#   echo '<findings-json-array>' | \
#     scripts/write-review-json.sh STORY-345 approve solo-reviewer[,migration-reviewer] \
#       '<ac_verification-json-array>'
#
# - STORY-ID         : STORY-<id> (any case; dir uses lowercase id)
# - verdict          : pass|concerns|block|approve|changes_requested
# - agents-csv       : comma-separated agent names (default: solo-reviewer)
# - ac_verification  : optional JSON array arg (default: [])
# - findings (stdin) : JSON array; each {agent,category,severity,file,line,issue,status}
#
# Writes $(rcfg state_dir)/story-<id-lc>/review.json. Stdout: the path.
# Exit 2 if findings stdin or ac arg is not a valid JSON array.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime-config-read.sh"

SID_RAW="${1:?Usage: write-review-json.sh STORY-ID verdict [agents] [ac_json]}"
VERDICT="${2:?verdict required}"
AGENTS_CSV="${3:-solo-reviewer}"
AC_JSON="${4:-[]}"

SID_LC=$(echo "${SID_RAW#STORY-}" | tr '[:upper:]' '[:lower:]')
STATE_DIR="$(rcfg state_dir /tmp/claude-workers)"
DIR="${STATE_DIR}/story-${SID_LC}"
mkdir -p "${DIR}"
OUT="${DIR}/review.json"

FINDINGS=$(cat 2>/dev/null || echo '[]')
[[ -z "${FINDINGS// }" ]] && FINDINGS='[]'

if ! echo "${FINDINGS}" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "ERROR: findings (stdin) is not a JSON array" >&2
  exit 2
fi
if ! echo "${AC_JSON}" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "ERROR: ac_verification arg is not a JSON array" >&2
  exit 2
fi

AGENTS_JSON=$(printf '%s' "${AGENTS_CSV}" | jq -R 'split(",")')
TS=$(date -Is)

jq -n \
  --arg story "STORY-${SID_LC}" \
  --arg ts "${TS}" \
  --arg verdict "${VERDICT}" \
  --argjson agents "${AGENTS_JSON}" \
  --argjson findings "${FINDINGS}" \
  --argjson ac "${AC_JSON}" \
  '{
    story: $story, ts: $ts, agents: $agents,
    overall_verdict: $verdict,
    blocking_count: ([$findings[] | select(.severity=="high" or .severity=="critical")] | length),
    followup_count:  ([$findings[] | select(.severity=="medium" or .severity=="low")]      | length),
    findings: $findings,
    ac_verification: $ac
  }' > "${OUT}" || { echo "ERROR: jq failed to build review.json" >&2; exit 2; }

# Final validity assertion — never leave a malformed file.
jq -e '.story and .overall_verdict and (.findings|type=="array")' "${OUT}" >/dev/null 2>&1 \
  || { echo "ERROR: produced review.json failed validation" >&2; exit 2; }

echo "${OUT}"
