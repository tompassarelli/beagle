;; FRAMRPC v2 JVM listener: closed operation set, typed payloads, history,
;; query snapshots, leases, cancellation, malformed input, and restart replay.
(require '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.datalog :as datalog]
         '[store.kernel :as kernel]
         '[store.query :as query]
         '[store.types :as t])

(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(def failures (atom []))
(def request-id (atom 0))

(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (when-not ok (swap! failures conj label)))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 200) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn fields [value tag count-value]
  (wire/rpc-record-fields! value tag count-value))

(defn values-list [value]
  (wire/rpc-list-values! value))

(defn payload [response]
  (t/rpc-response-payload-value response))

(defn error-code [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))

(defn request! [port space operation payload & {:keys [expected page timeout]}]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space operation expected page timeout payload)))

(defn action-results [response]
  (let [[results] (fields (payload response) :rpc/mutation-result 1)]
    (mapv #(fields % :rpc/action-result 3) (values-list results))))

(defn triples-result [response tag]
  (let [[values] (fields (payload response) tag 1)]
    (values-list values)))

(defn occurrence-results [response]
  (mapv #(fields % :rpc/occurrence 3)
        (triples-result response :rpc/occurrences)))

(defn query-rows [response]
  (mapv (fn [row]
          (let [[values] (fields row :query/row 1)] (values-list values)))
        (triples-result response :query/rows)))

(defn paged-query-rows [port space query-payload]
  (loop [cursor nil rows []]
    (let [response (request! port space :rpc/query query-payload
                             :page (wire/rpc-page-request! 1 cursor))
          page (t/rpcresponse-page response)
          next-cursor (when page (t/rpc-page-response-cursor-value page))]
      (if (or (error-code response) (nil? page))
        {:error (error-code response) :rows rows}
        (let [all-rows (into rows (query-rows response))]
          (if (t/rpcpageresponse-done page)
            {:error nil :rows all-rows}
            (recur next-cursor all-rows)))))))

(defn paged-read
  "Drain one paged read into its rows and the versions each page served."
  ([port space operation payload limit tag]
   (paged-read port space operation payload limit tag nil))
  ([port space operation payload limit tag start-cursor]
   (loop [cursor start-cursor rows [] versions []]
     (let [response (request! port space operation payload
                              :page (wire/rpc-page-request! limit cursor))
           page (t/rpcresponse-page response)]
       (if (or (error-code response) (nil? page))
         {:error (or (error-code response) :missing-page)
          :rows rows :versions versions}
         (let [all-rows (into rows (triples-result response tag))
               all-versions (conj versions
                                  (t/rpcresponse-served-version response))]
           (if (t/rpcpageresponse-done page)
             {:error nil :rows all-rows :versions all-versions}
             (recur (t/rpc-page-response-cursor-value page)
                    all-rows all-versions))))))))

(defn one-triple-plan [relation head-terms body-terms]
  (wire/rpc-query-plan!
   (wire/rpc-query-find-relation! relation)
   [(wire/rpc-query-stratum!
     [(wire/rpc-query-rule!
       (wire/rpc-query-head! relation head-terms)
       [(wire/rpc-query-relation! "triple" body-terms false)])])]))

(defn all-triples-plan []
  (let [t1 (wire/rpc-query-variable! "t1")
        t2 (wire/rpc-query-variable! "t2")
        t3 (wire/rpc-query-variable! "t3")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "all")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "all" [t1 t2 t3])
         [(wire/rpc-query-relation! "triple" [t1 t2 t3] false)])])])))

(defn all-occurrences-plan []
  (let [coordinate (wire/rpc-query-variable! "coordinate")
        action (wire/rpc-query-variable! "action")
        proposition (wire/rpc-query-variable! "proposition")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "occurrences")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "occurrences" [coordinate action proposition])
         [(wire/rpc-query-relation!
           "occurrence" [coordinate action proposition] false)])])])))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-native-rpc-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (io/file scratch "history.framlog")))
