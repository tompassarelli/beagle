#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/typing-prelude-call-index.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

command -v bb >/dev/null 2>&1 || {
  echo "typing_prelude_call_index_gate.sh: babashka (bb) is required" >&2
  exit 2
}

fixture="$repo/native-core/validation/scalar-numerics/fixture.bgl"
ast="$scratch/fixture.ast.json"
facts="$scratch/fixture.facts.manifest"
interface_digest="$scratch/fixture.interface.sha256"

"$repo/bin/beagle-ast" --interface-sha256-out "$interface_digest" \
  "$fixture" >"$ast"
interface_sha256="$(<"$interface_digest")"
bb "$repo/native-core/bin/source-facts.clj" \
  --input "$ast=native-core/validation/scalar-numerics/fixture.bgl" \
  --interface-sha256 \
  "native-core/validation/scalar-numerics/fixture.bgl=$interface_sha256" \
  --output "$facts" --include-defs

"$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/simd.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$repo/native-core/src/native/c11.bclj" \
  "$repo/native-core/src/native/slice.bclj" \
  --out "$scratch/out" >"$scratch/build.log" 2>&1 || {
    sed -n '1,240p' "$scratch/build.log" >&2
    exit 1
  }

gate="$scratch/gate.clj"
cat >"$gate" <<'CLJ'
(require '[native.core :as core]
         '[native.lower :as lower]
         '[native.slice :as slice]
         '[native.stages :as stages])

(def queries
  ["re-find" "re-matches" "some" "str/index-of" "str/includes?"
   "parse-double" "System/getenv" "java.lang.System/getenv" "selfhost.rt/getenv"
   "host.fs/path-kind" "host.fs/real-path" "host.fs/read-text-bounded"
   "host.stdin/read-text-bounded" "host.fs/list-directory-bounded"
   "host.fs/write-text-atomic" "host.fs/make-parent-directories"
   "host.fs/append-text" "host.fs/append-bytes" "host.fs/mtime-nanoseconds"
   "host.fs/create-temporary-sibling" "host.fs/rename-file" "host.fs/remove-file"
   "host.fs/wait-for-change" "host.fs/lock-exclusive" "host.fs/unlock"
   "host.clock/format-iso8601" "host.system/hostname" "host.process/run-capture"
   "host.process/spawn-stdout" "host.process/read-line-bounded"
   "host.process/read-line-deadline"])

(defn require! [condition detail]
  (when-not condition (throw (ex-info detail {}))))

(defn elapsed-ns [operation]
  (let [started (System/nanoTime)]
    (operation)
    (- (System/nanoTime) started)))

(defn best-ns [runs operation]
  (dotimes [_ 2] (operation))
  (apply min (repeatedly runs #(elapsed-ns operation))))

(defn reference-source-call-function [index call]
  (let [callee (lower/index-first-object index call "callee")
        binding-id (if (nil? callee) "" (lower/fact-text index callee "binding-id"))
        resolved (lower/resolve-source-name index
                   (lower/source-module-name index call)
                   (lower/source-callee-name index call))
        functions (lower/index-form-ids index "defn")]
    (loop [position 0]
      (if (>= position (count functions))
        nil
        (let [function (nth functions position)
              function-binding (lower/fact-text index function "binding-id")]
          (if (or
                (and (not= "" binding-id) (= binding-id function-binding))
                (and (lower/resolvedsourcenamev0-visible resolved)
                  (= (lower/resolvedsourcenamev0-module-name resolved)
                    (lower/source-module-name index function))
                  (= (lower/resolvedsourcenamev0-local-name resolved)
                    (lower/fact-text index function "name"))))
            function
            (recur (inc position))))))))

(defn reference-has-callee? [index expected]
  (let [calls (vec (concat (lower/index-form-ids index "call")
                           (lower/index-form-ids index "static-call")))]
    (boolean
      (some #(= expected (lower/source-callee-name index %)) calls))))

(defn reference-parameter-carrier-resolution [index source-function position]
  (let [calls (vec (concat (lower/index-form-ids index "call")
                           (lower/index-form-ids index "static-call")))]
    (loop [scan 0 chosen nil conflict false]
      (if (or (>= scan (count calls)) conflict)
        (if conflict nil chosen)
        (let [call (nth calls scan)
              target (reference-source-call-function index call)
              arguments-node (lower/index-first-object index call "args")
              arguments (if (nil? arguments-node)
                          []
                          (lower/index-sequence-items index arguments-node))]
          (if (or (nil? target)
                  (not (lower/same-id? target source-function))
                  (>= position (count arguments)))
            (recur (inc scan) chosen false)
            (let [candidate
                  (lower/source-expression-carrier-resolution index
                    (nth arguments position) (inc (lower/index-facts index)))]
              (cond
                (nil? candidate) (recur (inc scan) chosen false)
                (nil? chosen) (recur (inc scan) candidate false)
                (lower/same-id? (lower/typeresolutionv0-type-id chosen)
                                (lower/typeresolutionv0-type-id candidate))
                (recur (inc scan)
                  (lower/->TypeResolutionV0
                    (lower/typeresolutionv0-type-id chosen)
                    (lower/append-type-defs
                      (lower/typeresolutionv0-definitions chosen)
                      (lower/typeresolutionv0-definitions candidate))
                    [] true)
                  false)
                :else (recur (inc scan) chosen true)))))))))

(defn expected-calls-by-function [calls targets]
  (reduce
    (fn [found [call target]]
      (if (nil? target)
        found
        (let [key (core/nativeid-value target)]
          (update found key (fnil conj []) call))))
    {}
    (map vector calls targets)))

(let [rows (slice/read-fact-manifest (first *command-line-args*))
      source (slice/source-program rows "native.scalar-numerics"
               "native-core/validation/scalar-numerics/fixture.bgl")
      index (lower/build-source-index
              (stages/sourcestagev1-terms source)
              (stages/sourcestagev1-modules source))
      calls (vec (concat (lower/index-form-ids index "call")
                         (lower/index-form-ids index "static-call")))
      functions (lower/index-form-ids index "defn")
      reference-targets (mapv #(reference-source-call-function index %) calls)
      indexed-targets (mapv #(lower/source-call-function index %) calls)
      reference-callees (mapv #(reference-has-callee? index %) queries)
      indexed-callees (mapv #(lower/index-has-callee? index %) queries)
      expected-by-function (expected-calls-by-function calls reference-targets)
      actual-by-function (lower/sourceindexv0-calls-by-function index)
      carrier-coordinates
      (vec
        (mapcat
          (fn [function]
            (mapv #(vector function %)
              (range (count (lower/function-parameter-items index function)))))
          functions))
      reference-carriers
      (mapv (fn [[function position]]
              (reference-parameter-carrier-resolution index function position))
        carrier-coordinates)
      indexed-carriers
      (mapv (fn [[function position]]
              (lower/parameter-carrier-resolution index function position))
        carrier-coordinates)
      reference-resolutions
      (with-redefs [lower/source-call-function reference-source-call-function
                    lower/parameter-carrier-resolution
                    reference-parameter-carrier-resolution]
        (lower/resolve-functions index))
      indexed-resolutions (lower/resolve-functions index)
      base-index (assoc index :callee-names {} :call-targets {}
                   :calls-by-function {})
      reference-operation
      #(do
         (mapv (fn [call] (reference-source-call-function base-index call)) calls)
         (mapv (fn [query] (reference-has-callee? base-index query)) queries))
      indexed-operation
      #(let [rebuilt (lower/index-prelude-calls base-index)]
         (mapv (fn [call] (lower/source-call-function rebuilt call)) calls)
         (mapv (fn [query] (lower/index-has-callee? rebuilt query)) queries))
      reference-ns (best-ns 5 reference-operation)
      indexed-ns (best-ns 5 indexed-operation)
      early (lower/->FunctionTargetV0 2 (first functions))
      late (lower/->FunctionTargetV0 7 (last functions))]
  (require! (= 31 (count queries)) "gate no longer covers all 31 prelude queries")
  (require! (= reference-targets indexed-targets)
    "indexed call targets differ from the source-order reference")
  (require! (= reference-callees indexed-callees)
    "indexed callee answers differ from the scan reference")
  (require! (= expected-by-function actual-by-function)
    "calls-by-function changed call order or target membership")
  (require! (= reference-carriers indexed-carriers)
    "indexed carrier result, definitions, diagnostics, or order differ")
  (require! (= reference-resolutions indexed-resolutions)
    "indexed function resolutions or diagnostic order differ")
  (require! (= early (lower/earlier-function-target early late))
    "binding/name conflict did not retain the lower source ordinal")
  (require! (< (* 3 indexed-ns) reference-ns)
    "construction-inclusive index path was not at least 3x faster")
  (println "facts" (lower/index-facts index))
  (println "calls" (count calls))
  (println "functions" (count functions))
  (println "carrier-coordinates" (count carrier-coordinates))
  (println "all-call-targets-equal" true)
  (println "all-31-callee-answers-equal" true)
  (println "all-calls-by-function-order-equal" true)
  (println "all-carrier-results-diagnostics-equal" true)
  (println "all-function-resolutions-diagnostics-equal" true)
  (println "reference-ns" reference-ns)
  (println "index-construction-plus-lookups-ns" indexed-ns)
  (println "speedup" (double (/ reference-ns indexed-ns))))
CLJ

report="$scratch/report.txt"
bb -cp "$scratch/out" "$gate" "$facts" >"$report"
cat "$report"

grep -Fxq "all-call-targets-equal true" "$report"
grep -Fxq "all-31-callee-answers-equal true" "$report"
grep -Fxq "all-calls-by-function-order-equal true" "$report"
grep -Fxq "all-carrier-results-diagnostics-equal true" "$report"
grep -Fxq "all-function-resolutions-diagnostics-equal true" "$report"

echo "typing_prelude_call_index_gate.sh: production-path identity and scaling PASS"
