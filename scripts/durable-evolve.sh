#!/usr/bin/env bash
# Spacetime denseness explore — four-axis composition subject.
#
# Axes (one mutated per generation, all must keep verifying):
#   score  ~ Aether   free pure decision metric
#   kernel ~ Hephaestus triangle closed form
#   leaf   ~ Prometheus homogeneous pure map
#   hop    ~ Hermes ring next-hop
#
# Flow: multi-cand snapshot sandbox → select if composition holds →
#       state.json + frontier.jsonl + git commit
#
# See notes/evolution-model.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATE_DIR="$ROOT/notes/evolve-state"
STATE_FILE="$STATE_DIR/state.json"
JOURNAL="$STATE_DIR/journal.jsonl"
FRONTIER="$STATE_DIR/frontier.jsonl"
mkdir -p "$STATE_DIR"

GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_PATH="${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/../aether/lib:$ROOT/../hephaestus/lib:$ROOT/../prometheus/lib:$ROOT/../hermes/lib:$ROOT/lib}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable: $AURA_BIN" >&2
  exit 1
fi

# Seed multi-axis state (migrate old factor-ladder state if present)
python3 - "$STATE_FILE" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
default = {
    "mode": "spacetime-explore",
    "generation": 0,
    "axis_cursor": 0,
    "subjects": {
        "score": {
            "span": "aether",
            "role": "decision metric (free pure forms)",
            "body": "(lambda (x) (* x 2))",
        },
        "kernel": {
            "span": "hephaestus",
            "role": "triangle T(n)=n(n-1)/2",
            "body": "(lambda (n) (/ (* n (- n 1)) 2))",
        },
        "leaf": {
            "span": "prometheus",
            "role": "homogeneous pure map leaf(0)=0 leaf(2x)=2*leaf(x)",
            "body": "(lambda (x) (* x 3))",
        },
        "hop": {
            "span": "hermes",
            "role": "ring next-hop on {0,1,2}",
            "body": "(lambda (i) (modulo (+ i 1) 3))",
        },
    },
    "history": [],
    "status": "init",
}
if not path.is_file():
    path.write_text(json.dumps(default, indent=2))
    print("seeded multi-axis state")
    raise SystemExit(0)
st = json.load(open(path))
if st.get("mode") != "spacetime-explore" or "subjects" not in st:
    # migrate: keep generation, archive old body into history note
    old_body = st.get("body")
    old_gen = int(st.get("generation") or 0)
    default["generation"] = old_gen
    default["status"] = "migrated-from-factor-ladder"
    if old_body:
        default["history"] = [{
            "note": "migrated from factor-ladder",
            "old_body": old_body,
            "old_factor": st.get("factor"),
            "from_generation": old_gen,
        }]
    path.write_text(json.dumps(default, indent=2))
    print("migrated state to spacetime-explore")
else:
    print(f"state gen={st.get('generation')} mode={st.get('mode')}")
PY

# Pick axis + build free-ish candidates (Python) then Aura multi-sandbox
PACK="$(python3 - "$STATE_FILE" <<'PY'
import json, os, re, sys, urllib.request
from pathlib import Path

st = json.load(open(sys.argv[1]))
axes = ["score", "kernel", "leaf", "hop"]
cur = int(st.get("axis_cursor") or 0) % 4
axis = axes[cur]
subs = st["subjects"]
bodies = {k: subs[k]["body"] for k in axes}
gen = int(st.get("generation") or 0)

