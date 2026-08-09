#!/usr/bin/env bash
# Classify failure → detailed draft → optional create on cybrid-systems/aura.
#
# Modes:
#   1) From log (preferred — full classify + env + fingerprint):
#        ./scripts/file-aura-issue.sh --log path/to.log \
#            --label live-003 --cmd './scripts/run-aura.sh ...'
#
#   2) Legacy explicit body:
#        ./scripts/file-aura-issue.sh --title T --fingerprint F \
#            --body-file path.md --class host
#
# Policy (定界 first):
#   - Only class=host AND confidence=high AND should_file=true → cybrid-systems/aura
#   - unify-self → enqueue-self-evolve (never Aura)
#   - denseness / llm / unknown / host@medium|low → draft only
#   - UNIFY_AUTO_ISSUE=1 required to create (continuous sets this; still gated by should_file)
#   - Dedupes by fingerprint + GitHub search
#
# Auth: GH_TOKEN / GITHUB_TOKEN / ~/.github-token ; gh or curl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRAFT_DIR="$ROOT/notes/issue-drafts"
mkdir -p "$DRAFT_DIR"

TITLE=""
CLASS="host"
FINGERPRINT=""
BODY_FILE=""
LOG_FILE=""
LABEL="unknown"
CMD=""
NOTES=""
REPO="${UNIFY_AURA_REPO:-cybrid-systems/aura}"
LABELS="${UNIFY_ISSUE_LABELS:-bug}"
FORCE_DRAFT_ONLY=0
SHOULD_FILE=""
SHOULD_SELF=""
CONFIDENCE=""
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --draft-only) FORCE_DRAFT_ONLY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

load_token() {
  if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    export GITHUB_TOKEN="$GH_TOKEN"
    return 0
  fi
  local tf="${GITHUB_TOKEN_FILE:-$HOME/.github-token}"
  if [[ -f "$tf" ]]; then
    local raw
    raw="$(tr -d '\r\n' < "$tf" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$raw" == *=* ]]; then
      export GH_TOKEN="${raw#*=}"
    else
      export GH_TOKEN="$raw"
    fi
    export GITHUB_TOKEN="$GH_TOKEN"
    return 0
  fi
  return 1
}

# ── Classify from log when provided ───────────────────────────────────────
CLASSIFY_JSON=""
if [[ -n "$LOG_FILE" ]]; then
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "error: log missing: $LOG_FILE" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 required for --log classify" >&2
    exit 1
  fi
  CLASSIFY_JSON="$(python3 "$ROOT/scripts/classify-failure.py" \
    --log "$LOG_FILE" \
    --label "$LABEL" \
    --cmd "$CMD" \
    --root "$ROOT" \
    --notes "$NOTES")"
  TITLE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])' <<<"$CLASSIFY_JSON")"
  CLASS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])' <<<"$CLASSIFY_JSON")"
  FINGERPRINT="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])' <<<"$CLASSIFY_JSON")"
  CONFIDENCE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("confidence",""))' <<<"$CLASSIFY_JSON")"
  ACTION="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("action",""))' <<<"$CLASSIFY_JSON")"
  SHOULD_FILE="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("should_file") else "0")' <<<"$CLASSIFY_JSON")"
  SHOULD_SELF="$(python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("should_self_evolve") else "0")' <<<"$CLASSIFY_JSON")"
  BODY_FILE="$(mktemp)"
  python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])' <<<"$CLASSIFY_JSON" >"$BODY_FILE"
  trap 'rm -f "$BODY_FILE"' EXIT
fi

if [[ -z "$TITLE" || -z "$FINGERPRINT" || -z "$BODY_FILE" ]]; then
  echo "usage:" >&2
  echo "  $0 --log PATH [--label L] [--cmd C] [--notes N]" >&2
  echo "  $0 --title T --fingerprint F --body-file PATH [--class host]" >&2
  exit 2
fi

