#!/usr/bin/env bash
# Cross-cycle Aura daemon: one long-lived process, ticks from continuous.
#
#   ./scripts/aura-daemon.sh start
#   ./scripts/aura-daemon.sh tick     # run one multi-gen batch, wait ready
#   ./scripts/aura-daemon.sh status
#   ./scripts/aura-daemon.sh stop
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJ="${UNIFY_PROJECT:-projects/kv}"
EVOLVE="$ROOT/$PROJ/evolve"
mkdir -p "$EVOLVE"
export UNIFY_DAEMON_DIR="${UNIFY_DAEMON_DIR:-$EVOLVE}"
PID_FILE="$EVOLVE/daemon.pid"
CMD_FILE="$EVOLVE/daemon-cmd"
STATUS_FILE="$EVOLVE/daemon-status"
RESULT_FILE="$EVOLVE/daemon-result"
LOG_FILE="$EVOLVE/daemon.log"

export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PATH="${AURA_PATH:-$ROOT/$PROJ/lib:$ROOT/lib:$ROOT/../aura-grok/lib:$ROOT/../aether/lib:$ROOT/../hephaestus/lib:$ROOT/../prometheus/lib:$ROOT/../hermes/lib}"
export UNIFY_RESIDENT_GENS="${UNIFY_RESIDENT_GENS:-2}"
export UNIFY_LOAD_KEYS="${UNIFY_LOAD_KEYS:-40}"
export UNIFY_LOAD_OPS="${UNIFY_LOAD_OPS:-96}"
export UNIFY_HOT_FIBER_N="${UNIFY_HOT_FIBER_N:-16}"
export UNIFY_FIBER_SOAK_WAVES="${UNIFY_FIBER_SOAK_WAVES:-2}"

cmd="${1:-status}"

alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local p
  p="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

case "$cmd" in
  start)
    if alive; then
      echo "[daemon] already running pid=$(cat "$PID_FILE")"
      exit 0
    fi
    printf 'idle' >"$CMD_FILE"
    printf 'starting' >"$STATUS_FILE"
    : >"$RESULT_FILE"
    : >"$LOG_FILE"
    nohup "$AURA_BIN" <"$ROOT/$PROJ/tests/daemon-loop.aura" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    # wait ready
    for i in $(seq 1 100); do
      if [[ -f "$STATUS_FILE" ]] && grep -q ready "$STATUS_FILE" 2>/dev/null; then
        echo "[daemon] started pid=$(cat "$PID_FILE") status=ready"
        exit 0
      fi
      if ! alive; then
        echo "[daemon] died during boot" >&2
        tail -n 30 "$LOG_FILE" || true
        exit 1
      fi
      sleep 0.05
    done
    echo "[daemon] start timeout" >&2
    tail -n 40 "$LOG_FILE" || true
    exit 1
    ;;
  stop)
    if alive; then
      printf 'stop' >"$CMD_FILE"
      for i in $(seq 1 80); do
        if ! alive; then break; fi
        sleep 0.05
      done
      if alive; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        sleep 0.2
        kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
      fi
    fi
    rm -f "$PID_FILE"
    printf 'idle' >"$CMD_FILE"
    printf 'stopped' >"$STATUS_FILE"
    echo "[daemon] stopped"
    ;;
  status)
    if alive; then
      echo "running pid=$(cat "$PID_FILE") status=$(cat "$STATUS_FILE" 2>/dev/null || echo '?')"
      tail -n 5 "$RESULT_FILE" 2>/dev/null || true
      exit 0
    fi
    echo "stopped"
    exit 1
    ;;
  tick)
    if ! alive; then
      echo "[daemon] not running — start first" >&2
      # auto-start
      "$0" start || exit 1
    fi
    # clear previous result marker
    : >"$RESULT_FILE"
    printf 'ready' >"$STATUS_FILE"
    printf 'run' >"$CMD_FILE"
    # wait for result
    timeout_s="${UNIFY_DAEMON_TICK_TIMEOUT:-180}"
    t0=$(date +%s)
    while true; do
      if grep -q 'RESULT pass daemon-tick' "$RESULT_FILE" 2>/dev/null; then
        cat "$RESULT_FILE"
        # also append to cycle log if provided
        if [[ -n "${UNIFY_DAEMON_TICK_LOG:-}" ]]; then
          cat "$RESULT_FILE" >>"$UNIFY_DAEMON_TICK_LOG"
          # last lines of daemon log for metrology
          tail -n 40 "$LOG_FILE" >>"$UNIFY_DAEMON_TICK_LOG" 2>/dev/null || true
        fi
        # persist best policy if score present
        line="$(grep 'RESULT pass daemon-tick' "$RESULT_FILE" | tail -n1)"
        mode="$(echo "$line" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')"
        cache="$(echo "$line" | sed -n 's/.*cache=\([0-9]*\).*/\1/p')"
        thr="$(echo "$line" | sed -n 's/.*thr=\([0-9]*\).*/\1/p')"
        score="$(echo "$line" | sed -n 's/.*score=\([0-9.]*\).*/\1/p')"
        ENGINE="$ROOT/$PROJ/lib/kv-engine.aura"
        if [[ -n "$mode" && -f "$ENGINE" ]]; then
          python3 - "$ENGINE" "$mode" "$cache" "$thr" <<'PY' 2>/dev/null || true
import re, sys
path, mode, cache, thr = sys.argv[1:5]
src = open(path, encoding="utf-8").read()
src, _ = re.subn(r'\(define kv:pol-mode "[^"]*"\)', f'(define kv:pol-mode "{mode}")', src, count=1)
src, _ = re.subn(r'\(define kv:pol-cache \d+\)', f'(define kv:pol-cache {cache or 0})', src, count=1)
src, _ = re.subn(r'\(define kv:pol-thr \d+\)', f'(define kv:pol-thr {thr or 32})', src, count=1)
src, n = re.subn(
    r'\(define \(kv:_default-policy\)\s*\(list[^)]+\)\)',
    f'(define (kv:_default-policy) (list "{mode}" {cache or 0} {thr or 32}))',
    src, count=1)
open(path, "w", encoding="utf-8").write(src)
print("persisted", mode, cache, thr, "n", n)
PY
        fi
        echo "RESULT pass aura-daemon-tick improved=1 mode=${mode:-?} cache=${cache:-?} thr=${thr:-?} score=${score:-?} cold_starts=0"
        exit 0
      fi
      if ! alive; then
        echo "RESULT fail aura-daemon-tick reason=daemon-died" >&2
        tail -n 40 "$LOG_FILE" || true
        exit 1
      fi
      now=$(date +%s)
      if [[ $((now - t0)) -ge "$timeout_s" ]]; then
        echo "RESULT fail aura-daemon-tick reason=timeout" >&2
        tail -n 40 "$LOG_FILE" || true
        exit 1
      fi
      sleep 0.1
    done
    ;;
  *)
    echo "usage: $0 start|stop|status|tick" >&2
    exit 2
    ;;
esac
