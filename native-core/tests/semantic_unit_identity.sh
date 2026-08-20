#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-semantic-unit-identity.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

command -v bb >/dev/null 2>&1 || {
  echo "semantic_unit_identity.sh: babashka (bb) is required" >&2
  exit 2
}

interface_sha256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

bb -e '
  (require (quote [cheshire.core :as json])
           (quote [clojure.string :as str]))
  (load-file (nth *command-line-args* 10))
  (let [source-id "semantic/unit_fixture.bgl"
        int-type {"kind" "prim" "name" "Int"}
        parameter
        (fn [binding-id]
          {"type" "param"
           "name" "value"
           "ann" int-type
           "bindingId" binding-id})
        function
        (fn [name value binding-id]
          {"node" "defn"
           "name" name
           "private" false
           "params" [(parameter binding-id)]
           "rest" nil
           "ret" int-type
           "effectiveType" {"kind" "fn"
                            "params" [int-type]
                            "rest" nil
                            "ret" int-type}
           "body" [{"node" "call"
                    "fn" {"node" "ref" "name" "+"}
                    "args" [{"node" "ref"
                             "name" "value"
                             "refersTo" binding-id}
                            {"node" "literal" "kind" "number" "value" value}]}]})
        shadow
        (fn [reference-id]
          {"node" "defn"
           "name" "shadow"
           "private" false
           "params" [(parameter "parameter:semantic/unit_fixture.bgl:0:value")]
           "rest" nil
           "ret" int-type
           "effectiveType" {"kind" "fn"
                            "params" [int-type]
                            "rest" nil
                            "ret" int-type}
           "body" [{"node" "let"
                    "bindings" [{"name" "value"
                                 "ann" int-type
                                 "bindingId" "let:semantic/unit_fixture.bgl:1:value"
                                 "value" {"node" "literal" "kind" "number" "value" 5}}]
                    "body" [{"node" "ref"
                             "name" "value"
                             "refersTo" reference-id}]}]})
        base
        {"kind" "beagle.checked-program"
         "schemaVersion" 4
         "phase" "checked"
         "target" "core"
         "namespace" "semantic.unit-fixture"
         "sourceId" source-id
         "sourceSha256" (first *command-line-args*)
         "gen-class" false
         "imports" []
         "importedRecordFieldOrder" {}
         "importedRecordNamespaces" {}
         "requires" []
         "externs" []
         "forms" [(function "stable" 7
                    "parameter:semantic/unit_fixture.bgl:0:value")]}
        inserted
        (assoc base
          "sourceSha256" (second *command-line-args*)
          "forms" [(function "earlier" 3
                     "parameter:semantic/unit_fixture.bgl:0:value")
                   (function "stable" 7
                     "parameter:semantic/unit_fixture.bgl:1:value")])
        mutated
        (assoc base
          "sourceSha256" (nth *command-line-args* 2)
          "forms" [(function "stable" 8
                    "parameter:semantic/unit_fixture.bgl:0:value")])
        shadow-let
        (assoc base
          "sourceSha256" (nth *command-line-args* 3)
          "forms" [(shadow "let:semantic/unit_fixture.bgl:1:value")])
        shadow-parameter
        (assoc base
          "sourceSha256" (nth *command-line-args* 4)
          "forms" [(shadow "parameter:semantic/unit_fixture.bgl:0:value")])]
    (spit (nth *command-line-args* 5)
      (json/generate-string
        (native.checked-program/with-projection-digest base)))
    (spit (nth *command-line-args* 6)
      (json/generate-string
        (native.checked-program/with-projection-digest inserted)))
    (spit (nth *command-line-args* 7)
      (json/generate-string
        (native.checked-program/with-projection-digest mutated)))
    (spit (nth *command-line-args* 8)
      (json/generate-string
        (native.checked-program/with-projection-digest shadow-let)))
    (spit (nth *command-line-args* 9)
      (json/generate-string
        (native.checked-program/with-projection-digest shadow-parameter))))' \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  "sha256:2222222222222222222222222222222222222222222222222222222222222222" \
  "sha256:3333333333333333333333333333333333333333333333333333333333333333" \
  "sha256:4444444444444444444444444444444444444444444444444444444444444444" \
  "sha256:5555555555555555555555555555555555555555555555555555555555555555" \
  "$scratch/base.ast.json" \
  "$scratch/inserted.ast.json" \
  "$scratch/mutated.ast.json" \
  "$scratch/shadow-let.ast.json" \
  "$scratch/shadow-parameter.ast.json" \
  "$repo/native-core/bin/checked-program.clj"

