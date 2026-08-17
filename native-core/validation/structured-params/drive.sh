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
constraint_source="$here/constraint_fixture.bgl"
ast="$scratch/fixture.ast.json"
constraint_ast="$scratch/constraint.ast.json"
constraint_lower_facts="$scratch/constraint-lower.facts"
tampered_constraint_ast="$scratch/tampered-constraint.ast.json"
affordance_ast="$scratch/affordance.ast.json"
affordance_facts="$scratch/affordance.facts"
facts="$scratch/fixture.facts"
mismatch_ast="$scratch/mismatch.ast.json"
mismatch_facts="$scratch/mismatch.facts"
polymorphic_ast="$scratch/polymorphic.ast.json"
polymorphic_facts="$scratch/polymorphic.facts"
variadic_ast="$scratch/variadic.ast.json"
variadic_facts="$scratch/variadic.facts"
multi_ast="$scratch/multi.ast.json"
multi_facts="$scratch/multi.facts"
report="$scratch/affordance.json"

"$repo/bin/beagle" check --agent "$source_file"
if "$repo/bin/beagle" check --agent "$polymorphic_source" \
    >"$scratch/polymorphic-check.log" 2>&1; then
  echo "drive.sh: polymorphic Core ABI passed source checking" >&2
  exit 1
fi
rg -F 'Core requires a closed monomorphic Native ABI' \
  "$scratch/polymorphic-check.log"
"$repo/bin/beagle" ast "$source_file" >"$ast"

"$repo/bin/beagle" check --agent "$constraint_source"
"$repo/bin/beagle" ast "$constraint_source" >"$constraint_ast"
bb -e '
  (require (quote [cheshire.core :as json]))
  (let [ast (json/parse-string (slurp (first *command-line-args*)))
        tampered
        (update ast "forms"
          (fn [forms]
            (mapv
              (fn [form]
                (if (= "constrained" (get form "name"))
                  (assoc-in form ["params" 0 "constraint"] nil)
                  form))
              forms)))]
    (spit (second *command-line-args*) (json/generate-string tampered)))' \
  "$constraint_ast" "$tampered_constraint_ast"
if bb "$repo/native-core/bin/source-facts.clj" \
    --input "$tampered_constraint_ast=native-core/validation/structured-params/constraint_fixture.bgl" \
    --output "$scratch/tampered-constraint.facts" --include-defs \
    >"$scratch/tampered-constraint.stdout" \
    2>"$scratch/tampered-constraint.stderr"; then
  echo "drive.sh: tampered checked-program projection crossed the Native boundary" >&2
  exit 1
fi
rg -F 'projectionSha256 does not match its canonical payload' \
  "$scratch/tampered-constraint.stderr"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$constraint_ast=native-core/validation/structured-params/constraint_fixture.bgl" \
  --output "$scratch/constraint.facts" --include-defs
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$constraint_ast=native-core/validation/structured-params/constraint_fixture.bgl" \
  --output "$constraint_lower_facts" \
  --form 'positive?' --form constrained
rg -q $'\tconstraint\tn\t' "$scratch/constraint.facts"

bb -e '
  (let [rows (map #(clojure.string/split % #"\t")
                  (clojure.string/split-lines (slurp (first *command-line-args*))))
        objects (into {} (map (fn [[s p _ o]] [[s p] o]) rows))
        constraint-owners (keep (fn [[s p k o]]
                                  (when (and (= p "constraint") (= k "n"))
                                    [s o]))
                                rows)
        owner-kinds (frequencies
                      (map (fn [[owner _]]
                             (get objects [owner "form-kind"]))
                           constraint-owners))]
    (assert (= {"param" 10
                "binding" 2
                "for-clause" 1
                "doseq-clause" 1}
               owner-kinds))
    (doseq [kind ["arity-clause" "unsupported-letfn" "fn"]]
      (assert (some (fn [[[subject predicate] object]]
                      (and (= predicate "form-kind") (= object kind)))
                    objects)))
    (let [constraint-owner (first constraint-owners)]
      (assert constraint-owner)
      (let [[_ constraint] constraint-owner]
        (assert (= "ref" (get objects [constraint "form-kind"])))
        (assert (= "positive?" (get objects [constraint "name"]))))))' \
  "$scratch/constraint.facts"
[[ "$(rg -c $'\tconstraint\tn\t' "$scratch/constraint.facts")" -eq 14 ]]

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
  (load-file (nth *command-line-args* 2))
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
    (spit (second *command-line-args*)
      (json/generate-string
        (native.checked-program/with-projection-digest malformed))))' \
  "$ast" "$mismatch_ast" "$repo/native-core/bin/checked-program.clj"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$mismatch_ast=native-core/validation/structured-params/fixture.bgl" \
  --output "$mismatch_facts" --include-defs

