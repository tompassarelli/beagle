(require '[clojure.string :as str]
         '[store.rt-core :as rt])

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
      (when-not (and (= true (:beagle/doctor-refusal (ex-data error)))
                  (str/includes? (.getMessage error) message-fragment))
        (throw error))
      (println (str "rt-core\t" subject "\t" case-name "\tPASS")))))

(def digest-a (apply str (repeat 64 "a")))
(def digest-b (apply str (repeat 64 "b")))

(def valid-envelope
  {:store-edit-envelope 1
   :store-edit-log "coord.log"
   :store-edit-candidate "batch-7"
   :store-edit-batch "batch-7"
   :store-edit-module "store.rt-core"
   :store-edit-path "src/store/rt_core.bclj"
   :store-edit-base-version 4
   :store-edit-final-version 7
   :store-edit-ops 3
   :store-edit-installed 3
   :store-edit-ops-digest digest-a
   :store-edit-edn-digest digest-b
   :store-edit-line-count 3
   :store-edit-batch-sha digest-a
   :store-edit-seal-sha digest-b})

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
  (rt/edit-batch-envelope-marker? {:store-edit-envelope 1}) true)
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
(pass! "rt-core" "server-write-response" "ok"
  (rt/server-write-response {:ok 7}) "ok:7")
(pass! "rt-core" "server-write-response" "conflict"
  (rt/server-write-response {:reject :conflict}) "conflict")
(pass! "rt-core" "server-write-response" "log-mismatch"
  (rt/server-write-response
    {:code :log-mismatch :expected-log "a" :served-log "b"})
  "log-mismatch: expected a; server serves b")
(pass! "rt-core" "server-write-response" "incompatible"
  (rt/server-write-response {:error "unknown op"}) "protocol-incompatible")
(pass! "rt-core" "server-write-response" "rejected"
  (rt/server-write-response {:reject ["one" "two"]}) "reject:one; two")
(pass! "rt-core" "server-write-response" "error"
  (rt/server-write-response {:error "broken"}) "error:{:error \"broken\"}")
(pass! "rt-core" "server-version-response" "version"
  (rt/server-version-response {:version 19}) 19)
(pass! "rt-core" "server-version-response" "missing"
  (rt/server-version-response {}) -1)
(pass! "rt-core" "server-version-for-log-response" "version"
  (rt/server-version-for-log-response {:version 19}) 19)
(pass! "rt-core" "server-version-for-log-response" "mismatch"
  (rt/server-version-for-log-response {:code :log-mismatch}) -2)
(pass! "rt-core" "server-version-for-log-response" "unusable"
  (rt/server-version-for-log-response {}) -3)
(pass! "rt-core" "server-status-response" "up"
  (rt/server-status-response 7788 {:version 19})
  "server UP on 127.0.0.1:7788 (v19)")
(pass! "rt-core" "server-status-response" "wrong-log"
  (rt/server-status-response 7788
    {:code :log-mismatch :expected-log "a" :served-log "b"})
  (str "server WRONG LOG on 127.0.0.1:7788 — expected a; server serves b; "
    "refusing fenced reads and writes"))
(pass! "rt-core" "server-status-response" "incompatible"
  (rt/server-status-response 7788 {:error "unknown op"})
  (str "server INCOMPATIBLE on 127.0.0.1:7788 — server lacks required "
    "log-fence protocol; restart it with current Beagle Store"))
(pass! "rt-core" "server-status-response" "unusable"
  (rt/server-status-response 7788 {:error "broken"})
  "server UNUSABLE on 127.0.0.1:7788 — {:error \"broken\"}")
(pass! "rt-core" "server-status-down" "down"
  (rt/server-status-down 7788)
  "server DOWN on 127.0.0.1:7788 — start it with bin/beagle-store-up")
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
  [:store-edit-envelope :store-edit-log :store-edit-candidate :store-edit-batch
   :store-edit-module :store-edit-path :store-edit-base-version
   :store-edit-final-version :store-edit-ops :store-edit-installed
   :store-edit-ops-digest :store-edit-edn-digest :store-edit-line-count
   :store-edit-batch-sha])
(pass! "rt-core-error" "RewriteCrashError" "variant"
  (:doctor-refusal (rt/->RewriteCrash "message" "path" true)) true)
