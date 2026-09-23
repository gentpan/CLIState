#!/bin/bash
# Local builds keep 0.x.x unchanged; only explicit releases change it.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    --build) exec python3 scripts/local_version.py build ;;
    "") echo "usage: $0 --build | 0.x.x" >&2; exit 1 ;;
    *) exec python3 scripts/local_version.py release "$1" ;;
esac
