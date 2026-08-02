(ns semantic-contract.composite-raises)

;; error RewriteCrashError = RewriteCrash
(defrecord RewriteCrash [message path refusal])

(defn rewritecrash-message [r] (:message r))

(defn rewritecrash-path [r] (:path r))

(defn rewritecrash-refusal [r] (:refusal r))

(defn classify-rewrite-crash [^String coord live-ino old-ino new-ino old-bytes old-sha new-sha1 live-line1-sha live-prefix-sha]
  (cond
  (nil? live-ino) (throw (ex-info (str "rewrite intent present but " coord " does not exist — refusing to classify") {:path coord :refusal true}))
  (and (some? old-ino) (= live-ino old-ino)) :roll-back
  (and (some? new-ino) (= live-ino new-ino)) :roll-forward
  (and (some? new-sha1) (= new-sha1 live-line1-sha)) :roll-forward
  (and (some? old-bytes) (some? old-sha) (= old-sha live-prefix-sha)) :roll-back
  :else (throw (ex-info (str "rewrite intent does not match the live corpus at " coord " (neither source nor replacement inode/sha) — refusing to classify; operator intervention required") {:path coord :refusal true}))))
