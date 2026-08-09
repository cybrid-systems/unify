#!/usr/bin/env bash
# Unify self-evolution entry (project-level, LLM controller).
#
#   ./scripts/evolve.sh              # start loop + watchdog (resume-safe)
#   ./scripts/evolve.sh status
#   ./scripts/evolve.sh stop
#   ./scripts/evolve.sh resume       # same as start if dead; pull+restart
#   ./scripts/evolve.sh fg
#
# Resume: project state lives in projects/kv/ (lib, tests, evolve/state.json).
# Watchdog restarts run-continuous if the process dies; network blips are
# retried inside LLM controller + git push (non-fatal).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cmd="${1:-bg}"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
mkdir -p "$LOG_ROOT"
WANT="$LOG_ROOT/WANT_RUN"
WD_PID="$LOG_ROOT/watchdog.pid"

export_env() {
  if [[ -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
    # shellcheck disable=SC1091
    source ./scripts/env-minimax.sh
  else
    echo "warn: no MiniMax key — project-evolve needs LLM"
  fi
  export UNIFY_MAX_CYCLES="${UNIFY_MAX_CYCLES:-0}"
  export UNIFY_LIVE_N="${UNIFY_LIVE_N:-1}"
  export UNIFY_SLEEP_SEC="${UNIFY_SLEEP_SEC:-45}"
  export UNIFY_OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-5}"
  export UNIFY_AUTO_ISSUE="${UNIFY_AUTO_ISSUE:-1}"
  export UNIFY_SELF_EVOLVE="${UNIFY_SELF_EVOLVE:-0}"
  export UNIFY_PROJECT_EVOLVE="${UNIFY_PROJECT_EVOLVE:-1}"
  export UNIFY_PROJECT="${UNIFY_PROJECT:-projects/kv}"
  export UNIFY_LLM_TIMEOUT="${UNIFY_LLM_TIMEOUT:-480}"
  export UNIFY_LLM_RETRIES="${UNIFY_LLM_RETRIES:-3}"
  export UNIFY_LLM_SRC_CHARS="${UNIFY_LLM_SRC_CHARS:-24000}"
  export UNIFY_FIBER_STRESS="${UNIFY_FIBER_STRESS:-1}"
  export UNIFY_FIBER_N="${UNIFY_FIBER_N:-32}"
  export UNIFY_FIBER_KEYS="${UNIFY_FIBER_KEYS:-128}"
  export UNIFY_FIBER_WAVES="${UNIFY_FIBER_WAVES:-4}"
  export UNIFY_FIBER_BATCH="${UNIFY_FIBER_BATCH:-16}"
  export UNIFY_DURABLE_EVOLVE="${UNIFY_DURABLE_EVOLVE:-1}"
  export UNIFY_AURA_HOT="${UNIFY_AURA_HOT:-1}"
  export UNIFY_SQUEEZE="${UNIFY_SQUEEZE:-0}"
  export UNIFY_LLM_EVERY="${UNIFY_LLM_EVERY:-3}"
  export UNIFY_GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
  export UNIFY_GIT_PUSH="${UNIFY_GIT_PUSH:-1}"
  export UNIFY_WATCHDOG_SEC="${UNIFY_WATCHDOG_SEC:-60}"
}

loop_alive() {
  [[ -f "$LOG_ROOT/latest/pid" ]] || return 1
  local pid
  pid="$(cat "$LOG_ROOT/latest/pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

watchdog_alive() {
  [[ -f "$WD_PID" ]] || return 1
  local pid
  pid="$(cat "$WD_PID" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_watchdog() {
  if watchdog_alive; then
    echo "watchdog already running pid=$(cat "$WD_PID")"
    return 0
  fi
  nohup ./scripts/evolve-watchdog.sh >>"$LOG_ROOT/watchdog.log" 2>&1 &
  sleep 1
  if watchdog_alive; then
    echo "watchdog started pid=$(cat "$WD_PID") (restarts loop if it dies)"
  else
    echo "warn: watchdog failed to start — see $LOG_ROOT/watchdog.log" >&2
  fi
}

start_loop() {
  export_env
  touch "$WANT"
  rm -f "$LOG_ROOT/STOP"
  if loop_alive; then
    echo "loop already running pid=$(cat "$LOG_ROOT/latest/pid")"
  else
    nohup ./scripts/run-continuous.sh >>"$LOG_ROOT/nohup.out" 2>&1 &
    sleep 1
    if loop_alive; then
      echo "loop started pid=$(cat "$LOG_ROOT/latest/pid")"
    else
      echo "error: loop failed to start — see $LOG_ROOT/nohup.out" >&2
      return 1
    fi
  fi
  start_watchdog
  echo "  project: $UNIFY_PROJECT (state in workspace; survives restart)"
  echo "  plant:   adaptive in-mem KV — load-sim → retune index/cache (infinite)"
  echo "  fiber:   N=${UNIFY_FIBER_N} keys=${UNIFY_FIBER_KEYS} waves=${UNIFY_FIBER_WAVES:-4} batch=${UNIFY_FIBER_BATCH:-16} stress=${UNIFY_FIBER_STRESS}"
  echo "  LLM: 1 call/gen timeout=${UNIFY_LLM_TIMEOUT}s x${UNIFY_LLM_RETRIES}"
  echo "  status:  $0 status"
  echo "  stop:    $0 stop"
  ./scripts/status.sh 2>/dev/null | head -n 22 || true
}

case "$cmd" in
  stop)
    rm -f "$WANT"
    touch "$LOG_ROOT/STOP"
    if loop_alive; then
      echo "stopping loop pid=$(cat "$LOG_ROOT/latest/pid") (after current cycle)"
    else
      echo "loop not running"
    fi
    if watchdog_alive; then
      echo "stopping watchdog pid=$(cat "$WD_PID")"
      kill "$(cat "$WD_PID")" 2>/dev/null || true
      rm -f "$WD_PID"
    fi
    ;;
  status)
    exec ./scripts/status.sh "${2:-}"
    ;;
  resume)
    # Explicit resume: sync remote if possible, then ensure loop+watchdog
    echo "resume: ensure WANT_RUN + recover from workspace state"
    export_env
    if git fetch origin main >/dev/null 2>&1; then
      behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
      ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
      if [[ "${behind:-0}" -gt 0 && "${ahead:-0}" -eq 0 ]]; then
        echo "resume: ff-only pull origin/main"
        git merge --ff-only origin/main || true
      elif [[ "${ahead:-0}" -gt 0 ]]; then
        echo "resume: local ahead=$ahead — push will retry on accept"
        git push origin HEAD 2>/dev/null || echo "resume: push deferred (network?)"
      fi
    else
      echo "resume: offline — using local workspace only"
    fi
    start_loop
    ;;
  fg|foreground)
    export_env
    touch "$WANT"
    rm -f "$LOG_ROOT/STOP"
    # watchdog in background even for fg so crash recovery works if you Ctrl-Z etc.
    start_watchdog
    exec ./scripts/run-continuous.sh
    ;;
  bg|start|"")
    start_loop
    ;;
  *)
    echo "usage: $0 [bg|fg|stop|status|resume]" >&2
    exit 2
    ;;
esac
