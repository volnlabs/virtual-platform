#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ARCH="${VOLN_VP_ARCH:-aarch64}"
case "$ARCH" in
  aarch64|x86_64|riscv64) ;;
  *) echo "unsupported QEMU architecture: $ARCH" >&2; exit 2 ;;
esac
RUNNER="$REPO_ROOT/boards/virt/qemu/$ARCH.sh"

if [[ ! -x "$RUNNER" ]]; then
  echo "unsupported QEMU architecture: $ARCH" >&2
  exit 2
fi

exec "$RUNNER" "$@"
