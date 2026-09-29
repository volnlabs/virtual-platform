#!/usr/bin/env bash
set -euo pipefail

for binary in renode timeout realpath sha256sum; do
  if ! command -v "$binary" >/dev/null; then
    echo "MISSING: $binary" >&2
    exit 1
  fi
done

renode --version
echo "renode backend ok"
