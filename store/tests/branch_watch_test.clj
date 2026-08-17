;; Branch watch exposes only durable ref transitions and resumes from its
;; monotonic cursor without a gap or duplicate.
;; Run from the repository root: bb -cp out tests/branch_watch_test.clj
(require '[store.branch :as branch]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-branch-watch-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(defn- store-path [name]
  (.getPath (java.io.File. scratch name)))

(defn- seed-and-seal! [path value child]
  (database/create-triple-log! path "branch-watch-space")
  (database/assert! (database/open-database! path "branch-watch-space")
                    (t/triple "watch" :value value) {})
  (database/fork-store! path child)
  (database/read-branch-ref path branch/default-branch))

(defn- copy-segments! [source target document]
  (java.nio.file.Files/createDirectories
   (.toPath (java.io.File. (branch/segments-directory target)))
   (make-array java.nio.file.attribute.FileAttribute 0))
  (doseq [record (branch/refdocument-segments document)]
    (let [name (branch/segmentrecord-sha256 record)]
      (java.nio.file.Files/copy
       (.toPath (java.io.File. (branch/segment-path source name)))
       (.toPath (java.io.File. (branch/segment-path target name)))
       (into-array java.nio.file.CopyOption
                   [java.nio.file.StandardCopyOption/REPLACE_EXISTING])))))

(def target (store-path "target.framlog"))
(def source-a (store-path "candidate-a.framlog"))
(def source-b (store-path "candidate-b.framlog"))
(def original (seed-and-seal! target "original" "target-child"))
(def candidate-a (seed-and-seal! source-a "alpha" "alpha-child"))
(def candidate-b (seed-and-seal! source-b "bravo" "bravo-child"))
(copy-segments! source-a target candidate-a)
(copy-segments! source-b target candidate-b)

(def initial (database/branch-transitions-since!
              target branch/default-branch 0))
(println "branch watch:")
(check! "watch anchors an existing ref without inventing a transition"
        (= {:cursor 0 :transitions []} initial))

(def ready (java.util.concurrent.CountDownLatch. 1))
(def continuous
  (future
    (.countDown ready)
    (database/watch-branch! target branch/default-branch 0 2000)))
(.await ready)
(def first-result
  (database/compare-and-set-branch-ref!
   target branch/default-branch (branch/ref-identity original) candidate-a))
(def first-watch @continuous)
(def first-event (first (:transitions first-watch)))

(check! "a continuous watch receives exactly one successful ref transition"
        (and (:swapped? first-result)
             (= 1 (:cursor first-watch))
             (= 1 (count (:transitions first-watch)))
             (= 1 (:cursor first-event))))
(check! "the watch event is observable only with its durable ref installed"
        (and (= (:previous first-result) (:previous first-event))
             (= (:current first-result) (:current first-event))
             (= (:current first-event)
                (database/branch-ref-identity target branch/default-branch))))

(def second-result
  (database/compare-and-set-branch-ref!
   target branch/default-branch (:current first-result) candidate-b))
(def resumed
  (database/branch-transitions-since!
   target branch/default-branch (:cursor first-watch)))
(def all-events
  (:transitions
   (database/branch-transitions-since! target branch/default-branch 0)))

(check! "cursor resume returns the next transition without a duplicate"
        (and (:swapped? second-result)
             (= 2 (:cursor resumed))
             (= [2] (mapv :cursor (:transitions resumed)))))
(check! "durable watch history has no cursor gap"
        (= [1 2] (mapv :cursor all-events)))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nbranch watch:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nbranch watch:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