# The ordinary Core route must stop at checking, while lowering remains
# independently defensive against a supplied checked projection. Derive that
# controlled projection from the valid inferred fixture and replace only its
# effective signature with the generalized shape the source gate rejects.
bb -e '
  (require (quote [cheshire.core :as json]))
  (load-file (nth *command-line-args* 2))
  (let [ast (json/parse-string (slurp (first *command-line-args*)))
        polymorphic
        (update ast "forms"
          (fn [forms]
            (mapv
              (fn [form]
                (if (= "inferred-increment" (get form "name"))
                  (let [effective (get form "effectiveType")]
                    (assoc form "effectiveType"
                      {"kind" "poly"
                       "vars" ["A"]
                       "body" (assoc-in effective ["params" 0]
                                {"kind" "var" "name" "A"})
                       "bounds" []}))
                  form))
              forms)))]
    (spit (second *command-line-args*)
      (json/generate-string
        (native.checked-program/with-projection-digest polymorphic))))' \
  "$ast" "$polymorphic_ast" "$repo/native-core/bin/checked-program.clj"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$polymorphic_ast=native-core/validation/structured-params/fixture.bgl" \
  --output "$polymorphic_facts" --include-defs

"$repo/bin/beagle" ast "$variadic_source" >"$variadic_ast"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$variadic_ast=native-core/validation/structured-params/variadic_fixture.bgl" \
  --output "$variadic_facts" --include-defs
"$repo/bin/beagle" ast "$multi_source" >"$multi_ast"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$multi_ast=native-core/validation/structured-params/multi_fixture.bgl" \
  --output "$multi_facts" --include-defs

"$repo/bin/beagle" check --agent "$affordance_source"
"$repo/bin/beagle" ast "$affordance_source" >"$affordance_ast"
# Exercise the consumer with W2e's structural ref wire shape even when this
# isolated W2g lane is tested before the sibling serializer is integrated.
bb -e '
  (require (quote [cheshire.core :as json]))
  (let [path (first *command-line-args*)
        _ (load-file (second *command-line-args*))
        ast (json/parse-string (slurp path))
        qualified-ref {"node" "ref"
                       "qualifier" "str"
                       "name" "starts-with?"
                       "providerId" nil}
        structured (assoc-in ast ["forms" 1 "body" 0 "bindings" 0 "value" "fn"]
                     qualified-ref)]
    (assert (= qualified-ref
               (get-in structured
                 ["forms" 1 "body" 0 "bindings" 0 "value" "fn"])))
    (spit path
      (json/generate-string
        (native.checked-program/with-projection-digest structured))))' \
  "$affordance_ast" "$repo/native-core/bin/checked-program.clj"
bb "$repo/native-core/validation/slice-vec/ast-facts.clj" \
  "$affordance_ast=native-core/validation/structured-params/affordance_fixture.bgl" \
  "$affordance_facts"
bb -e '
  (let [rows (map #(clojure.string/split % #"\t")
                  (clojure.string/split-lines
                    (slurp (first *command-line-args*))))
        objects (into {} (map (fn [[s p _ o]] [[s p] o]) rows))
        callee (some (fn [[_ p kind object]]
                       (when (and (= "callee" p) (= "n" kind)) object))
                 rows)]
    (assert callee)
    (assert (= "ref" (get objects [callee "form-kind"])))
    (assert (= "str" (get objects [callee "qualifier"])))
    (assert (= "starts-with?" (get objects [callee "name"]))))' \
  "$affordance_facts"
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

assert_typing_accepted() {
  bb -cp "$compiled" -e '
    (require (quote [native.core :as core])
             (quote [native.lower :as lower])
             (quote [native.slice :as slice]))
    (let [rows (slice/parse-facts (slurp (first *command-line-args*)))
          source (slice/source-program rows "test" "fixture.bgl")
          frozen (lower/sourcefreezeacceptedv0-frozen
                   (lower/freeze-source-stage source "test" ["profile=3"]))
          result (lower/lower-typed-stage frozen "test" ["profile=3"])]
      (when-not (instance? native.lower.TypingAcceptedV0 result)
        (throw (ex-info "focused constraint lowering was rejected" {})))
      (let [diagnostics
              (core/passreceiptv0-diagnostics
                (lower/typingacceptedv0-receipt result))]
        (when-not (= 0 (count diagnostics))
          (throw (ex-info "focused constraint lowering emitted diagnostics"
                   {:diagnostics diagnostics})))))' "$1"
}

diagnostic_codes "$polymorphic_facts" \
  | rg -Fx 'LOWER-POLYMORPHIC-FUNCTION-ABI'
diagnostic_codes "$variadic_facts" \
  | rg -Fx 'LOWER-VARIADIC-FUNCTION-ABI'
diagnostic_codes "$multi_facts" \
  | rg -Fx 'LOWER-MULTI-ARITY-FUNCTION-ABI'
diagnostic_codes "$mismatch_facts" \
  | rg -Fx 'LOWER-EFFECTIVE-PARAMETER-COUNT'
assert_typing_accepted "$constraint_lower_facts"

echo "drive.sh: effective signatures, recursive source facts, one-slot aggregates, and named ABI refusals PASS"
