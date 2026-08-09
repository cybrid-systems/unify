#!/usr/bin/env bash
# Unify 自进化控制环入口（multi-cand sandbox + durable commit）
#
#   ./scripts/evolve.sh          # 后台跑
#   ./scripts/evolve.sh fg       # 前台跑（Ctrl-C 停）
#   ./scripts/evolve.sh stop     # 优雅停止
#   ./scripts/evolve.sh status   # 看状态
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cmd="${1:-bg}"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
mkdir -p "$LOG_ROOT"

case "$cmd" in
  stop)
    touch "$LOG_ROOT/STOP"
    if [[ -f "$LOG_ROOT/latest/pid" ]]; then
      pid="$(cat "$LOG_ROOT/latest/pid")"
      if kill -0 "$pid" 2>/dev/null; then
        echo "stopping pid=$pid (STOP file set; exits after current cycle)"
        exit 0
      fi
    fi
    echo "no running continuous process (STOP file written)"
    exit 0
    ;;
  status)
    exec ./scripts/status.sh
    ;;
  fg|foreground)
    rm -f "$LOG_ROOT/STOP"
    if [[ -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
      # shellcheck disable=SC1091
      source ./scripts/env-minimax.sh
    else
      echo "warn: no MiniMax key — live rounds use force-body offline path"
    fi
    export UNIFY_MAX_CYCLES="${UNIFY_MAX_CYCLES:-0}"
    export UNIFY_LIVE_N="${UNIFY_LIVE_N:-2}"
    export UNIFY_SLEEP_SEC="${UNIFY_SLEEP_SEC:-30}"
    export UNIFY_OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-3}"
    export UNIFY_AUTO_ISSUE="${UNIFY_AUTO_ISSUE:-1}"
    export UNIFY_SELF_EVOLVE="${UNIFY_SELF_EVOLVE:-0}"
    export UNIFY_PROJECT_EVOLVE="${UNIFY_PROJECT_EVOLVE:-1}"
    export UNIFY_PROJECT="${UNIFY_PROJECT:-projects/kv}"
    export UNIFY_DURABLE_EVOLVE="${UNIFY_DURABLE_EVOLVE:-0}"
    export UNIFY_GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
    export UNIFY_GIT_PUSH="${UNIFY_GIT_PUSH:-1}"
    echo "unify evolve (fg) project=$UNIFY_PROJECT commit=$UNIFY_GIT_COMMIT push=$UNIFY_GIT_PUSH"
    exec ./scripts/run-continuous.sh
    ;;
  bg|start|"")
    # stop previous if any
    if [[ -f "$LOG_ROOT/latest/pid" ]]; then
      old="$(cat "$LOG_ROOT/latest/pid")"
      if kill -0 "$old" 2>/dev/null; then
        echo "already running pid=$old — use: $0 status | $0 stop"
        exit 0
      fi
    fi
    rm -f "$LOG_ROOT/STOP"
    if [[ -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
      # shellcheck disable=SC1091
      source ./scripts/env-minimax.sh
    else
      echo "warn: no MiniMax key — live rounds use force-body offline path"
    fi
    export UNIFY_MAX_CYCLES="${UNIFY_MAX_CYCLES:-0}"
    export UNIFY_LIVE_N="${UNIFY_LIVE_N:-1}"
    export UNIFY_SLEEP_SEC="${UNIFY_SLEEP_SEC:-45}"
    export UNIFY_OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-5}"
    export UNIFY_AUTO_ISSUE="${UNIFY_AUTO_ISSUE:-1}"
    export UNIFY_SELF_EVOLVE="${UNIFY_SELF_EVOLVE:-0}"
    export UNIFY_PROJECT_EVOLVE="${UNIFY_PROJECT_EVOLVE:-1}"
    export UNIFY_PROJECT="${UNIFY_PROJECT:-projects/kv}"
    export UNIFY_DURABLE_EVOLVE="${UNIFY_DURABLE_EVOLVE:-0}"
    export UNIFY_GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
    export UNIFY_GIT_PUSH="${UNIFY_GIT_PUSH:-1}"
    nohup ./scripts/run-continuous.sh >>"$LOG_ROOT/nohup.out" 2>&1 &
    pid=$!
    sleep 1
    echo "evolve running pid=$pid"
    echo "  project-level: $UNIFY_PROJECT (SPEC+tests+LLM patch+commit+push)"
    echo "  status:  $0 status"
    echo "  logs:    tail -f logs/runs/latest/master.log"
    echo "  kv tests: AURA_PATH=projects/kv/lib:lib ./scripts/run-aura.sh projects/kv/tests/smoke.aura"
    echo "  stop:    $0 stop"
    ./scripts/status.sh 2>/dev/null | head -n 16 || true
    ;;
  *)
    echo "usage: $0 [bg|fg|stop|status]" >&2
    exit 2
    ;;
esac
