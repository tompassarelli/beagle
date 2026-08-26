;; Beagle Store adapter: speaks STORERPC v2 to server.clj over a real loopback
;; socket. boot-to-serving-ms excludes JVM startup and the ServerSocket bind,
;; per METHODOLOGY.md. Bulk reads use paged :rpc/query, never scan/occurrences
;; (both fail past ~250 rows, a term-depth bound).
(require '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.rt :as rt]
         '[store.types :as t])
;; server.clj's tail auto-invokes -main on a nonempty *command-line-args*.
(binding [*command-line-args* nil] (load-file "server.clj"))

(def corpus-triples (Long/parseLong (or (first *command-line-args*) "3000")))
(def run-id (Long/parseLong (or (second *command-line-args*) "1")))
(when-not (and (pos? corpus-triples) (zero? (mod corpus-triples 3)))
  (throw (ex-info "corpus size must be a positive multiple of 3"
                  {:corpus-triples corpus-triples})))

(def scratch (.toFile (java.nio.file.Files/createTempDirectory
                       "store-in-class-" (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "coordination.storelog")))
(def space-id "bench-in-class")
(def expected-rows (quot corpus-triples 3))

(defn corpus-fact [tx]
  (let [subject (quot (dec tx) 3)
        slot (mod (dec tx) 3)
        [predicate value] (case slot
                            0 [:kind "thread"]
                            1 [:title (str "title-" subject)]
                            2 [:owner (str "@owner-" (mod subject 32))])]
    (t/triple (str "@corpus-" subject) predicate value)))

(defn ms [f]
  (let [t0 (System/nanoTime)
        value (f)]
    [(/ (- (System/nanoTime) t0) 1e6) value]))

;; Untimed: one durable tx per live triple, on a throwaway server, so the timed boot replays a populated STORELOG.
(def seed-cancellation {:cancelled (atom false) :query-control (atom nil)})
(defn seed-assert! [proposition]
  (let [request (wire/rpc-request! space-id :rpc/assert nil nil nil
                                   (wire/rpc-write! proposition wire/rpc-subject-any nil))
        response (server/handle-rpc-request! request seed-cancellation)]
    (when (t/rpcresponse-error response)
      (throw (ex-info "corpus seeding write failed"
                      {:error (t/rpcresponse-error response)})))))

(server/boot! log-path space-id :active)
(doseq [tx (range 1 (inc corpus-triples))]
  (seed-assert! (corpus-fact tx)))
(server/shutdown!)

;; --- port + query plan ---
(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))
(def port (free-port))

(def q-join
  (let [s (wire/rpc-query-variable! "s")
        title (wire/rpc-query-variable! "title")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "in-class")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "in-class" [s title])
         [(wire/rpc-query-relation!
           "triple" [s (wire/rpc-query-constant! :kind) (wire/rpc-query-constant! "thread")] false)
          (wire/rpc-query-relation!
           "triple" [s (wire/rpc-query-constant! :title) title] false)])])])))
(def q-join-request (wire/rpc-query-request! q-join wire/query-current))

(defn request! [space operation payload & {:keys [expected page timeout]}]
  (rt/native-request!
   port (wire/rpc-request! space operation expected page timeout payload)))

(defn error-code [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))

(defn query-rows [response]
  (let [[values] (wire/rpc-record-fields! (t/rpc-response-payload-value response)
                                          :query/rows 1)]
    (mapv (fn [row]
            (let [[row-values] (wire/rpc-record-fields! row :query/row 1)]
              (wire/rpc-list-values! row-values)))
          (wire/rpc-list-values! values))))

;; TermCodecV1's 256-deep recursive-list encoding rejects a page anywhere
;; near the protocol's 4096-row max; 200 stays under the observed cliff.
(def query-page-limit 200)

(defn paged-query! []
  (loop [cursor nil rows []]
    (let [response (request! space-id :rpc/query q-join-request
                             :page (wire/rpc-page-request! query-page-limit cursor))]
      (if (error-code response)
        {:error (error-code response) :rows rows}
        (let [page (t/rpcresponse-page response)
              next-cursor (t/rpc-page-response-cursor-value page)
              all-rows (into rows (query-rows response))]
          (if (t/rpcpageresponse-done page)
            {:error nil :rows all-rows}
            (recur next-cursor all-rows)))))))

