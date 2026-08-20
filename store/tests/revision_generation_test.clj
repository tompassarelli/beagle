;; Revision-bound hydration stages a complete generation before publication.
;; Run from store/: bb -cp out tests/revision_generation_test.clj
(require '[babashka.fs :as fs]
         '[store.branch :as branch]
         '[store.revision-generation :as generation]
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
    "store-revision-generation-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log (.getPath (java.io.File. scratch "state.storelog")))
(def space "revision-generation-space")
(def source-revision "1111111111111111111111111111111111111111")
(def program-revision "2222222222222222222222222222222222222222")

(defn read-all [path]
  (java.nio.file.Files/readAllBytes (.toPath (java.io.File. (str path)))))

(defn state-bytes [path]
  (.encodeToString (java.util.Base64/getEncoder) (read-all path)))

(defn revision-set [revision]
  (generation/revision-set source-revision program-revision
                           (branch/branchrevision-identity revision)))

(try
  (database/create-triple-log! log space)
  (let [database (database/open-database! log space)]
    (database/assert! database (t/triple "world" :phase "old") {})
    (let [old-revision (database/branch-revision! log)
          old-binding (revision-set old-revision)
          old-bytes (state-bytes log)
          old-generation
          (generation/hydrate-generation old-binding old-binding old-bytes)
          active (atom old-generation)]
      (check! "initial hydration binds source, program, and durable state"
              (and (= source-revision
                      (generation/generation-source-revision @active))
                   (= program-revision
                      (generation/generation-program-revision @active))
                   (= (branch/branchrevision-identity old-revision)
                      (generation/generation-state-revision @active))))

      (database/assert! database (t/triple "world" :phase "new") {})
      (let [new-revision (database/branch-revision! log)
            new-binding (revision-set new-revision)
            new-bytes (state-bytes log)
            rejected
            (generation/hydrate-generation old-binding new-binding new-bytes)]
        (check! "revision mismatch rejects the staged generation"
                (nil? rejected))
        (check! "rejection leaves the previous generation visible"
                (and (= old-bytes
                        (generation/generation-state-bytes @active))
                     (= (branch/branchrevision-identity old-revision)
                        (generation/generation-state-revision @active))))

        (let [accepted
              (generation/hydrate-generation
               new-binding new-binding new-bytes)]
          (reset! active accepted)
          (check! "successful hydration exposes only its named revisions"
                  (and (= source-revision
                          (generation/generation-source-revision @active))
                       (= program-revision
                          (generation/generation-program-revision @active))
                       (= (branch/branchrevision-identity new-revision)
                          (generation/generation-state-revision @active))
                       (not= (branch/branchrevision-identity old-revision)
                             (generation/generation-state-revision @active))))
          (check! "the active generation exposes the exact durable bytes"
                  (and (= new-bytes
                          (generation/generation-state-bytes @active))
                       (= (count new-bytes)
                          (generation/generation-byte-count @active))))

          (let [before-restart-bytes (read-all log)
                before-restart-image
                (store/dump-term-store (database/database-store database))
                restarted (database/open-database! log space)
                restart-revision (database/branch-revision! log)
                restart-binding (revision-set restart-revision)
                restarted-generation
                (generation/hydrate-generation
                 restart-binding restart-binding (state-bytes log))]
            (check! "restart reproduces identical bytes and revision identity"
                    (and (java.util.Arrays/equals
                          before-restart-bytes (read-all log))
                         (= (branch/branchrevision-identity new-revision)
                            (branch/branchrevision-identity
                             restart-revision))
                         (= @active restarted-generation)))
            (check! "restart replay reproduces the identical store image"
                    (= before-restart-image
                       (store/dump-term-store
                        (database/database-store restarted)))))))))
  (finally
    (fs/delete-tree scratch)))

(let [failures (remove second @checks)]
  (println (str "\nrevision generation: "
                (- (count @checks) (count failures)) "/" (count @checks)
                " PASS"))
  (when (seq failures)
    (System/exit 1)))
