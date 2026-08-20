;; A branch ref is changed only by expected-head compare-and-set. Both
;; contenders are complete content-addressed histories; exactly one may win.
;; Run from the repository root: bb -cp out tests/branch_ref_cas_test.clj
(require '[store.branch :as branch]
         '[store.store :as store]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-branch-ref-cas-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(defn- store-path [name]
  (.getPath (java.io.File. scratch name)))

(defn- seed-and-seal! [path value child]
  (database/create-triple-log! path "branch-ref-cas-space")
  (database/assert! (database/open-database! path "branch-ref-cas-space")
                    (t/triple "winner" :value value) {})
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

(def target (store-path "target.storelog"))
(def source-a (store-path "candidate-a.storelog"))
(def source-b (store-path "candidate-b.storelog"))
(def original (seed-and-seal! target "original" "target-child"))
(def candidate-a (seed-and-seal! source-a "alpha" "alpha-child"))
(def candidate-b (seed-and-seal! source-b "bravo" "bravo-child"))
(copy-segments! source-a target candidate-a)
(copy-segments! source-b target candidate-b)

(def expected (branch/ref-identity original))
(def ready (java.util.concurrent.CountDownLatch. 2))
(def go (java.util.concurrent.CountDownLatch. 1))
(defn- contend! [candidate]
  (.countDown ready)
  (.await go)
  (database/compare-and-set-branch-ref!
   target branch/default-branch expected candidate))

(def contender-a (future (contend! candidate-a)))
(def contender-b (future (contend! candidate-b)))
(.await ready)
(.countDown go)
(def results [@contender-a @contender-b])
(def winner (first (filter :swapped? results)))
(def loser (first (remove :swapped? results)))
(def installed (database/read-branch-ref target branch/default-branch))

(println "branch ref CAS:")
(check! "two contenders against one expected ref produce one winner"
        (= 1 (count (filter :swapped? results))))
(check! "the stale contender observes the winner without changing it"
        (and loser
             (= (:current loser) (:current winner))
             (= (:current winner) (branch/ref-identity installed))))
(check! "the winning ref is exact canonical durable state after reread"
        (contains? #{candidate-a candidate-b} installed))

(def restarted
  (database/open-branch! target branch/default-branch
                         "branch-ref-cas-space"))
(def live (set (database/live-propositions restarted)))
(check! "restart folds the winning content-addressed head"
        (= 1 (count (filter #(and (= "winner" (t/triple-t1 %))
                                  (= :value (t/triple-t2 %)))
                            live))))

(let [before (slurp (branch/ref-path! target branch/default-branch))
      stale (database/compare-and-set-branch-ref!
             target branch/default-branch expected original)
      after (slurp (branch/ref-path! target branch/default-branch))]
  (check! "a later stale contender changes no ref bytes or state"
          (and (not (:swapped? stale)) (= before after))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nbranch ref CAS:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nbranch ref CAS:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
