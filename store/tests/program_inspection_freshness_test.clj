(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.program-inspection :as inspection]
         '[store.projection-lifecycle :as lifecycle])

(def checks (atom []))
(defn check! [label value]
  (println (str (if value "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(defn delete-tree! [root]
  (doseq [file (reverse (file-seq root))]
    (io/delete-file file true)))

(defn view-row [path identity]
  (first (filter #(str/includes? % (str ":semanticIdentity " (pr-str identity)))
                 (str/split-lines (slurp path)))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-program-freshness-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def source-dir (io/file scratch "src"))
(def target (io/file source-dir "a.bclj"))
(def corpus (io/file scratch ".store/corpus.facts"))
(def old-text (slurp "tests/fixtures/program-inspection/corpus.facts"))
(def fresh-slice
  (str "@file src/a.bclj\n"
       "[1 \"form-kind\" \"defn\"]\n"
       "[1 \"name\" \"alpha\"]\n"
       "[2 \"form-kind\" \"seq\"]\n"
       "[3 \"form-kind\" \"call\"]\n"
       "[3 \"calls\" \"middle\"]\n"
       "[2 \"child\" 3]\n"
       "[1 \"body\" 2]\n"
       "[1 \"child\" 2]\n"
       "[10 \"form-kind\" \"defn\"]\n"
       "[10 \"name\" \"middle\"]\n"
       "[11 \"form-kind\" \"seq\"]\n"
       "[12 \"form-kind\" \"call\"]\n"
       "[12 \"calls\" \"other\"]\n"
       "[11 \"child\" 12]\n"
       "[10 \"body\" 11]\n"
       "[10 \"child\" 11]\n"
       "[20 \"form-kind\" \"defn\"]\n"
       "[20 \"name\" \"target\"]\n"
       "[21 \"form-kind\" \"seq\"]\n"
       "[20 \"body\" 21]\n"
       "[20 \"child\" 21]\n"))

(.mkdirs source-dir)
(.mkdirs (.getParentFile corpus))
(spit target "OLD")
(spit corpus old-text)

(try
  (let [old-version (:logical-version (inspection/read-snapshot! corpus))
        publication
        (binding [lifecycle/*resolve-program-slice*
                  (fn [_ _ _] fresh-slice)]
          (lifecycle/publish-checked-projection!
           {:commit-outcome
            {:type :committed :module "a" :committed-version 12
             :proof {:ok true :id "freshness-receipt"}}
            :registered-root (.getCanonicalPath scratch)
            :registered-path "src/a.bclj"
            :checked-bytes (.getBytes "NEW" "UTF-8")
            :program-corpus (.getCanonicalPath corpus)
            :program-facts-command "test-resolver"
            :affected-definitions
            [{:name "alpha" :definition "@a#1"}
             {:name "middle" :definition "@a#10"}]}))
        new-version (get-in publication [:program-view :logical-version])
        current-target
        (inspection/invoke-path!
         corpus "find_references"
         {:semanticIdentity "src/a.bclj#20" :direction "inbound"})
        current-other
        (inspection/invoke-path!
         corpus "find_references"
         {:semanticIdentity "src/b.bclj#1" :direction "inbound"})
        pinned-target
        (inspection/invoke-path!
         corpus "find_references"
         {:semanticIdentity "src/a.bclj#20" :direction "inbound"
          :logicalVersion old-version})
        version-dir (io/file (str (.getCanonicalPath corpus) ".versions"))
        old-view (io/file version-dir
                          (str (subs old-version 7) ".view.edn"))
        new-view (io/file version-dir
                          (str (subs new-version 7) ".view.edn"))]
    (check! "successful projection commit advances the resolved program version"
            (and (= :committed-projection-published (:outcome publication))
                 (not= old-version new-version)
                 (= 12 (get-in publication [:program-view
                                            :source-graph-version]))))
    (check! "edit-then-ask sees the changed callee immediately"
            (and (empty? (:references current-target))
                 (= ["src/a.bclj#10"]
                    (mapv :semanticIdentity (:references current-other)))
                 (= new-version (:logicalVersion current-other))))
    (check! "an explicit old-version pin retains the old caller truth"
            (and (= old-version (:logicalVersion pinned-target))
                 (= ["src/a.bclj#10"]
                    (mapv :semanticIdentity (:references pinned-target)))))
    (check! "untouched identity view rows remain byte-stable across the commit"
            (and (= (view-row old-view "src/b.bclj#10")
                    (view-row new-view "src/b.bclj#10"))
                 (contains? (set (get-in publication
                                         [:program-view :reused-identities]))
                            "src/b.bclj#10")))
    (check! "incremental invalidation names only touched callers and changed callees"
            (= #{"src/a.bclj#1" "src/a.bclj#10" "src/a.bclj#20"
                 "src/b.bclj#1"}
               (set (get-in publication
                            [:program-view :invalidated-identities]))))
    (let [restored-slice (subs old-text 0 (.indexOf old-text "@file src/b.bclj"))
          restored
          (binding [lifecycle/*resolve-program-slice*
                    (fn [_ _ _] restored-slice)]
            (lifecycle/publish-checked-projection!
             {:commit-outcome
              {:type :committed :module "a" :committed-version 13
               :proof {:ok true :id "freshness-receipt-2"}}
              :registered-root (.getCanonicalPath scratch)
              :registered-path "src/a.bclj"
              :checked-bytes (.getBytes "RESTORED" "UTF-8")
              :program-corpus (.getCanonicalPath corpus)
              :program-facts-command "test-resolver"
              :affected-definitions
              [{:name "alpha" :definition "@a#1"}
               {:name "middle" :definition "@a#10"}]}))
          restored-version (get-in restored [:program-view :logical-version])
          restored-view (io/file version-dir
                                 (str (subs restored-version 7) ".view.edn"))
          current-restored
          (inspection/invoke-path!
           corpus "find_references"
           {:semanticIdentity "src/a.bclj#20" :direction "inbound"})
          pinned-new
          (inspection/invoke-path!
           corpus "find_references"
           {:semanticIdentity "src/a.bclj#20" :direction "inbound"
            :logicalVersion new-version})]
      (check! "successive commits consume the prior materialized view incrementally"
              (and (= ["src/a.bclj#10"]
                      (mapv :semanticIdentity (:references current-restored)))
                   (empty? (:references pinned-new))))
      (check! "successive commits continue reusing untouched view-row bytes"
              (= (view-row new-view "src/b.bclj#10")
                 (view-row restored-view "src/b.bclj#10")))
      (let [added-slice
            (str restored-slice
                 "[30 \"form-kind\" \"defn\"]\n"
                 "[30 \"name\" \"newcomer\"]\n"
                 "[31 \"form-kind\" \"seq\"]\n"
                 "[32 \"form-kind\" \"call\"]\n"
                 "[32 \"calls\" \"target\"]\n"
                 "[31 \"child\" 32]\n"
                 "[30 \"body\" 31]\n"
                 "[30 \"child\" 31]\n")
            added
            (binding [lifecycle/*resolve-program-slice*
                      (fn [_ _ _] added-slice)]
              (lifecycle/publish-checked-projection!
               {:commit-outcome
                {:type :committed :module "a" :committed-version 14
                 :proof {:ok true :id "freshness-receipt-3"}}
                :registered-root (.getCanonicalPath scratch)
                :registered-path "src/a.bclj"
                :checked-bytes (.getBytes "ADDED" "UTF-8")
                :program-corpus (.getCanonicalPath corpus)
                :program-facts-command "test-resolver"
                :affected-definitions
                [{:name "newcomer" :form nil :definition nil}]}))
            added-version (get-in added [:program-view :logical-version])
            added-view (io/file version-dir
                                (str (subs added-version 7) ".view.edn"))
            newcomer
            (inspection/invoke-path!
             corpus "read_definition" {:name "newcomer" :file "src/a.bclj"})
            current-target
            (inspection/invoke-path!
             corpus "find_references"
             {:semanticIdentity "src/a.bclj#20" :direction "inbound"})
            pinned-restored
            (inspection/invoke-path!
             corpus "find_references"
             {:semanticIdentity "src/a.bclj#20" :direction "inbound"
              :logicalVersion restored-version})]
        (check! "a newly added definition appends one stable incremental slice"
                (and (= "ok" (:outcome newcomer))
                     (= #{"src/a.bclj#10" (:semanticIdentity newcomer)}
                        (set (map :semanticIdentity (:references current-target))))
                     (= ["src/a.bclj#10"]
                        (mapv :semanticIdentity (:references pinned-restored)))))
        (check! "an added slice leaves existing unrelated view rows byte-stable"
                (= (view-row restored-view "src/b.bclj#10")
                   (view-row added-view "src/b.bclj#10"))))))
  (finally
    (delete-tree! scratch)))

(let [failures (remove second @checks)]
  (if (seq failures)
    (do (println "\nprogram inspection freshness:" (count failures)
                 "FAILED of" (count @checks))
        (System/exit 1))
    (println "\nprogram inspection freshness:" (count @checks) "/"
             (count @checks) "PASS")))
