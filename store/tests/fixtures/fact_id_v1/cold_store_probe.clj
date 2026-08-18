(require '[store.types :as t])

(load-file "database.clj")

(defn hex->bytes [text]
  (mapv #(Integer/parseInt (apply str %) 16) (partition 2 text)))

(let [[mode path id hex] *command-line-args*
      space "beagle-fact-id-v1-cold-store"]
  (case mode
    "write"
    (do
      (writer-authority/validate-fact-envelope! (hex->bytes hex) id)
      (database/create-triple-log! path space)
      (let [db (database/open-database! path space)]
        (database/assert!
         db (t/triple id :store/fact-envelope-v1 hex)
         {:actor "fact-id-v1-test"}))
      (prn {:id id :hex hex}))

    "read"
    (let [db (database/open-database! path space)
          proposition
          (first
           (filter
            #(and (t/triple? %)
                  (= id (t/triple-t1 %))
                  (= :store/fact-envelope-v1 (t/triple-t2 %)))
            (database/live-propositions db)))
          stored-hex (when proposition (t/triple-t3 proposition))
          decoded
          (when stored-hex
            (writer-authority/validate-fact-envelope!
             (hex->bytes stored-hex) id))]
      (prn {:id (:id decoded) :hex stored-hex}))

    (throw (ex-info "unknown cold Store probe mode" {:mode mode}))))
