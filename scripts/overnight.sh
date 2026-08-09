#!/usr/bin/env bash
# Overnight / finite continuous synthesis (wrapper around run-continuous.sh).
#
# Default: 20 live rounds in one cycle then exit (legacy overnight shape).
# For forever loop: UNIFY_MAX_CYCLES=0 ./scripts/run-continuous.sh
#
# Issues: draft-only unless UNIFY_AUTO_ISSUE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export UNIFY_LIVE_N="${UNIFY_OVERNIGHT_N:-${UNIFY_LIVE_N:-20}}"
export UNIFY_MAX_CYCLES="${UNIFY_MAX_CYCLES:-1}"
export UNIFY_SLEEP_SEC="${UNIFY_SLEEP_SEC:-0}"
export UNIFY_OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-1}"
export UNIFY_LOG_ROOT="${UNIFY_LOG_DIR:-${UNIFY_LOG_ROOT:-$ROOT/logs/runs}}"

echo "[overnight] LIVE_N=$UNIFY_LIVE_N MAX_CYCLES=$UNIFY_MAX_CYCLES LOG_ROOT=$UNIFY_LOG_ROOT"
exec ./scripts/run-continuous.sh
