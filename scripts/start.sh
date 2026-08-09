#!/usr/bin/env bash
# Deprecated alias — use ./scripts/evolve.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evolve.sh" "$@"
