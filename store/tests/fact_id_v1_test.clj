;; FactEnvelopeV1: pure canonical/hostile vectors, independent JS emitter,
;; and a two-process cold Store round trip.
(require '[cheshire.core :as json]
         '[clojure.edn :as edn]
         '[clojure.java.io :as io])

(load-file "writer_authority.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:fram/code (ex-data error)) (:type (ex-data error))))))

(defn hex->bytes [text]
  (mapv #(Integer/parseInt (apply str %) 16) (partition 2 text)))

(defn bytes->hex [bytes]
  (apply str (map #(format "%02x" %) bytes)))

(defn fixture-value [value]
  (cond
    (vector? value) (mapv fixture-value value)
    (and (map? value) (contains? value "$int"))
    (bigint (get value "$int"))
    (and (map? value) (contains? value "$float"))
    (Double/longBitsToDouble
     (Long/parseUnsignedLong (get value "$float") 16))
    (and (map? value) (contains? value "$keyword"))
    (keyword (get value "$keyword"))
    (and (map? value) (contains? value "$set"))
    (set (map fixture-value (get value "$set")))
    (and (map? value) (contains? value "$map"))
    (into {} (map (fn [[key item]]
                    [(fixture-value key) (fixture-value item)])
                  (get value "$map")))
    :else value))

(def fixture-path "tests/fixtures/fact_id_v1/vectors.json")
(def fixture (json/parse-string (slurp fixture-path)))
(def vectors (get fixture "vectors"))

(check! "V1 kind registry is exact and one-based"
        (= {"GateCandidateV1" 1
            "GatePhaseClaimV1" 2
            "GatePhaseObservationV1" 3
            "GateCandidateVerdictV1" 4
            "FactMissEventV1" 5
            "GateMaintenanceReceiptV1" 6
            "DevCompileUnitResultV1" 7}
           writer-authority/fact-kind-registry-v1))

(doseq [vector vectors]
  (let [payload (fixture-value (get vector "payload"))
        envelope
        (writer-authority/fact-envelope-v1 (get vector "kind") payload)
        decoded (writer-authority/decode-fact-envelope! (:bytes envelope))]
    (check! (str "golden bytes: " (get vector "name"))
            (= (get vector "hex") (bytes->hex (:bytes envelope))))
    (check! (str "golden ID: " (get vector "name"))
            (= (get vector "id") (:id envelope)))
    (check! (str "canonical decode: " (get vector "name"))
            (and (= (get vector "kind") (:kind decoded))
                 (= payload (:payload decoded))
                 (= (:id envelope) (:id decoded))))))

(defn invoke! [argv]
  (let [process (.start (ProcessBuilder. (into-array String argv)))
        stdout (slurp (.getInputStream process))
        stderr (slurp (.getErrorStream process))
        exit (.waitFor process)]
    {:exit exit :stdout stdout :stderr stderr}))

(let [reference
      (invoke! ["node" "tests/fixtures/fact_id_v1/reference.mjs" fixture-path])
      emitted (when (zero? (:exit reference))
                (json/parse-string (:stdout reference)))
      expected (mapv #(select-keys % ["name" "hex" "id"]) vectors)]
  (check! "independent JavaScript emitter matches every golden byte and ID"
          (and (zero? (:exit reference))
               (= "" (:stderr reference))
               (= expected emitted))))

(def base
  (:bytes
   (writer-authority/fact-envelope-v1
    "GateCandidateV1" [{"a" 1 "b" 2}])))
(def domain-size
  (count (.getBytes writer-authority/fact-envelope-domain-v1
                    java.nio.charset.StandardCharsets/UTF_8)))
(def payload-start (+ domain-size 8))
(def first-map-entry (+ payload-start 10))
(def entry-size 15)
(def reordered
  (vec (concat (subvec base 0 first-map-entry)
               (subvec base (+ first-map-entry entry-size)
                       (+ first-map-entry (* 2 entry-size)))
               (subvec base first-map-entry (+ first-map-entry entry-size)))))
(def duplicate
  (vec (concat (subvec base 0 (+ first-map-entry entry-size))
               (subvec base first-map-entry (+ first-map-entry entry-size)))))

(check! "corrupt domain separator rejects"
        (= :fact-envelope/corrupt
           (error-code #(writer-authority/decode-fact-envelope!
                         (assoc base 0 0)))))
(check! "unknown version rejects without V1 reinterpretation"
        (= :fact-envelope/unknown-version
           (error-code #(writer-authority/decode-fact-envelope!
                         (assoc base (inc domain-size) 2)))))
(check! "unknown kind ID rejects"
        (= :fact-envelope/unknown-kind
           (error-code #(writer-authority/decode-fact-envelope!
                         (assoc base (+ domain-size 3) 99)))))
(check! "duplicate canonical map key rejects"
        (= :fact-envelope/duplicate
           (error-code #(writer-authority/decode-fact-envelope! duplicate))))
(check! "reordered canonical map keys reject"
        (= :fact-envelope/reordered
           (error-code #(writer-authority/decode-fact-envelope! reordered))))
(check! "trailing envelope data rejects"
        (= :fact-envelope/trailing-data
           (error-code #(writer-authority/decode-fact-envelope! (conj base 0)))))
(check! "mismatched claimed fact ID rejects"
        (= :fact-envelope/id-mismatch
           (error-code #(writer-authority/validate-fact-envelope!
                         base
                         (str "sha256:" (apply str (repeat 64 "0")))))))
(check! "unordered input maps and sets mint identical bytes"
        (= (writer-authority/fact-envelope-v1-bytes
            "GateCandidateV1" [(array-map "b" 2 "a" 1) #{"b" "a"}])
           (writer-authority/fact-envelope-v1-bytes
            "GateCandidateV1" [(array-map "a" 1 "b" 2) #{"a" "b"}])))
(check! "payload field order remains identity-significant"
        (not= (writer-authority/fact-id-v1 "GateCandidateV1" ["a" "b"])
              (writer-authority/fact-id-v1 "GateCandidateV1" ["b" "a"])))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fact-id-v1-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "facts.framlog")))
(def cold-vector (first vectors))
(def cold-id (get cold-vector "id"))
(def cold-hex (get cold-vector "hex"))
(def cold-script "tests/fixtures/fact_id_v1/cold_store_probe.clj")
(try
  (let [write-result
        (invoke! ["bb" "-cp" "out" cold-script "write"
                  log-path cold-id cold-hex])
        read-result
        (when (zero? (:exit write-result))
          (invoke! ["bb" "-cp" "out" cold-script "read"
                    log-path cold-id cold-hex]))
        recovered (when (and read-result (zero? (:exit read-result)))
                    (edn/read-string (:stdout read-result)))]
    (check! "fresh writer process durably stores the exact envelope"
            (and (zero? (:exit write-result))
                 (= "" (:stderr write-result))))
    (check! "fresh reader process recovers identical bytes and ID"
            (and read-result
                 (zero? (:exit read-result))
                 (= "" (:stderr read-result))
                 (= {:id cold-id :hex cold-hex} recovered))))
  (finally
    (doseq [file (reverse (file-seq scratch))]
      (io/delete-file file true))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nfact-id-v1: " (count @checks) "/" (count @checks) " PASS"))
    (do
      (println (str "\nfact-id-v1: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
