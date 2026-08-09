#!/usr/bin/env bash
# Keep evolve loop alive: if run-continuous dies (crash, OOM, reboot of child),
# restart from workspace state so evolution continues after network blips etc.
#
#   ./scripts/evolve-watchdog.sh          # foreground watchdog
#   nohup ./scripts/evolve-watchdog.sh &  # usually launched by evolve.sh
#
# Stops when logs/runs/WANT_RUN is removed (evolve.sh stop).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
mkdir -p "$LOG_ROOT"
WANT="$LOG_ROOT/WANT_RUN"
WD_LOG="$LOG_ROOT/watchdog.log"
WD_PID="$LOG_ROOT/watchdog.pid"
INTERVAL="${UNIFY_WATCHDOG_SEC:-60}"

echo $$ >"$WD_PID"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$WD_LOG"
}

is_loop_alive() {
  local pid_file="$LOG_ROOT/latest/pid"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Pull remote if behind (network recovery / multi-host) without destroying local evolve commits.
sync_workspace() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  # Only fetch when network likely available; ignore failures
  if ! git fetch origin main >/dev/null 2>&1; then
    log "sync: fetch failed (network?); continue with local workspace"
    return 0
  fi
  local behind ahead
  behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  if [[ "${behind:-0}" -gt 0 && "${ahead:-0}" -eq 0 ]]; then
    log "sync: ff-only pull origin/main (behind=$behind)"
    git merge --ff-only origin/main >>"$WD_LOG" 2>&1 || log "sync: ff-only failed"
  elif [[ "${behind:-0}" -gt 0 && "${ahead:-0}" -gt 0 ]]; then
    log "sync: diverged ahead=$ahead behind=$behind — keep local; push later"
  else
    log "sync: up to date (ahead=$ahead behind=$behind)"
  fi
}

start_loop() {
  log "restart: starting evolve loop from workspace"
  rm -f "$LOG_ROOT/STOP"
  # Prefer evolve.sh bg but avoid re-entering "already running"
  if is_loop_alive; then
    log "restart: loop already alive"
    return 0
  fi
  if [[ -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
    # shellcheck disable=SC1091
    source ./scripts/env-minimax.sh >>"$WD_LOG" 2>&1 || true
  fi
  export UNIFY_MAX_CYCLES="${UNIFY_MAX_CYCLES:-0}"
  export UNIFY_LIVE_N="${UNIFY_LIVE_N:-1}"
  export UNIFY_SLEEP_SEC="${UNIFY_SLEEP_SEC:-45}"
  export UNIFY_OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-5}"
  export UNIFY_AUTO_ISSUE="${UNIFY_AUTO_ISSUE:-1}"
  export UNIFY_PROJECT_EVOLVE="${UNIFY_PROJECT_EVOLVE:-1}"
  export UNIFY_PROJECT="${UNIFY_PROJECT:-projects/kv}"
  export UNIFY_DURABLE_EVOLVE="${UNIFY_DURABLE_EVOLVE:-0}"
  export UNIFY_GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
  export UNIFY_GIT_PUSH="${UNIFY_GIT_PUSH:-1}"
  export UNIFY_LLM_TIMEOUT="${UNIFY_LLM_TIMEOUT:-480}"
  export UNIFY_LLM_RETRIES="${UNIFY_LLM_RETRIES:-3}"
  export UNIFY_LLM_SRC_CHARS="${UNIFY_LLM_SRC_CHARS:-24000}"
  nohup ./scripts/run-continuous.sh >>"$LOG_ROOT/nohup.out" 2>&1 &
  log "restart: spawned run-continuous pid=$!"
  sleep 2
  if is_loop_alive; then
    log "restart: OK pid=$(cat "$LOG_ROOT/latest/pid" 2>/dev/null || echo '?')"
  else
    log "restart: FAILED to stay up — see $LOG_ROOT/nohup.out"
  fi
}

log "watchdog start pid=$$ interval=${INTERVAL}s want=$WANT"
touch "$WANT"

while [[ -f "$WANT" ]]; do
  if [[ -f "$LOG_ROOT/STOP" ]] && [[ ! -f "$WANT" ]]; then
    break
  fi
  # User asked stop: STOP present and WANT removed by evolve.sh stop
  if [[ ! -f "$WANT" ]]; then
    break
  fi
  if is_loop_alive; then
    : # ok
  else
    log "loop dead — recovering from workspace (project state kept)"
    sync_workspace
    # Clear stale STOP if we still want to run (crash left STOP? only if WANT exists)
    if [[ -f "$WANT" ]]; then
      rm -f "$LOG_ROOT/STOP"
      start_loop
    fi
  fi
  sleep "$INTERVAL"
done

log "watchdog exit (WANT_RUN removed)"
rm -f "$WD_PID"
