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
# Set UNIFY_AUTO_ISSUE=1 to `gh issue create -R cybrid-systems/aura`.
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

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh not installed; draft kept at $DRAFT" >&2
  exit 4
fi

URL="$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$DRAFT")"
echo "created: $URL"
echo "$URL" >"${DRAFT}.url"
