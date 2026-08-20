#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/program-projection.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/store/src/store/slots.bgl"
  "$repo/store/src/store/types.bgl"
  "$repo/native-core/src/beagle/frontend_facts.bgl"
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/parser_reader.bgl"
  "$repo/native-core/src/beagle/program_projection.bgl"
  "$here/fixture.bgl"
)

timeout --foreground 45s "$repo/bin/beagle" check --agent "${sources[@]}"
timeout --foreground 110s "$repo/bin/beagle" native-exe \
  --out "$scratch/program-projection-fixture" \
  --artifacts "$scratch/artifacts" \
  --entry native.program-projection-fixture/main \
  "${sources[@]}"
timeout --foreground 10s "$scratch/program-projection-fixture"

rg -qx 'stage typed-to-native COMPLETE' "$scratch/artifacts/report.txt"
rg -q '^native-exe-c17 PASS ' "$scratch/artifacts/native-exe.report.txt"

if ldd "$scratch/program-projection-fixture" | rg -qi \
  'racket|raco|clojure|babashka|java|graal'; then
  echo "program-projection: hosted runtime leaked into native executable" >&2
  exit 1
fi

echo "program-projection: structural rename, lexical shadowing, source fidelity, and exact invalidation PASS"
