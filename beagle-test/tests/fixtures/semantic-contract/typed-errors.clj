(ns semantic-contract.typed-errors)

;; error RewriteError = RewriteFailure
(defrecord RewriteFailure [message path refusal])

(defn rewritefailure-message [r] (:message r))

(defn rewritefailure-path [r] (:path r))

(defn rewritefailure-refusal [r] (:refusal r))

(defn ^String classify [^Boolean missing ^Boolean mismatch ^String path]
  (cond
  missing (throw (ex-info "missing" {:path path :refusal true}))
  mismatch (throw (ex-info "mismatch" {:path path :refusal true}))
  :else "roll-back"))

(defn ^String propagate [^Boolean missing ^Boolean mismatch ^String path]
  (classify missing mismatch path))

(defn ^String render [^Boolean missing ^Boolean mismatch ^String path]
  (try
  (classify missing mismatch path)
  (catch clojure.lang.ExceptionInfo err__exception
    (let [err (->RewriteFailure (ex-message err__exception) (:path (ex-data err__exception)) (:refusal (ex-data err__exception)))]
      (:message err)))))
