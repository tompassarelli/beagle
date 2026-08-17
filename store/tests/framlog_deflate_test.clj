;; Deflate-flagged FRAMLOG generations: parity with plain logs, growth ratio,
;; and unchanged torn-tail semantics.
;;   bb -cp out tests/framlog_deflate_test.clj
(require '[clojure.java.io :as io]
         '[store.store :as store]
         '[store.types :as t])
(load-file "database.clj")

(def failures (atom 0))
(defn check! [label ok]
  (println (if ok "  [PASS]" "  [FAIL]") label)
  (when-not ok (swap! failures inc)))

(def scratch
  (.getCanonicalFile
   (io/file (System/getProperty "java.io.tmpdir")
            (str "framlog-deflate-" (System/nanoTime)))))
(.mkdirs scratch)

(def region-ids
  (vec (for [r (range 400)]
         (format "project_sheet_region_project_file_f91eacbaae684d63bb0bb1a4_p%04d_drawing-p%04d-region-%04d" r r r))))
(def corpus
  (vec (for [i (range 4000)]
         (t/triple (nth region-ids (quot i 10))
                   (nth ["kind" "name" "room" "text" "bbox"] (mod i 5))
                   (str "v" (mod i 97))))))

(def plain-path (str (io/file scratch "plain.framlog")))
(def gz-path (str (io/file scratch "deflate.framlog")))
(database/create-triple-log! plain-path "deflate-parity")
(database/create-triple-log! gz-path "deflate-parity" {:deflate? true})

(doseq [path [plain-path gz-path]]
  (let [db (database/open-database! path "deflate-parity")
        result (database/commit! db {:operations (mapv store/assert-operation corpus)})]
    (check! (str "commit accepted on " (if (= path gz-path) "deflate" "plain") " log")
            (:ok result))))

(def plain-bytes (.length (io/file plain-path)))
(def gz-bytes (.length (io/file gz-path)))
(check! (format "deflate generation is >5x smaller (%d -> %d bytes)"
                plain-bytes gz-bytes)
        (> plain-bytes (* 5 gz-bytes)))

(defn fold-propositions [path]
  (let [db (database/open-database! path "deflate-parity")]
    (set (map t/operationoccurrence-proposition
              (database/live-occurrences db)))))

(check! "deflate and plain generations fold to identical propositions"
        (= (fold-propositions plain-path) (fold-propositions gz-path)))

;; a second transaction appends compressed and reads back
(let [db (database/open-database! gz-path "deflate-parity")
      more (vec (for [i (range 100)]
                  (t/triple (str "extra-" i) "kind" "late")))
      result (database/commit! db {:operations (mapv store/assert-operation more)})]
  (check! "second deflate transaction commits" (:ok result))
  (check! "reopen folds both deflate frames"
          (= (+ 4000 100)
             (count (database/live-occurrences
                     (database/open-database! gz-path "deflate-parity"))))))

;; torn tail: truncate mid-frame, passive open reports, repair recovers
(let [bytes (java.nio.file.Files/readAllBytes (.toPath (io/file gz-path)))
      torn (str (io/file scratch "torn.framlog"))]
  (with-open [out (io/output-stream torn)]
    (.write out bytes 0 (- (alength bytes) 7)))
  (let [passive (database/open-database! torn "deflate-parity")]
    (check! "torn deflate tail is reported" (some? (:torn-tail passive))))
  (let [repaired (database/open-database! torn "deflate-parity" {:repair-torn? true})]
    (check! "torn deflate tail repairs to the valid prefix"
            (= 4000 (count (database/live-occurrences repaired))))))

;; corrupt compressed payload fails closed as corruption, not garbage data
(let [bytes (java.nio.file.Files/readAllBytes (.toPath (io/file gz-path)))
      broken (str (io/file scratch "broken.framlog"))
      flip (int (/ (alength bytes) 2))]
  (aset bytes flip (unchecked-byte (bit-xor (aget bytes flip) 255)))
  (with-open [out (io/output-stream broken)]
    (.write out bytes))
  (check! "bit-flipped deflate frame fails closed"
          (try (database/open-database! broken "deflate-parity") false
               (catch clojure.lang.ExceptionInfo e
                 (= :corrupt-triple-log (:fram/code (ex-data e)))))))

(if (zero? @failures)
  (println "\nframlog deflate: all checks PASS")
  (do (println (str "\nframlog deflate: " @failures " FAILED"))
      (System/exit 1)))
