#!/usr/bin/env bash
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd -P)
gate=""
for root in "${HIERARCHICAL_IMPLEMENTATION_ROOT:-}" "$dir/../.." "$HOME/vscode/hierarchical-implementation"; do
  [[ -n $root && -f "$root/hooks/hierarchical-implementation-gate.sh" ]] && {
    gate="$root/hooks/hierarchical-implementation-gate.sh"
    break
  }
done
if [[ -z $gate ]]; then
  printf '{}\n'
  exit 0
fi
exec bash "$gate" --harness gemini "$@"
