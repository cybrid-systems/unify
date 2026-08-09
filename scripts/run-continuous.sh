#!/usr/bin/env bash
# Continuous Unify synthesis loop with structured logs.
#
# Cycle: offline (optional) → live evolve ×N → git host probe → issue drafts
# Runs until killed, UNIFY_MAX_CYCLES, or STOP file.
#
#   source ./scripts/env-minimax.sh   # optional; live rounds skipped if no key
#   ./scripts/run-continuous.sh
#
# Env:
#   UNIFY_LIVE_N          live rounds per cycle (default 5)
#   UNIFY_SLEEP_SEC       sleep between cycles (default 30)
#   UNIFY_MAX_CYCLES      0 = forever (default 0)
#   UNIFY_OFFLINE_EVERY   run full offline every K cycles (default 1)
#   UNIFY_LOG_ROOT        log root (default: <repo>/logs/runs)
#   UNIFY_AUTO_ISSUE      post host issues to cybrid-systems/aura
#                         (default 1 for continuous; denseness/llm never filed)
#   UNIFY_STOP_FILE       path; if exists, exit after current cycle
#   UNIFY_AURA_REPO       default cybrid-systems/aura
#
# Locate problems:
#   tail -f logs/runs/latest/master.log
#   tail -f logs/runs/latest/events.jsonl
#   ls logs/runs/latest/failures/
#   ./scripts/status.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIVE_N="${UNIFY_LIVE_N:-5}"
SLEEP_SEC="${UNIFY_SLEEP_SEC:-30}"
MAX_CYCLES="${UNIFY_MAX_CYCLES:-0}"
OFFLINE_EVERY="${UNIFY_OFFLINE_EVERY:-1}"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
STOP_FILE="${UNIFY_STOP_FILE:-$LOG_ROOT/STOP}"
# Continuous defaults to auto-filing host residuals (detailed body + dedupe).
export UNIFY_AUTO_ISSUE="${UNIFY_AUTO_ISSUE:-1}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$LOG_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR/failures" "$RUN_DIR/cycles"
ln -sfn "$RUN_DIR" "$LOG_ROOT/latest"
echo $$ >"$RUN_DIR/pid"
echo "$RUN_ID" >"$LOG_ROOT/latest-id"

MASTER="$RUN_DIR/master.log"
EVENTS="$RUN_DIR/events.jsonl"
SUMMARY="$RUN_DIR/SUMMARY.md"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  # shellcheck disable=SC2145
  local line="[$(ts)] $*"
  printf '%s\n' "$line" | tee -a "$MASTER"
}

