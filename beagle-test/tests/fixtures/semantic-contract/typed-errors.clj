(ns semantic-contract.typed-errors)

;; error RewriteError = RewriteFailure
(defrecord RewriteFailure [message path refusal])

(defn ^String classify [missing? ^String path]
  (if missing?
    (throw (ex-info "missing" {:path path, :refusal true}))
    "roll-back"))

(defn ^String propagate [missing? ^String path]
  (classify missing? path))

(defn ^String render [missing? ^String path]
  (try
    (classify missing? path)
    (catch clojure.lang.ExceptionInfo err__exception
      (let [err (->RewriteFailure
                  (ex-message err__exception)
                  (:path (ex-data err__exception))
                  (:refusal (ex-data err__exception)))]
        (rewrite-failure-message err)))))
