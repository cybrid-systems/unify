#!/usr/bin/env python3
"""LLM as evolution *controller* (MiniMax-M3).

Roles (one call, structured sections):
  1. REVIEW   — what works / what's broken relative to SPEC + tests
  2. DIRECTION — next strategic move (phase goal, risks, non-goals)
  3. PATCH    — concrete FILE blocks the actuator will apply

The closed loop lives in project-evolve.sh / evolve.sh:
  observe (Aura tests) → control (this module) → act (sandbox files / Aura)
  → verify (Aura tests) → memory (state/journal) → next cycle.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def load_key() -> str:
    key_file = os.environ.get("MINIMAX_KEY_FILE") or str(Path.home() / "code/keys/minimax")
    if not Path(key_file).is_file():
        raise SystemExit(f"missing MiniMax key: {key_file}")
    raw = Path(key_file).read_text().strip()
    return raw.split("=", 1)[1] if "=" in raw else raw


def chat(system: str, user: str, temperature: float = 0.35) -> str:
    """Call MiniMax with long timeout + retries (codebases grow → slow generations)."""
    key = load_key()
    base = os.environ.get("LLM_BASE_URL", "https://api.minimaxi.com/v1").rstrip("/")
    model = os.environ.get("LLM_MODEL", "MiniMax-M3")
    timeout = int(os.environ.get("UNIFY_LLM_TIMEOUT", "480"))  # seconds
    retries = int(os.environ.get("UNIFY_LLM_RETRIES", "3"))
    payload = {
        "model": model,
        "temperature": temperature,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    data = json.dumps(payload).encode()
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            f"{base}/chat/completions",
            data=data,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            print(
                f"controller: LLM request attempt {attempt}/{retries} "
                f"timeout={timeout}s model={model} user_chars={len(user)}",
                flush=True,
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                content = json.load(resp)["choices"][0]["message"]["content"]
            print(f"controller: LLM ok attempt={attempt} reply_chars={len(content)}", flush=True)
            return content
        except Exception as e:
            last_err = e
            wait = min(60, 10 * attempt)
            print(
                f"controller: LLM error attempt={attempt}/{retries}: {type(e).__name__}: {e}",
                flush=True,
            )
            if attempt < retries:
                print(f"controller: backoff {wait}s then retry", flush=True)
                import time

                time.sleep(wait)
    raise SystemExit(f"LLM controller failed after {retries} attempts: {last_err}")


def clip_source(path: str, body: str, max_chars: int) -> str:
    """Keep prompt bounded so API stays under timeout as project grows."""
    if len(body) <= max_chars:
        return body
    head = max_chars // 2
    tail = max_chars - head - 80
    return (
        body[:head]
        + f"\n\n/* … truncated {len(body) - max_chars} chars from {path} … */\n\n"
        + body[-tail:]
    )


SYSTEM = """You are the *controller* of a continuous software self-evolution loop.

You do NOT run code. An automatic actuator (Unify + Aura) will:
  - apply your FILE patches in a sandbox
  - run the project's Aura tests
  - accept only if SCORE does not regress
  - commit/push winners
  - feed results back to you next generation

Your job each generation:
  1. REVIEW the project vs SPEC and test output
  2. Set DIRECTION (what to improve next; phase from SPEC)
  3. Emit a concrete PATCH the actuator can apply

## Output format (exact section headers)

### REVIEW
(bullet points: strengths, failures, denseness/host risks)

### DIRECTION
(one short plan: target phase, ops to implement, what NOT to touch)

### PATCH
FILE relative/path
```
full file contents
```

Rules for PATCH:
- Prefer full-file replacement for small projects (lib/kv.aura).
- Keep Aura export-before-define style when using (export ...).
- Prefer pure functional store updates; meter any FS as escape.
- If SCORE is already full, advance SPEC phase (new capability) via code that
  still keeps old tests green; you may also extend tests/smoke.aura carefully
  only if you also implement the feature.
- No secrets, no network in product code.
"""


def build_user(
    *,
    project: str,
    gen: int,
    score: str,
    total: str,
    spec: str,
    sources: dict[str, str],
    test_tail: str,
    memory: str,
) -> str:
    src_blocks = []
    for path, body in sources.items():
        src_blocks.append(f"#### {path}\n```\n{body}\n```")
    return f"""## Controller input

