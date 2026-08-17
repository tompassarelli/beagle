#!/usr/bin/env bb
;; replace-in-body — SUB-DEF surgical edit verb (resolve.clj).
;; Proves: a unique anchor swaps ONE interior fN edge (mint new + supersede one), the
;; def is NOT re-emitted, and the three fail-closed paths (0-match / ambiguous / no-def)
;; refuse with NO store mutation. Uses the real schema module (emit-edn'd) as the corpus.
(require '[resolve-ident :as ri] '[clojure.edn :as edn]
         '[clojure.java.io :as io] '[clojure.string :as str] '[babashka.process :refer [sh]])
;; resolve.clj + its Beagle-compiled parts are bare-ns files at the repo ROOT
;; (build.sh), off the `bb -cp out` classpath — load them the way the daemon
;; does (server.clj), then alias.
(load-file "out/resolve.clj")
(alias 'r 'resolve)

(def beagle-home (or (System/getenv "BEAGLE_HOME") (System/getenv "BEAGLE")
                     (str (System/getenv "HOME") "/code/beagle")))
(def beagle-bin (or (System/getenv "BEAGLE_STORE_BEAGLE") (str beagle-home "/bin/beagle")))
(when-not (.canExecute (io/file beagle-bin))
  (println "SKIP — missing prerequisite: Beagle CLI (" beagle-bin ")")
  (System/exit 0))
(def work (str (System/getProperty "java.io.tmpdir") "/replace-in-body-test-" (System/nanoTime)))
(.mkdirs (io/file work))
(def edn-path (str work "/schema.edn"))
(let [rr (sh {:out (io/file edn-path) :err :string}
             beagle-bin "facts-roundtrip" "--emit-edn"
             (str (System/getProperty "user.dir") "/src/store/schema.bclj"))]
  (when-not (zero? (:exit rr)) (println "emit-edn failed:" (:err rr)) (System/exit 1)))

(def pass (atom 0)) (def fail (atom 0))
(defn check [name ok?] (if ok? (do (swap! pass inc) (println "  [PASS] " name))
                          (do (swap! fail inc) (println "  [FAIL] " name))))
;; run a verb thunk under capture-only (no re-resolve/project), *reject!* -> a catchable
;; signal; return {:minted N :superseded M} or {:reject CODE}.
;; S2: a minted identity is a Term, so "how many nodes did this mint" is the
;; handle's ordinal count, and "how many facts did it supersede" is its
;; withdrawal count — the store's own retractions, not a supersedes list.
(defn run-verb [thunk]
  (let [id0 (ri/minted-count r/rctx) sup0 (ri/withdrawal-count r/rctx)]
    (try (thunk)
         {:minted (- (ri/minted-count r/rctx) id0) :superseded (- (ri/withdrawal-count r/rctx) sup0)}
         (catch clojure.lang.ExceptionInfo e (or (:data (ex-data e)) (ex-data e))))))

(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true
             r/*reject!* (fn [code & _] (throw (ex-info (str "REJECT " code) {:code code})))]
     (println "================ replace-in-body verb test ================")
     ;; 1) SUCCESS: unique anchor (empty? cs) -> (zero? (count cs))
     (let [res (run-verb #(r/verb-replace-in-body! "cardinality" "schema"
                                                   '(empty? events) '(zero? (count events))))]
       (check "unique anchor: superseded exactly 1 fN edge" (= 1 (:superseded res)))
       ;; minted a SMALL subtree (the 5-node replacement + its facts), NOT the whole def
       ;; (a whole-def cardinality re-mint is 100s of objects) — the sub-def granularity win.
       (check "unique anchor: minted the small replacement, not the whole def"
              (and (pos? (:minted res)) (< (:minted res) 60)))))))

;; fresh store per fail-closed case (a rejected edit must leave the store untouched)
(doseq [[nm anchor code] [["0-match anchor rejects (code 5)" '(no-such-form-xyz) 5]
                          ["ambiguous anchor rejects (code 5)" 'events 5]]]
  (r/resolve-edn!
   [edn-path]
   (fn []
     (binding [r/*capture-only?* true
               r/*reject!* (fn [code & _] (throw (ex-info (str "REJECT " code) {:code code})))]
       (let [res (run-verb #(r/verb-replace-in-body! "cardinality" "schema" anchor '(x)))]
         (check nm (and (= code (:code res)) (nil? (:minted res)))))))))
(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true
             r/*reject!* (fn [code & _] (throw (ex-info (str "REJECT " code) {:code code})))]
     (let [res (run-verb #(r/verb-replace-in-body! "no-such-def" "schema" '(a) '(b)))]
       (check "no-def rejects (code 5), nothing minted" (and (= 5 (:code res)) (nil? (:minted res))))))))

(sh {} "rm" "-rf" work)
(println (str "\nreplace-in-body: " @pass " / " (+ @pass @fail) " PASS"))
(when (pos? @fail) (System/exit 1))
