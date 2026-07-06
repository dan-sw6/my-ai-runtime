#!/usr/bin/env bash
# rebuild-rtm.sh — wrapper around rebuild-rtm.py.
# Regenerates rtm.yaml (srs.rtm_path) from ao.story_dir/**/*.md + srs.srs_path.
# Status canonical = SRS; RTM = derived linkage view. DO NOT hand-edit rtm.yaml.
#
# OPTIONAL module: no-op when srs.enabled is false in runtime.config.yaml.
#
# Usage:
#   bash rebuild-rtm.sh              # rewrite rtm.yaml
#   bash rebuild-rtm.sh --audit      # diff vs current, exit 1 if drift
#   bash rebuild-rtm.sh --check      # exit 1 if rebuilt != current (CI gate)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../runtime-config-read.sh"
rcfg_bool srs.enabled || { echo "[srs] disabled — skipping"; exit 0; }

exec python3 "${SCRIPT_DIR}/rebuild-rtm.py" "$@"
