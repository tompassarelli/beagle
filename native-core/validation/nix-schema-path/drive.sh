#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-nix-schema-path.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

echo "nix-schema-path: checking typed sources"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "$repo/native-core/src/beagle/datum_reader.bgl" \
  "$repo/native-core/src/beagle/nix_schema_path.bgl" \
  "$here/fixture.bgl"

echo "nix-schema-path: building focused Native executable"
timeout --foreground 180s "$repo/bin/beagle" native-exe \
  --out "$scratch/nix-schema-path-fixture" \
  --entry native.nix-schema-path-fixture/main \
  "$repo/native-core/src/beagle/datum_reader.bgl" \
  "$repo/native-core/src/beagle/nix_schema_path.bgl" \
  "$here/fixture.bgl"

echo "nix-schema-path: running pure contract"
timeout --foreground 10s "$scratch/nix-schema-path-fixture"

if ldd "$scratch/nix-schema-path-fixture" | rg -qi \
  'racket|clojure|babashka|java'; then
  echo "nix-schema-path: hosted runtime leaked into native executable" >&2
  exit 1
fi

echo "nix-schema-path: nested source paths, offsets, ignored roots, removals, and deterministic similarity PASS"
