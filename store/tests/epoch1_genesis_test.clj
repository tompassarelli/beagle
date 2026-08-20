(load-file "epoch.clj")
(require '[store.epoch :as epoch])

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (:store/code (ex-data error)))))

(def facts
  [{:id "syntax/program" :structural {:shape "module-definition"}}
   {:id "epoch/program" :semantic
    {:currentness {:kind "EPOCH" :name "epoch:program"}}}
   {:id "attestation/program" :semantic
    {:currentness {:kind "RE-ATTESTATION" :name "attestation:program:v1"}}}])

(def round-trip (epoch/cold-round-trip-v1 "genesis-program" facts))
(def snapshot (:snapshot round-trip))
(def certified (epoch/certify-cold-genesis-v1 round-trip))

(check! "structural and semantic facts are each classified once"
        (and (= ["STRUCTURAL" "SEMANTIC" "SEMANTIC"]
                (mapv #(get % "validity") (get snapshot "facts")))
             (= 3 (get snapshot "factCount"))))

(check! "semantic currentness names an epoch or re-attestation"
        (= #{"EPOCH" "RE-ATTESTATION"}
           (set (map #(get-in % ["currentness" "kind"])
                     (filter #(= "SEMANTIC" (get % "validity"))
                             (get snapshot "facts"))))))

(check! "cold JSON bytes round-trip exactly across the wire shape"
        (and (:round-trip? round-trip)
             (= snapshot
                (epoch/decode-snapshot-v1!
                 (byte-array (:wire-bytes round-trip))))))

(let [process (doto (ProcessBuilder.
                     (into-array String
                                 ["node" "-e"
                                  "process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))"
                                  (:wire-json round-trip)]))
                (.redirectErrorStream true))
      result (try
               (let [started (.start process)
                     stdout (slurp (.getInputStream started))
                     exit (.waitFor started)]
                 {:exit exit :stdout stdout})
               (catch Exception _ {:exit 1 :stdout ""}))]
  (check! "independent JavaScript runtime accepts the canonical vector"
          (and (zero? (:exit result))
               (= (:wire-json round-trip) (:stdout result)))))

(check! "GENESIS certificate carries the cold snapshot identity"
        (and (= "GENESIS" (get-in certified ["certificate" "kind"]))
             (= "COLD" (get-in certified ["certificate" "source"]))
             (= (get snapshot "snapshotId")
                (get-in certified ["certificate" "snapshotId"]))))

(check! "missing validity binding is refused"
        (= :epoch/ambiguous-validity
           (error-code #(epoch/genesis-snapshot-v1
                         "bad" [{:id "fact-without-binding"}]))))

(check! "two validity bindings are refused"
        (= :epoch/ambiguous-validity
           (error-code #(epoch/genesis-snapshot-v1
                         "bad" [{:id "fact-with-two-bindings"
                                  :structural {:shape "x"}
                                  :semantic {:currentness {:kind "EPOCH"
                                                            :name "e"}}}]))))

(check! "semantic binding without named currentness is refused"
        (= :epoch/invalid-semantic-binding
           (error-code #(epoch/genesis-snapshot-v1
                         "bad" [{:id "fact-without-currentness"
                                  :semantic {:currentness {:kind "EPOCH"}}}]))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nepoch1-genesis: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nepoch1-genesis: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
