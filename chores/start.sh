#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT/.env.chores" ]] && { set -a; source "$ROOT/.env.chores"; set +a; }
cd "$(dirname "$ROOT")/elixir"
exec mise exec -- bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4001 \
  "$ROOT/WORKFLOW.md"