for version in base inserted mutated shadow-let shadow-parameter; do
  bb "$repo/native-core/bin/source-facts.clj" \
    --input "$scratch/$version.ast.json=semantic/unit_fixture.bgl" \
    --interface-sha256 "semantic/unit_fixture.bgl=$interface_sha256" \
    --output "$scratch/$version.facts.manifest" --include-defs
done

real_fixture="$repo/native-core/validation/scalar-numerics/fixture.bgl"
"$repo/bin/beagle-ast" --interface-sha256-out "$scratch/real.interface.sha256" \
  "$real_fixture" >"$scratch/real.ast.json"
"$repo/bin/beagle-ast" --bundle "$real_fixture" >"$scratch/real.bundle.json"
bb -e '
  (require (quote [cheshire.core :as json])
           (quote [clojure.string :as str]))
  (let [projection (json/parse-string (slurp (first *command-line-args*)))
        bundle (json/parse-string (slurp (second *command-line-args*)))
        sidecar (str/trim (slurp (nth *command-line-args* 2)))
        bundled (get-in bundle ["modules" 0 "interfaceSha256"])]
    (assert (= 2 (get bundle "schemaVersion"))
      "bundle interface digest did not mint schemaVersion 2")
    (assert (= sidecar bundled) "single-source and bundle interface digests differ")
    (assert (not= sidecar (get projection "projectionSha256"))
      "real interface digest collapsed into checked projection digest"))' \
  "$scratch/real.ast.json" "$scratch/real.bundle.json" \
  "$scratch/real.interface.sha256"

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,200p' "$scratch/build.log" >&2
    exit 1
  }

