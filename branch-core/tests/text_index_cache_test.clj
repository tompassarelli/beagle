;; Exact-snapshot text-index residency, single-flight, and cache bounds.
(require '[fram.query :as q]
         '[fram.text-index :as text-index]
         '[fram.text-search :as text-search]
         '[fram.types :as t])
(load-file "server.clj")

(def checks (atom []))
(defn chk [name ok] (swap! checks conj [name ok]))
(def cancellation {:cancelled (atom false) :query-control (atom nil)})
(def cached! (var server/cached-text-index!))
(defn snapshot [version] {:generation 7 :space "text-cache" :version version})
(def propositions
  (vec (for [i (range 100)]
         (t/triple (str "@e" i) "body" (str "alpha beta " i)))))
(def deadline (+ (System/nanoTime) 60000000000))

(reset! server/server-generation 7)
((var server/drop-query-caches!))

(def build-count (atom 0))
(with-redefs [text-index/build-source!
              (let [original text-index/build-source!]
                (fn [rows maximum]
                  (swap! build-count inc)
                  (original rows maximum)))]
  (let [first-source (cached!
                      (snapshot 1) cancellation deadline #(identity propositions)
                      #{"body"})
        second-source (cached!
                       (snapshot 1) cancellation deadline #(identity propositions)
                       #{"body"})]
    (chk "an exact snapshot returns the identical immutable source"
         (identical? first-source second-source))
    (chk "an exact snapshot and attribute scope build once" (= 1 @build-count))
    (let [other-scope (cached!
                       (snapshot 1) cancellation deadline
                       #(identity propositions) #{"title"})]
      (chk "different bound attribute scopes do not share cache entries"
           (and (not (identical? first-source other-scope))
                (= 2 @build-count)))))

  (reset! build-count 0)
  (reset! server/text-index-cache
          ((var server/empty-text-index-cache) 7))
  (let [barrier (java.util.concurrent.CountDownLatch. 1)
        results (atom [])
        threads
        (mapv (fn [_]
                (Thread.
                 (fn []
                   (.await barrier)
                   (swap! results conj
                          (cached!
                           (snapshot 2) cancellation deadline
                           #(identity propositions) #{"body"})))))
              (range 32))]
    (doseq [thread threads] (.start thread))
    (.countDown barrier)
    (doseq [thread threads] (.join thread))
    (chk "32 concurrent cold readers publish one build" (= 1 @build-count))
    (chk "32 concurrent cold readers share one object"
         (every? #(identical? (first @results) %) @results))))

(doseq [version (range 3 9)]
  (cached!
   (snapshot version) cancellation deadline #(identity propositions)
   #{"body"}))
(chk "LRU retains at most four exact snapshot versions"
     (<= (count (:entries @server/text-index-cache)) 4))
(chk "LRU retains at most 64 MiB by estimated resident weight"
     (<= (:bytes @server/text-index-cache) (* 64 1024 1024)))
(chk "new snapshot keys structurally invalidate old lookup identity"
     (not (contains? (:entries @server/text-index-cache)
                     [7 "text-cache" 2])))

(let [entered (promise)
      release (promise)
      original text-index/build-source!
      future-source
      (with-redefs [text-index/build-source!
                    (fn [rows maximum]
                      (deliver entered true)
                      @release
                      (original rows maximum))]
        (let [work (future
                     (cached!
                      (snapshot 9) cancellation deadline
                      #(identity propositions) #{"body"}))]
          (deref entered 2000 false)
          (reset! server/text-index-cache
                  ((var server/empty-text-index-cache) 8))
          (deliver release true)
          (deref work 5000 nil)))]
  (chk "generation rollover does not retain a stale completed build"
       (and (some? future-source)
            (= 8 (:generation @server/text-index-cache))
            (empty? (:entries @server/text-index-cache)))))

(let [problem (try
                (text-search/build-source! propositions 1)
                nil
                (catch clojure.lang.ExceptionInfo error error))]
  (chk "oversize combined search build fails with typed query-text-index-limit"
       (= :query-text-index-limit (:fram/code (ex-data problem)))))

(let [mixed (conj propositions
                  (t/triple "@ignored" "private-note"
                            (apply str (repeat 10000 "unrelated "))))
      scoped (text-search/build-source-for-attributes! mixed #{"body"}
                                                       text-index/text-index-max-bytes)]
  (chk "attribute-scoped source excludes unrelated live strings"
       (= (count propositions)
          (count (text-search/textsearchsource-rows scoped)))))

(let [bad (remove second @checks)]
  (doseq [[name ok] @checks]
    (println (str "  [" (if ok "PASS" "FAIL") "] " name)))
  (if (empty? bad)
    (do
      (println (str "\ntext-index cache: " (count @checks) "/"
                    (count @checks) " PASS"))
      (shutdown-agents))
    (do (println (str "\ntext-index cache: " (count bad) " FAILED"))
        (System/exit 1))))
