#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
projection_key="$("$repo/bin/beagle-core-compiler-projection" --print-key)"
compiled="${BEAGLE_CORE_COMPILED_OVERRIDE:-${BEAGLE_CORE_COMPILER_CACHE:-${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}/beagle/core-compiler-projections}/$projection_key/compiled}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-dev-native-materialization-key.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for module in core stages obligations lower unit_reuse; do
    [[ -f "$compiled/native/$module.clj" ]] || {
        echo "dev-native-materialization-key: current compiled projection is not cached: $compiled" >&2
        exit 2
    }
done

attempt="$(awk '
    /^\(defn dev-compile-attempt/ { emitting = 1 }
    /^\(defn dev-fact-report/ { emitting = 0 }
    emitting { print }
' "$repo/bin/beagle-build-core")"
compact_attempt="$(tr '\n' ' ' <<<"$attempt")"
rg -q '\(unit/assemble-unit-payloads .* compiler-commit configuration abi\)' \
    <<<"$compact_attempt" || {
    echo "dev-native-materialization-key: compiler commit left final assembly provenance" >&2
    exit 1
}
rg -q '\(dev-native-result[[:space:]]+assembly[[:space:]]+compiler-commit[[:space:]]+configuration[[:space:]]+abi\)' \
    <<<"$compact_attempt" || {
    echo "dev-native-materialization-key: compiler commit left native receipt provenance" >&2
    exit 1
}

mkdir -p "$scratch/fixture"
{
    printf '%s\n' '(ns fixture.seam' \
        '  (:require [native.core :as core]' \
        '            [native.stages :as stages]' \
        '            [native.lower :as lower]' \
        '            [native.unit-reuse :as unit]))'
    awk '
        /^\(defn dev-materialization-closure-digest/ { emitting = 1 }
        /^\(defn dev-native-requests/ { emitting = 0 }
        emitting { print }
    ' "$repo/bin/beagle-build-core"
    awk '
        /^\(defn dev-native-result$/ { emitting = 1 }
        /^\(defn dev-compile-attempt/ { emitting = 0 }
        emitting { print }
    ' "$repo/bin/beagle-build-core"
} >"$scratch/fixture/seam.clj"

cat >"$scratch/assertions.clj" <<'EOF'
(ns fixture.assertions
  (:require [fixture.seam :as seam]
            [native.core :as core]
            [native.stages :as stages]
            [native.lower :as lower]
            [native.unit-reuse :as unit]))

(defn check [condition message]
  (when-not condition
    (binding [*out* *err*]
      (println (str "dev-native-materialization-key: " message)))
    (System/exit 1)))

(def profile
  (unit/->ProfileIdentityV1
   "native-core" "v1" "fixture-environment" "lp64"
   "fixture-profile-encoding" "fixture-profile-digest"))

(defn receipt [unit-id semantic-digest]
  (unit/->UnitDerivationReceiptV1
   (str "receipt-" semantic-digest)
   profile
   unit-id
   semantic-digest
   "fixture-dependency-context"
   "fixture-typing-environment"
   []
   "fixture-contract-set"
   "fixture-rule-epoch"
   "fixture-materialization-receipt"
   []
   (str "encoding-" semantic-digest)))

(def unit-a-id (core/->NativeId "fixture-unit-a"))
(def unit-b-id (core/->NativeId "fixture-unit-b"))
(def payload-id (core/->NativeId "fixture-payload-type"))
(def payload-i64
  (core/->TypeDef payload-id "FixturePayload"
                  (core/->AtomType (core/->I64Kind true))))
(def payload-bool
  (core/->TypeDef payload-id "FixturePayload"
                  (core/->AtomType (core/->BoolKind true))))

(defn typed-unit [unit-id body types]
  (unit/->TypedUnitV0
   unit-id {:body body} types [] []
   (str "typed-encoding-" body)
   (str "typed-digest-" body)))

(def typed-a-v1 (typed-unit unit-a-id "a-v1" [payload-i64]))
(def typed-a-v2 (typed-unit unit-a-id "a-v2" [payload-i64]))
(def typed-a-layout-v2 (typed-unit unit-a-id "a-v1" [payload-bool]))
(def typed-b (typed-unit unit-b-id "b-v1" []))
(def abi (core/abi-profile-lp64))
(def receipt-a-v1 (receipt unit-a-id "semantic-a-v1"))
(def receipt-a-v2 (receipt unit-a-id "semantic-a-v2"))
(def receipt-b (receipt unit-b-id "semantic-b-v1"))

(def base-digest
  (seam/dev-materialization-closure-digest [typed-a-v1 typed-b] abi))
(def body-change-digest
  (seam/dev-materialization-closure-digest [typed-a-v2 typed-b] abi))
(def reordered-digest
  (seam/dev-materialization-closure-digest [typed-b typed-a-v1] abi))
(def layout-change-digest
  (seam/dev-materialization-closure-digest [typed-a-layout-v2 typed-b] abi))

(check (= base-digest body-change-digest)
       "an unrelated typed body change changed resolved-layout identity")
(check (= base-digest reordered-digest)
       "typed-unit ordering is not canonical")
(check (not= base-digest layout-change-digest)
       "a resolved-layout change preserved the materialization closure digest")

(def base-a-key (seam/dev-native-result-key receipt-a-v1 base-digest))
(def base-b-key (seam/dev-native-result-key receipt-b base-digest))
(def body-change-b-key
  (seam/dev-native-result-key receipt-b body-change-digest))
(def layout-change-a-key
  (seam/dev-native-result-key receipt-a-v1 layout-change-digest))
(def layout-change-b-key
  (seam/dev-native-result-key receipt-b layout-change-digest))
(def receipt-change-a-key
  (seam/dev-native-result-key receipt-a-v2 base-digest))
(def receipt-change-b-key
  (seam/dev-native-result-key receipt-b base-digest))

(check (= base-b-key body-change-b-key)
       "an unrelated identical-layout body change invalidated an independent native key")
(check (and (not= base-a-key layout-change-a-key)
            (not= base-b-key layout-change-b-key))
       "a resolved-layout change did not invalidate every affected native key")
(check (and (not= base-a-key receipt-change-a-key)
            (= base-b-key receipt-change-b-key))
       "a target receipt change did not remain target-local")

(def graph-root (core/->NativeId "fixture-native-root"))
(def graph
  (stages/->TermGraphV0
   graph-root
   [(stages/->TermNodeV0 graph-root
                          (stages/->TextTermV0 "native-stage-v0"))]))
(def frozen-native
  (stages/->FrozenNativeStageV0
   (stages/->NativeStageV0 graph "fixture-typed-digest" nil [])
   "fixture-native-encoding"
   "fixture-native-digest"))
(def frozen-typed
  (unit/make-frozen-typed
   (stages/content-digest "fixture-source") [payload-i64] [] [] [] []))
(def typed-slice
  (lower/->TypedSliceV0
   [payload-i64] [] [] [] [] [(lower/type-id "LowerFailure")]))
(def assembly
  (unit/->UnitAssemblyV0 frozen-typed typed-slice frozen-native nil []))
(def compiler-commit "fixture-compiler-commit")
(def native-result
  (seam/dev-native-result
   assembly compiler-commit ["profile=3" "abi=lp64"] abi))
(def native-receipt (lower/nativeloweringcompletev0-receipt native-result))
(def native-input-digest
  (lower/typed-compatibility-native-input-digest
   frozen-typed (lower/prepare-native-slice typed-slice abi)))

(check (= compiler-commit
          (core/passreceiptv0-compiler-commit native-receipt))
       "compiler commit is absent from the native receipt")
(check (= native-input-digest
          (core/passreceiptv0-input-digest native-receipt))
       "native receipt input is not the independently prepared typed composite")

(println "dev-native-materialization-key: PASS")
EOF

bb -cp "$compiled:$scratch" "$scratch/assertions.clj"
