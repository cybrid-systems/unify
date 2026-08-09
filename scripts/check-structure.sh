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
  lib/unify-host.aura
  lib/unify-compose.aura
  examples/01-offline-compose/main.aura
  examples/02-live-evolve/main.aura
  examples/03-git-host-probe/main.aura
  scripts/run-aura.sh
  scripts/run-offline.sh
  scripts/env-minimax.sh
  scripts/file-aura-issue.sh
  scripts/overnight.sh
  scripts/run-continuous.sh
  scripts/status.sh
  scripts/classify-failure.py
  scripts/enqueue-self-evolve.sh
  scripts/start.sh
  scripts/evolve.sh
  scripts/evolve-watchdog.sh
  scripts/durable-evolve.sh
  scripts/project-evolve.sh
  scripts/fiber-stress.sh
  scripts/kv-load.sh
  scripts/kv-squeeze.sh
  scripts/llm_controller.py
  projects/kv/tests/fiber-stress.aura
  projects/kv/tests/load-sim.aura
  projects/kv/tests/policy-bench.aura
  projects/kv/lib/kv-engine.aura
  lib/unify-mutate.aura
  lib/unify-explore.aura
  notes/evolution-model.md
  projects/kv/SPEC.md
  projects/kv/lib/kv.aura
  projects/kv/tests/smoke.aura
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