bb -cp "$scratch/out" -e '
  (require (quote [native.slice :as slice])
           (quote [native.stages :as stages])
           (quote [native.core :as core])
           (quote [native.lower :as lower]))
  (defn definition-subject [rows definition-name]
    (some
      (fn [row]
        (when (and (= "name" (slice/slicefactv0-predicate row))
                   (slice/text-row? row)
                   (= definition-name (slice/row-text row)))
          (slice/slicefactv0-subject row)))
      rows))
  (let [base-rows (slice/read-fact-manifest (first *command-line-args*))
        inserted-rows (slice/read-fact-manifest (second *command-line-args*))
        mutated-rows (slice/read-fact-manifest (nth *command-line-args* 2))
        base-id (definition-subject base-rows "stable")
        inserted-id (definition-subject inserted-rows "stable")
        mutated-id (definition-subject mutated-rows "stable")
        source (slice/source-program base-rows
                 "semantic.unit-fixture" "semantic/unit_fixture.bgl")
        module (first (stages/sourcestagev1-modules source))
        unit (some
               (fn [candidate]
                 (when (= "stable" (stages/sourceunitv0-name candidate)) candidate))
               (stages/sourcestagev1-units source))
        base-semantic
        (slice/row-first-text base-rows base-id "semantic-unit-sha256")
        inserted-semantic
        (slice/row-first-text inserted-rows inserted-id "semantic-unit-sha256")
        mutated-semantic
        (slice/row-first-text mutated-rows mutated-id "semantic-unit-sha256")
        shadow-let-rows (slice/read-fact-manifest (nth *command-line-args* 3))
        shadow-parameter-rows
        (slice/read-fact-manifest (nth *command-line-args* 4))
        shadow-let-id (definition-subject shadow-let-rows "shadow")
        shadow-parameter-id (definition-subject shadow-parameter-rows "shadow")
        shadow-let-semantic
        (slice/row-first-text shadow-let-rows shadow-let-id "semantic-unit-sha256")
        shadow-parameter-semantic
        (slice/row-first-text shadow-parameter-rows shadow-parameter-id
          "semantic-unit-sha256")
        checked-projection
        (slice/row-first-text base-rows
          (first (slice/form-node-names base-rows "module-root"))
          "checked-projection-sha256")
        module-projection (stages/sourcemodulev1-projection-digest module)
        interface-digest (stages/sourcemodulev1-interface-digest module)
        expected-interface (nth *command-line-args* 3)
        result-id (core/->NativeId "semantic-test-result")
        type-id (core/->NativeId "semantic-test-type")
        block-id (core/->NativeId "semantic-test-block")
        function-id (core/->NativeId "semantic-test-function")
        result (core/->SsaValueV0 result-id type-id)
        atom-one (core/->AtomInstruction result (core/->I64Atom 1))
        atom-two (core/->AtomInstruction result (core/->I64Atom 2))
        positive-zero (core/->F64Atom 0.0)
        negative-zero (core/->F64Atom -0.0)
        nan-one (core/->F64Atom
                  (Double/longBitsToDouble 9221120237041090561))
        nan-two (core/->F64Atom
                  (Double/longBitsToDouble 9221120237041090562))
        function
        (fn [instruction]
          (core/->FunctionDef function-id "semantic-test" []
            [(core/->BasicBlock block-id [] [instruction]
               [(core/->ReturnTerminator result-id)])]
            block-id type-id [] [] []))
        function-one (lower/encode-native-function (function atom-one))
        function-two (lower/encode-native-function (function atom-two))
        failures
        (cond-> []
          (or (not= base-id inserted-id) (not= base-id mutated-id))
          (conj (str "semantic unit ID churned: "
                  base-id " -> " inserted-id " / " mutated-id))
          (not= base-semantic inserted-semantic)
          (conj "parameter-bearing definition semantic digest churned after earlier insertion")
          (= base-semantic mutated-semantic)
          (conj "private literal mutation did not change semantic-unit-sha256")
          (= shadow-let-semantic shadow-parameter-semantic)
          (conj "shadowed parameter and let reference merged into one semantic digest")
          (not= expected-interface interface-digest)
          (conj (str "SourceModuleV1 did not retain interface digest: "
                  interface-digest " != " expected-interface))
          (= checked-projection interface-digest)
          (conj "SourceModuleV1 used projectionSha256 as interface-digest")
          (not= checked-projection module-projection)
          (conj "SourceModuleV1 did not retain checked projection digest")
          (nil? unit)
          (conj "SourceUnitV0 was not exported")
          (and unit (not= base-semantic (stages/sourceunitv0-semantic-digest unit)))
          (conj "SourceUnitV0 semantic digest disagrees with source facts")
          (and unit
            (not= (core/nativeid-value (slice/node-id base-id))
                  (core/nativeid-value (stages/sourceunitv0-id unit))))
          (conj "SourceUnitV0 identity disagrees with its stable root term")
          (= (lower/encode-instruction atom-one)
             (lower/encode-instruction atom-two))
          (conj "AtomInstruction encoding omitted its NativeAtom payload")
          (= function-one function-two)
          (conj "native-function-v0 encoding omitted its literal payload")
          (= (stages/content-digest function-one)
             (stages/content-digest function-two))
          (conj "native function content digest ignored a literal mutation")
          (= (lower/encode-native-atom positive-zero)
             (lower/encode-native-atom negative-zero))
          (conj "F64 atom encoding collapsed positive and negative zero")
          (= (lower/encode-native-atom nan-one)
             (lower/encode-native-atom nan-two))
          (conj "F64 atom encoding collapsed distinct NaN payloads"))]
    (when (seq failures)
      (doseq [failure failures] (binding [*out* *err*] (println failure)))
      (throw (ex-info "semantic unit identity contract failed" {:failures failures})))
    (println "semantic unit identity: parameter-position stability, shadowing distinction, semantic/interface separation, and lossless atom encoding PASS"))' \
  "$scratch/base.facts.manifest" "$scratch/inserted.facts.manifest" \
  "$scratch/mutated.facts.manifest" "$scratch/shadow-let.facts.manifest" \
  "$scratch/shadow-parameter.facts.manifest" \
  "$interface_sha256"
