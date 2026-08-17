;; Native FRAMRPC probes for bin/beagle-store-doctor.
(require '[store.rpc :as wire]
         '[store.kernel :as kernel]
         '[store.rt :as rt]
         '[store.types :as terms])

(def port (Integer/parseInt (System/getenv "BEAGLE_STORE_SC_PORT")))
(def space (System/getenv "BEAGLE_STORE_SC_SPACE"))
(def phase (System/getenv "BEAGLE_STORE_SC_PHASE"))
(def expected-engine
  (case (System/getenv "BEAGLE_STORE_SC_EXPECTED_ENGINE")
    ":rpc/native" :rpc/native
    ":rpc/graal" :rpc/graal
    ":rpc/jvm" :rpc/jvm
    (throw
     (ex-info
      "BEAGLE_STORE_SC_EXPECTED_ENGINE must be :rpc/native, :rpc/graal, or :rpc/jvm"
      {}))))
(def results (atom []))
(def request-id (atom 0))

(defn request!
  ([operation payload] (request! operation payload nil nil))
  ([operation payload expected page]
   (rt/native-request-to!
    "127.0.0.1" port
    (wire/rpc-request! space operation expected page nil payload))))
(defn payload [response] (terms/rpc-response-payload-value response))
(defn error-code [response] (some-> response terms/rpcresponse-error terms/rpcerror-code))
(defn fields [value tag count-value] (wire/rpc-record-fields! value tag count-value))
(defn values-list [value] (wire/rpc-list-values! value))
(defn section [name thunk]
  (let [[ok detail]
        (try (thunk)
             (catch Throwable error [false (or (.getMessage error) (str (class error)))]))]
    (swap! results conj [name (boolean ok) detail])))

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

(if (= phase "restart")
  (section "restart"
    #(let [response (request! :rpc/scan
                              (wire/rpc-triple-pattern! "selfcheck" nil nil))
           [encoded] (fields (payload response) :rpc/triples 1)
           triples (values-list encoded)]
       [(and (nil? (error-code response)) (= 7 (count triples)))
        (str "replayed " (count triples) " recursive Triples")]))
  (do
    (section "socket"
      #(let [version (request! :rpc/version wire/rpc-unit)
             status (request! :rpc/status wire/rpc-unit)
             [state live-count engine _] (fields (payload status) :rpc/status 4)]
         [(and (= 0 (terms/rpcresponse-served-version version))
               (= :ready state) (= 0 live-count) (= expected-engine engine))
          "version/status typed round-trip"]))

    (section "terms"
      #(let [values ["text" -42 1.5 true :kernel/type
                     (terms/instant 1785580282 123000000)
                     (terms/triple "nested" :kernel/type "triple")]
             actions
             (mapv (fn [index value]
                     (wire/rpc-action!
                      :rpc/assert
                      (terms/triple "selfcheck" (keyword (str "probe/value-" index)) value)
                      wire/rpc-subject-any))
                   (range) values)
             response (request! :rpc/batch (wire/rpc-batch! actions nil) 0 nil)
             scan (request! :rpc/scan
                            (wire/rpc-triple-pattern! "selfcheck" nil nil))
             [encoded] (fields (payload scan) :rpc/triples 1)]
         [(and (nil? (error-code response))
               (= 1 (terms/rpcresponse-served-version response))
               (= 7 (count (values-list encoded))))
          "all Atom kinds plus nested Triple committed atomically"]))

    (section "occ"
      #(let [stale (request! :rpc/assert
                             (wire/rpc-write!
                              (terms/triple "stale" :probe/value true)
                              wire/rpc-subject-any nil)
                             0 nil)
             head (request! :rpc/version wire/rpc-unit)]
         [(and (= :rpc/conflict (error-code stale))
               (= 1 (terms/rpcresponse-served-version head)))
          "stale expected version rejected without movement"]))

    (section "fencing"
      #(let [acquired (request! :rpc/lease-acquire
                                (wire/rpc-lease-acquire! :selfcheck "holder" 60000))
             [fence _] (fields (payload acquired) :lease/grant 2)
             renewed (request! :rpc/lease-renew (wire/rpc-lease-renew! fence 60000))
             [next-fence _] (fields (payload renewed) :lease/grant 2)
             accepted (request! :rpc/assert
                                (wire/rpc-write!
                                 (terms/triple "fenced" :probe/value "winner")
                                 wire/rpc-subject-any next-fence))
             stale (request! :rpc/assert
                             (wire/rpc-write!
                              (terms/triple "fenced" :probe/value "loser")
                              wire/rpc-subject-any fence))]
         [(and (nil? (error-code accepted))
               (= :rpc/lease-fence-mismatch (error-code stale)))
          "renewed fence accepted; stale epoch rejected"]))

    (section "lease"
      #(let [acquired (request! :rpc/lease-acquire
                                (wire/rpc-lease-acquire! :release "holder" 60000))
             [fence _] (fields (payload acquired) :lease/grant 2)
             checked (request! :rpc/lease-check fence)
             [valid _] (fields (payload checked) :lease/check 2)
             released (request! :rpc/lease-release fence)
             [released?] (fields (payload released) :lease/released 1)
             after (request! :rpc/lease-check fence)
             [after-valid _] (fields (payload after) :lease/check 2)]
         [(and valid released? (not after-valid))
          "acquire/check/release is exact-epoch"]))

    (section "pagination"
      #(let [payload (wire/rpc-query-request! (all-triples-plan) wire/query-current)
             first-page (request! :rpc/query payload nil
                                  (wire/rpc-page-request! 2 nil))
             cursor (terms/rpc-page-response-cursor-value
                     (terms/rpcresponse-page first-page))
             second-page (request! :rpc/query payload nil
                                   (wire/rpc-page-request! 100 cursor))]
         [(and (some? cursor)
               (terms/rpcpageresponse-done (terms/rpcresponse-page second-page)))
          "cursor resumes one pinned query snapshot"]))))

(doseq [[name ok detail] @results]
  (println (format "  [%s] %-10s %s" (if ok "PASS" "FAIL") name detail)))
(when (some (comp not second) @results) (System/exit 1))
