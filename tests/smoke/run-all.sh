#!/usr/bin/env bash
# run-all.sh - the full smoke suite: offline first, then live model calls.
#
# Usage:
#   tests/smoke/run-all.sh
# (live tests use OpenCode's configured default model)

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${SMOKE_SKIP_LIVE:-0}" -eq 1 ]]; then
    printf 'SMOKE_SKIP_LIVE=1: running offline tests only\n'
    exec "$SMOKE_DIR/run-offline.sh"
fi

"$SMOKE_DIR/run-offline.sh" || exit 1
exec "$SMOKE_DIR/run-live.sh" "${1:-all}"
