;; Reachability collection treats branch refs and durable pin/checkpoint/session
;; documents as facts. Every document is verified before any unreferenced
;; content-addressed segment is deleted.
;; Run from the repository root:
;;   tests/run_hosted_test.sh 240s bb -cp out tests/branch_reachability_gc_test.clj
(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.branch :as branch]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(defn error-code [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error
      (or (:store/code (ex-data error)) (:type (ex-data error))))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-branch-reachability-gc-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(defn cleanup! []
  (doseq [file (reverse (file-seq scratch))]
    (io/delete-file file true)))
(def cleanup-hook
  (Thread. ^Runnable #(cleanup!) "branch-reachability-gc-cleanup"))
(.addShutdownHook (Runtime/getRuntime) cleanup-hook)

(def space "branch-reachability-gc-space")
(def target (.getPath (io/file scratch "target.storelog")))

(defn write-bytes! [path ^bytes content]
  (let [file (java.io.File. (str path))]
    (when-let [parent (.getParentFile file)] (.mkdirs parent))
    (java.nio.file.Files/write
     (.toPath file) content
     (into-array java.nio.file.OpenOption
                 [java.nio.file.StandardOpenOption/CREATE
                  java.nio.file.StandardOpenOption/WRITE
                  java.nio.file.StandardOpenOption/TRUNCATE_EXISTING]))))

(defn segment-exists? [sha]
  (.isFile (java.io.File. (branch/segment-path target sha))))

(defn copied-segment! [name]
  (let [source (.getPath (io/file scratch (str name ".storelog")))]
    (database/create-triple-log! source space)
    (database/assert! (database/open-database! source space)
                      (t/triple name :root true) {})
    (database/fork-store! source "child")
    (let [document (database/read-branch-ref! source branch/default-branch)
          segment (first (branch/refdocument-segments document))
          sha (branch/segmentrecord-sha256 segment)]
      (write-bytes!
       (branch/segment-path target sha)
       (java.nio.file.Files/readAllBytes
        (.toPath (java.io.File. (branch/segment-path source sha)))))
      {:document document :sha sha})))

(database/create-triple-log! target space)
(def head-fact (t/triple "head" :root true))
(database/assert! (database/open-database! target space) head-fact {})
(database/fork-store! target "live-head")
(def head-document
  (database/read-branch-ref! target branch/default-branch))
(def head-sha
  (branch/segmentrecord-sha256
   (first (branch/refdocument-segments head-document))))

(def pin (copied-segment! "pin-history"))
(def checkpoint (copied-segment! "checkpoint-history"))
(def session (copied-segment! "session-history"))
(def orphan (copied-segment! "orphan-history"))

(def duplicate-root-code
  (let [segment
        (first (branch/refdocument-segments (:document pin)))]
    (error-code
     #(database/retain-branch-root!
       target :pin "duplicate-root"
       (branch/->RefDocument space [segment segment])))))

(def pin-receipt
  (database/retain-branch-root!
   target :pin "release-pin" (:document pin)))
(def checkpoint-receipt
  (database/retain-branch-root!
   target :checkpoint "stable-checkpoint" (:document checkpoint)))
(def session-receipt
  (database/retain-branch-root!
   target :session "active-session" (:document session)))

(def unmanaged (str (branch/segments-directory target) "/README"))
(write-bytes! unmanaged (.getBytes "not a segment\n"
                                  java.nio.charset.StandardCharsets/UTF_8))

(println "branch reachability GC:")
(check! "retention canonicalizes and rejects constructor-only invalid refs"
        (and (= :invalid-branch-ref duplicate-root-code)
             (not (.exists
                   (java.io.File.
                    (str target ".roots/pins/duplicate-root"))))))
(check! "pin, checkpoint, and active session roots are durable ref documents"
        (and (= [(:sha pin)] (:segments pin-receipt))
             (= [(:sha checkpoint)] (:segments checkpoint-receipt))
             (= [(:sha session)] (:segments session-receipt))
             (every?
              #(.isFile (java.io.File. %))
              [(str target ".roots/pins/release-pin")
               (str target ".roots/checkpoints/stable-checkpoint")
               (str target ".roots/sessions/active-session")])))

(def first-collection (database/collect-unreachable-segments! target))
(def first-reachable #{head-sha (:sha pin) (:sha checkpoint) (:sha session)})

(check! "collection marks every current head, pin, checkpoint, and active session"
        (= first-reachable (set (:reachable first-collection))))
(check! "the only collected segment is unreachable from every durable root"
        (= [(:sha orphan)] (:collected first-collection)))
(check! "all four reachable segment classes survive collection"
        (every? segment-exists? first-reachable))
(check! "a collected orphan is absent while non-segment files are untouched"
        (and (not (segment-exists? (:sha orphan)))
             (.isFile (java.io.File. unmanaged))))
(check! "a cold branch open still folds its reachable head"
        (= #{head-fact}
           (set (database/live-propositions!
                 (database/open-branch!
                  target branch/default-branch space)))))

(def released (database/release-branch-root! target :pin "release-pin"))
(def second-collection (database/collect-unreachable-segments! target))
(check! "a released pin becomes collectible and no earlier"
        (and (:released? released)
             (= [(:sha pin)] (:collected second-collection))
             (not (segment-exists? (:sha pin)))
             (segment-exists? (:sha checkpoint))
             (segment-exists? (:sha session))))

(def late-orphan (copied-segment! "late-orphan-history"))
(def session-root (str target ".roots/sessions/active-session"))
(write-bytes!
 session-root
 (.getBytes
  (str/replace (slurp session-root)
               (str "space " space) "space corrupt-space")
  java.nio.charset.StandardCharsets/UTF_8))
(def malformed-code
  (error-code #(database/collect-unreachable-segments! target)))
(check! "a malformed durable root aborts collection before the first deletion"
        (and (= :invalid-branch-ref malformed-code)
             (segment-exists? (:sha late-orphan))
             (segment-exists? (:sha checkpoint))
             (segment-exists? (:sha session))))

(let [failures (remove second @checks)]
  (.removeShutdownHook (Runtime/getRuntime) cleanup-hook)
  (cleanup!)
  (shutdown-agents)
  (if (empty? failures)
    (println "\nbranch reachability GC:" (count @checks) "/"
             (count @checks) "PASS")
    (do
      (println "\nbranch reachability GC:" (count failures) "FAILED")
      (System/exit 1))))
