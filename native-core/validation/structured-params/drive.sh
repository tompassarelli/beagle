#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-structured-params.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

source_file="$here/fixture.bgl"
affordance_source="$here/affordance_fixture.bgl"
ast="$scratch/fixture.ast.json"
affordance_ast="$scratch/affordance.ast.json"
facts="$scratch/fixture.facts"
report="$scratch/affordance.json"

"$repo/bin/beagle" check --agent "$source_file"
"$repo/bin/beagle" ast "$source_file" >"$ast"

bb -e '
  (require (quote [cheshire.core :as json]))
  (let [ast (json/parse-string (slurp (first *command-line-args*)))
        functions (filter #(= "defn" (get % "node")) (get ast "forms"))]
    (assert (every? #(= 1 (count (get % "params"))) functions))
    (assert (= "map-destructure"
               (get-in (first functions) ["params" 0 "name" "type"])))
    (assert (= "seq-destructure"
               (get-in (nth functions 2) ["params" 0 "name" "type"])))
    (assert (= "seq-destructure"
               (get-in (nth functions 3)
                       ["params" 0 "name" "names" 0 "type"])))
    (assert (= "map-destructure"
               (get-in (last functions)
                       ["body" 0 "args" 0 "params" 0 "name" "type"]))))' "$ast"

bb "$repo/native-core/bin/source-facts.clj" \
  --input "$ast=native-core/validation/structured-params/fixture.bgl" \
  --output "$facts" --include-defs

rg -q $'\tform-kind\tt\tmap-destructure$' "$facts"
rg -q $'\tform-kind\tt\tseq-destructure$' "$facts"
rg -q $'\tform-kind\tt\tbinding-default$' "$facts"
rg -q $'\tname\tt\thost-name$' "$facts"

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
for function in request-host request-port-plus pair-sum nested-sum nested-request-port map-port request-ports; do
  rg -q "^lowered .* ${function} " "$scratch/artifacts/report.txt"
done

echo "drive.sh: checked AST, recursive source facts, affordance names, and one-slot native parameter projection PASS"
