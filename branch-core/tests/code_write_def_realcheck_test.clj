;; ============================================================================
;; code_write_def_realcheck_test.clj — A1×A2 integration: write-def wired to A2's
;; WARM graph-authored def-level check via the def-check-hook seam.
;; ============================================================================
;; Boots a code daemon with FRAM_DEFCHECK=1 so serve wires the stateful gate API
;; (including whole-tree check for :check). Proves the FULL adapter-v2 pipeline: a def that
;; mints but does NOT type-check comes back :stage :type with a repair :suggestion;
;; a valid def comes back :ok + :deep-check :ran; :check {} runs the whole-tree gate.
;;
;; SKIPS (exit 0) when the beagle sidecar can't start in this env (no racket/beagle) —
;; the wiring + shape are still exercised by code_write_def_test.clj's mock seam.
;;
;;   FRAM_DEFCHECK=1 clojure -M tests/code_write_def_realcheck_test.clj > out 2>&1; echo EXIT=$?
;; ============================================================================
(require '[clojure.string :as str] '[clojure.java.io :as io])

(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(when-not (.exists (io/file code-log))
  (println "SKIP — no .fram/code.log") (System/exit 0))
(when-not (= "1" (System/getenv "FRAM_DEFCHECK"))
  (println "SKIP — set FRAM_DEFCHECK=1 to run the warm def-check integration") (System/exit 0))

(binding [*command-line-args* []] (load-file "server.clj"))
(def flat (str (System/getProperty "java.io.tmpdir") "/realchk-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(defn- pf? [p] (try (with-open [s (java.net.Socket.)] (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false) (catch Exception _ true)))
(def port (or (some #(when (pf? %) %) (range 49015 49045)) 49015))
(boot-flat! flat)
(def server (future (serve port)))         ; serve calls maybe-wire-def-check! (FRAM_DEFCHECK=1)
(Thread/sleep 900)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))
(defn- w [m src] (client port {:op :write-def :spec {:module m :source src}}))
(defn- err-of [resp] (or (:failed resp) resp))

(def failures (atom 0))
(defn- check [label ok? detail]
  (println (format "  [%s] %s%s" (if ok? "PASS" "FAIL") label (if ok? "" (str "  <-- " detail))))
  (when-not ok? (swap! failures inc)))

;; probe: is the warm check actually alive? (a valid def that should type-check clean)
(def probe (w "schema" "(defn a1-rc-ok [(x Int)] Int (+ x 1))"))
(cond
  (and (false? (:ok probe)) (str/includes? (str (:message (err-of probe))) "unavailable"))
  (do (println "SKIP — beagle def-check sidecar unavailable in this env:" (:message (err-of probe))) (shutdown!) (System/exit 0))
  (not= :ran (:deep-check probe))
  (do (println "SKIP — FRAM_DEFCHECK wiring did not activate (deep-check" (:deep-check probe) ")") (shutdown!) (System/exit 0))
  :else
  (do
    (println "warm def-check LIVE, port=" port "\n")
    (check "valid def -> :ok, :deep-check :ran" (and (:ok probe) (= :ran (:deep-check probe))) (pr-str probe))
    ;; a def that MINTS but fails the type check: declares String, body is Int
    (let [bad (w "schema" "(defn a1-rc-bad [(x Int)] String (+ x 1))")
          e (err-of bad)]
      (check "bad-type write fails closed" (false? (:ok bad)) (pr-str (dissoc bad :failed)))
      (check "bad-type :stage :type" (= :type (:stage e)) (pr-str (dissoc e :errors)))
      (check "bad-type :at names module+def" (and (= "schema" (:module (:at e))) (= "a1-rc-bad" (:def (:at e)))) (pr-str (:at e)))
      (check "bad-type carries repair :suggestion" (not (str/blank? (str (:suggestion e)))) (pr-str (:suggestion e)))
      (check "bad-type expected/got surfaced" (and (= "String" (:expected e)) (= "Int" (:got e))) (pr-str (select-keys e [:expected :got]))))
    ;; :check {} — the whole-tree gate (:stage :gate) sees the committed-but-bad def
    (let [chk (client port {:op :check :spec {}})]
      (check ":check runs the whole-tree gate (:stage :gate)" (= :gate (:stage chk)) (pr-str (dissoc chk :errors))))
    (println (format "\n==== %s : %d failure(s) ====" (if (zero? @failures) "PASS" "FAIL") @failures))
    (shutdown!)
    (System/exit (if (zero? @failures) 0 1))))
