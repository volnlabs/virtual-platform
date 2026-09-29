#!/usr/bin/env bash
set -euo pipefail

for binary in python3 qemu-system-x86_64 qemu-system-aarch64 qemu-system-riscv64; do
  if ! command -v "$binary" >/dev/null; then
    echo "MISSING: $binary" >&2
    exit 1
  fi
done

echo "qemu backend ok"
