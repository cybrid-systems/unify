#!/usr/bin/env python3
"""Boundary-aware failure classifier for Unify.

Policy (定界 first — only confirmed Aura host residuals may hit GitHub):

  host        + confidence=high  → eligible to file on cybrid-systems/aura
  host        + confidence<high  → draft for human review (no auto-file)
  unify-self                     → self-evolve queue (fix in Unify, never Aura)
  denseness                      → denseness-report only
  llm                            → retry / backoff
  unknown                        → draft review only

Usage:
  python3 scripts/classify-failure.py --log path/to.log [--label L] [--cmd C]
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

# ── Strong host signals (Aura runtime / engine) ────────────────────────────
# These are treated as high-confidence *candidates* after unify-self exclusion.
STRONG_HOST: list[tuple[str, re.Pattern[str]]] = [
    ("segfault", re.compile(r"SIGSEGV|segmentation fault|segfault", re.I)),
    ("unbound", re.compile(r"error:\s*\d+:\d+:\s*unbound variable", re.I)),
    ("type_error_call", re.compile(r"type error:\s*cannot call", re.I)),
    ("eval_flat", re.compile(r"eval_flat", re.I)),
    ("recursion", re.compile(r"recursion depth exceeded", re.I)),
    ("internal", re.compile(r"internal error|assertion failed|\bpanic\b", re.I)),
]

# Soft host-ish signals — alone never auto-file.
SOFT_HOST: list[tuple[str, re.Pattern[str]]] = [
    ("pipeline", re.compile(r"export before require|#2766|pipeline strict", re.I)),
    ("capability", re.compile(r"effect denied|require_effect|capability", re.I)),
    ("git_prim", re.compile(r"\bgit-(?:status|diff|log|commit|stage|rev-parse|branch)\b", re.I)),
    ("set_code", re.compile(r"\bset-code\b|\beval-current\b", re.I)),
]

# Unify-owned harness / composition bugs — fix here via self-evolve, never Aura.
UNIFY_SELF: list[tuple[str, re.Pattern[str]]] = [
    ("missing_sibling", re.compile(r"MISSING sibling|MISSING probe", re.I)),
    ("runner_error", re.compile(r"runner error|not executable:|aura binary not found", re.I)),
    ("bash_syntax", re.compile(r"bash:\s|syntax error|unbound variable:\s+\w+\s*$", re.I)),
    ("script_path", re.compile(
        r"scripts/(?:run-|file-|classify|overnight|status|env-)|file-aura-issue|check-structure",
        re.I,
    )),
    ("harness_expect", re.compile(
        r"no expected RESULT|no RESULT pass|Structure (?:OK|check)|FAIL unify=",
        re.I,
    )),
    ("compose_logic", re.compile(
        r"unify:compose|unify:loop|unify:propose|force-body|schema-gate|parse-fail",
        re.I,
    )),
    ("env_minimax", re.compile(r"MiniMax key file not found|env-minimax", re.I)),
]

LLM_PATTERNS = [
    re.compile(
        r"llm-fail|no-key|rate[- ]?limit|ECONN|timed?\s*out|HTTP\s*[45]\d\d|"
        r"Connection refused|network is unreachable|SSL|certificate",
        re.I,
    ),
]
# Denseness = evolution/verify surface, not host crash.
DENSE_PATTERNS = [
    re.compile(
        r"verify-fail|already-correct|decision.?rollback|leaves-intact|"
        r"denseness|escape rate|correctness_fail|propose_fail|parse-fail",
        re.I,
    ),
]

ERROR_LINE = re.compile(
    r"(error:|FAIL:|RESULT fail|unbound variable|SIGSEGV|internal error|type error|MISSING )",
    re.I,
)

# Aura error pretty-printer often includes caret under the form.
AURA_DIAG = re.compile(r"error:\s*\d+:\d+:|did you mean|^\s*\|", re.M)


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
    return {
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


def extract_error_lines(text: str, limit: int = 40) -> list[str]:
    lines = text.splitlines()
    hits: list[str] = []
    for i, line in enumerate(lines):
        if ERROR_LINE.search(line):
            start = max(0, i - 1)
            end = min(len(lines), i + 3)
            for c in lines[start:end]:
                if c not in hits:
                    hits.append(c)
        if len(hits) >= limit:
            break
    if not hits:
        hits = [ln for ln in lines if ln.strip()][-20:]
    return hits[:limit]


def first_match(patterns: list[tuple[str, re.Pattern[str]]], text: str) -> str | None:
    for kind, pat in patterns:
        if pat.search(text):
            return kind
    return None


def match_any(patterns: list[re.Pattern[str]], text: str) -> bool:
    return any(p.search(text) for p in patterns)


def classify_boundary(text: str) -> dict[str, object]:
    """Return class, kind, confidence, should_file, should_self_evolve, action, reasons."""
    reasons: list[str] = []

    # 1) LLM edge — not Aura
    if match_any(LLM_PATTERNS, text) and not first_match(STRONG_HOST, text):
        reasons.append("llm/network signature without strong host crash")
        return _result(
            "llm", "llm", "high", False, False, "retry_llm", reasons
        )

    # 2) Unify-self harness / composition ownership
    self_kind = first_match(UNIFY_SELF, text)
    strong = first_match(STRONG_HOST, text)
    soft = first_match(SOFT_HOST, text)

    # If harness says MISSING / runner error, own it even if log is noisy.
    if self_kind in ("missing_sibling", "runner_error", "bash_syntax", "env_minimax", "harness_expect"):
        reasons.append(f"unify-self kind={self_kind}")
        return _result(
            "unify-self", self_kind, "high", False, True, "self_evolve", reasons
        )

    # Strong Aura runtime diagnostics with pretty-printer → confirmed host.
    if strong and AURA_DIAG.search(text):
        # Exception: pure force-body/schema text without aura error format handled above.
        reasons.append(f"strong host kind={strong} + Aura diagnostic format")
        # If also clearly only denseness verify without engine error lines:
        if strong is None:
            pass
        return _result(
            "host", strong, "high", True, False, "file_aura", reasons
        )

    if strong:
        # Strong keyword but weak format → medium (draft, human confirm)
        reasons.append(f"strong keyword kind={strong} but missing Aura diagnostic format")
        return _result(
            "host", strong, "medium", False, False, "draft_review", reasons
        )

    # 3) Denseness evolution failure (no engine crash)
    if match_any(DENSE_PATTERNS, text) and not strong:
        reasons.append("denseness/verify/rollback signature without host crash")
        # denseness of spans is not "self-evolve unify scripts" by default
        return _result(
            "denseness", "denseness", "high", False, False, "denseness_report", reasons
        )

    # 4) Soft host alone → draft review
    if soft:
        reasons.append(f"soft host-ish kind={soft}; needs human 定界 before Aura")
        return _result(
            "host", soft, "low", False, False, "draft_review", reasons
        )

    # 5) unify compose/script soft ownership
    if self_kind:
        reasons.append(f"unify-self kind={self_kind}")
        return _result(
            "unify-self", self_kind, "medium", False, True, "self_evolve", reasons
        )

    if re.search(r"RESULT fail|error:", text, re.I):
        reasons.append("failure without decisive host/self/llm signature")
        return _result(
            "unknown", "unknown", "low", False, False, "draft_review", reasons
        )

    reasons.append("no failure signature")
    return _result("ok", "ok", "high", False, False, "none", reasons)


def _result(
    class_: str,
    kind: str,
    confidence: str,
    should_file: bool,
    should_self_evolve: bool,
    action: str,
    reasons: list[str],
) -> dict[str, object]:
    return {
        "class": class_,
        "kind": kind,
        "confidence": confidence,
        "should_file": should_file,
        "should_self_evolve": should_self_evolve,
        "action": action,
        "reasons": reasons,
    }


def stable_fingerprint(kind: str, error_lines: list[str], label: str) -> str:
    del label
    blob_parts = [kind]
    for ln in error_lines[:12]:
        s = ln
        s = re.sub(r"/home/\S+", "<PATH>", s)
        s = re.sub(r"/tmp/\S+", "<TMP>", s)
        s = re.sub(r"\b[0-9a-f]{7,40}\b", "<SHA>", s)
        s = re.sub(r"\bcycle\s*\d+", "cycle N", s, flags=re.I)
        s = re.sub(r"\b\d{4,}\b", "N", s)
        s = re.sub(r"\s+", " ", s).strip().lower()
        if s.startswith("===") or s.startswith("---"):
            continue
        blob_parts.append(s)
    blob = "|".join(blob_parts)
    digest = hashlib.sha256(blob.encode("utf-8", errors="replace")).hexdigest()[:12]
    kind_slug = re.sub(r"[^a-z0-9]+", "-", (kind or "unknown").lower()).strip("-") or "unknown"
    return f"unify-{kind_slug}-{digest}"


def pick_title_head(error_lines: list[str], kind: str) -> str:
    prefer = [
        re.compile(r"unbound variable", re.I),
        re.compile(r"type error", re.I),
        re.compile(r"SIGSEGV|segmentation", re.I),
        re.compile(r"internal error|eval_flat", re.I),
        re.compile(r"MISSING ", re.I),
        re.compile(r"^error:", re.I),
        re.compile(r"RESULT fail", re.I),
    ]
    for pat in prefer:
        for ln in error_lines:
            if pat.search(ln):
                return re.sub(r"\s+", " ", ln).strip()
    for ln in error_lines:
        s = re.sub(r"\s+", " ", ln).strip()
        if s and not s.startswith("==="):
            return s
    return kind or "failure"


def title_for(kind: str, class_: str, label: str, error_lines: list[str], confidence: str) -> str:
    head = pick_title_head(error_lines, kind)
    if len(head) > 72:
        head = head[:69] + "..."
    if class_ == "host":
        return f"[Unify/host:{kind}/{confidence}] {head}"
    return f"[Unify/{class_}:{kind}] {label}: {head}"


def build_body(
    *,
    class_: str,
    kind: str,
    confidence: str,
    action: str,
    should_file: bool,
    should_self_evolve: bool,
    reasons: list[str],
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
    reasons_md = "\n".join(f"- {r}" for r in reasons) or "- (none)"
    boundary = (
        "**CONFIRMED Aura host residual** — eligible for cybrid-systems/aura."
        if should_file
        else (
            "**Unify-owned** — fix via self-evolve / local patch; do **not** file to Aura."
            if should_self_evolve
            else (
                "**Not confirmed as Aura bug** — draft only; human 定界 before any Aura issue."
                if class_ == "host"
                else f"**Action `{action}`** — not an Aura tracker item."
            )
        )
    )
    return f"""## Summary

