#!/usr/bin/env bash
# MiniMax-M3 only — Unify fixed provider policy.
#
#   source ./scripts/env-minimax.sh
#   ./scripts/run-aura.sh examples/02-live-evolve/main.aura
#
# Key: ~/code/keys/minimax (raw token or KEY=value). Never prints secrets.

set -euo pipefail

KEY_FILE="${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}"
if [[ ! -f "$KEY_FILE" ]]; then
  echo "error: MiniMax key file not found: $KEY_FILE" >&2
  return 1 2>/dev/null || exit 1
fi

_raw="$(tr -d '\r\n' < "$KEY_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ "$_raw" == *=* ]]; then
  export LLM_API_KEY="${_raw#*=}"
else
  export LLM_API_KEY="$_raw"
fi
unset _raw

# Fixed — do not override to other providers in this repo.
export LLM_BASE_URL="https://api.minimaxi.com/v1"
export LLM_MODEL="MiniMax-M3"
export UNIFY_LIVE="${UNIFY_LIVE:-1}"

echo "env-minimax: LLM_MODEL=$LLM_MODEL LLM_BASE_URL=$LLM_BASE_URL UNIFY_LIVE=$UNIFY_LIVE key=set"