| field | value |
|-------|-------|
| project | {project} |
| generation | {gen} |
| baseline SCORE | {score}/{total} |
| time_utc | {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")} |

### SPEC
{spec}

### Current sources
{chr(10).join(src_blocks)}

### Recent controller memory (journal tail)
{memory or "(empty)"}

### Last test output (tail)
```
{test_tail}
```

Respond with ### REVIEW, ### DIRECTION, ### PATCH only.
"""


def parse_sections(text: str) -> dict[str, str]:
    parts = {"REVIEW": "", "DIRECTION": "", "PATCH": "", "raw": text}
    cur = None
    buf: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^###\s+(REVIEW|DIRECTION|PATCH)\s*$", line.strip(), re.I)
        if m:
            if cur:
                parts[cur] = "\n".join(buf).strip()
            cur = m.group(1).upper()
            buf = []
        else:
            buf.append(line)
    if cur:
        parts[cur] = "\n".join(buf).strip()
    # If model forgot headers but has FILE blocks, treat all as PATCH
    if not parts["PATCH"] and re.search(r"FILE\s+\S+", text):
        parts["PATCH"] = text
        if not parts["REVIEW"]:
            parts["REVIEW"] = "(model omitted REVIEW section)"
        if not parts["DIRECTION"]:
            parts["DIRECTION"] = "(model omitted DIRECTION section)"
    return parts


def apply_patch_text(root: Path, patch_text: str) -> list[str]:
    """Apply FILE blocks into project root. Returns list of relative paths."""
    pat = re.compile(r"FILE\s*:?\s*(\S+)\s*\n```(?:\w*)\n(.*?)```", re.S | re.I)
    applied: list[str] = []
    root = root.resolve()
    for m in pat.finditer(patch_text):
        rel = m.group(1).strip().strip("`").lstrip("./")
        if not rel or rel in (":", "-", "path"):
            continue
        for prefix in ("projects/kv/", "kv/"):
            if rel.startswith(prefix):
                rel = rel[len(prefix) :]
        if ".." in rel or rel.startswith("/"):
            continue
        dest = (root / rel).resolve()
        if not str(dest).startswith(str(root)):
            continue
        body = m.group(2)
        if not body.endswith("\n"):
            body += "\n"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(body, encoding="utf-8")
        applied.append(rel)
    if not applied and "(define" in patch_text and "kv:" in patch_text:
        body = re.sub(r"^```\w*\n", "", patch_text)
        body = re.sub(r"\n```\s*$", "", body)
        if not body.endswith("\n"):
            body += "\n"
        (root / "lib/kv.aura").write_text(body)
        applied.append("lib/kv.aura")
    return applied


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="project root path")
    ap.add_argument("--gen", type=int, default=0)
    ap.add_argument("--score", default="0")
    ap.add_argument("--total", default="0")
    ap.add_argument("--spec", required=True)
    ap.add_argument("--test-log", required=True)
    ap.add_argument("--memory", default="")
    ap.add_argument("--source", action="append", default=[], help="path relative to project")
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--out-patch", required=True)
    args = ap.parse_args()

    proj = Path(args.project)
    spec = Path(args.spec).read_text(encoding="utf-8", errors="replace")
    test_tail = "\n".join(
        Path(args.test_log).read_text(encoding="utf-8", errors="replace").splitlines()[-80:]
    )
    memory = ""
    if args.memory and Path(args.memory).is_file():
        memory = "\n".join(Path(args.memory).read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
    # Cap each source file in the prompt (full files still on disk for actuator).
    max_src = int(os.environ.get("UNIFY_LLM_SRC_CHARS", "24000"))
    sources: dict[str, str] = {}
    for rel in args.source or ["lib/kv.aura"]:
        p = proj / rel
        if p.is_file():
            raw = p.read_text(encoding="utf-8", errors="replace")
            sources[rel] = clip_source(rel, raw, max_src)

    user = build_user(
        project=str(proj),
        gen=args.gen,
        score=args.score,
        total=args.total,
        spec=spec,
        sources=sources,
        test_tail=test_tail,
        memory=memory,
    )
    raw = chat(SYSTEM, user)
    sections = parse_sections(raw)
    Path(args.out_patch).write_text(raw, encoding="utf-8")
    out = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
        "review": sections.get("REVIEW", ""),
        "direction": sections.get("DIRECTION", ""),
        "patch": sections.get("PATCH", ""),
        "raw_path": args.out_patch,
    }
    Path(args.out_json).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"controller: wrote review/direction/patch → {args.out_json}")
    print("--- REVIEW ---")
    print(out["review"][:1200] or "(empty)")
    print("--- DIRECTION ---")
    print(out["direction"][:800] or "(empty)")
    print("--- PATCH preview ---")
    print((out["patch"] or raw)[:400])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
