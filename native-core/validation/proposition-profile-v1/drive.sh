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

echo "proposition-profile-v1: reconciling compiler workload with tracked corpus"
namespace="native.proposition-profile-v1-fixture"

timeout --foreground 10s bb -cp "$scratch" -e \
  "(require '$namespace)
   (doseq [line ($namespace/compiler-oracle-identity-lines)]
     (println line))" \
  >"$scratch/actual-identities.tsv"

awk -F $'\t' '
  BEGIN {OFS="\t"}
  $1 == "baseline" && $2 == "semantic-unit-id" {print; next}
  $2 == "module-source" && $3 == "corpus/foundation.bgl" &&
    ($1 == "baseline" || $1 == "comment-layout" ||
     $1 == "private-implementation" || $1 == "public-interface") {print; next}
  $2 == "module-source" && $3 == "corpus/feature.bgl" &&
    ($1 == "baseline" || $1 == "public-interface") {print; next}
  $2 == "semantic-unit-content" &&
    (($3 == "corpus.foundation/private-offset" &&
      ($1 == "baseline" || $1 == "private-implementation")) ||
     ($3 == "corpus.foundation/adjust" &&
      ($1 == "baseline" || $1 == "public-interface")) ||
     ($3 == "corpus.feature/score-value" &&
      ($1 == "baseline" || $1 == "public-interface"))) {print; next}
  $2 == "module-interface" && $3 == "corpus/foundation.bgl" &&
    ($1 == "baseline" || $1 == "public-interface") {print}
' "$repo/bin/test/branch-compile-corpus/oracle/identities.tsv" \
  >"$scratch/expected-identities.tsv"

LC_ALL=C sort "$scratch/actual-identities.tsv" \
  >"$scratch/actual-identities.sorted.tsv"
LC_ALL=C sort "$scratch/expected-identities.tsv" \
  >"$scratch/expected-identities.sorted.tsv"
diff -u \
  "$scratch/expected-identities.sorted.tsv" \
  "$scratch/actual-identities.sorted.tsv"

timeout --foreground 10s bb -cp "$scratch" -e \
  "(require '$namespace)
   (doseq [line ($namespace/compiler-read-lines)]
     (println line))" \
  >"$scratch/actual-reads.tsv"

awk -F $'\t' '
  BEGIN {OFS="\t"}
  $1 !~ /^#/ && $4 != "-" {
    count = split($4, dependencies, ",")
    for (i = 1; i <= count; i += 1) {
      print $1, dependencies[i]
    }
  }
' "$repo/bin/test/branch-compile-corpus/units.tsv" \
  >"$scratch/expected-reads.tsv"

LC_ALL=C sort "$scratch/actual-reads.tsv" >"$scratch/actual-reads.sorted.tsv"
LC_ALL=C sort "$scratch/expected-reads.tsv" \
  >"$scratch/expected-reads.sorted.tsv"
diff -u "$scratch/expected-reads.sorted.tsv" "$scratch/actual-reads.sorted.tsv"

timeout --foreground 10s bb -cp "$scratch" -e \
  "(require '$namespace)
   (doseq [line ($namespace/compiler-cone-member-lines)]
     (println line))" \
  >"$scratch/actual-cones.tsv"

for stage in typed-unit native-unit; do
  awk -F $'\t' -v stage="$stage" '
    BEGIN {OFS="\t"}
    $1 !~ /^#/ && $2 == stage && $3 != "-" {
      count = split($3, units, ",")
      for (i = 1; i <= count; i += 1) {
        print $1, units[i]
      }
    }
  ' "$repo/bin/test/branch-compile-corpus/expected-cones.tsv" \
    | LC_ALL=C sort >"$scratch/expected-$stage.tsv"
done

diff -u "$scratch/expected-typed-unit.tsv" "$scratch/expected-native-unit.tsv"
LC_ALL=C sort "$scratch/actual-cones.tsv" >"$scratch/actual-cones.sorted.tsv"
diff -u "$scratch/expected-typed-unit.tsv" "$scratch/actual-cones.sorted.tsv"

echo "proposition-profile-v1: fixture PASS"
