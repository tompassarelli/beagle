;; Request logging must never be allowed to append observability text to the
;; authoritative transaction log.
(require '[clojure.java.io :as io])

(binding [*command-line-args* []]
  (load-file "server.clj"))

(def failures (atom []))

(defn check! [label value]
  (println (str (if value "[PASS] " "[FAIL] ") label))
  (when-not value (swap! failures conj label)))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-request-log-alias-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "history.storelog")))

(database/create-triple-log! log-path "request-log-alias-space")
(def before (java.nio.file.Files/readAllBytes (.toPath (io/file log-path))))
(def failure
  (with-redefs [server/request-log-path log-path]
    (try
      (server/serve! 0 log-path "request-log-alias-space" :active)
      nil
      (catch clojure.lang.ExceptionInfo error
        (ex-data error)))))
(def after (java.nio.file.Files/readAllBytes (.toPath (io/file log-path))))

(check! "same-path request logging fails before Store boot"
        (= :request-log-aliases-store-log (:store/code failure)))
(check! "same-path rejection preserves every existing STORELOG byte"
        (java.util.Arrays/equals before after))
(check! "same-path rejection leaves the Store process unbooted"
        (nil? @server/active-store))

(when (seq @failures)
  (System/exit 1))
