#!/usr/bin/env bash
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd -P)
gate=${HIERARCHICAL_IMPLEMENTATION_ROOT:-$dir/../..}/hooks/hierarchical-implementation-gate.sh
if [[ ! -f $gate ]]; then
  printf '{}\n'
  exit 0
fi
exec bash "$gate" --harness agy "$@"
