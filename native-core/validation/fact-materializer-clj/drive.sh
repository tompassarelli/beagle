#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/fact-materializer-clj.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
mkdir -p "$scratch/compiled/beagle" "$scratch/compiled/native"

"$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/frontend_facts.bgl" \
  "$repo/native-core/src/beagle/checker.bgl" \
  "$repo/native-core/src/beagle/artifact_linker.bgl" \
  "$repo/native-core/src/beagle/fact_profile.bgl" \
  "$repo/native-core/src/beagle/fact_materializer.bgl" \
  "$repo/native-core/src/beagle/fact_materializer_clj_render.bgl" \
  "$repo/native-core/src/beagle/fact_materializer_clj.bgl" \
  "$here/fixture.bgl"

"$repo/bin/beagle-build" --target clj \
  "$repo/native-core/src/beagle/fact_materializer_clj_render.bgl" \
  "$scratch/compiled/beagle/fact_materializer_clj_render.clj"
"$repo/bin/beagle-build" --target clj \
  --module-root "native-core/src=$repo/native-core/src" \
  "$here/fixture.bgl" \
  "$scratch/compiled/native/fact_materializer_clj_fixture.clj"

bb -cp "$scratch/compiled" -e \
  "(require 'native.fact-materializer-clj-fixture)
   (System/exit (native.fact-materializer-clj-fixture/main []))"

printf 'fact-materializer-clj: exact deterministic bytes and unsafe identifier rejection passed\n'