if [[ ! -f "$BODY_FILE" ]]; then
  echo "error: body file missing: $BODY_FILE" >&2
  exit 1
fi

SAFE_FP="$(echo "$FINGERPRINT" | tr -cd 'a-zA-Z0-9._-')"
DRAFT="$DRAFT_DIR/${SAFE_FP}.md"
META="$DRAFT_DIR/${SAFE_FP}.json"
URL_FILE="${DRAFT}.url"

# Already filed?
if [[ -f "$URL_FILE" ]]; then
  echo "skip: already filed $(cat "$URL_FILE")"
  exit 0
fi

if [[ -f "$DRAFT" ]] && [[ -f "$META" ]]; then
  prev_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url",""))' "$META" 2>/dev/null || true)"
  if [[ -n "$prev_url" ]]; then
    echo "skip: meta has url $prev_url"
    echo "$prev_url" >"$URL_FILE"
    exit 0
  fi
fi

# Write / refresh draft (always keep latest body for same fingerprint)
{
  echo "<!-- fingerprint: $SAFE_FP class: $CLASS -->"
  echo
  cat "$BODY_FILE"
} >"$DRAFT"

python3 - "$META" "$SAFE_FP" "$CLASS" "$TITLE" "$REPO" <<'PY'
import json, sys
from datetime import datetime, timezone
meta_path, fp, cls, title, repo = sys.argv[1:6]
data = {
    "fingerprint": fp,
    "class": cls,
    "title": title,
    "repo": repo,
    "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "url": "",
}
try:
    old = json.load(open(meta_path))
    if old.get("url"):
        data["url"] = old["url"]
except Exception:
    pass
json.dump(data, open(meta_path, "w"), indent=2)
print(meta_path)
PY

echo "drafted: $DRAFT"
echo "class=$CLASS confidence=${CONFIDENCE:-n/a} action=${ACTION:-n/a} fingerprint=$SAFE_FP title=$TITLE"
echo "should_file=${SHOULD_FILE:-?} should_self_evolve=${SHOULD_SELF:-?}"

# Unify-owned → self-evolve queue, never Aura
if [[ "$SHOULD_SELF" == "1" || "$CLASS" == "unify-self" ]]; then
  echo "refuse-api: unify-self → enqueue self-evolve (not Aura)"
  if [[ -n "$LOG_FILE" ]]; then
    ./scripts/enqueue-self-evolve.sh \
      --log "$LOG_FILE" \
      --label "$LABEL" \
      --cmd "$CMD" \
      --notes "$NOTES" || true
  fi
  exit 0
fi

# Hard gate: only confirmed host may hit Aura API
if [[ "$CLASS" != "host" ]]; then
  echo "refuse-api: class=$CLASS (not host); draft kept"
  exit 0
fi

if [[ -n "$LOG_FILE" && "$SHOULD_FILE" != "1" ]]; then
  echo "refuse-api: host not confirmed (confidence=${CONFIDENCE:-unknown} should_file=0) — human 定界 required; draft kept"
  exit 0
fi

# Legacy --body-file path without classifier: require explicit UNIFY_FORCE_HOST=1
if [[ -z "$LOG_FILE" && "${UNIFY_FORCE_HOST:-0}" != "1" ]]; then
  echo "refuse-api: legacy body-file without --log requires UNIFY_FORCE_HOST=1 after human 定界; draft kept"
  exit 0
fi

# Auto-issue: still need UNIFY_AUTO_ISSUE=1 (continuous sets default 1)
AUTO="${UNIFY_AUTO_ISSUE:-0}"
if [[ "$FORCE_DRAFT_ONLY" == "1" ]]; then
  AUTO=0
fi

if [[ "$AUTO" != "1" ]]; then
  echo "dry-run: set UNIFY_AUTO_ISSUE=1 to create issue on $REPO (draft kept; 定界 already passed)"
  exit 0
fi

load_token || true

