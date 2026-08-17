;; ============================================================================
;; code_edit_min_speed.clj — Build B GATE 3 (SPEED): per-edit wall-clock on the
;; WARM server after A+B (minimal-op commit + scoped re-resolve). Boots ONE warm
;; code server over a /tmp COPY of .fram/code.log, then drives SEVERAL set-body
;; edits through :edit-min, reporting each edit's wall-clock. The FIRST edit pays a
;; one-time cold whole-corpus refers_to materialize (ensure-refers! cold); every
;; STEADY-STATE edit pays only a SCOPED re-resolve of the dirty module — that is
;; the Build B number. NEVER 7977 / north.
;;   bb -cp out code_edit_min_speed.clj
;; ============================================================================
(require '[fram.store :as c] '[fram.schema :as s]
         '[clojure.string :as str] '[clojure.edn :as edn] '[clojure.java.io :as io])
(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(when-not (.exists (io/file code-log))
  (println "SKIP — no .fram/code.log") (System/exit 0))
(binding [*command-line-args* []] (load-file "server.clj"))

(def flat (str (System/getProperty "java.io.tmpdir") "/edit-min-speed-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(defn- port-free? [p] (try (with-open [s (java.net.Socket.)]
                             (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false)
                           (catch Exception _ true)))
(def port (or (some #(when (port-free? %) %) [8140 8141 8142 8143 8144]) 8140))
(boot-flat! flat)
(def server (future (serve port)))
(Thread/sleep 500)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))
(def status (client port {:op :status}))
(when-not (and (= flat (str (:log status))) (pos? (:facts status)))
  (println "ABORT: server serves" (pr-str (:log status))) (shutdown!) (System/exit 1))
(println "server up:" (:facts status) "live facts, port=" port)

;; a sequence of DISTINCT 1-line set-body edits to `cardinality` (each replaces the
;; prior body; same defn so the verb path is identical edit-to-edit).
(defn body-edn [tag]
  (edn/read-string
    (str "(let [p (c/value-id ctx pname) cp (c/value-id ctx \"" tag "\") "
         "cs (if (and (some? p) (some? cp)) (c/by-lp ctx p cp) [])] "
         "(if (empty? cs) \"multi\" (c/literal ctx (:r (c/fact-of ctx (first cs))))))")))

(defn edit! [tag]
  (let [t0 (System/nanoTime)
        resp (client port {:op :edit-min
                           :spec {:op "set-body" :module "schema" :name "cardinality"
                                  :datum (body-edn tag)}})
        ms (/ (- (System/nanoTime) t0) 1e6)]
    [resp ms]))

(println "\n=== GATE 3 — per-edit wall-clock on the WARM server ===")
(def results
  (vec (for [tag ["cardinality" "card-a" "card-b" "card-c" "card-d"]]
         (let [[resp ms] (edit! tag)]
           (println (format "  set-body[%-12s] ops=%-4d retracts=%-2d  %.1f ms  %s"
                            tag (:ops resp) (:retracts resp) ms (if (:ok resp) "OK" (str "FAIL " (pr-str resp)))))
           {:tag tag :ms ms :ok (:ok resp) :ops (:ops resp)}))))

(def cold (-> results first :ms))
(def warm (map :ms (rest results)))
(def warm-avg (/ (reduce + warm) (count warm)))
(def warm-min (apply min warm))
(println (format "\n  FIRST edit (cold whole-corpus materialize + scoped commit): %.1f ms" cold))
(println (format "  STEADY-STATE edits (scoped re-resolve of the dirty module): avg %.1f ms, min %.1f ms" warm-avg warm-min))
(println (format "  contrast: pre-Build-B per-edit (whole-corpus walk EVERY edit): ~1710 ms"))

(shutdown!)
(if (every? :ok results)
  (do (println (format "\nGATE 3: steady-state per-edit %.0f ms (was ~1710 ms whole-corpus every edit)" warm-avg))
      (System/exit 0))
  (do (println "\nGATE 3 FAIL — an edit was rejected") (System/exit 1)))
