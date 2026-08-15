#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-datum-reader.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

"$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/datum_reader.bgl" \
  "$here/fixture.bgl"

"$repo/bin/beagle" native-exe \
  --out "$scratch/datum-reader-fixture" \
  --entry native.datum-reader-fixture/main \
  "$repo/native-core/src/beagle/datum_reader.bgl" \
  "$here/fixture.bgl"

"$scratch/datum-reader-fixture"
"$scratch/datum-reader-fixture" --emit-source >"$scratch/representative.bnix"
"$repo/bin/beagle" syntax "$scratch/representative.bnix"
if ldd "$scratch/datum-reader-fixture" | rg -qi 'racket|clojure|babashka|java'; then
  echo "datum-reader: hosted runtime leaked into native executable" >&2
  exit 1
fi
echo "datum-reader: typed Native event and literal contract passed"
