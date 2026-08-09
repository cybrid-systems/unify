#!/usr/bin/env bash
# Classify host residual → issue draft; optionally post to cybrid-systems/aura.
#
# Usage:
#   ./scripts/file-aura-issue.sh \
#     --title "short title" \
#     --class host \
#     --fingerprint "socket-wrapper-recurse" \
#     --body-file /path/to/repro.md
#
# Default: write notes/issue-drafts/<fingerprint>.md only.
# Set UNIFY_AUTO_ISSUE=1 to create the issue.
#
# Auth (first match):
#   1. GH_TOKEN / GITHUB_TOKEN env
#   2. ~/.github-token (raw token or KEY=value)
#   3. gh auth session
#
# Prefer `gh` when installed; else GitHub REST via curl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRAFT_DIR="$ROOT/notes/issue-drafts"
mkdir -p "$DRAFT_DIR"

TITLE=""
CLASS="host"
FINGERPRINT=""
BODY_FILE=""
REPO="${UNIFY_AURA_REPO:-cybrid-systems/aura}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TITLE" || -z "$FINGERPRINT" || -z "$BODY_FILE" ]]; then
  echo "usage: $0 --title T --fingerprint F --body-file PATH [--class host]" >&2
  exit 2
fi

if [[ "$CLASS" != "host" ]]; then
  echo "refuse: only class=host may be filed to Aura (got $CLASS)" >&2
  exit 3
fi

if [[ ! -f "$BODY_FILE" ]]; then
  echo "error: body file missing: $BODY_FILE" >&2
  exit 1
fi

SAFE_FP="$(echo "$FINGERPRINT" | tr -cd 'a-zA-Z0-9._-')"
DRAFT="$DRAFT_DIR/${SAFE_FP}.md"

if [[ -f "$DRAFT" ]]; then
  echo "skip: draft already exists $DRAFT"
  exit 0
fi

{
  echo "# $TITLE"
  echo
  echo "- class: \`$CLASS\`"
  echo "- fingerprint: \`$SAFE_FP\`"
  echo "- source: Unify synthesis bed"
  echo "- date: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo
  cat "$BODY_FILE"
} >"$DRAFT"

echo "drafted: $DRAFT"

if [[ "${UNIFY_AUTO_ISSUE:-0}" != "1" ]]; then
  echo "dry-run: set UNIFY_AUTO_ISSUE=1 to create issue on $REPO"
  exit 0
fi

# Load token from ~/.github-token when env empty.
load_token() {
  if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
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

load_token || true

create_with_gh() {
  command -v gh >/dev/null 2>&1 || return 1
  local url
  url="$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$DRAFT")"
  echo "created: $url"
  echo "$url" >"${DRAFT}.url"
  return 0
}

create_with_curl() {
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "error: no GH_TOKEN / ~/.github-token; draft kept at $DRAFT" >&2
    return 4
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "error: neither gh nor curl available; draft kept at $DRAFT" >&2
    return 4
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 required for JSON encode; draft kept at $DRAFT" >&2
    return 4
  fi

  local payload response code body_tmp
  body_tmp="$(mktemp)"
  payload="$(python3 - "$TITLE" "$DRAFT" <<'PY'
import json, sys
title, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    body = f.read()
print(json.dumps({"title": title, "body": body}))
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

  if [[ "$code" != "201" ]]; then
    echo "error: GitHub API HTTP $code; draft kept at $DRAFT" >&2
    head -c 800 "$response" >&2 || true
    echo >&2
    rm -f "$response" "$body_tmp"
    return 5
  fi

  local url
  url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("html_url",""))' "$response")"
  rm -f "$response" "$body_tmp"
  if [[ -z "$url" ]]; then
    echo "error: no html_url in response; draft kept at $DRAFT" >&2
    return 5
  fi
  echo "created: $url"
  echo "$url" >"${DRAFT}.url"
  return 0
}

if create_with_gh; then
  exit 0
fi

create_with_curl
