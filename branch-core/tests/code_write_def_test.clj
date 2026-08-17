;; ============================================================================
;; code_write_def_test.clj — thread A1 acceptance: S-profile text-bridge verbs.
;; ============================================================================
;; Boots ONE warm code daemon over a /tmp COPY of .fram/code.log on a verified-free
;; port >= 49010 (NEVER 7977/48942/48950 — live servers), then drives the new
;; write-def / read-def / index wire verbs THROUGH the socket, asserting each of the
;; spec's known authoring fumbles either canonicalizes OR returns a structured error
;; whose :suggestion names the fix. Runs on the JVM (clojure -M) so the reader is the
;; SAME LispReader production uses (bb's SCI reader differs on #(..)/::).
;;
;;   clojure -M tests/code_write_def_test.clj > /tmp/a1-selftest.out 2>&1; echo EXIT=$?
;;
;; When tests/fixtures/authoring-fumbles.edn (thread A0) lands, this runner also folds
;; every fixture in (see the fixtures section at the end).
;; ============================================================================
(require '[fram.store :as c] '[fram.schema :as s]
         '[clojure.string :as str] '[clojure.edn :as edn] '[clojure.java.io :as io])

(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(when-not (.exists (io/file code-log))
  (println "SKIP — no .fram/code.log (run bin/fram-ingest-code first)") (System/exit 0))

(binding [*command-line-args* []] (load-file "server.clj"))

;; --- throwaway daemon over a /tmp COPY, on a free port >= 49010 -------------
(def flat (str (System/getProperty "java.io.tmpdir") "/write-def-test-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(defn- port-free? [p] (try (with-open [s (java.net.Socket.)]
                             (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false)
                           (catch Exception _ true)))
(def port (or (some #(when (port-free? %) %) (range 49010 49040)) 49010))
(boot-flat! flat)
(def server (future (serve port)))
(Thread/sleep 600)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))

(def status (client port {:op :status}))
(when-not (and (= flat (str (:log status))) (pos? (:facts status)))
  (println "ABORT: daemon serves" (pr-str (:log status)) "expected" flat) (shutdown!) (System/exit 1))
(println "daemon up:" (:facts status) "facts, port=" port ", log=" flat "\n")

;; --- tiny assertion harness -------------------------------------------------
(def failures (atom 0))
(defn- check [label ok? detail]
  (println (format "  [%s] %s%s" (if ok? "PASS" "FAIL") label (if ok? "" (str "  <-- " detail))))
  (when-not ok? (swap! failures inc)))
(defn- w [module source] (client port {:op :write-def :spec {:module module :source source}}))
(defn- r [module name]   (client port {:op :read-def  :spec {:module module :name name}}))
(defn- idx [& [module]]  (client port {:op :index     :spec (when module {:module module})}))
;; the ERROR shape: per-form errors ride under :failed (a form was rejected mid-write);
;; top-level errors (bad module / parse failure / prose) ARE the resp itself.
(defn- err-of [resp] (or (:failed resp) resp))

(def M "schema")   ; a real ingested module

(println "=== index ===")
(let [all (idx)]
  (check "index lists modules (incl schema)"
         (and (:ok all) (some #(str/includes? % M) (:modules all)))
         (pr-str all)))
(let [si (idx M)]
  (check "index schema returns defs with sigs"
         (and (:ok si) (pos? (:count si)) (every? :name (:defs si)))
         (pr-str (dissoc si :defs))))

(println "\n=== write-def happy path + read-def round-trip ===")
(let [resp (w M "(defn a1-selftest-inc [(x Int)] Int (+ x 1))")]
  (check "write typed defn -> :ok" (and (:ok resp) (= 1 (:written resp))) (pr-str resp))
  (check "deep-check status is surfaced (never silent)"
         (contains? #{:deferred :ran} (:deep-check resp)) (pr-str (:deep-check resp))))
(let [resp (r M "a1-selftest-inc")]
  (check "read-def returns source text" (and (:ok resp) (str/includes? (str (:source resp)) "a1-selftest-inc")) (pr-str resp))
  (check "read-def derives sig (Int -> Int)" (= "(Int -> Int)" (:sig resp)) (pr-str (:sig resp))))

(println "\n=== FUMBLE: #(...) lambda -> (fn ...) ===")
(let [resp (w M "(def a1-selftest-lam #(+ % 1))")]
  (check "#() def canonicalizes -> :ok" (:ok resp) (pr-str resp)))
(let [resp (r M "a1-selftest-lam")]
  (check "#() rendered back as (fn ...), not #(...)"
         (and (:ok resp) (str/includes? (str (:source resp)) "(fn") (not (str/includes? (str (:source resp)) "#(")))
         (pr-str (:source resp))))

(println "\n=== FUMBLE: ::kw -> pointed reject ===")
(let [resp (w M "(def a1-selftest-kw ::foo)")
      e (err-of resp)]
  (check "::kw write fails closed" (false? (:ok resp)) (pr-str resp))
  (check "::kw error is :stage :canon" (= :canon (:stage e)) (pr-str e))
  (check "::kw :suggestion names the fix (:foo)" (str/includes? (str (:suggestion e)) ":foo") (pr-str e)))

(println "\n=== FUMBLE: (Vector String) -> nearest-miss Vec ===")
(let [resp (w M "(defn a1-selftest-vt [(x (Vector String))] Nil nil)")
      e (err-of resp)]
  (check "(Vector ..) write fails closed" (false? (:ok resp)) (pr-str resp))
  (check "unknown-type error is :stage :type" (= :type (:stage e)) (pr-str e))
  (check "(Vector) :nearest suggests Vec" (some #{"Vec"} (:nearest e)) (pr-str e))
  (check "(Vector) :suggestion names Vec" (str/includes? (str (:suggestion e)) "Vec") (pr-str e)))

(println "\n=== FUMBLE: markdown fences around code ===")
(let [resp (w M "```clojure\n(def a1-selftest-fenced 42)\n```")]
  (check "fenced code strips + writes -> :ok" (:ok resp) (pr-str resp)))

(println "\n=== FUMBLE: prose preamble ===")
(let [resp (w M "Here is the code:\n\n(def a1-selftest-prose 7)")
      e (err-of resp)]
  (check "prose write fails closed" (false? (:ok resp)) (pr-str resp))
  (check "prose error :suggestion names the fix"
         (and (:suggestion e) (or (str/includes? (str (:suggestion e)) "prose")
                                  (str/includes? (str (:suggestion e)) "def")))
         (pr-str e)))

(println "\n=== FUMBLE: atom-wrapped value def (valid — Atom is a real ctor) ===")
(let [resp (w M "(def a1-selftest-atom (atom 0))")]
  (check "atom-wrapped def canonicalizes -> :ok" (:ok resp) (pr-str resp)))

(println "\n=== LOOKUP: unknown module -> nearest-miss ===")
(let [resp (w "shema" "(def z 1)")]
  (check "unknown module fails closed" (false? (:ok resp)) (pr-str resp))
  (check "unknown module :stage :lookup" (= :lookup (:stage resp)) (pr-str resp))
  (check "unknown module :nearest suggests schema" (some #(str/includes? % "schema") (:nearest resp)) (pr-str resp)))

(println "\n=== read-def / index unknown-name nearest-miss ===")
(let [resp (r M "a1-selftest-inx")]   ; typo of a1-selftest-inc
  (check "unknown def :stage :lookup + :nearest" (and (= :lookup (:stage resp)) (seq (:nearest resp))) (pr-str resp)))

(println "\n=== ROBUSTNESS: multi-form / replace-by-name / quote / def-form sig ===")
(let [resp (w M "(def a1-multi-a 1)\n(defn a1-multi-b [(x Int)] Int x)")]
  (check "multi-form :source -> both forms minted" (and (:ok resp) (= 2 (:written resp))) (pr-str resp)))
(let [r1s (:source (do (w M "(def a1-rep Int 1)") (r M "a1-rep")))
      r2  (do (w M "(def a1-rep Int 2)") (r M "a1-rep"))]      ; replace by name
  (check "upsert replaces by name (idempotent surface)"
         (and (:ok r2) (str/includes? (:source r2) "2") (not= r1s (:source r2))) (pr-str [r1s (:source r2)])))
(let [resp (w M "(def a1-q 'sym)") rd (r M "a1-q")]
  (check "'x canonicalizes + writes -> :ok" (:ok resp) (pr-str resp))
  (check "'x stored/rendered as (quote sym)" (and (:ok rd) (str/includes? (str (:source rd)) "quote")) (pr-str (:source rd))))
(let [_ (w M "(def a1-sig String \"hi\")") rd (r M "a1-sig")]
  (check "def-form sig derived (String)" (= "String" (:sig rd)) (pr-str (:sig rd))))

(println "\n=== READER-FORM ROUND-TRIP: regex / set / nested / char / ratio (EXP-025 b1 mint fix) ===")
;; The host LispReader hands write-def OBJECTS (Pattern, PersistentHashSet, Character,
;; Ratio) — mint-datum! must re-encode them into the SAME (#%regex …)/(#%set …) nodes
;; --emit-edn mints so the renderer inverts them back. Regression: a bare-source `#","`
;; was pr-str'd to the STRING "#\",\"", corrupting the def (oracle red). rt-datum reads
;; the rendered source with the FULL reader (same production LispReader) so the assertion
;; is reader-form identity, not a substring guess.
(defn- rt-datum [s] (binding [*read-eval* false] (read-string s)))   ; -> (def <name> <value>)
(let [_ (w M "(def a1-rt-regex #\",\")") rd (r M "a1-rt-regex")
      src (str (:source rd)) d (try (rt-datum src) (catch Throwable _ nil))]
  (check "regex #\",\" renders as a regex literal, NOT a string"
         (and (:ok rd) (str/includes? src "#\",\"") (instance? java.util.regex.Pattern (last d)))
         (pr-str src)))
(let [_ (w M "(defn a1-rt-split [x] (str/split x #\",\"))") rd (r M "a1-rt-split")
      src (str (:source rd))]
  (check "nested (str/split x #\",\") keeps the regex arg (no leaked \"# string)"
         (and (:ok rd) (str/includes? src "#\",\"") (not (str/includes? src "\"#")))
         (pr-str src)))
(let [_ (w M "(def a1-rt-set #{1 2 3})") rd (r M "a1-rt-set")
      src (str (:source rd)) d (try (rt-datum src) (catch Throwable _ nil))]
  (check "set #{1 2 3} renders as #{…} + re-reads to the identical set"
         (and (:ok rd) (str/includes? src "#{") (= #{1 2 3} (last d)))
         (pr-str src)))
(let [_ (w M "(def a1-rt-char \\x)") rd (r M "a1-rt-char")
      src (str (:source rd)) d (try (rt-datum src) (catch Throwable _ nil))]
  (check "char literal \\x round-trips (backslash preserved)"
         (and (:ok rd) (str/includes? src "\\x") (= \x (last d)))
         (pr-str src)))
(let [_ (w M "(def a1-rt-ratio 1/2)") rd (r M "a1-rt-ratio")
      src (str (:source rd)) d (try (rt-datum src) (catch Throwable _ nil))]
  (check "ratio 1/2 round-trips"
         (and (:ok rd) (str/includes? src "1/2") (= 1/2 (last d)))
         (pr-str src)))

(println "\n=== SEAM: def-check-hook surfaces a def-level reject end-to-end (deliverable 5) ===")
;; Prove the swappable check seam: A2 `reset!`s a (fn [module name] -> nil | ERROR) here.
;; A mock stands in for A2's warm primitive to verify write-def wires it correctly.
(reset! def-check-hook
        (fn [module name]
          (when (str/includes? (str name) "seam-bad")
            {:ok false :stage :type :message (str name " fails the mock type gate")
             :suggestion "fix the mock type error"})))
(try
  (let [good (w M "(def a1-seam-good 1)")
        bad  (w M "(def a1-seam-bad 2)")
        e (err-of bad)]
    (check "hook clean -> write succeeds, :deep-check :ran" (and (:ok good) (= :ran (:deep-check good))) (pr-str good))
    (check "hook reject -> write fails closed" (false? (:ok bad)) (pr-str bad))
    (check "hook reject surfaces :stage :type" (= :type (:stage e)) (pr-str e))
    (check "hook reject :at merged with module+def" (and (= M (:module (:at e))) (= "a1-seam-bad" (:def (:at e)))) (pr-str (:at e)))
    (check "hook reject carries a :suggestion" (not (str/blank? (str (:suggestion e)))) (pr-str e)))
  (finally (reset! def-check-hook default-def-check)))   ; restore before the fixture sweep

(println "\n=== EFFECT-DEFS: defmethod / defmulti / extend-* writable (EXP-025 b4 DEFECT 1) ===")
;; Regression: write-def of a `(defmethod …)` was rejected at the canon gate with the
;; WRONG medicine — "wrap it as `(def <name> (defmethod …))`". A multimethod method is a
;; top-level REGISTRATION effect, not a value; the wrap misleads the model into churn
;; (b4 w-malli-01 toolcalls turn 2). Identity: defmethod keyed by M + dispatch value
;; (siblings coexist, same M+dispatch replaces); defmulti/extend keyed by name/target.
(defn- names-of [module] (set (map :name (:defs (idx module)))))
;; -- defmulti (named identity) --
(let [resp (w M "(defmulti wd-mm class)")]
  (check "defmulti write -> :ok (was: rejected, not a value def)" (:ok resp) (pr-str resp)))
(check "defmulti addressable in index" (contains? (names-of M) "wd-mm") (pr-str (names-of M)))
;; -- defmethod: two dispatch values COEXIST (identity = M + dispatch) --
(let [a (w M "(defmethod wd-mm :alpha [x] x)")
      b (w M "(defmethod wd-mm :beta [x] x)")]
  (check "defmethod :alpha write -> :ok (DEFECT 1 fix)" (:ok a) (pr-str a))
  (check "defmethod :beta  write -> :ok" (:ok b) (pr-str b)))
(let [ns (names-of M)]
  (check "both defmethods coexist (M+dispatch identity, not M)"
         (and (contains? ns "wd-mm::alpha") (contains? ns "wd-mm::beta")) (pr-str ns)))
;; -- re-writing SAME M+dispatch REPLACES (no duplicate append) --
(let [before (count (filter #(str/starts-with? (str %) "wd-mm") (names-of M)))
      re     (w M "(defmethod wd-mm :alpha [x] (inc x))")
      after  (count (filter #(str/starts-with? (str %) "wd-mm") (names-of M)))
      rd     (r M "wd-mm::alpha")]
  (check "re-write same M+dispatch -> :ok" (:ok re) (pr-str re))
  (check "re-write REPLACES (count unchanged, no dup)" (= before after) (str "before=" before " after=" after))
  (check "re-write body took (inc)" (and (:ok rd) (str/includes? (str (:source rd)) "inc")) (pr-str (:source rd))))
;; -- extend-type (head + target identity) --
(let [resp (w M "(extend-type WdFoo WdProto (wd-m [this] 1))")]
  (check "extend-type write -> :ok (DEFECT 1 fix)" (:ok resp) (pr-str resp))
  (check "extend-type addressable as Target@Proto" (contains? (names-of M) "WdFoo@WdProto") (pr-str (names-of M))))
;; -- NEGATIVE: a genuinely non-writable head still fails, WITHOUT the wrong medicine --
(let [resp (w M "(println \"nope\")")
      e (err-of resp)]
  (check "non-writable head still fails closed" (false? (:ok resp)) (pr-str resp))
  (check "reject :stage :canon" (= :canon (:stage e)) (pr-str e))
  (check "reject does NOT prescribe the wrong `wrap it as (def ...)` medicine"
         (not (str/includes? (str (:suggestion e)) "wrap it as")) (pr-str (:suggestion e))))

(println "\n=== EXTEND-TARGET LINT: (class (byte-array 0)) in target position (EXP-025 p2g ring-01) ===")
;; The p2g autopsy: a write-def extend-protocol block with `(class (byte-array 0))` as a
;; TARGET silently mis-partitions (extend-protocol keys targets as SYMBOLS), byte arrays
;; never get the impl, the oracle stays red across 3 attempts. Repair-grade canon lint must
;; REJECT the runtime-expression target and teach the `(extend (Class/forName "[B") ...)` idiom.
(let [bad "(extend-protocol StreamableResponseBody\n  (class (byte-array 0))\n  (write-body-to-stream [body _ output-stream]\n    (.write output-stream body)\n    (.close output-stream)))"
      resp (w M bad)
      e (err-of resp)]
  (check "extend-protocol w/ (class ..) target fails closed" (false? (:ok resp)) (pr-str resp))
  (check "extend-target reject :stage :canon" (= :canon (:stage e)) (pr-str e))
  (check "reject :message names the mis-partition footgun"
         (str/includes? (str (:message e)) "mis-partition") (pr-str (:message e)))
  (check "reject :suggestion teaches the (extend (Class/forName ..) ..) idiom"
         (and (str/includes? (str (:suggestion e)) "Class/forName")
              (str/includes? (str (:suggestion e)) "extend")) (pr-str (:suggestion e)))
  (check "reject :got shows the offending target"
         (str/includes? (str (:got e)) "byte-array") (pr-str (:got e))))
;; a legal extend-protocol (SYMBOLS only) is accepted — the lint must not false-positive.
(let [resp (w M "(extend-protocol WdLintProto WdLintType (wd-lint-m [this] 1))")]
  (check "legal extend-protocol (symbol targets) -> :ok" (:ok resp) (pr-str resp)))
;; the CORRECT idiom — a top-level (extend (Class/forName "[B") ...) with an EXPRESSION
;; target — is LEGAL (plain `extend` takes runtime targets) and must apply + round-trip.
(let [resp (w M "(extend (Class/forName \"[B\") WdLintProto {:wd-lint-m (fn [this] 2)})")]
  (check "legal (extend (Class/forName ..) ..) -> :ok (expression target allowed)" (:ok resp) (pr-str resp)))
(let [again (w M "(extend (Class/forName \"[B\") WdLintProto {:wd-lint-m (fn [this] 3)})")]
  (check "re-writing the extend form replaces in place -> :ok (round-trips)" (:ok again) (pr-str again)))

;; --- A0's real t-r1 fumble corpus (thread A0) -------------------------------
;; Each fixture carries `:emitted` — the RAW text the model actually produced in
;; EXP-021 t-r1 (often a fenced EDN changeset, prose, JSON keys, or a bare form). We
;; feed it to write-def AS `:source` — that IS what the agentic arm will send. The
;; phase-1 GUARANTEE proven here: closed-under-mistake — every emission either
;; canonicalizes OR returns a structured error carrying a repair :suggestion; NEVER a
;; bare exception / message-less reject. (Whether a :gate-stage fumble's error names
;; the EXACT gate fix is phase 2 — the def-level check seam, thread A2.)
(def fixtures-file (str root "/tests/fixtures/authoring-fumbles.edn"))
(when (.exists (io/file fixtures-file))
  (println "\n=== A0 t-r1 fumble corpus (closed-under-mistake over REAL emissions) ===")
  (let [fixtures (try (edn/read-string (slurp fixtures-file)) (catch Throwable t (println "  (unreadable:" (.getMessage t) ")") nil))
        cats (atom {:canon-ok 0 :err-with-suggestion 0 :bare 0})]
    (doseq [fx fixtures]
      (let [module (or (:module fx) M)
            src    (:emitted fx)]
        (when-not (str/blank? (str src))
          (let [resp (w module src)
                e    (err-of resp)
                ok   (boolean (:ok resp))
                has-suggest (and (not ok) (not (str/blank? (str (:suggestion e)))))]
            (swap! cats update (cond ok :canon-ok has-suggest :err-with-suggestion :else :bare) inc)
            (check (str "fixture " (:id fx))
                   (or ok has-suggest)                  ; MUST be canon-ok OR error-with-suggestion
                   (str "stage=" (:stage e) " msg=" (:message e) " (no :suggestion — bare error!)"))))))
    (println "  breakdown:" (pr-str @cats)
             (str "(" (:canon-ok @cats) " canon-ok, " (:err-with-suggestion @cats) " repair-errors, " (:bare @cats) " BARE)"))))

(println (format "\n==== %s : %d failure(s) ====" (if (zero? @failures) "PASS" "FAIL") @failures))
(shutdown!)
(System/exit (if (zero? @failures) 0 1))
