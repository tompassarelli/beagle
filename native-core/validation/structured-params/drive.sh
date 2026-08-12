#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-structured-params.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
export BEAGLE_CORE_BUILD_CACHE="$scratch/build-cache"

source_file="$here/fixture.bgl"
affordance_source="$here/affordance_fixture.bgl"
polymorphic_source="$here/polymorphic_fixture.bgl"
variadic_source="$here/variadic_fixture.bgl"
multi_source="$here/multi_fixture.bgl"
ast="$scratch/fixture.ast.json"
affordance_ast="$scratch/affordance.ast.json"
facts="$scratch/fixture.facts"
mismatch_ast="$scratch/mismatch.ast.json"
mismatch_facts="$scratch/mismatch.facts"
report="$scratch/affordance.json"

"$repo/bin/beagle" check --agent "$source_file"
"$repo/bin/beagle" ast "$source_file" >"$ast"

bb -e '
  (require (quote [cheshire.core :as json]))
  (let [ast (json/parse-string (slurp (first *command-line-args*)))
        functions (filter #(= "defn" (get % "node")) (get ast "forms"))
        by-name (into {} (map (juxt #(get % "name") identity) functions))
        aggregates (remove #(= "inferred-increment" (get % "name")) functions)
        inferred (get by-name "inferred-increment")]
    (assert (every? #(= 1 (count (get % "params"))) functions))
    (assert (nil? (get-in inferred ["params" 0 "ann"])))
    (assert (= "fn" (get-in inferred ["effectiveType" "kind"])))
    (assert (= "Int" (get-in inferred ["effectiveType" "params" 0 "name"])))
    (assert (= "Int" (get-in inferred ["effectiveType" "ret" "name"])))
    (assert (= "map-destructure"
               (get-in (first aggregates) ["params" 0 "name" "type"])))
    (assert (= "seq-destructure"
               (get-in (nth aggregates 2) ["params" 0 "name" "type"])))
    (assert (= "seq-destructure"
               (get-in (nth aggregates 3)
                       ["params" 0 "name" "names" 0 "type"])))
    (assert (= "map-destructure"
               (get-in (last aggregates)
                       ["body" 0 "args" 0 "params" 0 "name" "type"]))))' "$ast"

bb "$repo/native-core/bin/source-facts.clj" \
  --input "$ast=native-core/validation/structured-params/fixture.bgl" \
  --output "$facts" --include-defs

rg -q $'\tform-kind\tt\tmap-destructure$' "$facts"
rg -q $'\tform-kind\tt\tseq-destructure$' "$facts"
rg -q $'\tform-kind\tt\tbinding-default$' "$facts"
rg -q $'\tname\tt\thost-name$' "$facts"
rg -q $'\teffective-type\tn\t' "$facts"
rg -q $'\tform-kind\tt\ttype-fn$' "$facts"

bb -e '
  (let [rows (map #(clojure.string/split % #"\t")
                  (clojure.string/split-lines (slurp (first *command-line-args*))))
        objects (into {} (map (fn [[s p _ o]] [[s p] o]) rows))
        text (fn [s p] (get objects [s p]))
        inferred (some (fn [[s p _ o]]
                         (when (and (= p "name") (= o "inferred-increment")) s))
                       rows)
        params (text inferred "params")
        param (text params "f0")
        effective (text inferred "effective-type")
        effective-params (text effective "params")
        effective-param (text effective-params "f0")]
    (assert inferred)
    (assert (nil? (text param "ann")))
    (assert (= "type-fn" (text effective "form-kind")))
    (assert (= "Int" (text effective-param "name"))))' "$facts"

bb -e '
  (require (quote [cheshire.core :as json]))
  (let [ast (json/parse-string (slurp (first *command-line-args*)))
        malformed
        (update ast "forms"
          (fn [forms]
            (mapv
              (fn [form]
                (if (= "inferred-increment" (get form "name"))
                  (assoc-in form ["effectiveType" "params"] [])
                  form))
              forms)))]
    (spit (second *command-line-args*) (json/generate-string malformed)))' \
  "$ast" "$mismatch_ast"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$mismatch_ast=native-core/validation/structured-params/fixture.bgl" \
  --output "$mismatch_facts" --include-defs

"$repo/bin/beagle" check --agent "$affordance_source"
"$repo/bin/beagle" ast "$affordance_source" >"$affordance_ast"
bb "$repo/native-core/analysis/epoch/affordance.clj" \
  --item structured-params \
  --ast "$affordance_ast=$affordance_source" \
  --out "$report"
bb -e '(require (quote [cheshire.core :as json]))
       (let [report (json/parse-string (slurp (first *command-line-args*)))]
         (assert (= 1 (get-in report ["summary" "totalSites"])))
         (assert (= "vector-literal" (get-in report ["sites" 0 "construct"]))))' \
  "$report"

"$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/artifacts" \
  "$source_file"

rg -q '^stage source-to-typed ACCEPTED$' "$scratch/artifacts/report.txt"
rg -q '^stage typed-to-native COMPLETE$' "$scratch/artifacts/report.txt"
for function in inferred-increment request-host request-port-plus pair-sum nested-sum nested-request-port map-port request-ports; do
  rg -q "^lowered .* ${function} " "$scratch/artifacts/report.txt"
  function_index="$(sed -nE \
    "s/^lowered fn_([0-9]+) ${function} .*/\\1/p" \
    "$scratch/artifacts/report.txt")"
  prototype="$(rg " native_m0_fn_${function_index}\\(" \
    "$scratch/artifacts/module_0.h")"
  [[ "$(rg -o 'native_v_[0-9]+' <<<"$prototype" | wc -l)" -eq 1 ]] || {
    echo "drive.sh: ${function} did not retain exactly one source ABI slot" >&2
    exit 1
  }
done

for refusal in polymorphic variadic multi; do
  source_var="${refusal}_source"
  output="$scratch/${refusal}-artifacts"
  if "$repo/bin/beagle" build --materializer c17 --out "$output" \
      "${!source_var}" >"$scratch/${refusal}.log" 2>&1; then
    echo "drive.sh: ${refusal} Native ABI unexpectedly lowered" >&2
    exit 1
  fi
done

compiled_candidates=("$BEAGLE_CORE_BUILD_CACHE"/*/compiled)
[[ ${#compiled_candidates[@]} -eq 1 && -d "${compiled_candidates[0]}" ]] || {
  echo "drive.sh: could not identify the focused compiled Native core" >&2
  exit 1
}
compiled="${compiled_candidates[0]}"

diagnostic_codes() {
  bb -cp "$compiled" -e '
    (require (quote [native.core :as core])
             (quote [native.stages :as stages])
             (quote [native.lower :as lower])
             (quote [native.slice :as slice]))
    (let [rows (slice/parse-facts (slurp (first *command-line-args*)))
          source (slice/source-program rows "test" "fixture.bgl")
          frozen (lower/sourcefreezeacceptedv0-frozen
                   (lower/freeze-source-stage source "test" ["profile=3"]))
          result (lower/lower-typed-stage frozen "test" ["profile=3"])
          receipt (if (instance? native.lower.TypingRejectedV0 result)
                    (lower/typingrejectedv0-receipt result)
                    (lower/typingacceptedv0-receipt result))]
      (doseq [diagnostic (core/passreceiptv0-diagnostics receipt)]
        (println (core/diagnosticv0-code diagnostic))))' "$1"
}

diagnostic_codes "$scratch/polymorphic-artifacts/source.facts" \
  | rg -Fx 'LOWER-POLYMORPHIC-FUNCTION-ABI'
diagnostic_codes "$scratch/variadic-artifacts/source.facts" \
  | rg -Fx 'LOWER-VARIADIC-FUNCTION-ABI'
diagnostic_codes "$scratch/multi-artifacts/source.facts" \
  | rg -Fx 'LOWER-MULTI-ARITY-FUNCTION-ABI'
diagnostic_codes "$mismatch_facts" \
  | rg -Fx 'LOWER-EFFECTIVE-PARAMETER-COUNT'

echo "drive.sh: effective signatures, recursive source facts, one-slot aggregates, and named ABI refusals PASS"
