;; Durable shadow gate fact adapter. Every command runs in a fresh babashka
;; process so a passing read proves FRAMLOG reopen, not retained heap state.
(require '[clojure.edn :as edn]
         '[clojure.java.io :as io])

(def checks (atom []))

(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(defn sha256-id [text]
  (str
   "sha256:"
   (apply str
          (map #(format "%02x" (bit-and (int %) 255))
               (.digest
                (java.security.MessageDigest/getInstance "SHA-256")
                (.getBytes ^String text
                           java.nio.charset.StandardCharsets/UTF_8))))))

(defn entry [payload]
  (let [encoded (pr-str payload)]
    [(sha256-id encoded) (first payload) encoded]))

(def test-file (.getCanonicalFile (io/file *file*)))
(def repo-root
  (-> test-file .getParentFile .getParentFile .getParentFile))
(def out-path (.getPath (io/file repo-root "store/out")))
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-gate-facts-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "facts.framlog")))

(defn cleanup! []
  (doseq [file (reverse (file-seq scratch))]
    (io/delete-file file true)))

(def cleanup-hook
  (Thread. ^Runnable #(cleanup!) "gate-facts-cleanup"))
(.addShutdownHook (Runtime/getRuntime) cleanup-hook)

(defn invoke! [command request]
  (let [builder
        (doto
         (ProcessBuilder.
          (into-array String
                      ["bb" "-cp" out-path "-m" "store.gate-facts"
                       command]))
          ;; Deliberately not the repository root: generated loading must be
          ;; rooted in its own file, not ambient process cwd.
          (.directory scratch))
        _ (.remove (.environment builder) "BEAGLE_STORE_TELEMETRY_LOG")
        process (.start builder)]
    (with-open [writer (io/writer (.getOutputStream process))]
      (.write writer (str (pr-str request) "\n")))
    (let [stdout (slurp (.getInputStream process))
          stderr (slurp (.getErrorStream process))
          exit (.waitFor process)]
      {:exit exit
       :stderr stderr
       :response (edn/read-string stdout)})))

(def base "8fd36b52a283a289ed872b5e44e7088e63e27a3a")
(def candidate-root "sha256:candidate-root-v1")
(def route-prefix [log-path base candidate-root])

(def candidate
  (entry
   ["GateCandidateV1" candidate-root base base "gate-importer-v1" "active"
    ["beagle-lib" "store/src"]
    [["bin/beagle-test" 100 "sha256:source"]]
    1 100]))
(def claim
  (entry
   ["GatePhaseClaimV1" "claim:test" candidate-root "tier" "active tests"
    "sha256:command" "sha256:inputs" "beagle-test" "policy-v1" []]))
(def observation
  (entry
   ["GatePhaseObservationV1" "observation:test" "claim:test" 1 "PASS" 0
    1 1 "complete" "sha256:log" "sha256:phase-receipt"]))
(def missing-observation
  (entry
   ["GatePhaseObservationV1" "observation:missing" "claim:test" 1 "PASS"
    0 1 1 "complete" "sha256:log-missing" "sha256:receipt-missing"]))
(def miss
  (entry
   ["FactMissEventV1" "miss:test" "query:test" candidate-root
    candidate-root "ABSENT" [["claim" "claim:test"]] "beagle-test"
    "policy-v1" "run-old-phase" "claim:test" "observation:test"]))
(def verdict
  (entry
   ["GateCandidateVerdictV1" "verdict:test" candidate-root "ADMITTED"
    "PASS" 0 "beagle-test" "policy-v1"
    [["claim:test" "observation:test"]] "all claims observed"]))
(def receipt
  (entry
   ["GateMaintenanceReceiptV1" "receipt:test" candidate-root "verdict:test"
    ["claim:test"] ["observation:test"]
    [["miss:test" "observation:test"]]
    [["PASS" 1]] [["ABSENT" 1]] 0 1 1 "SHADOW" 0 "UNPUBLISHED"]))

(def import-result
  (invoke!
   "import"
   (into ["store.gate-facts/import-v1"]
         (conj route-prefix [candidate claim]))))
(def import-response (:response import-result))
(def import-revision (nth import-response 3))

(println "gate facts:")
(check! "import returns the frozen exact-candidate response"
        (and (zero? (:exit import-result))
             (= "" (:stderr import-result))
             (= ["store.gate-facts/response-v1" "ok" candidate-root]
                (subvec import-response 0 3))
             (= #{(first candidate) (first claim)}
                (set (map first (nth import-response 4))))
             (empty? (nth import-response 5))
             (empty? (nth import-response 6))))

(def first-cold
  (invoke!
   "cold-query"
   (into ["store.gate-facts/cold-query-v1"]
         (conj route-prefix [(first candidate) "sha256:not-present"]))))
(check! "a fresh process reopens the exact root and returns all entries"
        (and (zero? (:exit first-cold))
             (= import-response (:response first-cold))))

(def missing-link-id (str "sha256:" (apply str (repeat 64 "0"))))
(def observation-before-miss
  (invoke!
   "record-observation"
   (into ["store.gate-facts/record-observation-v1"]
         (into route-prefix [missing-observation missing-link-id]))))
(def after-rejected-observation
  (invoke!
   "cold-query"
   (into ["store.gate-facts/cold-query-v1"]
         (conj route-prefix []))))
(check! "fallback result is refused before its durable miss"
        (and (= 2 (:exit observation-before-miss))
             (= "store.gate-facts/error-v1"
                (first (:response observation-before-miss)))
             (= "gate-facts/miss-not-durable"
                (second (:response observation-before-miss)))
             (= import-revision (nth (:response after-rejected-observation) 3))
             (not (contains?
                   (set (map first
                             (nth (:response after-rejected-observation) 4)))
                   (first missing-observation)))))

(def miss-result
  (invoke!
   "record-miss"
   (into ["store.gate-facts/record-miss-v1"]
         (conj route-prefix miss))))
(def miss-response (:response miss-result))
(check! "record-miss returns only after a cold-visible standalone append"
        (and (zero? (:exit miss-result))
             (not= import-revision (nth miss-response 3))
             (contains? (set (map first (nth miss-response 4))) (first miss))
             (empty? (nth miss-response 5))))

(def observation-result
  (invoke!
   "record-observation"
   (into ["store.gate-facts/record-observation-v1"]
         (into route-prefix [observation (first miss)]))))
(check! "fallback observation and miss link publish together after the miss"
        (and (zero? (:exit observation-result))
             (= [[(first miss) (first observation)]]
                (nth (:response observation-result) 5))))

(def unaccounted-finalize
  (invoke!
   "finalize"
   (into ["store.gate-facts/finalize-v1"]
         (into route-prefix [verdict receipt []]))))
(check! "finalize refuses a receipt that omits a durable miss"
        (and (= 2 (:exit unaccounted-finalize))
             (= "gate-facts/unaccounted-miss"
                (second (:response unaccounted-finalize)))))

(def finalize-result
  (invoke!
   "finalize"
   (into ["store.gate-facts/finalize-v1"]
         (into route-prefix
               [verdict receipt [[(first miss) (first observation)]]]))))
(check! "finalize admits the verdict and exposes the receipt id"
        (and (zero? (:exit finalize-result))
             (= [(first receipt)] (nth (:response finalize-result) 6))
             (= #{(first candidate) (first claim) (first miss)
                  (first observation) (first verdict) (first receipt)}
                (set (map first (nth (:response finalize-result) 4))))))

(def wrong-root
  (invoke!
   "cold-query"
   ["store.gate-facts/cold-query-v1" log-path base
    "sha256:another-candidate" []]))
(check! "a wrong candidate root errors instead of returning plausible empty"
        (and (= 2 (:exit wrong-root))
             (= "gate-facts/candidate-root-unresolved"
                (second (:response wrong-root)))))

(def wrong-space
  (invoke!
   "cold-query"
   ["store.gate-facts/cold-query-v1" log-path
    "9fd36b52a283a289ed872b5e44e7088e63e27a3a" candidate-root []]))
(check! "a stale base commit cannot open the experimental SpaceId"
        (and (= 2 (:exit wrong-space))
             (= "space-mismatch" (second (:response wrong-space)))))

(def unknown-payload ["UnknownFactV1" "unknown"])
(def unknown-entry (entry unknown-payload))
(def unknown-kind
  (invoke!
   "import"
   (into ["store.gate-facts/import-v1"]
         (conj route-prefix [unknown-entry]))))
(check! "unknown fact kinds fail closed"
        (and (= 2 (:exit unknown-kind))
             (= "gate-facts/unknown-kind" (second (:response unknown-kind)))))

(def noncanonical-payload
  "[\"GatePhaseClaimV1\", \"claim:noncanonical\"]")
(def noncanonical-entry
  [(sha256-id noncanonical-payload) "GatePhaseClaimV1" noncanonical-payload])
(def noncanonical
  (invoke!
   "import"
   (into ["store.gate-facts/import-v1"]
         (conj route-prefix [noncanonical-entry]))))
(check! "noncanonical envelope bytes are rejected"
        (and (= 2 (:exit noncanonical))
             (= "gate-facts/invalid-envelope"
                (second (:response noncanonical)))))

(def bad-id-entry
  [(str "sha256:" (apply str (repeat 64 "f")))
   (second claim)
   (nth claim 2)])
(def bad-id
  (invoke!
   "import"
   (into ["store.gate-facts/import-v1"]
         (conj route-prefix [bad-id-entry]))))
(check! "fact ids must digest the exact canonical envelope bytes"
        (and (= 2 (:exit bad-id))
             (= "gate-facts/fact-id-mismatch" (second (:response bad-id)))))

(.removeShutdownHook (Runtime/getRuntime) cleanup-hook)
(cleanup!)
(shutdown-agents)

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println "\ngate facts:" (count @checks) "/" (count @checks) "PASS")
    (do
      (println "\ngate facts:" (count failures) "FAILED")
      (System/exit 1))))
