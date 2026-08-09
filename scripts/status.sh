#!/usr/bin/env bash
# Human-friendly evolve progress (default). Use --verbose for raw logs.
#
#   ./scripts/evolve.sh status
#   ./scripts/status.sh --verbose
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
LATEST="$LOG_ROOT/latest"
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

python3 - "$ROOT" "$LOG_ROOT" "$LATEST" "$VERBOSE" <<'PY'
import json, os, re, sys, time
from pathlib import Path

root, log_root, latest, verbose = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4])

def read_json(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

def short(s, n=100):
    s = re.sub(r"[*_`#]+", "", (s or "").strip())
    s = re.sub(r"\s+", " ", s)
    return s if len(s) <= n else s[: n - 1] + "…"

def age(path: Path) -> str:
    try:
        sec = max(0, int(time.time() - path.stat().st_mtime))
    except Exception:
        return "?"
    if sec < 60:
        return f"{sec}s ago"
    if sec < 3600:
        return f"{sec // 60}m ago"
    return f"{sec // 3600}h ago"

# ── Process ──────────────────────────────────────────────────────────────
run_dir = None
if latest.exists() or latest.is_symlink():
    try:
        run_dir = latest.resolve()
    except Exception:
        run_dir = Path(os.path.realpath(latest))

pid = None
alive = False
if run_dir and (run_dir / "pid").is_file():
    try:
        pid = int((run_dir / "pid").read_text().strip())
        os.kill(pid, 0)
        alive = True
    except Exception:
        alive = False

print("Unify evolve")
print("────────────")
if alive:
    print(f"  loop     RUNNING  pid={pid}")
elif pid:
    print(f"  loop     STOPPED  (stale pid={pid})")
else:
    print("  loop     STOPPED  (no pid — start with: ./scripts/evolve.sh)")

if (log_root / "STOP").is_file():
    print("  note     STOP requested (exits after current cycle)")

# cycle status
cycle_line = ""
if run_dir and (run_dir / "status.txt").is_file():
    cycle_line = (run_dir / "status.txt").read_text().strip()
current = "idle / between steps"
cycle_now = None
if run_dir and (run_dir / "events.jsonl").is_file():
    lines = (run_dir / "events.jsonl").read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines[-60:]:
        try:
            e = json.loads(line)
        except Exception:
            continue
        kind = e.get("kind")
        if kind == "cycle_begin":
            cycle_now = e.get("cycle")
            current = f"cycle {cycle_now} running"
        if kind == "cycle_end":
            cycle_now = e.get("cycle")
            current = f"cycle {cycle_now} done (ok={e.get('ok')} fail={e.get('fail')})"
            if (run_dir / "status.txt").is_file():
                cycle_line = (run_dir / "status.txt").read_text().strip()
        if kind == "step":
            name, res = e.get("name"), e.get("result")
            if res:
                current = f"last: {name} → {res}"
    # if last event is step start only — master may be mid project-evolve
    master = run_dir / "master.log"
    if master.is_file():
        mt = master.read_text(encoding="utf-8", errors="replace").splitlines()
        for line in reversed(mt[-30:]):
            if "STEP start name=" in line:
                m = re.search(r"STEP start name=(\S+)", line)
                if m:
                    # check if ended
                    name = m.group(1)
                    ended = any(
                        f"STEP end name={name}" in x for x in mt[-15:]
                    )
                    if not ended:
                        current = f"running: {name}"
                break
            if "sleep " in line and "s" in line:
                current = line.split("] ", 1)[-1].strip()
                break

if cycle_now is not None and (not cycle_line or f"cycle={cycle_now}" not in cycle_line.replace(" ","")):
    # mid-cycle: status.txt only updates at cycle_end
    cycle_line = f"cycle={cycle_now} (in progress)"
print(f"  activity {current}")
if cycle_line:
    print(f"  cycle    {cycle_line}")
if run_dir:
    print(f"  run      {run_dir.name}  (logs {age(run_dir / 'master.log') if (run_dir / 'master.log').is_file() else '?'})")

# ── Project (primary) ────────────────────────────────────────────────────
kv_state = root / "projects/kv/evolve/state.json"
print()
print("Project  projects/kv")
print("────────────────────")
st = read_json(kv_state)
if not st:
    print("  (no evolve state yet)")
else:
    gen = st.get("generation", 0)
    bs, bt = st.get("best_score", 0), st.get("best_total", 0)
    status = st.get("status", "?")
    pct = f"{100 * bs // bt}%" if bt else "—"
    bar_n = 20
    filled = int(bar_n * bs / bt) if bt else 0
    bar = "█" * filled + "░" * (bar_n - filled)
    print(f"  score    {bs}/{bt}  [{bar}] {pct}")
    print(f"  gen      {gen}   status={status}   updated={st.get('updated', '—')}")
    # last history
    hist = st.get("history") or []
    if hist:
        h = hist[-1]
        acc = "accept" if h.get("accepted") else "reject"
        print(f"  last     gen {h.get('generation')}  {acc}  {h.get('baseline')} → {h.get('candidate')}  ({h.get('reason')})")
    direction = (st.get("last_direction") or "").strip()
    if not direction:
        rev = root / "projects/kv/evolve/last-review.md"
        if rev.is_file():
            text = rev.read_text(encoding="utf-8", errors="replace")
            if "# DIRECTION" in text:
                direction = text.split("# DIRECTION", 1)[-1].strip()
    if direction:
        # first meaningful line
        for line in direction.splitlines():
            line = line.strip().lstrip("-* ")
            if line and not line.startswith("#"):
                print(f"  plan     {short(line, 110)}")
                break
    # files
    kv = root / "projects/kv/lib/kv.aura"
    tests = root / "projects/kv/tests/smoke.aura"
    if kv.is_file():
        print(f"  code     lib/kv.aura ({kv.stat().st_size} B)  tests/smoke.aura ({tests.stat().st_size if tests.is_file() else 0} B)")

# ── Recent issues (one line, only if any open/recent success) ───────────
# Skip dumping all draft URLs by default.

# ── Failures summary (plain language) ───────────────────────────────────
print()
print("Recent issues")
print("─────────────")
fails = []
if run_dir and (run_dir / "events.jsonl").is_file():
    for line in (run_dir / "events.jsonl").read_text(encoding="utf-8", errors="replace").splitlines()[-50:]:
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("kind") == "step" and e.get("result") == "fail":
            name = e.get("name", "?")
            logp = e.get("log", "")
            why = "failed"
            if logp and Path(logp).is_file():
                t = Path(logp).read_text(encoding="utf-8", errors="replace")
                if "TimeoutError" in t or "timed out" in t:
                    why = "LLM API timeout (will retry next cycle)"
                elif "soft-reject" in t:
                    why = "patch rejected (no score gain)"
                elif "no-patch" in t:
                    why = "controller produced no usable FILE patch"
                elif "RESULT fail" in t:
                    m = re.search(r"RESULT fail[^\n]*", t)
                    why = short(m.group(0) if m else "test/command failed", 90)
            fails.append((e.get("ts", ""), name, why))
if fails:
    for ts, name, why in fails[-3:]:
        print(f"  • [{ts}] {name}: {why}")
else:
    print("  (none in recent events)")

# ── Tips ────────────────────────────────────────────────────────────────
# LLM cadence (from running loop env if available)
print()
print("LLM controller")
print("──────────────")
print("  when     1 MiniMax call per project-evolve generation (after tests)")
print("  cadence  ~ every cycle (live + git-probe + project-evolve + sleep 45s)")
print("  timeout  UNIFY_LLM_TIMEOUT (default 480s) × UNIFY_LLM_RETRIES (default 3)")
print("  note     timeout → soft-reject, next cycle retries (not a host bug)")

print()
print("Commands")
print("────────")
print("  tail -f logs/runs/latest/master.log          # live stream")
print("  cat projects/kv/evolve/last-review.md        # LLM review + plan")
print("  tail projects/kv/evolve/journal.jsonl        # accept/reject history")
print("  AURA_PATH=projects/kv/lib:lib ./scripts/run-aura.sh projects/kv/tests/smoke.aura")
print("  ./scripts/evolve.sh stop | ./scripts/evolve.sh   # stop / restart")

if verbose and run_dir:
    print()
    print("── verbose: last master lines ──")
    master = run_dir / "master.log"
    if master.is_file():
        # filter stack-noise: keep step/cycle lines
        keep = []
        for line in master.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]:
            if any(k in line for k in ("STEP ", "CYCLE", "event cycle", "git tip", "project-evolve", "RESULT", "observe", "CONTROL", "VERIFY", "TIMEOUT", "Timeout")):
                if "File \"" in line or "~~~~~~~" in line:
                    continue
                keep.append(line)
        for line in keep[-20:]:
            print(line)
    print()
    print("── verbose: last events ──")
    ev = run_dir / "events.jsonl"
    if ev.is_file():
        for line in ev.read_text(encoding="utf-8", errors="replace").splitlines()[-8:]:
            print(line)
PY