(defn write! [subject value]
  (request! space-id :rpc/assert
           (wire/rpc-write! (t/triple subject :bench-value value)
                            wire/rpc-subject-any nil)))

(defn percentile [xs p]
  (let [sorted (vec (sort xs))]
    (nth sorted (min (dec (count sorted))
                     (int (Math/floor (* p (count sorted))))))))

(def errors (atom 0))
(defn checked-write! [subject value]
  (let [reply (write! subject value)]
    (when (error-code reply) (swap! errors inc))
    reply))
(defn checked-query! []
  (let [{:keys [error rows]} (paged-query!)]
    (when (or error (not= expected-rows (count rows)))
      (swap! errors inc))
    rows))

;; Binds by hand (not server/serve!): replay + rpc/status are timed, the bind is not.
(def boot-elapsed
  (let [[replay-ms _] (ms #(server/boot! log-path space-id :active))
        server-socket (java.net.ServerSocket. (int port) 128
                                              (java.net.InetAddress/getByName "127.0.0.1"))]
    (reset! server/listener server-socket)
    (def server-future
      (future
        (try
          (while (not @server/stopping?)
            (try
              (let [socket (.accept server-socket)]
                (future (try (server/serve-connection! socket)
                             (catch Throwable _
                               (try (.close socket) (catch Throwable _ nil))))))
              (catch java.net.SocketException _
                (when-not @server/stopping? (throw (ex-info "accept failed" {}))))))
          (catch Throwable _ nil))))
    (let [[status-ms status] (ms #(request! space-id :rpc/status wire/rpc-unit))]
      (when (error-code status)
        (throw (ex-info "adapter-ready probe failed" {:response status})))
      (+ replay-ms status-ms))))

(def cold
  (let [[elapsed rows] (ms checked-query!)]
    {:ms elapsed :rows (count rows)}))

;; JIT/first-touch warmup happens only after the cold measurements.
(dotimes [i 30]
  (checked-write! (str "@warm-" i) (str "warm-" i)))
(dotimes [_ 10] (checked-query!))

(def sustained
  (let [stop? (atom false)
        reads (atom 0)
        reader (future
                 (while (not @stop?)
                   (checked-query!)
                   (swap! reads inc)))
        [elapsed _]
        (ms #(dotimes [i 1200]
               (checked-write! (str "@sustained-" run-id "-" i)
                               (str "value-" i))))]
    (reset! stop? true)
    @reader
    (when (zero? @reads) (swap! errors inc))
    {:ops-s (/ 1200.0 (/ elapsed 1000.0))
     :read-ops @reads}))

(def mixed
  (let [read-latencies (atom [])
        [elapsed _]
        (ms #(dotimes [i 40]
               (checked-write! (str "@mixed-" run-id "-" i) (str "value-" i))
               (dotimes [_ 3]
                 (let [[read-ms _] (ms checked-query!)]
                   (swap! read-latencies conj read-ms)))))]
    {:ops-s (/ 160.0 (/ elapsed 1000.0))
     :read-p50-ms (percentile @read-latencies 0.50)}))

(def row
  {:adapter "store"
   :run run-id
   :corpus-triples corpus-triples
   :boot-to-serving-ms boot-elapsed
   :cold-start-query-ms (:ms cold)
   :cold-query-rows (:rows cold)
   :write-under-read-ops-s (:ops-s sustained)
   :concurrent-read-ops (:read-ops sustained)
   :mixed-ops-s (:ops-s mixed)
   :mixed-read-p50-ms (:read-p50-ms mixed)
   :errors @errors})

(println "BENCHROW" (json/generate-string row))

(server/shutdown!)
(deref server-future 3000 nil)

(doseq [^java.io.File f (reverse (file-seq scratch))]
  (.delete f))

;; futures pin the non-daemon agent thread pool; the JVM won't exit without this.
(shutdown-agents)
