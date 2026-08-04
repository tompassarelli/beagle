(require '[clojure.string :as str]
         '[fram.rt-core :as rt])

(defn pass! [kind subject case-name actual expected]
  (when-not (= expected actual)
    (throw (ex-info "managed rt_core oracle mismatch"
      {:kind kind :subject subject :case case-name
       :expected expected :actual actual})))
  (println (str kind "\t" subject "\t" case-name "\tPASS")))

(defn throws! [subject case-name thunk message-fragment]
  (try
    (thunk)
    (throw (ex-info "managed rt_core oracle expected an exception"
      {:subject subject :case case-name}))
    (catch clojure.lang.ExceptionInfo error
      (when-not (and (= true (:fram/doctor-refusal (ex-data error)))
                  (str/includes? (.getMessage error) message-fragment))
        (throw error))
      (println (str "rt-core\t" subject "\t" case-name "\tPASS")))))

(def digest-a (apply str (repeat 64 "a")))
(def digest-b (apply str (repeat 64 "b")))

(def valid-envelope
  {:fram-edit-envelope 1
   :fram-edit-log "coord.log"
   :fram-edit-candidate "batch-7"
   :fram-edit-batch "batch-7"
   :fram-edit-module "fram.rt-core"
   :fram-edit-path "src/fram/rt_core.bclj"
   :fram-edit-base-version 4
   :fram-edit-final-version 7
   :fram-edit-ops 3
   :fram-edit-installed 3
   :fram-edit-ops-digest digest-a
   :fram-edit-edn-digest digest-b
   :fram-edit-line-count 3
   :fram-edit-batch-sha digest-a
   :fram-edit-seal-sha digest-b})

(pass! "rt-core" "str-index-of" "found" (rt/str-index-of "abcabc" "bc") 1)
(pass! "rt-core" "str-index-of" "absent" (rt/str-index-of "abc" "z") nil)
(pass! "rt-core" "split-comma" "trim-remove-blank"
  (rt/split-comma " a, ,b, c ") ["a" "b" "c"])
(pass! "rt-core" "str-lt?" "ascending" (rt/str-lt? "alpha" "beta") true)
(pass! "rt-core" "str-lt?" "equal" (rt/str-lt? "alpha" "alpha") false)
(pass! "rt-core" "split-kv" "pair" (rt/split-kv "  key value here  ")
  ["key" "value here"])
(pass! "rt-core" "split-kv" "key-only" (rt/split-kv " key ") ["key" ""])
(pass! "rt-core" "fmt-id" "four-segments" (rt/fmt-id "20260804123456")
  "2026-08-04-123456")
(pass! "rt-core" "slugify" "punctuation" (rt/slugify " Hello, World! ")
  "hello_world")
(pass! "rt-core" "slugify" "empty" (rt/slugify "---") "untitled")
(pass! "rt-core" "filter-digits" "mixed" (rt/filter-digits "a1-2x03") "1203")
(pass! "rt-core" "is-iso-datetime-19" "valid"
  (rt/is-iso-datetime-19 "2026-08-04T12:34:56") true)
(pass! "rt-core" "is-iso-datetime-19" "short"
  (rt/is-iso-datetime-19 "2026-08-04T12:34") false)
(pass! "rt-core" "is-iso-datetime-16" "valid"
  (rt/is-iso-datetime-16 "2026-08-04T12:34") true)
(pass! "rt-core" "is-iso-datetime-16" "long"
  (rt/is-iso-datetime-16 "2026-08-04T12:34:56") false)
(pass! "rt-core" "repeat-str" "positive" (rt/repeat-str "ab" 3) "ababab")
(pass! "rt-core" "repeat-str" "negative" (rt/repeat-str "ab" -2) "")
(pass! "rt-core" "edit-batch-envelope-marker?" "present"
  (rt/edit-batch-envelope-marker? {:fram-edit-envelope 1}) true)
(pass! "rt-core" "edit-batch-envelope-marker?" "absent"
  (rt/edit-batch-envelope-marker? {}) false)
(pass! "rt-core" "digest?" "valid" (rt/digest? digest-a) true)
(pass! "rt-core" "digest?" "uppercase" (rt/digest? (str/upper-case digest-a)) false)
(pass! "rt-core" "nonblank?" "text" (rt/nonblank? "x") true)
(pass! "rt-core" "nonblank?" "blank" (rt/nonblank? " \t") false)
(pass! "rt-core" "generation-record?" "generation"
  (rt/generation-record? {:l "@log:gen" :p "generation"}) true)
(pass! "rt-core" "generation-record?" "other"
  (rt/generation-record? {:l "@log:gen" :p "fact"}) false)
(pass! "rt-core" "valid-edit-batch-envelope?" "valid"
  (rt/valid-edit-batch-envelope? valid-envelope digest-b) true)
(pass! "rt-core" "valid-edit-batch-envelope?" "wrong-seal"
  (rt/valid-edit-batch-envelope? valid-envelope digest-a) false)
(pass! "rt-core" "classify-rewrite-crash" "old-inode"
  (rt/classify-rewrite-crash "coord.log" 10 10 11 20 digest-a digest-b digest-b digest-a)
  :roll-back)
(pass! "rt-core" "classify-rewrite-crash" "new-inode"
  (rt/classify-rewrite-crash "coord.log" 11 10 11 20 digest-a digest-b digest-b digest-a)
  :roll-forward)
(throws! "classify-rewrite-crash" "missing-live"
  #(rt/classify-rewrite-crash "coord.log" nil nil nil nil nil nil nil nil)
  "does not exist")
(pass! "rt-core" "log-envelope" "plain"
  (rt/log-envelope "coord.log" {:op :for-log})
  {:op :for-log :expected-log "coord.log" :request {:op :for-log}})
(pass! "rt-core" "log-envelope" "format"
  (rt/log-envelope "coord.log" {:op :for-log :fmt :log-mismatch})
  {:op :for-log :expected-log "coord.log"
   :request {:op :for-log :fmt :log-mismatch} :fmt :log-mismatch})
(pass! "rt-core" "reject-message" "sequence"
  (rt/reject-message ["left" "right"]) "left; right")
(pass! "rt-core" "reject-message" "single"
  (rt/reject-message ["conflict"]) "conflict")
(pass! "rt-core" "coord-write-response" "ok"
  (rt/coord-write-response {:ok 7}) "ok:7")
(pass! "rt-core" "coord-write-response" "conflict"
  (rt/coord-write-response {:reject :conflict}) "conflict")
(pass! "rt-core" "coord-write-response" "log-mismatch"
  (rt/coord-write-response
    {:code :log-mismatch :expected-log "a" :served-log "b"})
  "log-mismatch: expected a; daemon serves b")
(pass! "rt-core" "coord-write-response" "incompatible"
  (rt/coord-write-response {:error "unknown op"}) "protocol-incompatible")
(pass! "rt-core" "coord-write-response" "rejected"
  (rt/coord-write-response {:reject ["one" "two"]}) "reject:one; two")
(pass! "rt-core" "coord-write-response" "error"
  (rt/coord-write-response {:error "broken"}) "error:{:error \"broken\"}")
(pass! "rt-core" "coord-version-response" "version"
  (rt/coord-version-response {:version 19}) 19)
(pass! "rt-core" "coord-version-response" "missing"
  (rt/coord-version-response {}) -1)
(pass! "rt-core" "coord-version-for-log-response" "version"
  (rt/coord-version-for-log-response {:version 19}) 19)
(pass! "rt-core" "coord-version-for-log-response" "mismatch"
  (rt/coord-version-for-log-response {:code :log-mismatch}) -2)
(pass! "rt-core" "coord-version-for-log-response" "unusable"
  (rt/coord-version-for-log-response {}) -3)
(pass! "rt-core" "coord-status-response" "up"
  (rt/coord-status-response 7788 {:version 19})
  "coordinator UP on 127.0.0.1:7788 (v19)")
(pass! "rt-core" "coord-status-response" "wrong-log"
  (rt/coord-status-response 7788
    {:code :log-mismatch :expected-log "a" :served-log "b"})
  (str "coordinator WRONG LOG on 127.0.0.1:7788 — expected a; daemon serves b; "
    "refusing fenced reads and writes"))
(pass! "rt-core" "coord-status-response" "incompatible"
  (rt/coord-status-response 7788 {:error "unknown op"})
  (str "coordinator INCOMPATIBLE on 127.0.0.1:7788 — daemon lacks required "
    "log-fence protocol; restart it with current Fram"))
(pass! "rt-core" "coord-status-response" "unusable"
  (rt/coord-status-response 7788 {:error "broken"})
  "coordinator UNUSABLE on 127.0.0.1:7788 — {:error \"broken\"}")
(pass! "rt-core" "coord-status-down" "down"
  (rt/coord-status-down 7788)
  "coordinator DOWN on 127.0.0.1:7788 — start it with bin/fram-up")
(pass! "rt-core" "warm-read-response" "unknown"
  (rt/warm-read-response {:error "unknown op"}) nil)
(pass! "rt-core" "warm-read-response" "value"
  (rt/warm-read-response {:request [["s" "p" "o"]]})
  {:request [["s" "p" "o"]]})
(pass! "rt-core" "warm-read-for-log-response" "unknown"
  (rt/warm-read-for-log-response {:error "unknown op"}) nil)
(pass! "rt-core" "warm-read-for-log-response" "rejected"
  (rt/warm-read-for-log-response {:reject :log-mismatch}) nil)
(pass! "rt-core" "warm-read-for-log-response" "value"
  (rt/warm-read-for-log-response {:request [[1 true nil]]})
  {:request [[1 true nil]]})

(doseq [[name pattern]
        [["COMMA-RE" rt/COMMA-RE]
         ["SPLIT-KV-RE" rt/SPLIT-KV-RE]
         ["SLUG-NONWORD-RE" rt/SLUG-NONWORD-RE]
         ["SLUG-LEADING-RE" rt/SLUG-LEADING-RE]
         ["SLUG-TRAILING-RE" rt/SLUG-TRAILING-RE]
         ["DIGITS-ONLY-RE" rt/DIGITS-ONLY-RE]
         ["ISO19-RE" rt/ISO19-RE]
         ["ISO16-RE" rt/ISO16-RE]
         ["DIGEST-RE" rt/DIGEST-RE]]]
  (pass! "rt-core-def" name "regex" (instance? java.util.regex.Pattern pattern) true))
(pass! "rt-core-def" "EDIT-BATCH-ENVELOPE-VERSION" "value"
  rt/EDIT-BATCH-ENVELOPE-VERSION 1)
(pass! "rt-core-def" "EDIT-BATCH-ENVELOPE-KEYS" "value"
  rt/EDIT-BATCH-ENVELOPE-KEYS (set (keys valid-envelope)))
(pass! "rt-core-def" "EDIT-BATCH-ENVELOPE-SEAL-FIELDS" "value"
  rt/EDIT-BATCH-ENVELOPE-SEAL-FIELDS
  [:fram-edit-envelope :fram-edit-log :fram-edit-candidate :fram-edit-batch
   :fram-edit-module :fram-edit-path :fram-edit-base-version
   :fram-edit-final-version :fram-edit-ops :fram-edit-installed
   :fram-edit-ops-digest :fram-edit-edn-digest :fram-edit-line-count
   :fram-edit-batch-sha])
(pass! "rt-core-error" "RewriteCrashError" "variant"
  (:doctor-refusal (rt/->RewriteCrash "message" "path" true)) true)
