#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-program-transaction.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

module_root="store/src=$repo/store/src"
sources=(
  "$repo/store/src/store/slots.bgl"
  "$repo/store/src/store/types.bgl"
  "$repo/native-core/src/beagle/program_transaction.bgl"
  "$here/fixture.bgl"
)

echo "program-transaction: checking exact Triple planner"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  --module-root "$module_root" "${sources[@]}"

echo "program-transaction: building focused Native executable"
timeout --foreground 150s "$repo/bin/beagle" native-exe \
  --out "$scratch/program-transaction-fixture" \
  --entry native.program-transaction-fixture/main \
  --module-root "$module_root" "${sources[@]}"

echo "program-transaction: running shadowing-safe rename"
timeout --foreground 10s "$scratch/program-transaction-fixture"

if ldd "$scratch/program-transaction-fixture" | rg -qi \
  'racket|raco|clojure|babashka|java|graal'; then
  echo "program-transaction: hosted runtime leaked into Native executable" >&2
  exit 1
fi

echo "program-transaction: exact Triple deltas and conflict atomicity PASS"
