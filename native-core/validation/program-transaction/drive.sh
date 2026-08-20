#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-program-transaction.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

module_roots=(
  --module-root "store/src=$repo/store/src"
  --module-root "native-core/src=$repo/native-core/src"
)

echo "program-transaction: checking ProgramRoot transaction boundary"
timeout --foreground 30s \
  "$repo/bin/beagle" check --agent "${module_roots[@]}" "$here/fixture.bgl"

echo "program-transaction: building focused Native executable"
timeout --foreground 120s \
  "$repo/bin/beagle-native-exe" \
    "${module_roots[@]}" \
    --out "$scratch/program-transaction-fixture" \
    --artifacts "$scratch/artifacts" \
    --entry native.program-transaction-fixture/main \
    -- "$here/fixture.bgl" >"$scratch/native-exe.log"

echo "program-transaction: running shadowing-safe rename"
timeout --foreground 10s "$scratch/program-transaction-fixture"

if ldd "$scratch/program-transaction-fixture" | rg -qi \
  'racket|raco|clojure|babashka|java|graal'; then
  echo "program-transaction: hosted runtime leaked into Native executable" >&2
  exit 1
fi

echo "program-transaction: candidate admission, equality, and conflict boundary PASS"
