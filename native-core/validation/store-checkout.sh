#!/usr/bin/env bash
# Resolve the Store module in this checkout for validation gates.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd -P)"
store="$repo/store"
[[ -d "$store" ]] || {
  echo "store-checkout: Store module is unavailable: $store" >&2
  exit 1
}
printf '%s\n' "$store"
