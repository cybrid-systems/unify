#!/usr/bin/env python3
"""Classify Unify/Aura failure logs and emit structured JSON for issue filing.

Usage:
  python3 scripts/classify-failure.py --log path/to.log [--label step-name] [--cmd 'repro']
  → prints JSON to stdout
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Order matters: first match wins for primary kind.
HOST_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("segfault", re.compile(r"SIGSEGV|segmentation fault|segfault", re.I)),
    ("unbound", re.compile(r"unbound variable", re.I)),
    ("type_error_call", re.compile(r"type error:\s*cannot call", re.I)),
    ("eval_flat", re.compile(r"eval_flat", re.I)),
    ("recursion", re.compile(r"recursion depth exceeded", re.I)),
    ("internal", re.compile(r"internal error|assertion failed|panic", re.I)),
    ("pipeline", re.compile(r"pipeline|export before require|#2766", re.I)),
    ("capability", re.compile(r"effect denied|capability|require_effect", re.I)),
    ("git_prim", re.compile(r"\bgit-(?:status|diff|log|commit|stage|rev-parse|branch)\b", re.I)),
    ("set_code", re.compile(r"set-code|eval-current", re.I)),
]

LLM_PATTERNS = [
    re.compile(r"llm-fail|no-key|rate[- ]?limit|MiniMax|ECONN|timed?\s*out|HTTP\s*[45]\d\d|network", re.I),
]
DENSE_PATTERNS = [
    re.compile(r"verify-fail|rollback|denseness|leaves-intact|escape rate|RESULT fail", re.I),
]

ERROR_LINE = re.compile(
    r"(error:|FAIL:|RESULT fail|unbound variable|SIGSEGV|internal error|type error)",
    re.I,
)


def sh(cmd: list[str], cwd: str | None = None) -> str:
    try:
        return subprocess.check_output(cmd, cwd=cwd, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""


def env_snapshot(root: str) -> dict[str, str]:
    aura_bin = os.environ.get("AURA_BIN") or ""
    if not aura_bin:
        cand = Path(root) / "../aura-grok/build/aura"
        if cand.is_file():
            aura_bin = str(cand.resolve())
    snap = {
        "unify_root": root,
        "cwd": os.getcwd(),
        "date_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
        "hostname": sh(["hostname"]) or os.environ.get("HOSTNAME", ""),
        "aura_bin": aura_bin,
        "aura_path": os.environ.get("AURA_PATH", ""),
        "llm_model": os.environ.get("LLM_MODEL", ""),
        "llm_base": os.environ.get("LLM_BASE_URL", ""),
        "unify_live": os.environ.get("UNIFY_LIVE", ""),
        "git_head": sh(["git", "-C", root, "rev-parse", "--short", "HEAD"]),
        "git_branch": sh(["git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"]),
    }
    if aura_bin and Path(aura_bin).is_file():
        # Best-effort version string
        try:
            out = subprocess.check_output(
                [aura_bin],
                input="(display (git-rev-parse))(newline)\n",
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=5,
                env={**os.environ, "AURA_SANDBOX": "off"},
            )
            snap["aura_self_rev"] = out.strip().splitlines()[-1] if out.strip() else ""
        except Exception:
            snap["aura_self_rev"] = ""
    return snap


def extract_error_lines(text: str, limit: int = 40) -> list[str]:
    lines = text.splitlines()
    hits: list[str] = []
    for i, line in enumerate(lines):
        if ERROR_LINE.search(line):
            # include a little context
            start = max(0, i - 1)
            end = min(len(lines), i + 3)
            chunk = lines[start:end]
            for c in chunk:
                if c not in hits:
                    hits.append(c)
        if len(hits) >= limit:
            break
    if not hits:
        # fallback: last non-empty lines
        hits = [ln for ln in lines if ln.strip()][-20:]
    return hits[:limit]


def primary_host_kind(text: str) -> str | None:
    for kind, pat in HOST_PATTERNS:
        if pat.search(text):
            return kind
    return None


def classify(text: str) -> str:
    if primary_host_kind(text):
        return "host"
    for pat in LLM_PATTERNS:
        if pat.search(text):
            return "llm"
    for pat in DENSE_PATTERNS:
        if pat.search(text):
            return "denseness"
    if re.search(r"RESULT fail|error:", text, re.I):
        return "unknown"
    return "ok"


def stable_fingerprint(kind: str, error_lines: list[str], label: str) -> str:
    """Content-stable fingerprint so the same bug collapses across nights.

    Label is intentionally excluded so the same diagnostic from different
    steps/cycles maps to one issue.
    """
    del label  # stable across steps
    blob_parts = [kind]
    for ln in error_lines[:12]:
        s = ln
        s = re.sub(r"/home/\S+", "<PATH>", s)
        s = re.sub(r"/tmp/\S+", "<TMP>", s)
        s = re.sub(r"\b[0-9a-f]{7,40}\b", "<SHA>", s)
        s = re.sub(r"\bcycle\s*\d+", "cycle N", s, flags=re.I)
        s = re.sub(r"\b\d{4,}\b", "N", s)
        s = re.sub(r"\s+", " ", s).strip().lower()
        # drop pure separators / banners
        if s.startswith("===") or s.startswith("---"):
            continue
        blob_parts.append(s)
    blob = "|".join(blob_parts)
    digest = hashlib.sha256(blob.encode("utf-8", errors="replace")).hexdigest()[:12]
    kind_slug = re.sub(r"[^a-z0-9]+", "-", (kind or "unknown").lower()).strip("-") or "unknown"
    return f"unify-{kind_slug}-{digest}"


def pick_title_head(error_lines: list[str], kind: str) -> str:
    """Prefer the most diagnostic line for the issue title."""
    prefer = [
        re.compile(r"unbound variable", re.I),
        re.compile(r"type error", re.I),
        re.compile(r"SIGSEGV|segmentation", re.I),
        re.compile(r"internal error|eval_flat", re.I),
        re.compile(r"^error:", re.I),
        re.compile(r"RESULT fail", re.I),
    ]
    for pat in prefer:
        for ln in error_lines:
            if pat.search(ln):
                return re.sub(r"\s+", " ", ln).strip()
    if error_lines:
        for ln in error_lines:
            s = re.sub(r"\s+", " ", ln).strip()
            if s and not s.startswith("==="):
                return s
    return kind or "failure"


def title_for(kind: str, class_: str, label: str, error_lines: list[str]) -> str:
    head = pick_title_head(error_lines, kind)
    if len(head) > 72:
        head = head[:69] + "..."
    if class_ == "host":
        return f"[Unify/host:{kind}] {head}"
    return f"[Unify/{class_}] {label}: {head}"


def build_body(
    *,
    class_: str,
    kind: str,
    label: str,
    fingerprint: str,
    cmd: str,
    log_path: str,
    error_lines: list[str],
    log_tail: str,
    env: dict[str, str],
    extra_notes: str,
) -> str:
    err_block = "\n".join(error_lines) if error_lines else "(no error lines extracted)"
    notes = extra_notes.strip() or "_None_"
    return f"""## Summary

