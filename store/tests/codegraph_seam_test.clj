#!/usr/bin/env bb
;; codegraph_seam_test.clj — the other half of the fold's structural seam.
;;
;; core_code_blind_test.clj guards ONE direction (store-core must not learn beagle-as-
;; subject). This guards the OTHER: the folded codegraph module (beagle source
;; code-intelligence) may rent ONLY store's small, stable, PUBLIC fact+Datalog surface
;; — it must not reach into engine internals. Co-locating the repos removes the
;; cross-classpath friction that used to make a deep reach cost something, so a CI
;; check replaces it.
;;
;; The allowlist is deliberately TIGHT — exactly what codegraph rents today
;; ({store.store, store.datalog, store.types}, the same generic family north pins).
;; store.types is on the list because the store's write surface takes Triples: a
;; proposition cannot be spelled without the Term constructor. Widening it is a
;; conscious seam decision (edit this list), never a silent drift. If codegraph one day
;; legitimately needs store.kernel/fold, that shows up here as a failing guard prompting
;; the decision — which is the point.

(require '[clojure.string :as str])

(def codegraph-src "codegraph/src")
(def allowed #{"store.store" "store.datalog" "store.types"})

(def src-files
  (when (.exists (clojure.java.io/file codegraph-src))
    (->> (file-seq (clojure.java.io/file codegraph-src))
         (filter #(.isFile %))
         (map #(.getPath %))
         ;; .bclj too: the analysis driver is now a graph-authored Beagle module
         ;; (codegraph.bclj), and the seam it rents must stay guarded across that
         ;; migration — a .clj-only glob would have silently stopped watching it.
         (filter #(or (str/ends-with? % ".clj") (str/ends-with? % ".bclj")))
         sort)))

(when (empty? src-files)
  (println "codegraph_seam_test: skipped — codegraph/ not present (pre-fold).") (System/exit 0))

(def store-ns-re #"\bstore\.[a-z][a-z0-9-]*")
(def violations
  (mapcat (fn [path]
            (->> (str/split-lines (slurp path))
                 (map-indexed (fn [i line] [(inc i) line]))
                 (remove (fn [[_ line]] (str/starts-with? (str/triml line) ";")))
                 (mapcat (fn [[n line]]
                           (->> (re-seq store-ns-re line)
                                (remove allowed)
                                (map (fn [ns'] [path n ns'])))))))
          src-files))

(println "== codegraph-seam guard ==")
(println (str "  codegraph rents (allowed): " allowed))
(if (empty? violations)
  (println (str "  PASS — codegraph/src rents only store's public fact+Datalog surface across "
                (count src-files) " files."))
  (do
    (println "  FAIL — codegraph reached into store beyond the allowed public surface:")
    (doseq [[f n ns'] (distinct violations)]
      (println (str "    " f ":" n "  " ns')))
    (println "  (if intentional, widen `allowed` in this guard — a deliberate seam decision.)")
    (System/exit 1)))
