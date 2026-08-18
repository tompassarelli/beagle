;; SP3: deterministic conflict algebra and fail-closed Store publication.
(require '[clojure.edn :as edn])

(load-file "conflict.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:fram/code (ex-data error)) (:type (ex-data error))))))

(defn permutations [items]
  (if (empty? items)
    [[]]
    (mapcat
     (fn [index]
       (let [item (nth items index)
             remaining (vec (concat (subvec items 0 index)
                                    (subvec items (inc index))))]
         (map #(into [item] %) (permutations remaining))))
     (range (count items)))))

(def fixture
  (edn/read-string (slurp "tests/fixtures/sp3-conflict/cases.edn")))
(def key-v1 (conflict/fact-conflict-key-v1 (:key fixture)))
(def pass-fact
  (conflict/decision-fact-v1
   key-v1 :pass (:pass-evidence fixture)))
(def alternate-pass-fact
  (conflict/decision-fact-v1
   key-v1 :pass (:pass-evidence-alternate fixture)))
(def fail-fact
  (conflict/decision-fact-v1
   key-v1 :fail (:fail-evidence fixture)))

(check! "Conflict V1 public identifiers and exact full key remain frozen"
        (and (= 1 conflict/conflict-algebra-version-v1)
             (= "beagle.store/FactConflictKeyV1"
                conflict/fact-conflict-key-format-v1)
             (= "beagle.store/ConflictSetDigestV1"
                conflict/conflict-set-digest-format-v1)
             (= "beagle.store/FactSupersessionV1"
                conflict/fact-supersession-format-v1)
             (= [:candidateRoot :claimId :verifierMaterializationId
                 :compilerEpochId :policyId :targetAbiProfile :factSchemaId]
                conflict/fact-conflict-key-fields-v1)))

(let [inputs [pass-fact fail-fact pass-fact]
      results
      (map #(conflict/resolve-conflict-set-v1 {:key key-v1 :facts %})
           (permutations inputs))]
  (check! "every writer permutation has one conflict result and digest"
          (and (apply = results)
               (= :conflict (:status (first results)))
               (= 2 (count (:fact-ids (first results))))
               (= (sort (:fact-ids (first results)))
                  (:fact-ids (first results))))))

(let [results
      (map #(conflict/resolve-conflict-set-v1 {:key key-v1 :facts %})
           (permutations [pass-fact pass-fact pass-fact]))]
  (check! "byte-identical content deduplicates idempotently"
          (and (apply = results)
               (= :pass (:status (first results)))
               (= 1 (count (:fact-ids (first results)))))))

(check! "different evidence for the same status remains a conflict"
        (= :conflict
           (:status
            (conflict/resolve-conflict-set-v1
             {:key key-v1 :facts [pass-fact alternate-pass-fact]}))))

(let [other-key
      (conflict/fact-conflict-key-v1
       (assoc key-v1 :verifierMaterializationId
              (:alternate-materialization fixture)))
      other-fact
      (conflict/decision-fact-v1
       other-key :pass (:pass-evidence fixture))
      results
      (map #(conflict/resolve-conflict-set-v1 {:key key-v1 :facts %})
           (permutations [pass-fact other-fact]))]
  (check! "multiple materializations are inadmissible without a policy"
          (and (apply = results)
               (= :inadmissible (:status (first results))))))

(check! "zero decisions is MISSING, never PASS"
        (= :missing
           (:status
            (conflict/resolve-conflict-set-v1 {:key key-v1 :facts []}))))

(check! "a supplied ID that does not match canonical bytes rejects"
        (= conflict/fact-id-mismatch-code-v1
           (error-code
            #(conflict/resolve-conflict-set-v1
              {:key key-v1
               :facts [(assoc pass-fact :fact-id
                              (str "sha256:" (apply str (repeat 64 "0"))))]}))))

(let [retained {"sha256:controlled-collision" [1 2 3]}]
  (check! "same valid ID with different content rejects without replacement"
          (and (= conflict/fact-id-collision-code-v1
                  (error-code
                   #(conflict/merge-validated-content-v1
                     retained
                     {:fact-id "sha256:controlled-collision" :bytes [4 5 6]})))
               (= [1 2 3] (get retained "sha256:controlled-collision")))))

(def conflict-before-supersession
  (conflict/resolve-conflict-set-v1
   {:key key-v1 :facts [pass-fact fail-fact]}))
(def valid-supersession
  (conflict/fact-supersession-v1
   {:key key-v1
    :prior-conflict-set-digest
    (:conflict-set-digest conflict-before-supersession)
    :superseded-fact-id (:fact-id fail-fact)
    :replacement-fact-id (:fact-id pass-fact)
    :reason (:supersession-reason fixture)
    :authority (:supersession-authority fixture)}))

(let [results
      (map #(conflict/resolve-conflict-set-v1
             {:key key-v1
              :facts %
              :supersessions [valid-supersession]
              :admitted-supersession-reasons
              #{(:supersession-reason fixture)}
              :admitted-supersession-authorities
              #{(:supersession-authority fixture)}})
           (permutations [pass-fact fail-fact]))]
  (check! "exact-set admitted supersession resolves every permutation"
          (and (apply = results)
               (= :pass (:status (first results)))
               (= [(:fact-id pass-fact)] (:fact-ids (first results))))))

(check! "stale, unauthorized, or content-altered supersession rejects"
        (every?
         #(= :conflict/invalid-supersession (error-code %))
         [#(conflict/resolve-conflict-set-v1
            {:key key-v1
             :facts [pass-fact fail-fact]
             :supersessions
             [(conflict/fact-supersession-v1
               (assoc valid-supersession
                      :prior-conflict-set-digest "sha256:stale"))]
             :admitted-supersession-reasons
             #{(:supersession-reason fixture)}
             :admitted-supersession-authorities
             #{(:supersession-authority fixture)}})
          #(conflict/resolve-conflict-set-v1
            {:key key-v1
             :facts [pass-fact fail-fact]
             :supersessions [valid-supersession]
             :admitted-supersession-reasons #{}
             :admitted-supersession-authorities
             #{(:supersession-authority fixture)}})
          #(conflict/resolve-conflict-set-v1
            {:key key-v1
             :facts [pass-fact fail-fact]
             :supersessions [(assoc valid-supersession
                                    :reason "altered-after-addressing")]
             :admitted-supersession-reasons
             #{"altered-after-addressing"}
             :admitted-supersession-authorities
             #{(:supersession-authority fixture)}})]))

(def state-v1 (conflict/conflict-state-v1 "store-revision-7" "route-old"))
(def conflict-publication
  {:expected-revision "store-revision-7"
   :published-route "route-pass"
   :key key-v1
   :facts [pass-fact fail-fact]})

(let [outcome
      (conflict/apply-conflict-publication-v1
       state-v1 conflict-publication "store-revision-8")]
  (check! "unresolved conflict cannot publish authoritative PASS"
          (and (= :unresolved (get-in outcome [:result :status]))
               (= conflict/unresolved-publication-code-v1
                  (get-in outcome [:result :code]))
               (= :conflict
                  (get-in outcome [:result :resolution :status]))
               (identical? state-v1 (:state outcome))
               (= "route-old" (get-in outcome [:state :published-route])))))

(let [outcome
      (conflict/apply-conflict-publication-v1
       state-v1
       (assoc conflict-publication :expected-revision "store-revision-6")
       "store-revision-8")]
  (check! "Store revision race returns typed conflict without route mutation"
          (and (= :stale-revision (get-in outcome [:result :status]))
               (= conflict/stale-revision-code-v1
                  (get-in outcome [:result :code]))
               (= "store-revision-6"
                  (get-in outcome [:result :expected-revision]))
               (= "store-revision-7"
                  (get-in outcome [:result :current-revision]))
               (identical? state-v1 (:state outcome))
               (= "route-old" (get-in outcome [:state :published-route])))))

(let [outcome
      (conflict/apply-conflict-publication-v1
       state-v1
       (assoc conflict-publication :facts [pass-fact])
       "store-revision-8")]
  (check! "one resolved PASS advances revision and route atomically"
          (and (= :accepted (get-in outcome [:result :status]))
               (= :pass (get-in outcome [:result :resolution :status]))
               (= "store-revision-8" (get-in outcome [:state :revision]))
               (= "route-pass" (get-in outcome [:state :published-route])))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp3-conflict: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp3-conflict: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
