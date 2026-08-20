#!/usr/bin/env bb

(require '[clojure.edn :as edn]
         '[clojure.java.io :as io]
         '[source-fact-store :as source-store])

(import '[java.nio.file Files])

(let [scratch (Files/createTempDirectory "beagle-source-facts-"
                (make-array java.nio.file.attribute.FileAttribute 0))
      store (.toString (.resolve scratch "store.log"))
      context (str "sha256:" (apply str (repeat 64 "a")))
      entries (mapv (fn [i]
                      [(str "sha256:" (format "%064x" i)) context
                       "source-facts-shard-v1" (str "module-" i)
                       (pr-str {"moduleRoot" (str i)
                                "nodeCount" i
                                "rows" [[(str i) "form-kind" "t" "module"]]
                                "selectedCounts" {}
                                "sourceId" (str "module-" i)
                                "syntheticText"
                                (apply str
                                  (repeat (* 300 1024)
                                    (char (+ (int \a) (mod i 26)))))} )])
                    (range 33))
      requests (mapv (fn [[key _ profile source-id _]]
                       ["typed" key context profile source-id])
                 entries)]
  (try
    (let [append-start (System/nanoTime)]
      (source-store/append! store entries)
      (let [append-ms (/ (- (System/nanoTime) append-start) 1000000.0)
            query-start (System/nanoTime)
            rows (nth (source-store/query! store requests) 4)
            query-ms (/ (- (System/nanoTime) query-start) 1000000.0)
            payloads (mapv (fn [row]
                             (nth (edn/read-string (nth row 3)) 8))
                       rows)
            expected (mapv #(nth % 4) entries)]
        (when-not (= expected payloads)
          (throw (ex-info "source-fact Store hydration changed shard bytes" {})))
        (println
          (format
            "source-fact Store: 33 x 300 KiB cold append %.1f ms; warm batch query %.1f ms; byte-exact PASS"
            append-ms query-ms))))
    (finally
      (.delete (io/file store))
      (doseq [file (or (seq (.listFiles (io/file (str store ".objects")))) [])]
        (.delete file))
      (.delete (io/file (str store ".objects")))
      (.delete (.toFile scratch)))))