# Per-axis seed candidates that diversify denseness surface
catalog = {
    "score": [
        "(lambda (x) (* x 2))",
        "(lambda (x) (* x 3))",
        "(lambda (x) (* x x))",
        "(lambda (x) (* x (* x x)))",
        "(lambda (x) (+ x x))",
        "(lambda (x) (* (+ x 1) (- x 1)))",  # x^2-1 — score(0)=-1 FAIL denseness boundary
        "(lambda (x) 5)",  # constant — FAIL
    ],
    "kernel": [
        "(lambda (n) (/ (* n (- n 1)) 2))",
        "(lambda (n) (/ (* (- n 1) n) 2))",
        "(lambda (n) (* n n))",  # wrong closed form — FAIL denseness
        "(lambda (n) n)",  # FAIL
    ],
    "leaf": [
        "(lambda (x) (* x 2))",
        "(lambda (x) (* x 3))",
        "(lambda (x) (* x 5))",
        "(lambda (x) (* x 7))",
        "(lambda (x) (+ x 1))",  # breaks homogeneous — FAIL
        "(lambda (x) (* x x))",  # breaks leaf(6)=2*leaf(3) — FAIL
    ],
    "hop": [
        "(lambda (i) (modulo (+ i 1) 3))",
        "(lambda (i) (modulo (+ i 4) 3))",  # equiv +1
        "(lambda (i) (modulo (- i 1) 3))",  # reverse ring — FAIL hop oracle
        "(lambda (i) i)",  # FAIL
    ],
}
cands = list(catalog[axis])
# Always include current body (stability)
cands.insert(0, bodies[axis])

# LLM free propose for the active axis (pure only)
key_file = os.environ.get("MINIMAX_KEY_FILE") or str(Path.home() / "code/keys/minimax")
if os.path.isfile(key_file) and os.environ.get("UNIFY_EVOLVE_LLM", "1") == "1":
    raw = open(key_file).read().strip()
    key = raw.split("=", 1)[1] if "=" in raw else raw
    prompts = {
        "score": (
            "Propose ONE pure Aura body for score(x). Constraints: score(0)=0; "
            "not constant on {1,2,3}; only x and arithmetic. "
            "Explore freely (linear, quadratic, cubic, products). "
            "Reply exactly: BODY|(lambda (x) ...)"
        ),
        "kernel": (
            "Propose pure Aura body for kernel(n)=triangle n(n-1)/2. "
            "Reply exactly: BODY|(lambda (n) ...)"
        ),
        "leaf": (
            "Propose pure Aura body for leaf(x) with leaf(0)=0 and leaf(2x)=2*leaf(x) for samples. "
            "Prefer (lambda (x) (* x K)). Reply exactly: BODY|(lambda (x) ...)"
        ),
        "hop": (
            "Propose pure Aura body hop(i) ring on {0,1,2}: hop(0)=1 hop(1)=2 hop(2)=0. "
            "Reply exactly: BODY|(lambda (i) ...)"
        ),
    }
    payload = {
        "model": os.environ.get("LLM_MODEL", "MiniMax-M3"),
        "temperature": 0.7,
        "messages": [
            {"role": "system", "content": "You explore pure-Aura denseness. One line BODY|(lambda ...) only. No markdown."},
            {"role": "user", "content": prompts[axis]},
        ],
    }
    base = os.environ.get("LLM_BASE_URL", "https://api.minimaxi.com/v1").rstrip("/")
    try:
        req = urllib.request.Request(
            f"{base}/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=90) as resp:
            content = json.load(resp)["choices"][0]["message"]["content"]
        chosen = None
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("BODY|"):
                chosen = line[5:].strip()
                break
        if not chosen:
            m = re.search(r"\(lambda\s*\([^)]*\)[\s\S]*\)", content)
            if m:
                # take first line-ish
                chosen = m.group(0).split("\n")[0].strip()
        if chosen and chosen.startswith("(lambda") and "set!" not in chosen and "define" not in chosen:
            cands.insert(0, chosen)
    except Exception:
        pass

# dedupe
seen, uniq = set(), []
for c in cands:
    if c not in seen:
        seen.add(c)
        uniq.append(c)

print(json.dumps({
    "generation": gen,
    "axis": axis,
    "axis_cursor": cur,
    "next_cursor": (cur + 1) % 4,
    "subjects": bodies,
    "candidates": uniq,
    "span": subs[axis]["span"],
}))
PY
)"

AXIS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["axis"])' "$PACK")"
SPAN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["span"])' "$PACK")"
CUR_GEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["generation"])' "$PACK")"
NEXT_CUR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_cursor"])' "$PACK")"
# Aura lists are space-separated: (list "a" "b") — commas become unbound unquote junk
CAND_AURA="$(python3 -c 'import json,sys; cs=json.loads(sys.argv[1])["candidates"]; print("(list "+" ".join(json.dumps(c) for c in cs)+")")' "$PACK")"
N_CAND="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["candidates"]))' "$PACK")"
SB="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["subjects"]["score"])[1:-1])' "$PACK")"
KB="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["subjects"]["kernel"])[1:-1])' "$PACK")"
LB="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["subjects"]["leaf"])[1:-1])' "$PACK")"
HB="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["subjects"]["hop"])[1:-1])' "$PACK")"

