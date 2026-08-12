(ns fram.rt-core
  (:require [clojure.string :as str]))

(def COMMA-RE (re-pattern ","))

(def SPLIT-KV-RE (re-pattern "^(\\S+)\\s+(.*)$"))

(def SLUG-NONWORD-RE (re-pattern "[^a-z0-9]+"))

(def SLUG-LEADING-RE (re-pattern "^_+"))

(def SLUG-TRAILING-RE (re-pattern "_+$"))

(def DIGITS-ONLY-RE (re-pattern "[^0-9]"))

(def ISO19-RE (re-pattern "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}"))

(def ISO16-RE (re-pattern "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}"))

(defn str-index-of [^String s ^String sub]
  (str/index-of s sub))

(defn split-comma [^String s]
  (vec (remove str/blank? (map str/trim (str/split s COMMA-RE)))))

(defn ^Boolean str-lt? [^String a ^String b]
  (neg? (compare a b)))

(defn split-kv [^String line]
  (let [t (str/trim line)
   m (re-find SPLIT-KV-RE t)]
  (if (some? m) (let [parts [(nth m 1) (nth m 2)]]
  parts) (let [parts [t ""]]
  parts))))

(defn ^String fmt-id [^String n]
  (let [s (str n)]
  (str (subs s 0 4) "-" (subs s 4 6) "-" (subs s 6 8) "-" (subs s 8 14))))

(defn ^String slugify [^String title]
  (let [base (str/replace (str/replace (str/replace (str/lower-case (str title)) SLUG-NONWORD-RE "_") SLUG-LEADING-RE "") SLUG-TRAILING-RE "")
   capped (if (> (count base) 60) (subs base 0 60) base)
   clean (str/replace capped SLUG-TRAILING-RE "")]
  (if (str/blank? clean) "untitled" clean)))

(defn ^String filter-digits [^String s]
  (str/replace s DIGITS-ONLY-RE ""))

(defn ^Boolean is-iso-datetime-19 [^String s]
  (boolean (and (= 19 (count s)) (re-matches ISO19-RE s))))

(defn ^Boolean is-iso-datetime-16 [^String s]
  (boolean (and (= 16 (count s)) (re-matches ISO16-RE s))))

(defn ^String repeat-str [^String s n]
  (apply str (repeat (max 0 (long n)) s)))

(def EDIT-BATCH-ENVELOPE-VERSION 1)

