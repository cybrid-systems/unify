#!/usr/bin/env bash
# Run a Unify .aura program against local Aura + span libs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${AURA_BIN:-}" ]]; then
  if [[ -x "$ROOT/../aura-grok/build/aura" ]]; then
    AURA_BIN="$ROOT/../aura-grok/build/aura"
  elif [[ -x "$ROOT/../aura/build/aura" ]]; then
    AURA_BIN="$ROOT/../aura/build/aura"
  else
    echo "error: aura binary not found; set AURA_BIN" >&2
    exit 1
  fi
fi

AURA_LIB="${AURA_LIB:-$ROOT/../aura-grok/lib}"
AETHER_LIB="${AETHER_LIB:-$ROOT/../aether/lib}"
HEPH_LIB="${HEPH_LIB:-$ROOT/../hephaestus/lib}"
PROM_LIB="${PROM_LIB:-$ROOT/../prometheus/lib}"
HERMES_LIB="${HERMES_LIB:-$ROOT/../hermes/lib}"
UNIFY_LIB="${UNIFY_LIB:-$ROOT/lib}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: not executable: $AURA_BIN" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <file.aura>" >&2
  exit 1
fi

SRC="$1"
if [[ ! -f "$SRC" ]]; then
  echo "error: not found: $SRC" >&2
  exit 1
fi

# MiniMax-M3 is the only allowed live model for Unify.
if [[ -n "${LLM_API_KEY:-}" ]]; then
  export LLM_MODEL="${LLM_MODEL:-MiniMax-M3}"
  export LLM_BASE_URL="${LLM_BASE_URL:-https://api.minimaxi.com/v1}"
fi

export AURA_BIN
export AURA_PATH="${AURA_PATH:-$AURA_LIB:$AETHER_LIB:$HEPH_LIB:$PROM_LIB:$HERMES_LIB:$UNIFY_LIB}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"

echo "[unify] AURA_BIN=$AURA_BIN"
echo "[unify] AURA_PATH=$AURA_PATH"
echo "[unify] running: $SRC"

exec "$AURA_BIN" < "$SRC"
