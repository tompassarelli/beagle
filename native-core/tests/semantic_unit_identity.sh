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
  (require (quote [cheshire.core :as json]))
  (load-file (nth *command-line-args* 4))
  (let [source-id "semantic/unit_fixture.bgl"
        function
        (fn [name value]
          {"node" "defn"
           "name" name
           "private" false
           "params" []
           "rest" nil
           "ret" {"kind" "prim" "name" "Int"}
           "effectiveType" {"kind" "fn"
                            "params" []
                            "rest" nil
                            "ret" {"kind" "prim" "name" "Int"}}
           "body" [{"node" "literal" "kind" "number" "value" value}]})
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
         "forms" [(function "stable" 7)]}
        inserted
        (assoc base
          "sourceSha256" (second *command-line-args*)
          "forms" [(function "earlier" 3) (function "stable" 7)])]
    (spit (nth *command-line-args* 2)
      (json/generate-string
        (native.checked-program/with-projection-digest base)))
    (spit (nth *command-line-args* 3)
      (json/generate-string
        (native.checked-program/with-projection-digest inserted))))' \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  "sha256:2222222222222222222222222222222222222222222222222222222222222222" \
  "$scratch/base.ast.json" \
  "$scratch/inserted.ast.json" \
  "$repo/native-core/bin/checked-program.clj"

for version in base inserted; do
  bb "$repo/native-core/bin/source-facts.clj" \
    --input "$scratch/$version.ast.json=semantic/unit_fixture.bgl" \
    --interface-sha256 "semantic/unit_fixture.bgl=$interface_sha256" \
    --output "$scratch/$version.facts" --include-defs
done

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
           (quote [native.stages :as stages]))
  (defn definition-subject [rows definition-name]
    (some
      (fn [row]
        (when (and (= "name" (slice/slicefactv0-predicate row))
                   (slice/text-row? row)
                   (= definition-name (slice/row-text row)))
          (slice/slicefactv0-subject row)))
      rows))
  (let [base-rows (slice/parse-facts (slurp (first *command-line-args*)))
        inserted-rows (slice/parse-facts (slurp (second *command-line-args*)))
        base-id (definition-subject base-rows "stable")
        inserted-id (definition-subject inserted-rows "stable")
        source (slice/source-program base-rows
                 "semantic.unit-fixture" "semantic/unit_fixture.bgl")
        module (first (stages/sourcestagev0-modules source))
        projection (slice/row-first-text base-rows base-id "semantic-unit-sha256")
        checked-projection
        (slice/row-first-text base-rows
          (first (slice/form-node-names base-rows "module-root"))
          "checked-projection-sha256")
        interface-digest (stages/sourcemodulev0-interface-digest module)
        expected-interface (nth *command-line-args* 2)
        failures
        (cond-> []
          (not= base-id inserted-id)
          (conj (str "ordinal source IDs churned stable: " base-id " -> " inserted-id))
          (not= expected-interface interface-digest)
          (conj (str "SourceModuleV0 did not retain interface digest: "
                  interface-digest " != " expected-interface))
          (= checked-projection interface-digest)
          (conj "SourceModuleV0 used projectionSha256 as interface-digest")
          (nil? projection)
          (conj "semantic-unit-sha256 was not exported"))]
    (when (seq failures)
      (doseq [failure failures] (binding [*out* *err*] (println failure)))
      (throw (ex-info "semantic unit identity contract failed" {:failures failures})))
    (println "semantic unit identity: stable IDs, semantic digest, and interface separation PASS"))' \
  "$scratch/base.facts" "$scratch/inserted.facts" "$interface_sha256"
