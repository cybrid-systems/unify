#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

required=(
  README.md
  LICENSE
  prompts/GROK.md
  notes/denseness-report.md
  notes/escape-log.md
  notes/host-residuals.md
  lib/unify-min.aura
  lib/unify-measure.aura
  lib/unify-loop.aura
  examples/02-live-evolve/main.aura
  scripts/run-aura.sh
  scripts/run-offline.sh
  scripts/env-minimax.sh
  scripts/file-aura-issue.sh
  scripts/overnight.sh
)

echo "=== Unify structure check ==="
for f in "${required[@]}"; do
  if [[ -f "$f" ]]; then
    echo "  OK  $f"
  else
    echo "  MISSING  $f"
    exit 1
  fi
done
echo "Structure OK"