echo "[explore] gen=$CUR_GEN axis=$AXIS span=$SPAN candidates=$N_CAND"

TMP_AURA="$(mktemp /tmp/unify-explore-XXXXXX.aura)"
TMP_LOG="$(mktemp /tmp/unify-explore-XXXXXX.log)"
trap 'rm -f "$TMP_AURA" "$TMP_LOG"' EXIT

cat >"$TMP_AURA" <<EOF
(require "unify-min" all:)
(unify:stats-reset!)
(define axis "$AXIS")
(define candidates $CAND_AURA)

(display "=== spacetime explore axis=") (display axis) (newline)
(display "explore-version=") (display unify:explore-version) (newline)

(define ok-install
  (unify:explore-install! "$SB" "$KB" "$LB" "$HB"))

(if (not ok-install)
  (begin (display "RESULT fail explore reason=install") (newline))
  (begin
    (display "pre-verify-all=") (display (unify:explore-verify-all)) (newline)
    (display "locus=") (write (try (query :find axis) (catch (e) (quote ())))) (newline)
    (let ((sel (unify:explore-select-axis! axis candidates)))
      (display "select=") (write sel) (newline)
      (display "stats=") (write (unify:stats-alist)) (newline)
      (if (unify:alist-ref ":ok" sel #f)
        (begin
          (display "EXPLORE_AXIS ") (display axis) (newline)
          (display "EXPLORE_BODY ") (display (unify:alist-ref ":body" sel "")) (newline)
          (display "EXPLORE_TRIED ") (display (unify:alist-ref ":tried" sel 0)) (newline)
          (display "EXPLORE_FIT ") (display (unify:alist-ref ":fitness" sel 0)) (newline)
          (display "post-verify-all=") (display (unify:explore-verify-all)) (newline)
          (display "RESULT pass explore axis=") (display axis) (newline))
        (begin
          (display "EXPLORE_FAIL_REASON ") (display (unify:alist-ref ":reason" sel "x")) (newline)
          (display "EXPLORE_BEST ") (display (unify:alist-ref ":best_body" sel "")) (newline)
          (display "RESULT fail explore reason=")
          (display (unify:alist-ref ":reason" sel "select"))
          (newline))))))
EOF

set +e
"$AURA_BIN" <"$TMP_AURA" >"$TMP_LOG" 2>&1
set -e
cat "$TMP_LOG"

if ! grep -q 'RESULT pass explore' "$TMP_LOG"; then
  cp -f "$TMP_LOG" "$STATE_DIR/last-fail.log"
  # Record frontier: denseness boundary sample
  python3 - "$FRONTIER" "$AXIS" "$SPAN" "$TMP_LOG" "$PACK" <<'PY'
import json, sys, re
from datetime import datetime, timezone
fp, axis, span, logp, pack = sys.argv[1:6]
log = open(logp, encoding="utf-8", errors="replace").read()
pack = json.loads(pack)
row = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "axis": axis,
    "span": span,
    "class": "denseness" if "no-viable" in log or "verify" in log else "unknown",
    "reason": "explore-fail",
    "candidates": pack.get("candidates", [])[:8],
    "log_tail": log.splitlines()[-15:],
}
with open(fp, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
print("frontier: recorded explore-fail")
PY
  echo "RESULT fail durable-evolve"
  exit 1
fi

NEW_BODY="$(grep '^EXPLORE_BODY ' "$TMP_LOG" | tail -n1 | sed 's/^EXPLORE_BODY //')"
TRIED="$(grep '^EXPLORE_TRIED ' "$TMP_LOG" | tail -n1 | sed 's/^EXPLORE_TRIED //' || echo 0)"
FIT="$(grep '^EXPLORE_FIT ' "$TMP_LOG" | tail -n1 | sed 's/^EXPLORE_FIT //' || echo 0)"

python3 - "$STATE_FILE" "$JOURNAL" "$AXIS" "$NEW_BODY" "$CUR_GEN" "$NEXT_CUR" "$TRIED" "$FIT" "$SPAN" "$N_CAND" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, axis, body, gen, next_cur, tried, fit, span, n_cand = sys.argv[1:11]
gen = int(gen)
st = json.load(open(path))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
old = st["subjects"][axis]["body"]
st["subjects"][axis]["body"] = body
st["generation"] = gen + 1
st["axis_cursor"] = int(next_cur)
st["status"] = "ok"
st["updated"] = now
st["last_axis"] = axis
st["last_span"] = span
hist = st.get("history") or []
hist.append({
    "ts": now,
    "generation": gen + 1,
    "axis": axis,
    "span": span,
    "from_body": old,
    "to_body": body,
    "tried": int(tried or 0),
    "candidates_n": int(n_cand or 0),
    "fitness": int(float(fit or 0)),
    "mode": "spacetime-explore",
})
st["history"] = hist[-80:]
json.dump(st, open(path, "w"), indent=2)
with open(journal, "a", encoding="utf-8") as f:
    f.write(json.dumps(hist[-1], ensure_ascii=False) + "\n")
print(f"state: gen={st['generation']} axis={axis} span={span} body={body}")
PY

# Human/agent readable subject dump (string truth, not AST decompile)
python3 - "$STATE_FILE" "$STATE_DIR/subject.aura" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
subs = st["subjects"]
lines = [
    "; Auto-generated explore subject (string truth after multi-cand select)",
    f"; generation={st.get('generation')} updated={st.get('updated')}",
    f"; last_axis={st.get('last_axis')} last_span={st.get('last_span')}",
    f"(define score {subs['score']['body']})",
    f"(define kernel {subs['kernel']['body']})",
    f"(define leaf {subs['leaf']['body']})",
    f"(define hop {subs['hop']['body']})",
    "",
]
open(sys.argv[2], "w").write("\n".join(lines))
print("wrote", sys.argv[2])
PY

cat >"$STATE_DIR/README.md" <<EOF
# Spacetime denseness explore state

| field | value |
|-------|-------|
| mode | spacetime-explore |
| generation | $(python3 -c 'import json;print(json.load(open("'"$STATE_FILE"'"))["generation"])') |
| last axis | $AXIS ($SPAN) |
| winner body | \`$NEW_BODY\` |
| candidates tried | ${TRIED:-?}/$N_CAND |

## Four axes (composition)

| axis | span | role |
|------|------|------|
| score | Aether | free pure decision metric |
| kernel | Hephaestus | triangle closed form |
| leaf | Prometheus | homogeneous pure map |
| hop | Hermes | ring next-hop |

Each generation mutates **one** axis under multi-cand sandbox; **all** must still verify.
Failed explorations → \`frontier.jsonl\` (denseness boundary samples).

Readable dump: \`subject.aura\`. Entry: \`./scripts/evolve.sh\`.
EOF

echo "RESULT pass durable-evolve generation=$((CUR_GEN + 1)) axis=$AXIS span=$SPAN"

if [[ "$GIT_COMMIT" != "1" ]]; then
  echo "git: skipped"
  exit 0
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add notes/evolve-state/state.json notes/evolve-state/journal.jsonl \
    notes/evolve-state/README.md notes/evolve-state/subject.aura \
    notes/evolve-state/frontier.jsonl 2>/dev/null || true
  if git diff --cached --quiet; then
    echo "git: nothing new"
  else
    git commit -m "$(cat <<EOF
explore: gen $((CUR_GEN + 1)) axis=${AXIS} (${SPAN}) multi-sandbox

Four-axis spacetime denseness explore; composition verify held.
EOF
)" || true
    echo "git: $(git log -1 --oneline)"
    # Default ON: evolve should publish state to origin (set UNIFY_GIT_PUSH=0 to disable)
    if [[ "${UNIFY_GIT_PUSH:-1}" == "1" ]]; then
      if git push origin HEAD 2>&1; then
        echo "git: pushed $(git rev-parse --short HEAD) → origin"
      else
        echo "git: push failed (non-fatal; commit kept local)" >&2
      fi
    else
      echo "git: push skipped (UNIFY_GIT_PUSH=0)"
    fi
  fi
fi