(def EDIT-BATCH-ENVELOPE-KEYS #{:fram-edit-seal-sha :fram-edit-candidate :fram-edit-line-count :fram-edit-path :fram-edit-ops :fram-edit-ops-digest :fram-edit-edn-digest :fram-edit-envelope :fram-edit-base-version :fram-edit-installed :fram-edit-log :fram-edit-final-version :fram-edit-module :fram-edit-batch-sha :fram-edit-batch})

(def DIGEST-RE (re-pattern "[0-9a-f]{64}"))

(defn ^Boolean edit-batch-envelope-marker? [record]
  (and (map? record) (contains? record :fram-edit-envelope)))

(defn ^Boolean digest? [^String value]
  (and (string? value) (boolean (re-matches DIGEST-RE value))))

(defn ^Boolean nonblank? [^String value]
  (and (string? value) (not (str/blank? value))))

(defn ^Boolean generation-record? [op]
  (and (= "@log:gen" (:l op)) (= "generation" (:p op))))

(defn ^Boolean valid-edit-batch-envelope? [record ^String expected-seal]
  (let [base (:fram-edit-base-version record)
   final (:fram-edit-final-version record)
   ops (:fram-edit-ops record)
   installed (:fram-edit-installed record)
   lines (:fram-edit-line-count record)]
  (and (map? record) (= EDIT-BATCH-ENVELOPE-KEYS (set (keys record))) (= EDIT-BATCH-ENVELOPE-VERSION (:fram-edit-envelope record)) (nonblank? (:fram-edit-log record)) (nonblank? (:fram-edit-candidate record)) (= (:fram-edit-candidate record) (:fram-edit-batch record)) (nonblank? (:fram-edit-module record)) (nonblank? (:fram-edit-path record)) (int? base) (not (neg? base)) (int? final) (not (neg? final)) (int? ops) (not (neg? ops)) (int? installed) (not (neg? installed)) (int? lines) (not (neg? lines)) (= ops installed) (= installed lines) (= final (+ base installed)) (digest? (:fram-edit-ops-digest record)) (digest? (:fram-edit-edn-digest record)) (digest? (:fram-edit-batch-sha record)) (digest? (:fram-edit-seal-sha record)) (= (:fram-edit-seal-sha record) expected-seal))))

(def EDIT-BATCH-ENVELOPE-SEAL-FIELDS [:fram-edit-envelope :fram-edit-log :fram-edit-candidate :fram-edit-batch :fram-edit-module :fram-edit-path :fram-edit-base-version :fram-edit-final-version :fram-edit-ops :fram-edit-installed :fram-edit-ops-digest :fram-edit-edn-digest :fram-edit-line-count :fram-edit-batch-sha])

(defn classify-rewrite-crash [^String server-path live-ino old-ino new-ino old-bytes old-sha new-sha1 live-line1-sha live-prefix-sha]
  (cond
  (nil? live-ino) (throw (ex-info (str "rewrite intent present but " server-path " does not exist — refusing to classify") {:path server-path :fram/doctor-refusal true}))
  (and (some? old-ino) (= live-ino old-ino)) :roll-back
  (and (some? new-ino) (= live-ino new-ino)) :roll-forward
  (and (some? new-sha1) (= new-sha1 live-line1-sha)) :roll-forward
  (and (some? old-bytes) (some? old-sha) (= old-sha live-prefix-sha)) :roll-back
  :else (throw (ex-info (str "rewrite intent does not match the live corpus at " server-path " (neither source nor replacement inode/sha) — refusing to classify; operator intervention required") {:path server-path :fram/doctor-refusal true}))))

(defn log-envelope [^String canonical-log req]
  (let [base {:op :for-log :expected-log canonical-log :request req}]
  (if (contains? req :fmt) (assoc base :fmt (:fmt req)) base)))

(defn ^String reject-message [rejection]
  (if (sequential? rejection) (str/join "; " (map str rejection)) (str rejection)))

(defn ^String server-write-response [resp]
  (cond
  (:ok resp) (str "ok:" (:ok resp))
  (= (:reject resp) :conflict) "conflict"
  (= (:code resp) :log-mismatch) (str "log-mismatch: expected " (:expected-log resp) "; server serves " (:served-log resp))
  (= "unknown op" (:error resp)) "protocol-incompatible"
  (:reject resp) (str "reject:" (reject-message (:reject resp)))
  :else (str "error:" (pr-str resp))))

(defn server-version-response [resp]
  (let [version (:version resp)]
  (if (integer? version) version -1)))

(defn server-version-for-log-response [resp]
  (cond
  (integer? (:version resp)) (:version resp)
  (= :log-mismatch (:code resp)) -2
  :else -3))

(defn ^String server-status-response [port resp]
  (cond
  (integer? (:version resp)) (str "server UP on 127.0.0.1:" port " (v" (:version resp) ")")
  (= :log-mismatch (:code resp)) (str "server WRONG LOG on 127.0.0.1:" port " — expected " (:expected-log resp) "; server serves " (:served-log resp) "; refusing fenced reads and writes")
  (= "unknown op" (:error resp)) (str "server INCOMPATIBLE on 127.0.0.1:" port " — server lacks required log-fence protocol; restart it with current Fram")
  :else (str "server UNUSABLE on 127.0.0.1:" port " — " (pr-str resp))))

(defn ^String server-status-down [port]
  (str "server DOWN on 127.0.0.1:" port " — start it with bin/fram-up"))

(defn warm-read-response [resp]
  (if (and (map? resp) (= "unknown op" (:error resp))) nil resp))

(defn warm-read-for-log-response [resp]
  (if (or (= "unknown op" (:error resp)) (contains? resp :reject)) nil resp))

;; error RewriteCrashError = RewriteCrash
(defrecord RewriteCrash [message path doctor-refusal])

(defn rewritecrash-message [r] (:message r))

(defn rewritecrash-path [r] (:path r))

(defn rewritecrash-doctor-refusal [r] (:doctor-refusal r))
