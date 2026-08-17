;; One exact table is classified by the hosted branch route and by an actual
;; no-JVM Native Core executable built from fram.chain-rules.
;; Run from the repository root:
;;   tests/run_hosted_test.sh 240s bb -cp out tests/branch_chain_parity_test.clj
(require '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str]
         '[fram.chain-rules :as chain-rules])

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-branch-chain-parity-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def executable (.getPath (io/file scratch "chain-parity")))
(def artifacts (.getPath (io/file scratch "artifacts")))
(def beagle (.getCanonicalPath (io/file "../bin/beagle")))
(def compiler (or (System/getenv "CC") "cc"))

(def fields
  [:name :route :position :expected-space :actual-space
   :recorded-start :actual-start :recorded-end :actual-end
   :recorded-bytes :actual-bytes :continuation :torn :expected-next
   :expected-verdict])
(def cases
  (mapv (fn [line] (zipmap fields (str/split line #"\t")))
        (remove #(or (str/blank? %) (str/starts-with? % "#"))
                (str/split-lines
                 (slurp "tests/fixtures/branch_chain_parity.tsv")))))

(defn number [value] (Long/parseLong value))
(defn bool [value] (= value "true"))

(defn hosted-verdict [entry]
  (let [fault
        (if (= "sealed" (:route entry))
          (chain-rules/sealed-member-fault
           (number (:position entry))
           (:expected-space entry)
           (:actual-space entry)
           (number (:recorded-start entry))
           (number (:actual-start entry))
           (number (:recorded-end entry))
           (number (:actual-end entry))
           (number (:recorded-bytes entry))
           (number (:actual-bytes entry))
           (bool (:continuation entry))
           (bool (:torn entry))
           (number (:expected-next entry)))
          (chain-rules/tail-member-fault
           (number (:position entry))
           (:expected-space entry)
           (:actual-space entry)
           (number (:actual-start entry))
           (bool (:continuation entry))
           (number (:expected-next entry))))]
    (if fault "reject" "accept")))

(def build
  (shell/sh beagle "native-exe"
            "--out" executable
            "--entry" "fram.branch-chain-parity-probe/main"
            "--cc" compiler
            "--artifacts" artifacts
            "src/fram/chain_rules.bgl"
            "tests/fixtures/branch_chain_parity_probe.bgl"))

(println "branch chain parity:")
(check! "the Native Core parity probe compiles and links without a JVM"
        (zero? (:exit build)))

(def results
  (when (zero? (:exit build))
    (mapv
     (fn [entry]
       (let [arguments
             (mapv entry
                   [:route :position :expected-space :actual-space
                    :recorded-start :actual-start :recorded-end :actual-end
                    :recorded-bytes :actual-bytes :continuation :torn
                    :expected-next])
             native (apply shell/sh executable arguments)]
         {:name (:name entry)
          :expected (:expected-verdict entry)
          :hosted (hosted-verdict entry)
          :native (case (:exit native) 0 "accept" 1 "reject" "invalid")}))
     cases)))

(check! "the corpus covers acceptance and every chain rejection family"
        (and (= 16 (count cases))
             (= #{"accept" "reject"}
                (set (map :expected-verdict cases)))))
(check! "the hosted route matches every expected corpus verdict"
        (every? #(= (:expected %) (:hosted %)) results))
(check! "Native Core and hosted routes classify the exact same corpus"
        (every? #(= (:hosted %) (:native %)) results))

(doseq [file (reverse (file-seq scratch))]
  (io/delete-file file true))
(shutdown-agents)

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println "\nbranch chain parity:" (count @checks) "/" (count @checks)
             "PASS")
    (do
      (println "\nbranch chain parity:" (count failures) "FAILED")
      (when-not (zero? (:exit build))
        (binding [*out* *err*]
          (println (:out build))
          (println (:err build))))
      (System/exit 1))))