# Search open issues for fingerprint / title dedupe
search_existing() {
  local q url code resp
  if [[ -z "${GH_TOKEN:-}" ]]; then
    return 1
  fi
  # Search in repo issues for fingerprint marker
  q="repo:${REPO}+is:issue+in:body+${SAFE_FP}"
  resp="$(mktemp)"
  code="$(curl -sS -o "$resp" -w "%{http_code}" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/search/issues?q=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$q")&per_page=5" || true)"
  if [[ "$code" != "200" ]]; then
    rm -f "$resp"
    return 1
  fi
  url="$(python3 - "$resp" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
items = data.get("items") or []
print(items[0]["html_url"] if items else "")
PY
)"
  rm -f "$resp"
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi
  return 1
}

if existing="$(search_existing)"; then
  echo "skip: open/existing issue $existing"
  echo "$existing" >"$URL_FILE"
  python3 - "$META" "$existing" <<'PY'
import json, sys
path, url = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["url"] = url
json.dump(d, open(path, "w"), indent=2)
PY
  exit 0
fi

create_with_gh() {
  command -v gh >/dev/null 2>&1 || return 1
  local args=(issue create -R "$REPO" --title "$TITLE" --body-file "$DRAFT")
  if [[ -n "$LABELS" ]]; then
    # best-effort labels (may fail if label missing)
    IFS=',' read -ra ls <<<"$LABELS"
    for lb in "${ls[@]}"; do
      lb="$(echo "$lb" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$lb" ]] && args+=(--label "$lb")
    done
  fi
  local url
  if ! url="$(gh "${args[@]}" 2>/tmp/unify-gh-issue.err)"; then
    # retry without labels
    url="$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$DRAFT")" || return 1
  fi
  echo "created: $url"
  echo "$url" >"$URL_FILE"
  python3 - "$META" "$url" <<'PY'
import json, sys
path, url = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["url"] = url
json.dump(d, open(path, "w"), indent=2)
PY
  return 0
}

create_with_curl() {
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "error: no GH_TOKEN / ~/.github-token; draft kept at $DRAFT" >&2
    return 4
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "error: curl+python3 required; draft kept at $DRAFT" >&2
    return 4
  fi

  local payload response code
  payload="$(python3 - "$TITLE" "$DRAFT" "$LABELS" <<'PY'
import json, sys
title, path, labels = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    body = f.read()
obj = {"title": title, "body": body}
labs = [x.strip() for x in labels.split(",") if x.strip()]
if labs:
    obj["labels"] = labs
print(json.dumps(obj))
PY
)"
  response="$(mktemp)"
  code="$(curl -sS -o "$response" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/${REPO}/issues" \
    -d "$payload" || true)"

  # Retry without labels if 422 (unknown label)
  if [[ "$code" == "422" ]]; then
    payload="$(python3 - "$TITLE" "$DRAFT" <<'PY'
import json, sys
title, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    body = f.read()
print(json.dumps({"title": title, "body": body}))
PY
)"
    code="$(curl -sS -o "$response" -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      "https://api.github.com/repos/${REPO}/issues" \
      -d "$payload" || true)"
  fi

  if [[ "$code" != "201" ]]; then
    echo "error: GitHub API HTTP $code; draft kept at $DRAFT" >&2
    head -c 1200 "$response" >&2 || true
    echo >&2
    rm -f "$response"
    return 5
  fi

  local url
  url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("html_url",""))' "$response")"
  rm -f "$response"
  if [[ -z "$url" ]]; then
    echo "error: no html_url; draft kept at $DRAFT" >&2
    return 5
  fi
  echo "created: $url"
  echo "$url" >"$URL_FILE"
  python3 - "$META" "$url" <<'PY'
import json, sys
path, url = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["url"] = url
json.dump(d, open(path, "w"), indent=2)
PY
  return 0
}

if create_with_gh; then
  exit 0
fi
create_with_curl
