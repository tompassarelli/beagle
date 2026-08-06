#!/usr/bin/env bash
# Materialize the frozen Atom fixture through C17, prove all Native Core
# obligations, prove QBE's explicit refusal, then compile and run the result.
set -euo pipefail

abi="${NATIVE_SLICE_ABI:-lp64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_ATOM_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-atom.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

mkdir -p "$scratch/source-art" "$scratch/refusal-art"
"$repo/bin/beagle-ast" "$here/atom_mutations.bclj" \
  >"$scratch/atom_mutations.ast.json"
"$repo/bin/beagle-ast" "$here/atom_mutation_refusals.bclj" \
  >"$scratch/atom_mutation_refusals.ast.json"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/atom_mutations.ast.json=beagle:native-core/validation/atom/atom_mutations.bclj" \
  --output "$scratch/atom_mutations.facts"
bb "$repo/native-core/validation/slice-bodies/ast-facts.clj" \
  --input "$scratch/atom_mutation_refusals.ast.json=beagle:native-core/validation/atom/atom_mutation_refusals.bclj" \
  --output "$scratch/atom_mutation_refusals.facts"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/worlds.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  "$repo/native-core/src/native/qbe.bclj" \
  "$repo/native-core/src/native/fold_c17.bclj" \
  "$repo/native-core/src/native/body_c17.bclj" \
  "$repo/native-core/src/native/body_slice.bclj" \
  "$repo/native-core/src/native/qbe_validation_corpus.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

# Cross-module union patterns need the provider's records referred and imported
# on the clj validation target.
core_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/core.clj" | tr '\n' ' ')"
qbe_records="$(sed -nE 's/.*\(defrecord ([^ ]+).*/\1/p' \
  "$scratch/out/native/qbe.clj" | tr '\n' ' ')"

for name in worlds lower obligations c11 slice qbe fold_c17 body_c17 body_slice \
    qbe_validation_corpus; do
  sed -i 's/\[native\.core :as core\]/[native.core :as core :refer :all]/' \
    "$scratch/out/native/$name.clj"
  awk -v imp="(import '[native.core $core_records])" \
    '!seen && /^$/ { print imp; seen = 1 } { print }' \
    "$scratch/out/native/$name.clj" >"$scratch/out/native/$name.clj.tmp"
  mv "$scratch/out/native/$name.clj.tmp" "$scratch/out/native/$name.clj"
done

sed -i 's/\[native\.qbe :as qbe\]/[native.qbe :as qbe :refer :all]/' \
  "$scratch/out/native/qbe_validation_corpus.clj"
sed -i "4i(import '[native.qbe $qbe_records])" \
  "$scratch/out/native/qbe_validation_corpus.clj"

clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-slice)
(spit \"$scratch/source-report.txt\"
  (native.body-slice/emit-slice!
    \"$scratch/atom_mutations.facts\"
    \"native.atom-mutations\"
    \"beagle:native-core/validation/atom/atom_mutations.bclj\"
    \"$scratch/source-art\" \"native-atom-mutations-v0\" \"$abi\"))
(spit \"$scratch/refusal-report.txt\"
  (native.body-slice/emit-slice!
    \"$scratch/atom_mutation_refusals.facts\"
    \"native.atom-mutation-refusals\"
    \"beagle:native-core/validation/atom/atom_mutation_refusals.bclj\"
    \"$scratch/refusal-art\" \"native-atom-mutation-refusals-v0\" \"$abi\"))"

for name in direct-update make-counter-cell make-vector-cell reset-counter! \
    update-counter! assoc-counter! assoc-counter-map! append-value! \
    append-values!; do
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { found = 1 } END { exit !found }' \
    "$scratch/source-report.txt" || {
    echo "drive.sh: source mutation did not lower: $name" >&2
    sed -n '1,200p' "$scratch/source-report.txt" >&2
    exit 1
  }
done
rg -q '^materialize OK module_0.h module_0.c$' "$scratch/source-report.txt"
rg -q 'TODO-NATIVE-ATOM-SWAP-UPDATER: swap! requires a statically named pure native updater' \
  "$scratch/refusal-report.txt"

mkdir -p "$scratch/c"
clojure -Sdeps "{:paths [\"$scratch/out\"]}" -M -e "
(require 'native.body-c17 'native.core 'native.obligations 'native.qbe-validation-corpus)
(let [world native.qbe-validation-corpus/atom-world
      verdicts [(native.obligations/valid-ssa world)
                (native.obligations/exhaustive-matches world)
                (native.obligations/closed-layouts world (native.core/abi-profile-lp64))
                (native.obligations/checked-arithmetic world)
                (native.obligations/legal-abi world)
                (native.obligations/discharged-tokens world)
                (native.obligations/bounded-effects world)]
      result (native.body-c17/materialize-world world 4)]
  (when-not (every? native.obligations/obligation-passed? verdicts)
    (throw (ex-info \"Atom fixture failed a Native Core obligation\"
             {:verdicts verdicts})))
  (when-not native.qbe-validation-corpus/atom-refusal-proven?
    (throw (ex-info \"QBE did not explicitly refuse Atom state\" {})))
  (when-not (native.body-c17/materialization-ok? result)
    (throw (ex-info (native.body-c17/materialization-detail result) {})))
  (let [artifact (native.body-c17/materialization-artifact result)]
    (spit (str \"$scratch/c/\" (native.body-c17/bodyartifactv0-header-name artifact))
      (native.body-c17/bodyartifactv0-header-text artifact))
    (spit (str \"$scratch/c/\" (native.body-c17/bodyartifactv0-source-name artifact))
      (native.body-c17/bodyartifactv0-source-text artifact))))
"

cp "$repo/native-core/shim/native_shim.c" \
  "$repo/native-core/shim/native_shim.h" "$repo/native-core/shim/native_unicode15_data.h" "$scratch/c/"

main_source='/* Atom C17 validation driver. */
#include "module_4.h"

int main(void) {
  uint8_t storage[1024];
  native_arena arena;
  native_capability capability = { UINT64_C(1) };
  native_atom *cell;
  native_arena_init(&arena, storage, sizeof(storage));
  cell = native_m4_fn_1(&arena, &capability, INT64_C(17));
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(17)) return 1;
  if (native_m4_fn_3(&arena, &capability, cell, INT64_C(41)) != INT64_C(41)) return 2;
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(41)) return 3;
  if (native_m4_fn_3(&arena, &capability, cell, INT64_C(-7)) != INT64_C(-7)) return 4;
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(-7)) return 5;
  if (native_m4_fn_4(&arena, &capability, cell, INT64_C(99)) != INT64_C(99)) return 6;
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(99)) return 7;
  if (!native_m4_fn_5(&arena, &capability, cell, INT64_C(99), INT64_C(123))) return 8;
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(123)) return 9;
  if (native_m4_fn_5(&arena, &capability, cell, INT64_C(99), INT64_C(456))) return 10;
  if (native_m4_fn_2(&arena, &capability, cell) != INT64_C(123)) return 11;
  return 0;
}
'
printf '%s' "$main_source" >"$scratch/c/main.c"

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
(cd "$scratch/source-art" && gcc "${strict[@]}" -I"$repo/native-core/shim" \
  -c module_0.c -o source_mutations.o)
(cd "$scratch/c" && gcc "${strict[@]}" -o atom_gcc \
  module_4.c native_shim.c main.c && ./atom_gcc)
echo "drive.sh: seven obligations + QBE refusal + gcc strict C17 run ok"

clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" ]]; then
  clang_bin="$(ls -d /nix/store/*-clang-wrapper-*/bin/clang 2>/dev/null | \
    sort -V | tail -1)"
fi
if [[ -n "$clang_bin" ]]; then
  (cd "$scratch/source-art" && "$clang_bin" "${strict[@]}" \
    -I"$repo/native-core/shim" -c module_0.c -o source_mutations_clang.o)
  (cd "$scratch/c" && "$clang_bin" "${strict[@]}" -o atom_clang \
    module_4.c native_shim.c main.c && ./atom_clang)
  echo "drive.sh: clang strict C17 run ok"
else
  echo "drive.sh: clang not found — second frontend not exercised" >&2
fi
