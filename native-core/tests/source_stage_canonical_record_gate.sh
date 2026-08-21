#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-source-stage-canonical-record.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

command -v bb >/dev/null 2>&1 || {
  echo "source_stage_canonical_record_gate.sh: babashka (bb) is required" >&2
  exit 2
}

timeout 120s nice -n 19 "$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  --out "$scratch/out"

timeout 30s nice -n 19 bb -cp "$scratch/out" -e '
  (require (quote [native.core :as core])
           (quote [native.stages :as stages])
           (quote [clojure.string :as str]))

  (defn require! [condition detail]
    (when-not condition (throw (ex-info detail {}))))

  (defn old-record [tag fields]
    (str (count tag) ":" tag ":" (core/canonical-parts fields)))

  (defn joined-record [tag fields]
    (let [size (count fields)
          pieces [(str (count tag) ":" tag ":")]]
      (loop [index 0
             pieces pieces]
        (if (>= index size)
          (str/join "" pieces)
          (let [field (nth fields index)]
            (recur (inc index)
              (conj (conj (conj pieces (str (count field))) ":") field)))))))

  (defn old-set [tag items]
    (old-record tag (sort items)))

  (defn vectorized-old-set [tag items]
    (old-record tag (vec (sort items))))

  (defn joined-lazy-set [tag items]
    (joined-record tag (sort items)))

  (defn elapsed-ms [operation]
    (let [started (System/nanoTime)]
      (operation)
      (/ (double (- (System/nanoTime) started)) 1000000.0)))

  (defn best-ms [operation]
    (apply min (repeatedly 2 #(elapsed-ms operation))))

  (defn failure-class [operation]
    (try
      (operation)
      nil
      (catch Throwable error (class error))))

  (let [edge-cases [[]
                    [""]
                    ["same" "same"]
                    ["z" "a" "middle"]
                    ["lambda-λ" "emoji-💥" "nul-\u0000"]]]
    (doseq [items edge-cases]
      (let [old (old-set "edge" items)
            vectorized (vectorized-old-set "edge" items)
            joined (joined-lazy-set "edge" items)
            current (stages/canonical-set "edge" items)]
        (require! (= old vectorized joined current)
          (str "canonical bytes changed for " (pr-str items)))))
    (require! (= "3:set:1:a1:m1:z" (stages/canonical-set "set" ["z" "a" "m"]))
      "canonical lexical order changed")
    (require! (= (failure-class #(old-set "bad" ["a" nil]))
                 (failure-class #(stages/canonical-set "bad" ["a" nil])))
      "canonical-set changed invalid-input failure behavior"))

  (let [node-count 1000
        ids (mapv #(core/->NativeId (str "node-" %)) (range node-count))
        nodes (mapv (fn [id]
                      (stages/->TermNodeV0 id
                        (stages/->TextTermV0 (core/nativeid-value id))))
                ids)
        root (first ids)
        graph (stages/->TermGraphV0 root nodes)
        module-id (core/->NativeId "module")
        module (stages/->SourceModuleV1 module-id "fixture" "fixture.bgl"
                 "sha256:source" "sha256:projection" "sha256:interface" root)
        unit (stages/->SourceUnitV0 (core/->NativeId "unit") module-id
               "function" "fixture" "sha256:semantic" root
               [(first ids) (last ids)])
        location (stages/->SourceLocationV0 module-id "fixture.bgl" 1 1)
        stage (stages/->SourceStageV1 graph [module] [unit]
                [(last ids)] [location])
        old-encoding (with-redefs [stages/canonical-record old-record
                                   stages/canonical-set old-set]
                       (stages/encode-source-stage stage))
        current-encoding (stages/encode-source-stage stage)]
    (require! (= old-encoding current-encoding)
      "whole source-stage canonical bytes changed")
    (require! (= (stages/content-digest old-encoding)
                 (stages/content-digest current-encoding))
      "whole source-stage digest changed"))

  (let [small (mapv #(format "%08d:value" %) (range 5000))
        large (mapv #(format "%08d:value" %) (range 20000))]
    (old-set "warm" (subvec small 0 1000))
    (stages/canonical-set "warm" (subvec small 0 1000))
    (let [old-small (best-ms #(old-set "scale" small))
          old-large (best-ms #(old-set "scale" large))
          vec-small (best-ms #(vectorized-old-set "scale" small))
          vec-large (best-ms #(vectorized-old-set "scale" large))
          join-small (best-ms #(joined-lazy-set "scale" small))
          join-large (best-ms #(joined-lazy-set "scale" large))
          current-small (best-ms #(stages/canonical-set "scale" small))
          current-large (best-ms #(stages/canonical-set "scale" large))
          old-growth (/ old-large old-small)
          vec-growth (/ vec-large vec-small)
          join-growth (/ join-large join-small)
          current-growth (/ current-large current-small)]
      (require! (> old-growth 8.0)
        (str "fixture did not expose old quadratic scaling: " old-growth))
      (require! (> join-growth 8.0)
        (str "record-only repair unexpectedly removed lazy traversal: " join-growth))
      (require! (< vec-growth 8.0)
        (str "vectorization-only repair did not restore near-linear scaling: " vec-growth))
      (require! (< current-growth 8.0)
        (str "combined repair did not restore near-linear scaling: " current-growth))
      (require! (< current-large (/ old-large 4.0))
        (str "combined repair is not decision-changing: old=" old-large
             "ms current=" current-large "ms"))
      (println "source_stage_canonical_record_gate: PASS"
        {:old-ms old-large
         :vectorized-old-ms vec-large
         :joined-lazy-ms join-large
         :combined-ms current-large
         :old-growth old-growth
         :combined-growth current-growth})))'
