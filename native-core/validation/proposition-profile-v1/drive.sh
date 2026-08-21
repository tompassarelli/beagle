#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/proposition-profile-v1.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

echo "proposition-profile-v1: checking typed fixture"
timeout --foreground 30s "$repo/bin/beagle" check --agent "$here/fixture.bgl"

echo "proposition-profile-v1: projecting checked Core to Clojure executor"
mkdir -p "$scratch/native"
generated="$scratch/native/proposition_profile_v1_fixture.clj"
timeout --foreground 60s "$repo/bin/beagle-build" \
  --target clj "$here/fixture.bgl" "$generated"

echo "proposition-profile-v1: running bounded semantic canaries"
timeout --foreground 10s bb -cp "$scratch" -e \
  "(require 'native.proposition-profile-v1-fixture)
   (let [exit-code (native.proposition-profile-v1-fixture/main)]
     (when (zero? exit-code)
       (doseq [line (native.proposition-profile-v1-fixture/demo-lines)]
         (println line)))
     (System/exit exit-code))"

echo "proposition-profile-v1: fixture PASS"
