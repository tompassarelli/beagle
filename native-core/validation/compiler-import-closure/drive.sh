#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
sources=(
  "$repo/native-core/src/beagle/datum_reader.bgl"
  "$repo/native-core/src/beagle/frontend_facts.bgl"
  "$repo/native-core/src/beagle/parser_reader.bgl"
  "$repo/native-core/src/beagle/syntax_semantics.bgl"
  "$here/fixture.bgl"
)

"$repo/bin/beagle" check --agent "${sources[@]}"
echo "native compiler import normalization focused check: PASS"