Unify synthesis bed failure during step `{label}`.

{boundary}

| Field | Value |
|-------|-------|
| class | `{class_}` |
| kind | `{kind}` |
| confidence | `{confidence}` |
| action | `{action}` |
| should_file (Aura) | `{should_file}` |
| should_self_evolve | `{should_self_evolve}` |
| fingerprint | `{fingerprint}` |
| unify HEAD | `{env.get('git_head', '')}` @ `{env.get('git_branch', '')}` |
| date (UTC) | `{env.get('date_utc', '')}` |
| host | `{env.get('hostname', '')}` |

### 定界 reasons

{reasons_md}

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
export AURA_SANDBOX=off
{cmd or '# (command not recorded — see log path)'}
```

Log path (local): `{log_path}`

## Expected

Step completes with `RESULT pass`. Host-class engine crashes are Aura; harness/schema/compose mistakes are Unify-self.

## Actual

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
*Boundary policy: only `should_file=true` (host + confidence=high) may be created on cybrid-systems/aura.*
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--label", default="unknown")
    ap.add_argument("--cmd", default="")
    ap.add_argument("--root", default="")
    ap.add_argument("--notes", default="")
    ap.add_argument("--tail-lines", type=int, default=80)
    args = ap.parse_args()

    log_path = Path(args.log)
    if not log_path.is_file():
        print(json.dumps({"ok": False, "error": f"missing log: {log_path}"}))
        return 2

    text = log_path.read_text(encoding="utf-8", errors="replace")
    root = args.root or str(Path(__file__).resolve().parents[1])
    boundary = classify_boundary(text)
    class_ = str(boundary["class"])
    kind = str(boundary["kind"])
    confidence = str(boundary["confidence"])
    should_file = bool(boundary["should_file"])
    should_self_evolve = bool(boundary["should_self_evolve"])
    action = str(boundary["action"])
    reasons = list(boundary["reasons"])  # type: ignore[arg-type]

    error_lines = extract_error_lines(text)
    fp = stable_fingerprint(kind, error_lines, args.label)
    title = title_for(kind, class_, args.label, error_lines, confidence)
    tail = "\n".join(text.splitlines()[-args.tail_lines :])
    env = env_snapshot(root)
    body = build_body(
        class_=class_,
        kind=kind,
        confidence=confidence,
        action=action,
        should_file=should_file,
        should_self_evolve=should_self_evolve,
        reasons=reasons,
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
        "confidence": confidence,
        "action": action,
        "should_file": should_file,
        "should_self_evolve": should_self_evolve,
        "reasons": reasons,
        "fingerprint": fp,
        "title": title,
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
