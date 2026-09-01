;; Exact-resource lease lookup must remain independent of unrelated
;; supersession history. This is intentionally a focused executable regression:
;;
;;   bb -cp out tests/lease_lookup_bounded_test.clj
(require '[store.store :as store]
         '[store.types :as t])

(load-file "database.clj")

(def unrelated-history-size 2048)
(def db (database/new-database "lease-lookup-bounded"))
(def context (database/database-store! db))

(dotimes [position unrelated-history-size]
  (let [subject (str "unrelated-" position)
        transaction
        (store/commit-transaction!
         context
         [(store/assert-operation (t/triple subject :state "old"))])
        old-coordinate (t/occurrence-coordinate transaction 0)
        replacement-transaction
        (t/transaction-coordinate "lease-lookup-bounded"
                                  (store/next-sequence context))
        replacement-coordinate
        (t/occurrence-coordinate replacement-transaction 0)]
    (store/commit-transaction!
     context
     [(store/assert-operation (t/triple subject :state "new"))
      (store/assert-operation
       (t/triple replacement-coordinate
                 :kernel/supersedes
                 old-coordinate))])))

(def resource "lease-resource")
(def holder "lease-holder")
(def stale-lease-transaction
  (store/commit-transaction!
   context
   [(store/assert-operation
     (t/triple resource :kernel/lease
               (t/triple "stale-holder" :kernel/expires-at 999999998)))]))
(def stale-lease-coordinate
  (t/occurrence-coordinate stale-lease-transaction 0))
(def current-lease-transaction
  (t/transaction-coordinate "lease-lookup-bounded"
                            (store/next-sequence context)))
(def current-lease-coordinate
  (t/occurrence-coordinate current-lease-transaction 0))
(store/commit-transaction!
 context
 [(store/assert-operation
   (t/triple resource :kernel/lease
             (t/triple holder :kernel/expires-at 999999999)))
  (store/assert-operation
   (t/triple current-lease-coordinate
             :kernel/supersedes
             stale-lease-coordinate))])

(def matching-live-propositions-var
  (ns-resolve 'store.store 'matching-live-propositions))
(def matching-live-propositions-original
  @matching-live-propositions-var)
(def supersession-lookups (atom []))
(def started-at (System/nanoTime))
(def lease
  (with-redefs-fn
    {matching-live-propositions-var
     (fn [term-store t1 t2 t3 maximum]
       (when (= :kernel/supersedes t2)
         (swap! supersession-lookups conj [t1 t3 maximum]))
       (matching-live-propositions-original
        term-store t1 t2 t3 maximum))}
    #(database/current-lease! db resource)))
(def elapsed-ms
  (/ (double (- (System/nanoTime) started-at)) 1000000.0))

(def exact-supersession-lookups?
  (and (<= (count @supersession-lookups) 2)
       (every? (fn [[_ coordinate _]] (some? coordinate))
               @supersession-lookups)))

(println {:unrelated-supersessions unrelated-history-size
          :lookup-ms elapsed-ms
          :supersession-lookups @supersession-lookups})

(when-not (and (= holder (:holder lease))
               (= current-lease-coordinate (:occurrence lease))
               exact-supersession-lookups?)
  (binding [*out* *err*]
    (println "lease lookup traversed unrelated supersession history"
             {:lease lease
              :supersession-lookups @supersession-lookups}))
  (System/exit 1))

(println "lease lookup bounded: PASS")
