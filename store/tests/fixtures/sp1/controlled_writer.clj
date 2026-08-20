(require '[clojure.java.io :as io]
         '[store.types :as t])

(load-file "writer_authority.clj")
(load-file "database.clj")

(defn wait-for! [path timeout-ms]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (cond
        (.exists (io/file path)) true
        (>= (System/currentTimeMillis) deadline)
        (throw (ex-info "controlled writer fixture timed out"
                        {:path path :timeout-ms timeout-ms}))
        :else (do (Thread/sleep 5) (recur))))))

(let [[mode log space batch epoch marker progress release] *command-line-args*]
  (case mode
    "hold"
    (let [authority (writer-authority/acquire! log)]
      (try
        (spit marker "ready\n")
        (wait-for! release 5000)
        (finally (writer-authority/release! authority))))

    "write"
    (let [receipt
          (writer-authority/run-admitted-batch!
           {:log log
            :space-id space
            :batch-id batch
            :compiler-epoch-id epoch
            :timeout-ms 5000
            :retry-ms 5
            :progress! #(spit progress (str (pr-str %) "\n") :append true)
            :derive!
            (fn []
              (let [proposition (t/triple batch :sp1/accepted true)]
                (spit marker "derived\n")
                proposition))
            :publish!
            (fn [_ proposition]
              (let [db (database/open-database! log space)
                    committed (database/assert! db proposition
                                                {:source-record batch})]
                {:batch-id batch :transaction (:ok committed)}))})]
      (println (pr-str (dissoc receipt :value))))

    (throw (ex-info "unknown controlled writer mode" {:mode mode}))))
