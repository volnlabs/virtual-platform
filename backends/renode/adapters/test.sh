#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Tests always prove userspace entry; a diagnostic override cannot weaken it.
export VOLN_VP_VERB=test
exec "$SCRIPT_DIR/run.sh" "$@"
