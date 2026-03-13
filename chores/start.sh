#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT/.env.chores" ]] && { set -a; source "$ROOT/.env.chores"; set +a; }
cd "$(dirname "$ROOT")/elixir"
exec mise exec -- mix phx.server -- "$ROOT/WORKFLOW.md" --port 4001