Unify synthesis bed hit a **`{class_}`** residual (kind=`{kind}`) during step `{label}`.

| Field | Value |
|-------|-------|
| class | `{class_}` |
| kind | `{kind}` |
| fingerprint | `{fingerprint}` |
| step | `{label}` |
| unify HEAD | `{env.get('git_head', '')}` @ `{env.get('git_branch', '')}` |
| date (UTC) | `{env.get('date_utc', '')}` |
| host | `{env.get('hostname', '')}` |

Only **class=host** should be tracked on cybrid-systems/aura. Denseness / LLM failures stay in Unify notes.

## Environment

| Field | Value |
|-------|-------|
| AURA_BIN | `{env.get('aura_bin', '')}` |
| AURA_PATH | `{env.get('aura_path', '') or '(default via run-aura.sh)'}` |
| LLM_MODEL | `{env.get('llm_model', '')}` |
| LLM_BASE_URL | `{env.get('llm_base', '')}` |
| UNIFY_LIVE | `{env.get('unify_live', '')}` |
| unify root | `{env.get('unify_root', '')}` |

## Repro

```bash
cd {env.get('unify_root', 'unify')}
# sibling checkouts: aura-grok, aether, hephaestus, prometheus, hermes
export AURA_SANDBOX=off
{cmd or '# (command not recorded — see log path)'}
```

Log path (local): `{log_path}`

## Expected

Step completes with `RESULT pass` and no host-class diagnostics (unbound / eval_flat / SIGSEGV / type-error call / capability deny).

## Actual

Extracted error / diagnostic lines:

```
{err_block}
```

## Log tail

```
{log_tail.rstrip() or '(empty)'}
```

## Notes

{notes}

---
*Auto-filed by Unify `scripts/file-aura-issue.sh` / continuous runner. Fingerprint dedupes repeats.*
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="path to failure log")
    ap.add_argument("--label", default="unknown", help="step label")
    ap.add_argument("--cmd", default="", help="repro command")
    ap.add_argument("--root", default="", help="unify root")
    ap.add_argument("--notes", default="", help="extra notes markdown")
    ap.add_argument("--tail-lines", type=int, default=80)
    args = ap.parse_args()

    log_path = Path(args.log)
    if not log_path.is_file():
        print(json.dumps({"ok": False, "error": f"missing log: {log_path}"}))
        return 2

    text = log_path.read_text(encoding="utf-8", errors="replace")
    root = args.root or str(Path(__file__).resolve().parents[1])
    class_ = classify(text)
    kind = primary_host_kind(text) or class_
    error_lines = extract_error_lines(text)
    fp = stable_fingerprint(str(kind), error_lines, args.label)
    title = title_for(str(kind), class_, args.label, error_lines)
    lines = text.splitlines()
    tail = "\n".join(lines[-args.tail_lines :])
    env = env_snapshot(root)
    body = build_body(
        class_=class_,
        kind=str(kind),
        label=args.label,
        fingerprint=fp,
        cmd=args.cmd,
        log_path=str(log_path.resolve()),
        error_lines=error_lines,
        log_tail=tail,
        env=env,
        extra_notes=args.notes,
    )

    out = {
        "ok": True,
        "class": class_,
        "kind": kind,
        "fingerprint": fp,
        "title": title,
        "should_file": class_ == "host",
        "error_lines": error_lines,
        "body": body,
        "env": env,
        "log": str(log_path.resolve()),
        "label": args.label,
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
