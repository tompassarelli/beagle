(ns semantic-read-store-cache-test
  (:require [clojure.string :as str]
            [semantic-read-store :as cache]
            [source-fact-store :as blobs]
            [store.dev-compile-facts :as compile-facts])
  (:import [java.nio.charset StandardCharsets]
           [java.nio.file Files Path]
           [java.nio.file.attribute FileAttribute]))

(defn check! [label condition]
  (when-not condition
    (throw (ex-info (str "semantic-read Store cache: " label) {}))))

(defn delete-tree! [^Path root]
  (when (Files/exists root (make-array java.nio.file.LinkOption 0))
    (with-open [paths (Files/walk root (make-array java.nio.file.FileVisitOption 0))]
      (doseq [path (reverse (vec (.toList paths)))]
        (Files/deleteIfExists path)))))

(defn with-store [f]
  (let [scratch (Files/createTempDirectory "beagle-semantic-read-store-"
                                           (make-array FileAttribute 0))]
    (try
      (f (str (.resolve scratch "semantic.storelog")))
      (finally (delete-tree! scratch)))))

(def digest-a (str "sha256:" (apply str (repeat 64 "a"))))
(def digest-b (str "sha256:" (apply str (repeat 64 "b"))))
(def digest-c (str "sha256:" (apply str (repeat 64 "c"))))
(def source-facts
  (str "1\tform-kind\tt\tmodule-root\n"
       "1\tnamespace\tt\tdemo.core\n"
       "1\trelative-path\tt\tdemo/core.bgl\n"
       "1\tsource-sha256\tt\t" digest-a "\n"
       "1\tchecked-projection-sha256\tt\t" digest-b "\n"
       "1\tinterface-sha256\tt\t" digest-c "\n"
       "0\tform-kind\tt\tprogram-root\n"
       "0\tmodules\tn\t2\n"
       "2\tform-kind\tt\tseq\n"
       "2\tf0\tn\t1\n"))
(def payload (str source-facts "1\tsemantic-read\tn\t1\n"))
(def source-rows
  (mapv #(str/split % #"\t" -1) (str/split-lines source-facts)))

(defn admitted-query! []
  (let [admission
        (cache/admit-and-identify-query
         (cache/->QueryAdmissionRequest source-facts digest-b digest-c
                                        ["demo.core/main"] false))]
    (check! "query admission succeeds" (cache/query-admitted? admission))
    (cache/admitted-query admission)))

(defn admitted-whole-program-query! []
  (let [admission
        (cache/admit-and-identify-query
         (cache/->QueryAdmissionRequest source-facts digest-b digest-c [] false))]
    (check! "whole-program query admission succeeds"
            (cache/query-admitted? admission))
    (cache/admitted-query admission)))

(defn cache-row [store query]
  (first
   (nth
    (compile-facts/query!
     store
     [["typed" (:query-digest query) (:rules-content-id query)
       (:compiler-projection-content-id query)
       (:source-facts-content-id query)]])
    4)))

(with-store
 (fn [store]
   (let [query (admitted-query!)
         whole-program-query (admitted-whole-program-query!)
         whole-program-query-again (admitted-whole-program-query!)
         row-admission
         (cache/admit-and-identify-query
          (cache/->QueryAdmissionRequest source-rows digest-b digest-c
                                         ["demo.core/main"] false))
         facts (:facts query)
         miss (cache/query! store query)]
     (check! "segmented rows preserve the canonical text query identity"
             (and (cache/query-admitted? row-admission)
                  (= (:query-digest query)
                     (:query-digest (cache/admitted-query row-admission)))
                  (= (:source-facts-content-id query)
                     (:source-facts-content-id
                      (cache/admitted-query row-admission)))))
     (let [invalid-request
           (cache/admit-and-identify-result {:query query :payload payload})]
       (check! "result admission requires its typed request"
               (and (cache/result-rejected? invalid-request)
                    (= :result/invalid-request (:code invalid-request)))))
     (check! "admitted query preserves canonical order and entry slot"
             (and (= (vec (range 1 (inc (count facts)))) (mapv :order facts))
                  (= [9 :query/entry "query" 0 "demo.core/main"]
                     (let [entry (last facts)]
                       [(:order entry) (:relation entry) (:subject entry)
                        (:slot entry) (:value entry)]))))
     (check! "whole-program query has a deterministic identity distinct from named entries"
             (and (= [] (:entries whole-program-query))
                  (= (:query-digest whole-program-query)
                     (:query-digest whole-program-query-again))
                  (not= (:query-digest query)
                        (:query-digest whole-program-query))))
     (doseq [[label entries] [["non-vector entries" "demo.core/main"]
                             ["blank entry" [""]]
                             ["duplicate entries" ["demo.core/main"
                                                   "demo.core/main"]]]]
       (let [admission
             (cache/admit-and-identify-query
              (cache/->QueryAdmissionRequest source-facts digest-b digest-c
                                               entries false))]
         (check! label
                 (and (cache/query-rejected? admission)
                      (= :query/invalid-entries (:code admission))))))
     (check! "first lookup is absence" (cache/result-missing? miss))
     (let [whole-miss (cache/query! store whole-program-query)]
       (check! "whole-program first lookup is absence"
               (cache/result-missing? whole-miss))
       (check! "whole-program append response is admitted"
               (cache/result-admitted?
                (cache/append! store whole-program-query payload)))
       (let [whole-hit (cache/query! store whole-program-query)]
         (check! "whole-program exact lookup returns verified payload"
                 (and (cache/result-admitted? whole-hit)
                      (= payload (cache/admitted-result-payload whole-hit))))))
     (check! "append response is admitted"
             (cache/result-admitted? (cache/append! store query payload)))
     (let [hit (cache/query! store query)]
       (check! "exact lookup returns verified payload"
               (and (cache/result-admitted? hit)
                    (= payload (cache/admitted-result-payload hit))
                    (= (cache/sha256 payload)
                       (cache/admitted-result-payload-content-id hit))))
       (let [row (cache-row store query)
             response ["store.dev-compile-facts/query-response-v1" "ONLINE"
                       "revision" [] [["typed" (:query-digest query)]]]
             malformed
             (with-redefs [compile-facts/query! (fn [_ _] response)]
               (cache/query! store query))
             duplicate
             (with-redefs [compile-facts/query!
                           (fn [_ _]
                             ["store.dev-compile-facts/query-response-v1" "ONLINE"
                              "revision" [] [row row]])]
               (cache/query! store query))]
         (check! "malformed candidate rejects"
                 (and (cache/result-rejected? malformed)
                      (= :result/malformed-candidate (:code malformed))))
         (check! "duplicate candidates reject"
                 (and (cache/result-rejected? duplicate)
                      (= :result/duplicate-candidates (:code duplicate))))
         (Files/write (blobs/blob-path store (cache/sha256 payload))
                      (.getBytes "corrupt" StandardCharsets/UTF_8)
                      (make-array java.nio.file.OpenOption 0))
         (let [corrupt (cache/query! store query)]
           (check! "corrupt payload content ID rejects"
                   (and (cache/result-rejected? corrupt)
                        (= :result/payload-content-id-mismatch (:code corrupt))))))))
   (println "semantic-read Store cache: exact hit and malformed/corrupt/duplicate rejection PASS")))