# JSON-ish event line (no jq required). Values must not contain double quotes.
event() {
  local kind="$1"
  shift
  local pairs=("$@")
  local buf="{\"ts\":\"$(ts)\",\"kind\":\"$kind\""
  local i=0
  while [[ $i -lt ${#pairs[@]} ]]; do
    local k="${pairs[$i]}"
    local v="${pairs[$((i + 1))]:-}"
    v="${v//$'\n'/ }"
    v="${v//\"/\'}"
    buf+=",\"$k\":\"$v\""
    i=$((i + 2))
  done
  buf+="}"
  printf '%s\n' "$buf" >>"$EVENTS"
  log "event $kind $*"
}

have_minimax=0
if [[ -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
  # shellcheck disable=SC1091
  source ./scripts/env-minimax.sh
  have_minimax=1
else
  log "WARN no MiniMax key; live rounds will be force-body offline path only"
fi

{
  echo "# Unify continuous run \`$RUN_ID\`"
  echo
  echo "| field | value |"
  echo "|-------|-------|"
  echo "| started | $(ts) |"
  echo "| pid | $$ |"
  echo "| LIVE_N | $LIVE_N |"
  echo "| SLEEP_SEC | $SLEEP_SEC |"
  echo "| MAX_CYCLES | $MAX_CYCLES |"
  echo "| OFFLINE_EVERY | $OFFLINE_EVERY |"
  echo "| minimax | $have_minimax |"
  echo "| AUTO_ISSUE | ${UNIFY_AUTO_ISSUE:-0} |"
  echo
  echo "## How to inspect"
  echo
  echo '```bash'
  echo "tail -f $MASTER"
  echo "tail -f $EVENTS"
  echo "ls $RUN_DIR/failures"
  echo "./scripts/status.sh"
  echo '```'
  echo
  echo "## Cycles"
  echo
} >"$SUMMARY"

total_ok=0
total_fail=0
total_host=0
cycle=0

# On any step failure: classify log → detailed draft → file host to Aura.
file_failure() {
  local label="$1"
  local logf="$2"
  local cmd="$3"
  local fail_copy="$RUN_DIR/failures/cycle$(printf '%04d' "$cycle")-${label}.log"
  cp -f "$logf" "$fail_copy" 2>/dev/null || true

  local out class fp url=""
  out="$(mktemp)"
  set +e
  ./scripts/file-aura-issue.sh \
    --log "$logf" \
    --label "c${cycle}-${label}" \
    --cmd "$cmd" \
    --notes "Continuous run_id=\`$RUN_ID\` cycle=$cycle step=\`$label\`. See also \`$fail_copy\`." \
    >"$out" 2>&1
  local frc=$?
  set -e
  cat "$out" | while IFS= read -r line; do log "  issue| $line"; done || true

  class="$(grep -E '^class=' "$out" | tail -n1 | sed 's/^class=//;s/ fingerprint=.*//')" || class=""
  fp="$(grep -E 'fingerprint=' "$out" | tail -n1 | sed 's/.*fingerprint=//;s/ title=.*//')" || fp=""
  url="$(grep -E '^(created|skip):' "$out" | tail -n1 | sed 's/^created: //;s/^skip: already filed //;s/^skip: open\/existing issue //;s/^skip: meta has url //')" || url=""

  if [[ "$class" == "host" ]]; then
    total_host=$((total_host + 1))
    event host_flag label "$label" fingerprint "$fp" url "$url" rc "$frc"
  else
    event fail_classified label "$label" class "${class:-unknown}" fingerprint "$fp" rc "$frc"
  fi
  rm -f "$out"
}

run_step() {
  local name="$1"
  local cmd="$2"
  local expect="$3"
  local logf="$4"
  local t0 t1 rc=0
  t0=$(date +%s)
  log "STEP start name=$name log=$logf"
  set +e
  bash -c "$cmd" >"$logf" 2>&1
  rc=$?
  set -e
  t1=$(date +%s)
  local dur=$((t1 - t0))
  local result="fail"
  if [[ $rc -eq 0 ]] && grep -qE "$expect" "$logf" 2>/dev/null; then
    result="pass"
    total_ok=$((total_ok + 1))
  else
    total_fail=$((total_fail + 1))
    log "STEP fail name=$name → classify + maybe file Aura issue"
    file_failure "$name" "$logf" "$cmd"
  fi
  event step name "$name" result "$result" rc "$rc" dur_s "$dur" log "$logf"
  log "STEP end name=$name result=$result rc=$rc dur=${dur}s"
  if [[ "$result" != "pass" ]]; then
    log "--- tail $name ---"
    tail -n 20 "$logf" | while IFS= read -r line; do log "  | $line"; done || true
  fi
  [[ "$result" == "pass" ]]
}

log "START run_id=$RUN_ID dir=$RUN_DIR pid=$$"
event start run_id "$RUN_ID" pid "$$" live_n "$LIVE_N" sleep "$SLEEP_SEC"

while true; do
  if [[ -f "$STOP_FILE" ]]; then
    log "STOP file present: $STOP_FILE — exiting after graceful check"
    event stop reason "stop_file"
    break
  fi
  if [[ "$MAX_CYCLES" -gt 0 && "$cycle" -ge "$MAX_CYCLES" ]]; then
    log "MAX_CYCLES=$MAX_CYCLES reached"
    event stop reason "max_cycles" cycle "$cycle"
    break
  fi
  cycle=$((cycle + 1))

  cdir="$RUN_DIR/cycles/$(printf '%04d' "$cycle")"
  mkdir -p "$cdir"
  log "======== CYCLE $cycle begin ========"
  event cycle_begin cycle "$cycle" dir "$cdir"
  c_ok=0
  c_fail=0

  # Offline every OFFLINE_EVERY cycles (always on cycle 1)
  if (( cycle % OFFLINE_EVERY == 0 || cycle == 1 )); then
    if run_step "offline" \
      "./scripts/run-offline.sh" \
      "RESULT pass example=01-offline-compose" \
      "$cdir/offline.log"; then
      c_ok=$((c_ok + 1))
    else
      c_fail=$((c_fail + 1))
    fi
  else
    log "skip offline (OFFLINE_EVERY=$OFFLINE_EVERY)"
  fi

  # Live evolve rounds
  for i in $(seq 1 "$LIVE_N"); do
    # With key: live path; without: still run force-body via unset live is wrong —
    # env-minimax sets UNIFY_LIVE=1; if no key, run-aura offline path works when UNIFY_LIVE unset.
    local_cmd="./scripts/run-aura.sh examples/02-live-evolve/main.aura"
    if run_step "live-$(printf '%03d' "$i")" \
      "$local_cmd" \
      "RESULT pass example=02-live-evolve" \
      "$cdir/live-$(printf '%03d' "$i").log"; then
      c_ok=$((c_ok + 1))
    else
      c_fail=$((c_fail + 1))
    fi
  done

  # Git host probe
  if run_step "git-probe" \
    "./scripts/run-aura.sh examples/03-git-host-probe/main.aura" \
    "RESULT pass example=03-git-host-probe" \
    "$cdir/git-probe.log"; then
    c_ok=$((c_ok + 1))
  else
    c_fail=$((c_fail + 1))
  fi

  {
    echo "### cycle $cycle — $(ts)"
    echo
    echo "- ok=$c_ok fail=$c_fail cumulative_ok=$total_ok cumulative_fail=$total_fail host_flags=$total_host"
    echo "- dir: \`$cdir\`"
    if [[ "$c_fail" -gt 0 ]]; then
      echo "- **has failures** → see \`failures/\` and \`$cdir\`"
    fi
    echo
  } >>"$SUMMARY"

  printf 'cycle=%s ok=%s fail=%s total_ok=%s total_fail=%s host=%s\n' \
    "$cycle" "$c_ok" "$c_fail" "$total_ok" "$total_fail" "$total_host" \
    >"$RUN_DIR/status.txt"

  event cycle_end cycle "$cycle" ok "$c_ok" fail "$c_fail" \
    total_ok "$total_ok" total_fail "$total_fail" host "$total_host"
  log "======== CYCLE $cycle end ok=$c_ok fail=$c_fail ========"

  if [[ -f "$STOP_FILE" ]]; then
    log "STOP file seen after cycle"
    event stop reason "stop_file_after_cycle"
    break
  fi

  log "sleep ${SLEEP_SEC}s"
  sleep "$SLEEP_SEC"
done

log "DONE total_ok=$total_ok total_fail=$total_fail host=$total_host cycles=$cycle"
event done total_ok "$total_ok" total_fail "$total_fail" host "$total_host" cycles "$cycle"
{
  echo
  echo "## Finished"
  echo
  echo "- ended: $(ts)"
  echo "- cycles: $cycle"
  echo "- total_ok: $total_ok"
  echo "- total_fail: $total_fail"
  echo "- host_flags: $total_host"
} >>"$SUMMARY"

# Clear pid marker on clean exit
rm -f "$RUN_DIR/pid"
exit 0
