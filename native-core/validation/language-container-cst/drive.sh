#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/language-container-cst.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

sources=(
  "$repo/native-core/src/beagle/language_container_cst.bgl"
  "$here/fixture.bgl"
)

timeout 30s "$repo/bin/beagle" check --agent "${sources[@]}"
timeout 30s "$repo/bin/beagle" native-exe \
  --out "$scratch/language-container-cst" \
  --entry native.language-container-cst-fixture/main \
  "${sources[@]}"
timeout 30s "$scratch/language-container-cst"

echo "language-container-cst: exact trivia, repeated regions, bounded payloads, collision-safe fences, and recovery PASS"
