(ns semantic-read-store-cache-test
  (:require [semantic-read-store :as cache])
  (:import [java.nio.file Files Path]
           [java.nio.file.attribute FileAttribute]))

(defn check! [label condition]
  (when-not condition
    (throw (ex-info (str "semantic-read Store cache: " label) {}))))

(defn delete-tree! [^Path root]
  (when (Files/exists root (make-array java.nio.file.LinkOption 0))
    (with-open [paths (Files/walk root (make-array java.nio.file.FileVisitOption 0))]
      (doseq [path (reverse (vec (.toList paths)))]
        (Files/deleteIfExists path)))))

(def scratch
  (Files/createTempDirectory "beagle-semantic-read-store-"
                             (make-array FileAttribute 0)))
(def store (str (.resolve scratch "semantic.storelog")))
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

(try
  (let [request (cache/request source-facts digest-b digest-c
                               ["demo.core/main"] false)
        changed-entry (cache/request source-facts digest-b digest-c
                                     ["demo.core/other"] false)]
    (check! "normalized query uses separate facts"
            (and (vector? (:facts request))
                 (some #(= "query/source-shard" (nth % 1)) (:facts request))
                 (some #(= "query/interface" (nth % 1)) (:facts request))
                 (some #(= "query/entry" (nth % 1)) (:facts request))))
    (check! "first lookup misses" (nil? (cache/query! store request)))
    (cache/append! store request payload)
    (check! "exact lookup returns canonical projected facts"
            (= payload (cache/query! store request)))
    (check! "different reachability context misses"
            (nil? (cache/query! store changed-entry)))
    (println "semantic-read Store cache: miss -> append -> exact hit; entry change misses"))
  (finally
    (delete-tree! scratch)))