(def space "native-rpc-test")
(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(try
  (check! "listener starts on FRAMRPC v2"
          (some? (eventually #(request! port space :rpc/version wire/rpc-unit))))

    (check! "operation disposition is exhaustive for the thirteen v2 operations"
          (and (= 13 (count server/native-rpc-operations))
               (every? #(= :supported (server/native-op-disposition %))
                       server/native-rpc-operations)
               (every? #(= :unsupported (server/native-op-disposition %))
                       [:rpc/not-an-operation])))

  (let [response (request! port space :rpc/version wire/rpc-unit)]
    (check! "rpc/version reports the outer logical version"
            (and (nil? (error-code response))
                 (= 0 (t/rpcresponse-served-version response))
                 (= wire/rpc-unit (payload response)))))

  (let [response (request! port space :rpc/status wire/rpc-unit)
        [state live-count engine cache] (fields (payload response) :rpc/status 4)
        [hits misses bytes evictions] (fields cache :rpc/result-cache 4)]
    (check! "rpc/status is a typed record"
            (and (= :ready state) (= 0 live-count) (= :rpc/jvm engine)
                 (= [0 0 0 0] [hits misses bytes evictions]))))

  (let [cancel-bytes (wire/encode-rpc-frame-v2! (wire/rpc-cancel-frame 44))]
    (aset-byte cancel-bytes 14 (unchecked-byte 255))
    (aset-byte cancel-bytes 15 (unchecked-byte 255))
    (aset-byte cancel-bytes 16 (unchecked-byte 255))
    (aset-byte cancel-bytes 17 (unchecked-byte 127))
    (check! "oversized frames are rejected from the header before body allocation"
            (= :rpc-frame-too-large
               (try
                 (server/read-rpc-frame!
                  (java.io.ByteArrayInputStream. cancel-bytes))
                 nil
                 (catch clojure.lang.ExceptionInfo error
                   (:fram/code (ex-data error)))))))

  (let [nested-subject (t/triple "source-file" :page 1)
        proposition (t/triple nested-subject :title "Door Schedule")
        response (request! port space :rpc/assert
                           (wire/rpc-write! proposition wire/rpc-subject-any nil))
        [[input-index changed coordinate]] (action-results response)]
    (check! "recursive Triple assertion returns its occurrence coordinate"
            (and (= 0 input-index) changed
                 (t/occurrence-coordinate? coordinate)
                 (= 0 (t/triple-t3 coordinate))
                 (= 1 (t/triple-t3 (t/triple-t1 coordinate)))
                 (= 1 (t/rpcresponse-served-version response))))
    (let [scan (request! port space :rpc/scan
                         (wire/rpc-triple-pattern! nested-subject nil nil))]
      (check! "slot-addressed scan returns the recursive proposition"
              (= [proposition] (triples-result scan :rpc/triples))))

    (let [replacement (t/triple nested-subject :title "Revised Schedule")
          batch (request!
                 port space :rpc/batch
                 (wire/rpc-batch!
                  [(wire/rpc-action! :rpc/assert replacement wire/rpc-subject-existing)
                   (wire/rpc-action! :rpc/assert (t/triple "other" :value 2)
                                     wire/rpc-subject-any)
                   (wire/rpc-action! :rpc/retract proposition wire/rpc-subject-existing)]
                  nil))
          results (action-results batch)
          coordinates
          (mapv #(nth % 2) results)]
      (check! "batch applies ordered assert/retract actions in one transaction"
              (and (= [0 1 2] (mapv first results))
                   (= [true true true] (mapv second results))
                   (every? t/occurrence-coordinate? coordinates)
                   (= [2 2 2]
                      (mapv #(t/triple-t3 (t/triple-t1 %)) coordinates))
                   (= [0 1 2] (mapv t/triple-t3 coordinates))
                   (= 2 (t/rpcresponse-served-version batch))))

      (let [no-op (request! port space :rpc/retract
                            (wire/rpc-write! proposition wire/rpc-subject-any nil))
            [[_ changed occurrence]] (action-results no-op)]
        (check! "missing retract records an occurrence without changing live state"
                (and (false? changed)
                     (t/occurrence-coordinate? occurrence)
                     (= 3 (t/rpcresponse-served-version no-op)))))

      (let [before (request! port space :rpc/version wire/rpc-unit)
            predicate :oversized-batch-fixture
            action-count (inc wire/rpc-v2-max-batch-actions)
            rejected
            (request!
             port space :rpc/batch
             (wire/rpc-batch!
              (mapv
               (fn [index]
                 (wire/rpc-action!
                  :rpc/assert
                  (t/triple (str "oversized-" index) predicate index)
                  wire/rpc-subject-any))
               (range action-count))
              nil))
            after (request! port space :rpc/version wire/rpc-unit)
            scan (request! port space :rpc/scan
                           (wire/rpc-triple-pattern! nil predicate nil))]
        (check! "248-action batch is rejected before version or state changes"
                (and (= 247 wire/rpc-v2-max-batch-actions)
                     (= 248 action-count)
                     (= :term-depth-exceeded (error-code rejected))
                     (= (t/rpcresponse-served-version before)
                        (t/rpcresponse-served-version rejected)
                        (t/rpcresponse-served-version after)
                        (t/rpcresponse-served-version scan))
                     (empty? (triples-result scan :rpc/triples)))))

      (let [history (request! port space :rpc/occurrences wire/rpc-unit)
            events (occurrence-results history)]
        (check! "occurrences are typed protocol records with physical actions"
                (and (seq events)
                     (every? t/occurrence-coordinate? (map first events))
                     (every? #{:assert :retract} (map second events))
                     (every? t/triple? (map #(nth % 2) events)))))

      (let [plan (all-triples-plan)
            query-payload (wire/rpc-query-request! plan wire/query-current)
            first-page (request! port space :rpc/query query-payload
                                 :page (wire/rpc-page-request! 1 nil))
            cursor (t/rpc-page-response-cursor-value
                    (t/rpcresponse-page first-page))
            later (t/triple "later" :value 3)
            asserted-later (request! port space :rpc/assert
                                     (wire/rpc-write! later wire/rpc-subject-any nil))
            second-page (request! port space :rpc/query query-payload
                                  :page (wire/rpc-page-request! 4096 cursor))
            pinned-rows (into (query-rows first-page) (query-rows second-page))
            historical (request!
                        port space :rpc/query
                        (wire/rpc-query-request! plan (wire/rpc-query-as-of! 1)))
            current-after-ack
            (request! port space :rpc/scan
                      (wire/rpc-triple-pattern! "later" :value 3))]
        (check! "query cursor pins snapshot version across later commits"
                (and (= 3 (t/rpcresponse-served-version first-page))
                     (= 4 (t/rpcresponse-served-version asserted-later))
                     (= 3 (t/rpcresponse-served-version second-page))
                     (not-any? #(= ["later" :value 3] %) pinned-rows)))
        (check! "query as-of rebuilds the requested logical snapshot"
                (and (= 1 (t/rpcresponse-served-version historical))
                     (some #(= [(t/triple "source-file" :page 1)
                                :title "Door Schedule"] %)
                           (query-rows historical))))
        (let [occurrence-plan (all-occurrences-plan)
              at-one (request!
                      port space :rpc/query
                      (wire/rpc-query-request!
                       occurrence-plan (wire/rpc-query-as-of! 1)))
              at-two (request!
                      port space :rpc/query
                      (wire/rpc-query-request!
                       occurrence-plan (wire/rpc-query-as-of! 2)))
              since-one (request!
                         port space :rpc/query
                         (wire/rpc-query-request!
                          occurrence-plan
                          (wire/rpc-query-since!
                           1 (wire/rpc-query-as-of! 2))))
              current-since (request!
                             port space :rpc/query
                             (wire/rpc-query-request!
                              occurrence-plan
                              (wire/rpc-query-since! 1 wire/query-current)))
              row-sequence (fn [row]
                             (-> row first t/triple-t1 t/triple-t3))]
          (check! "query since composes deterministic (L,U] occurrence history"
                  (and (= 2 (t/rpcresponse-served-version at-two))
                       (= (set (query-rows at-two))
                          (into (set (query-rows at-one))
                                (query-rows since-one)))
                       (every? #(= 2 (row-sequence %))
                               (query-rows since-one))
                       (every? #(<= 2 (row-sequence %)
                                      (t/rpcresponse-served-version current-since))
                               (query-rows current-since))))
          (let [first-page
                (request!
                 port space :rpc/query
                 (wire/rpc-query-request!
                  occurrence-plan
                  (wire/rpc-query-since! 1 wire/query-current))
                 :page (wire/rpc-page-request! 1 nil))
                cursor (t/rpc-page-response-cursor-value
                        (t/rpcresponse-page first-page))
                mismatched
                (request!
                 port space :rpc/query
                 (wire/rpc-query-request!
                  occurrence-plan
                  (wire/rpc-query-since! 0 wire/query-current))
                 :page (wire/rpc-page-request! 1 cursor))]
            (check! "query cursor binds the resolved since lower bound"
                    (= :query-cursor-mismatch (error-code mismatched))))
          (with-redefs [server/query-checkpoint-interval 1]
            (#'server/drop-query-caches!)
            (let [checkpoint (io/file
                              (str log-path ".query-checkpoints")
                              "snapshot-1.fri")
                  built (request!
                         port space :rpc/query
                         (wire/rpc-query-request!
                          occurrence-plan (wire/rpc-query-as-of! 1)))
                  _ (spit checkpoint "corrupt-derived-cache")
                  _ (#'server/drop-query-caches!)
                  rebuilt (request!
                           port space :rpc/query
                           (wire/rpc-query-request!
                            occurrence-plan (wire/rpc-query-as-of! 1)))]
              (check! "as-of uses prefix-bound FRI2 checkpoints and corrupt cache falls back"
                      (and (.isFile checkpoint)
                           (nil? (error-code built))
                           (nil? (error-code rebuilt))
                           (= (query-rows built) (query-rows rebuilt))
                           (> (.length checkpoint) 32)))))
          (let [before (request!
                        port space :rpc/query
                        (wire/rpc-query-request!
                         occurrence-plan (wire/rpc-query-as-of! 1)))
                entry (server/seal-query-epoch! 1)
                after (request!
                       port space :rpc/query
                       (wire/rpc-query-request!
                        occurrence-plan (wire/rpc-query-as-of! 1)))
                _ (.delete (io/file (:path entry)))
                _ (reset! (var-get #'server/query-archive-databases) {})
                _ (#'server/drop-query-caches!)
                unavailable (request!
                             port space :rpc/query
                             (wire/rpc-query-request!
                              occurrence-plan (wire/rpc-query-as-of! 1)))
                _ (server/seal-query-epoch! 1)
                _ (server/expire-query-epoch! 1)
                expired (request!
                         port space :rpc/query
                         (wire/rpc-query-request!
                          occurrence-plan (wire/rpc-query-as-of! 1)))
                _ (server/seal-query-epoch! 1)]
            (check! "sealed epoch preserves rows and distinguishes unavailable from expired"
                    (and (= (query-rows before) (query-rows after))
                         (= :query/archive-unavailable
                            (error-code unavailable))
                         (true? (some-> unavailable t/rpcresponse-error
                                        t/rpcerror-retryable))
                         (= :query/snapshot-expired (error-code expired))
                         (false? (some-> expired t/rpcresponse-error
                                         t/rpcerror-retryable))))))
        (check! "a read after an acknowledged write sees at least its version"
                (and (<= (t/rpcresponse-served-version asserted-later)
                         (t/rpcresponse-served-version current-after-ack))
                     (= [later]
                        (triples-result current-after-ack :rpc/triples))))
        (let [work-limited
              (with-redefs-fn
                {#'server/cached-result!
                 (fn [& _]
                   (throw (ex-info "query evaluation stopped: query-work-limit"
                                   {:fram/code :query-work-limit})))}
                #(request!
                  port space :rpc/query
                  (wire/rpc-query-request! plan (wire/rpc-query-as-of! 1))))]
          (check! "an as-of work-limit error reports the snapshot it served"
                  (and (= :query-work-limit (error-code work-limited))
                       (= 1 (t/rpcresponse-served-version work-limited)))))))

      (let [stale (request!
                   port space :rpc/assert
                   (wire/rpc-write! (t/triple "stale" :value 2)
                                    wire/rpc-subject-any nil)
                   :expected 2)
            head (request! port space :rpc/version wire/rpc-unit)]
        (check! "stale expected-version fails OCC without version movement"
                (and (= :rpc/conflict (error-code stale))
                     (= 4 (t/rpcresponse-served-version head)))))

      (let [same (t/triple "same" :same "same")
            asserted-same (request! port space :rpc/assert
                                    (wire/rpc-write! same wire/rpc-subject-any nil))
            patterns
            [["constant predicate and reordered distinct bindings"
              (let [subject (wire/rpc-query-variable! "subject")
                    value (wire/rpc-query-variable! "value")]
                (one-triple-plan
                 "values" [value subject value]
                 [subject (wire/rpc-query-constant! :value) value]))]
             ["repeated body variable unifies equal slots"
              (let [value (wire/rpc-query-variable! "value")]
                (one-triple-plan
                 "self" [value]
                 [value (wire/rpc-query-constant! :same) value]))]
             ["constant subject projects one binding"
              (let [value (wire/rpc-query-variable! "value")]
                (one-triple-plan
                 "one-value" [value]
                 [(wire/rpc-query-constant! "other")
                  (wire/rpc-query-constant! :value)
                  value]))]
             ["constant-only match grounds a constant head"
              (one-triple-plan
               "constant-match" [(wire/rpc-query-constant! :matched)]
               [(wire/rpc-query-constant! "same")
                (wire/rpc-query-constant! :same)
                (wire/rpc-query-constant! "same")])]
             ["repeated body variable rejects unequal slots"
              (let [value (wire/rpc-query-variable! "value")]
                (one-triple-plan
                 "not-self" [value]
                 [value (wire/rpc-query-constant! :value) value]))]]]
        (check! "one-triple fixture assertion advances one version"
                (= 5 (t/rpcresponse-served-version asserted-same)))
        (doseq [[label plan] patterns]
          (let [query-payload (wire/rpc-query-request! plan wire/query-current)
                reference (request! port space :rpc/query query-payload)
                paged (paged-query-rows port space query-payload)]
            (check! (str "paged one-triple path matches Datalog: " label)
                    (and (nil? (error-code reference))
                         (nil? (:error paged))
                         (= (query-rows reference) (:rows paged)))))))

      (let [subject (wire/rpc-query-variable! "subject")
            value (wire/rpc-query-variable! "value")
            plan (one-triple-plan
                  "pinned-values" [subject value]
                  [subject (wire/rpc-query-constant! :value) value])
            query-payload (wire/rpc-query-request! plan wire/query-current)
            reference (request! port space :rpc/query query-payload)
            first-page (request! port space :rpc/query query-payload
                                 :page (wire/rpc-page-request! 1 nil))
            snapshot-version (t/rpcresponse-served-version first-page)
            cursor (t/rpc-page-response-cursor-value
                    (t/rpcresponse-page first-page))
            asserted-new (request!
                          port space :rpc/assert
                          (wire/rpc-write! (t/triple "new-value" :value 4)
                                           wire/rpc-subject-any nil))
            second-page (request! port space :rpc/query query-payload
                                  :page (wire/rpc-page-request! 4096 cursor))
            pinned-rows (into (query-rows first-page) (query-rows second-page))]
        (check! "selective one-triple cursor retains its immutable snapshot"
                (and (= snapshot-version
                        (t/rpcresponse-served-version second-page))
                     (= (inc snapshot-version)
                        (t/rpcresponse-served-version asserted-new))
                     (= (query-rows reference) pinned-rows)
                     (not-any? #(= ["new-value" 4] %) pinned-rows))))

    (let [subject (wire/rpc-query-variable! "subject")
          value (wire/rpc-query-variable! "value")
          values-plan (one-triple-plan
                       "values-after-writes" [subject value]
                       [subject (wire/rpc-query-constant! :value) value])
          values-payload (wire/rpc-query-request! values-plan wire/query-current)
          before-lease (request! port space :rpc/query values-payload)
          acquired (request! port space :rpc/lease-acquire
                             (wire/rpc-lease-acquire! :resource "holder" 60000))
          [fence _] (fields (payload acquired) :lease/grant 2)
          after-acquire (request! port space :rpc/query values-payload)
          checked (request! port space :rpc/lease-check fence)
          fenced-write (request!
                        port space :rpc/assert
                        (wire/rpc-write! (t/triple "fenced" :value true)
                                         wire/rpc-subject-any fence))
          renewed (request! port space :rpc/lease-renew
                            (wire/rpc-lease-renew! fence 60000))
          [next-fence _] (fields (payload renewed) :lease/grant 2)
          stale-fence (request!
                       port space :rpc/assert
                       (wire/rpc-write! (t/triple "fenced" :value false)
                                        wire/rpc-subject-any fence))
          old-check (request! port space :rpc/lease-check fence)
          released (request! port space :rpc/lease-release next-fence)
          projection-used (atom false)
          direct-reads
          (with-redefs [datalog/edb
                        (fn [& _]
                          (reset! projection-used true)
                          (throw (ex-info "whole-corpus projection used" {})))]
            {:query (request! port space :rpc/query values-payload)
             :paged (paged-query-rows port space values-payload)})
          [valid _] (fields (payload checked) :lease/check 2)
          [old-valid _] (fields (payload old-check) :lease/check 2)
          [released?] (fields (payload released) :lease/released 1)]
      (check! "lease acquire/check/renew/release use typed Fence records"
              (and valid (not old-valid) released? (not= fence next-fence)))
      (check! "write fencing accepts the current epoch and rejects the stale one"
              (and (nil? (error-code fenced-write))
                   (= :rpc/lease-fence-mismatch (error-code stale-fence))))
      (check! "one-triple query reads through lease acquisition"
              (and (nil? (error-code before-lease))
                   (nil? (error-code after-acquire))
                   (= (query-rows before-lease) (query-rows after-acquire))))
      (check! "one-triple query and page see the ordinary write after lease writes"
              (let [direct-rows (query-rows (:query direct-reads))]
                (and (nil? (error-code (:query direct-reads)))
                     (nil? (get-in direct-reads [:paged :error]))
                     (some #{["fenced" true]} direct-rows)
                     (= direct-rows (get-in direct-reads [:paged :rows])))))
      (check! "one-triple reads bypass the whole-corpus query projection"
              (false? @projection-used)))

    (let [subject (wire/rpc-query-variable! "cache-subject")
          value (wire/rpc-query-variable! "cache-value")
          arguments [subject (wire/rpc-query-constant! :value) value]
          plan (wire/rpc-query-plan!
                (wire/rpc-query-find-relation! "single-flight-values")
                [(wire/rpc-query-stratum!
                  [(wire/rpc-query-rule!
                    (wire/rpc-query-head!
                     "single-flight-values" [subject value])
                    [(wire/rpc-query-relation! "triple" arguments false)
                     (wire/rpc-query-relation! "triple" arguments false)])])])
          query-payload (wire/rpc-query-request! plan wire/query-current)
          row-builder (ns-resolve 'store.query 'run-plan-projected!)
          original-builder (var-get row-builder)
          builds (atom 0)
          [first-read second-read advanced current-read historical-read]
          (with-redefs-fn
            {row-builder
             (fn [& args]
               (swap! builds inc)
               (Thread/sleep 100)
               (apply original-builder args))}
            #(let [a (future (request! port space :rpc/query query-payload))
                   b (future (request! port space :rpc/query query-payload))
                   first-read @a
                   second-read @b
                   pinned-version (t/rpcresponse-served-version first-read)
                   advanced
                   (request! port space :rpc/assert
                             (wire/rpc-write!
                              (t/triple "cache-version" :value 99)
                              wire/rpc-subject-any nil))
                   current-read (request! port space :rpc/query query-payload)
                   historical-read
                   (request!
                    port space :rpc/query
                    (wire/rpc-query-request!
                     plan (wire/rpc-query-as-of! pinned-version)))]
               [first-read second-read advanced current-read historical-read]))
          _ (doseq [index (range 9)]
              (request!
               port space :rpc/query
               (wire/rpc-query-request!
                (one-triple-plan
                 (str "cache-bound-" index) [subject value]
                 [subject (wire/rpc-query-constant! :value) value])
                wire/query-current)))
          status (request! port space :rpc/status wire/rpc-unit)
          [_ _ _ cache] (fields (payload status) :rpc/status 4)
          [hits misses bytes evictions] (fields cache :rpc/result-cache 4)
          cache-state @server/query-result-cache
          version-counts (frequencies (map first (keys (:entries cache-state))))
          validated (request! port space :rpc/validate wire/rpc-unit)
          [valid violations] (fields (payload validated) :rpc/validation 2)]
      (check! "rpc/validate round-trips the store and result cache stays bounded"
              (and valid (empty? (values-list violations))
                   (= 2 @builds)
                   (= (query-rows first-read) (query-rows second-read))
                   (= (inc (t/rpcresponse-served-version first-read))
                      (t/rpcresponse-served-version advanced))
                   (not= (query-rows first-read) (query-rows current-read))
                   (= (query-rows first-read) (query-rows historical-read))
                   (pos? hits) (pos? misses) (pos? bytes) (pos? evictions)
                   (= bytes (:bytes cache-state))
                   (<= (count version-counts) 4)
                   (every? #(<= % 8) (vals version-counts))
                   (<= bytes (* 64 1024 1024)))))

    (let [profile-id "relational-v1"
          declaration (kernel/relational-profile-declaration space profile-id)
          profile-facts (into [declaration]
                              (mapv #(kernel/profile-rule profile-id %)
                                    kernel/relational-profile-rules))
          _ (doseq [proposition profile-facts]
              (request! port space :rpc/assert
                        (wire/rpc-write! proposition wire/rpc-subject-any nil)))
          violating (t/triple "profile-observe"
                              "nested-value"
                              (t/triple "still" "commits" true))
          write-response (request! port space :rpc/assert
                                   (wire/rpc-write!
                                    violating wire/rpc-subject-any nil))
          validated (request! port space :rpc/validate wire/rpc-unit)
          [valid violations] (fields (payload validated) :rpc/validation 2)
          advisories (values-list violations)]
      (check! "observe profile commits a violating write and validate reports it"
              (and valid
                   (nil? (error-code write-response))
                   (some (fn [advisory]
                           (let [[code detail]
                                 (fields advisory :rpc/violation 2)]
                             (and (= :rpc/profile-violation code)
                                  (= violating (t/triple-t1 detail)))))
                         advisories)
                   (not-any? (fn [advisory]
                               (let [[_ detail]
                                     (fields advisory :rpc/violation 2)]
                                 (= declaration (t/triple-t1 detail))))
                             advisories))))

    (let [predicate :page-fixture
          fixture-count 400
          scan-payload (wire/rpc-triple-pattern! nil predicate nil)
          scan-reference (fn []
                           (filterv #(= predicate (t/triple-t2 %))
                                    (database/live-propositions
                                     @server/database)))
          occurrence-reference (fn []
                                 (mapv
                                  (fn [occurrence]
                                    (wire/rpc-occurrence!
                                     (t/operationoccurrence-coordinate occurrence)
                                     (t/operationoccurrence-action occurrence)
                                     (t/operationoccurrence-proposition occurrence)))
                                  (database/occurrences @server/database)))]
      (doseq [batch (partition-all 100 (range fixture-count))]
        (request! port space :rpc/batch
                  (wire/rpc-batch!
                   (mapv (fn [index]
                           (wire/rpc-action!
                            :rpc/assert
                            (t/triple (str "fixture-" index) predicate index)
                            wire/rpc-subject-any))
                         batch)
                   nil)))

      (let [scan-rows (scan-reference)
            occurrences (occurrence-reference)
            paged-scan (paged-read port space :rpc/scan scan-payload
                                   100 :rpc/triples)
            paged-occurrences (paged-read port space :rpc/occurrences
                                          wire/rpc-unit 100 :rpc/occurrences)
            unpaged-scan (request! port space :rpc/scan scan-payload)
            unpaged-occurrences (request! port space :rpc/occurrences
                                          wire/rpc-unit)]
        (check! "paged scan reassembles the corpus the unpaged reply cannot carry"
                (and (= fixture-count (count scan-rows))
                     (nil? (:error paged-scan))
                     (= scan-rows (:rows paged-scan))))
        (check! "paged occurrences reassemble the history past 251 events"
                (and (< 251 (count occurrences))
                     (nil? (:error paged-occurrences))
                     (= occurrences (:rows paged-occurrences))))
        (check! "unpaged scan and occurrences past the depth bound still fail typed"
                (and (= :term-depth-exceeded (error-code unpaged-scan))
                     (= :term-depth-exceeded (error-code unpaged-occurrences)))))

      (let [visited (atom 0)
            live database/live-propositions
            bounded (with-redefs [database/live-propositions
                                  (fn [db]
                                    (map (fn [proposition]
                                           (swap! visited inc)
                                           proposition)
                                         (live db)))]
                      (request! port space :rpc/scan scan-payload))]
        (check! "unpaged scan stops folding once the depth bound is unreachable"
                (and (= :term-depth-exceeded (error-code bounded))
                     (< @visited (count (scan-reference))))))

      (let [reference (scan-reference)
            first-page (request! port space :rpc/scan scan-payload
                                 :page (wire/rpc-page-request! 1 nil))
            pinned-version (t/rpcresponse-served-version first-page)
            cursor (t/rpc-page-response-cursor-value
                    (t/rpcresponse-page first-page))
            later (request! port space :rpc/assert
                            (wire/rpc-write!
                             (t/triple "fixture-later" predicate 4000)
                             wire/rpc-subject-any nil))
            rest-pages (paged-read port space :rpc/scan scan-payload
                                   100 :rpc/triples cursor)
            pinned (into (triples-result first-page :rpc/triples)
                         (:rows rest-pages))]
        (check! "scan cursor pins its snapshot across an intervening commit"
                (and (nil? (:error rest-pages))
                     (= (inc pinned-version)
                        (t/rpcresponse-served-version later))
                     (every? #(= pinned-version %) (:versions rest-pages))
                     (= reference pinned))))

      (let [reference (occurrence-reference)
            first-page (request! port space :rpc/occurrences wire/rpc-unit
                                 :page (wire/rpc-page-request! 1 nil))
            pinned-version (t/rpcresponse-served-version first-page)
            cursor (t/rpc-page-response-cursor-value
                    (t/rpcresponse-page first-page))
            later (request! port space :rpc/assert
                            (wire/rpc-write!
                             (t/triple "occurrence-later" predicate 4001)
                             wire/rpc-subject-any nil))
            rest-pages (paged-read port space :rpc/occurrences wire/rpc-unit
                                   100 :rpc/occurrences cursor)
            pinned (into (triples-result first-page :rpc/occurrences)
                         (:rows rest-pages))]
        (check! "occurrences cursor pins its snapshot across an intervening commit"
                (and (nil? (:error rest-pages))
                     (= (inc pinned-version)
                        (t/rpcresponse-served-version later))
                     (every? #(= pinned-version %) (:versions rest-pages))
                     (= reference pinned))))

      (let [duplicated (t/triple "duplicated" :page-dup 0)
            dup-payload (wire/rpc-triple-pattern! nil :page-dup nil)]
        (doseq [proposition [duplicated
                             (t/triple "between" :page-dup 1)
                             duplicated
                             (t/triple "tail" :page-dup 2)]]
          (request! port space :rpc/assert
                    (wire/rpc-write! proposition wire/rpc-subject-any nil)))
        (let [reference (filterv #(= :page-dup (t/triple-t2 %))
                                 (database/live-propositions
                                  @server/database))
              paged (paged-read port space :rpc/scan dup-payload
                                3 :rpc/triples)]
          (check! "scan pages resume by position, not by row value"
                  (and (= 4 (count reference))
                       (= 2 (count (filter #{duplicated} reference)))
                       (nil? (:error paged))
                       (= reference (:rows paged))))))

      (let [fixture-cursor (t/rpc-page-response-cursor-value
                            (t/rpcresponse-page
                             (request! port space :rpc/scan scan-payload
                                       :page (wire/rpc-page-request! 1 nil))))
            mismatched (request! port space :rpc/scan
                                 (wire/rpc-triple-pattern! nil :value nil)
                                 :page (wire/rpc-page-request! 1 fixture-cursor))
            over-limit (request! port space :rpc/scan scan-payload
                                 :page (wire/rpc-page-request!
                                        (inc query/max-page-limit) nil))
            unpaged-op (request! port space :rpc/status wire/rpc-unit
                                 :page (wire/rpc-page-request! 1 nil))]
        (check! "scan cursors stay bound to their pattern, limit, and operation"
                (and (= :query-cursor-mismatch (error-code mismatched))
                     (= :query-page-limit (error-code over-limit))
                     (= :rpc/unexpected-page (error-code unpaged-op))))))

    (let [before (t/rpcresponse-served-version
                  (request! port space :rpc/version wire/rpc-unit))
          cancellation {:cancelled (atom true) :query-control (atom nil)}
          refused (server/handle-rpc-request!
                   (wire/rpc-request!
                    space :rpc/assert nil nil nil
                    (wire/rpc-write! (t/triple "cancelled" :value 1)
                                     wire/rpc-subject-any nil))
                   cancellation)
          after (t/rpcresponse-served-version
                 (request! port space :rpc/version wire/rpc-unit))]
      (check! "pre-durability cancellation cannot append a transaction"
              (and (= :rpc/cancelled (error-code refused)) (= before after))))

    (let [cancellation {:cancelled (atom false) :query-control (atom nil)}]
      (swap! server/active-requests assoc 777 cancellation)
      (server/handle-rpc-frame! (wire/rpc-cancel-frame 777)
                                      {:cancelled (atom false)
                                       :query-control (atom nil)})
      (swap! server/active-requests dissoc 777)
      (check! "cancel frames target the matching active request id"
              @(:cancelled cancellation))))

  (finally
    (server/shutdown!)
    (deref server 3000 nil)))

(let [restart-port (free-port)
      restarted (future (server/serve! restart-port log-path space :active))]
  (try
    (let [version (eventually #(request! restart-port space :rpc/version wire/rpc-unit))
          scan (request! restart-port space :rpc/scan
                         (wire/rpc-triple-pattern! "later" :value 3))
          status (request! restart-port space :rpc/status wire/rpc-unit)
          [_ _ _ cache] (fields (payload status) :rpc/status 4)
          cache-stats (fields cache :rpc/result-cache 4)]
      (check! "restart replays native RPC mutations from FRAMLOG"
              (and (pos? (t/rpcresponse-served-version version))
                   (= [(t/triple "later" :value 3)]
                      (triples-result scan :rpc/triples))
                   (= [0 0 0 0] cache-stats))))
    (finally
      (server/shutdown!)
      (deref restarted 3000 nil))))

(let [receipt-space "native-rpc-receipt-bound"
      receipt-log-path (str (io/file scratch "receipt-bound-history.framlog"))
      receipt-port (free-port)
      receipt-server
      (future
        (server/serve! receipt-port receipt-log-path receipt-space :active))]
  (try
    (check! "isolated mutation-receipt server starts"
            (some? (eventually
                    #(request! receipt-port receipt-space :rpc/version
                               wire/rpc-unit))))
    (let [proposition (t/triple true :receipt-bound true)
          pattern (wire/rpc-triple-pattern! true :receipt-bound true)
          before
          (request! receipt-port receipt-space :rpc/version wire/rpc-unit)
          accepted
          (request!
           receipt-port receipt-space :rpc/batch
           (wire/rpc-batch!
            (vec
             (repeat
              wire/rpc-v2-max-batch-actions
              (wire/rpc-action! :rpc/assert proposition
                                wire/rpc-subject-any)))
            nil))
          results (action-results accepted)
          coordinates
          (mapv #(nth % 2) results)
          after
          (request! receipt-port receipt-space :rpc/version wire/rpc-unit)
          scan
          (paged-read receipt-port receipt-space :rpc/scan pattern
                      100 :rpc/triples)]
      (check! "247-action batch commits one ordered coordinate receipt"
              (and (nil? (error-code accepted))
                   (= 247 wire/rpc-v2-max-batch-actions
                      (count results)
                      (count coordinates)
                      (count (:rows scan)))
                   (= (vec (range 247)) (mapv first results))
                   (every? true? (map second results))
                   (every? t/occurrence-coordinate? coordinates)
                   (every? #(= receipt-space
                               (t/triple-t1 (t/triple-t1 %)))
                           coordinates)
                   (= (vec (repeat 247 1))
                      (mapv #(t/triple-t3 (t/triple-t1 %)) coordinates))
                   (= (vec (range 247)) (mapv t/triple-t3 coordinates))
                   (= (inc (t/rpcresponse-served-version before))
                      (t/rpcresponse-served-version accepted)
                      (t/rpcresponse-served-version after))
                   (nil? (:error scan))
                   (every? #{proposition} (:rows scan))))
      (let [rejected
            (request!
             receipt-port receipt-space :rpc/batch
             (wire/rpc-batch!
              (vec
               (repeat
                248
                (wire/rpc-action! :rpc/assert proposition
                                  wire/rpc-subject-any)))
              nil))
            after-rejection
            (request! receipt-port receipt-space :rpc/version wire/rpc-unit)
            scan-after-rejection
            (paged-read receipt-port receipt-space :rpc/scan pattern
                        100 :rpc/triples)]
        (check! "248-action batch rejection preserves the 247-action commit"
                (and (= :term-depth-exceeded (error-code rejected))
                     (= (t/rpcresponse-served-version accepted)
                        (t/rpcresponse-served-version rejected)
                        (t/rpcresponse-served-version after-rejection))
                     (nil? (:error scan-after-rejection))
                     (= (:rows scan) (:rows scan-after-rejection))))))
    (finally
      (server/shutdown!)
      (deref receipt-server 3000 nil))))

(let [lease-space "native-rpc-lease-preflight"
      lease-log-path (str (io/file scratch "lease-preflight-history.framlog"))
      lease-port (free-port)
      lease-server
      (future (server/serve! lease-port lease-log-path lease-space :active))]
  (try
    (check! "isolated lease-preflight server starts"
            (some? (eventually
                    #(request! lease-port lease-space :rpc/version
                               wire/rpc-unit))))
    (let [resource
          (nth (iterate #(t/triple % 0 0) :lease/deep-resource) 253)
          pattern (wire/rpc-triple-pattern! nil :kernel/lease nil)
          before-version
          (request! lease-port lease-space :rpc/version wire/rpc-unit)
          before-scan (request! lease-port lease-space :rpc/scan pattern)
          rejected
          (request! lease-port lease-space :rpc/lease-acquire
                    (wire/rpc-lease-acquire! resource "holder" 60000))
          after-version
          (request! lease-port lease-space :rpc/version wire/rpc-unit)
          after-scan (request! lease-port lease-space :rpc/scan pattern)]
      (check! "unencodable deep lease grant is rejected before commit"
              (and (= :term-depth-exceeded (error-code rejected))
                   (= (t/rpcresponse-served-version before-version)
                      (t/rpcresponse-served-version rejected)
                      (t/rpcresponse-served-version after-version)
                      (t/rpcresponse-served-version before-scan)
                      (t/rpcresponse-served-version after-scan))
                   (= (triples-result before-scan :rpc/triples)
                      (triples-result after-scan :rpc/triples)
                      []))))
    (finally
      (server/shutdown!)
      (deref lease-server 3000 nil))))

(let [long-space (apply str (repeat wire/rpc-v2-max-space-bytes "s"))
      long-log-path (str (io/file scratch "long-space-history.framlog"))
      long-port (free-port)
      long-server
      (future (server/serve! long-port long-log-path long-space :active))]
  (try
    (check! "listener accepts a max-legal 4096-byte SpaceId"
            (some? (eventually
                    #(request! long-port long-space :rpc/version
                               wire/rpc-unit))))
    (let [proposition (t/triple true true true)
          pattern (wire/rpc-triple-pattern! true true true)
          before-version
          (request! long-port long-space :rpc/version wire/rpc-unit)
          before-scan (request! long-port long-space :rpc/scan pattern)
          accepted-request
          (wire/rpc-request!
           long-space :rpc/batch nil nil nil
           (wire/rpc-batch!
            (vec
             (repeat
              243
              (wire/rpc-action! :rpc/assert proposition
                                wire/rpc-subject-any)))
            nil))
          accepted
          (server/handle-rpc-request!
           accepted-request
           {:cancelled (atom false) :query-control (atom nil)})
          encoded-accepted
          (wire/encode-rpc-frame-v2!
           (wire/rpc-response-frame 8001 accepted))
          results (action-results accepted)
          coordinates
          (mapv #(nth % 2) results)
          after-success-version
          (request! long-port long-space :rpc/version wire/rpc-unit)
          after-success-scan
          (request! long-port long-space :rpc/scan pattern)
          rejected-request
          (wire/rpc-request!
           long-space :rpc/batch nil nil nil
           (wire/rpc-batch!
            (vec
             (repeat
              244
              (wire/rpc-action! :rpc/assert proposition
                                wire/rpc-subject-any)))
            nil))
          rejected
          (server/handle-rpc-request!
           rejected-request
           {:cancelled (atom false) :query-control (atom nil)})
          after-rejection-version
          (request! long-port long-space :rpc/version wire/rpc-unit)
          after-rejection-scan
          (request! long-port long-space :rpc/scan pattern)]
      (check! "243-action long-SpaceId receipt commits at the byte boundary"
              (and (nil? (error-code accepted))
                   (= 1045981 (alength encoded-accepted))
                   (= 243 (count results)
                      (count coordinates)
                      (count (triples-result after-success-scan :rpc/triples)))
                   (= (vec (range 243)) (mapv first results))
                   (every? true? (map second results))
                   (every? t/occurrence-coordinate? coordinates)
                   (= (vec (repeat 243 1))
                      (mapv #(t/triple-t3 (t/triple-t1 %)) coordinates))
                   (= (vec (range 243)) (mapv t/triple-t3 coordinates))
                   (= (inc (t/rpcresponse-served-version before-version))
                      (t/rpcresponse-served-version accepted)
                      (t/rpcresponse-served-version after-success-version)
                      (t/rpcresponse-served-version after-success-scan))
                   (empty? (triples-result before-scan :rpc/triples))
                   (every? #{proposition}
                           (triples-result after-success-scan :rpc/triples))))
      (check! "unencodable 244-action receipt preserves the 243-action commit"
              (and (= :rpc-frame-too-large (error-code rejected))
                   (= (t/rpcresponse-served-version accepted)
                      (t/rpcresponse-served-version rejected)
                      (t/rpcresponse-served-version after-rejection-version)
                      (t/rpcresponse-served-version after-rejection-scan))
                   (= (triples-result after-success-scan :rpc/triples)
                      (triples-result after-rejection-scan :rpc/triples)))))
    (let [near-max-value (apply str (repeat 1039000 "x"))
          proposition (t/triple true true near-max-value)
          request
          (wire/rpc-request!
           long-space :rpc/assert nil nil nil
           (wire/rpc-write! proposition wire/rpc-subject-any nil))
          encoded-request
          (wire/encode-rpc-frame-v2! (wire/rpc-request-frame 9001 request))
          response
          (server/handle-rpc-request!
           request {:cancelled (atom false) :query-control (atom nil)})
          encoded-response
          (wire/encode-rpc-frame-v2!
           (wire/rpc-response-frame 9001 response))
          [[input-index changed coordinate]] (action-results response)
          version
          (request! long-port long-space :rpc/version wire/rpc-unit)]
      (check! "near-max legal proposition commits with an encodable receipt"
              (and (nil? (error-code response))
                   (>= (alength encoded-request)
                       (- wire/rpc-v2-max-frame-bytes 8192))
                   (<= (alength encoded-request) wire/rpc-v2-max-frame-bytes)
                   (<= (alength encoded-response) wire/rpc-v2-max-frame-bytes)
                   (= 0 input-index)
                   changed
                   (t/occurrence-coordinate? coordinate)
                   (= 0 (t/triple-t3 coordinate))
                   (= 2 (t/rpcresponse-served-version response)
                      (t/triple-t3 (t/triple-t1 coordinate))
                      (t/rpcresponse-served-version version))
                   (some #{proposition}
                         (database/live-propositions @server/database)))))
    (finally
      (server/shutdown!)
      (deref long-server 3000 nil))))

(shutdown-agents)

(if (seq @failures)
  (do
    (println (str "\n" (count @failures) " native RPC server checks failed"))
    (System/exit 1))
  (println "\nFRAMRPC v2 JVM server: all checks passed"))
