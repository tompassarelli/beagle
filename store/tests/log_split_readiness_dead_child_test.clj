;; Seeded regression: if the server process exits before ever becoming
;; ready, the harness must fail fast (well inside its deadline) and
;; diagnostically (carrying the child's exit code and captured stderr)
;; instead of silently waiting out the full timeout as if it were a slow
;; boot. This is the "dead child" half of the log-split E2E cold-boot-flake
;; fix; this case covers a child that exits before readiness
;; half.
(require '[babashka.process :as p])
(load-file "tests/log_split_readiness_lib.clj")

(def port (free-port))
(def child
  (p/process [(str (System/getProperty "user.dir") "/tests/fixtures/dead_server_wrapper.sh")]
             {:dir (System/getProperty "user.dir")
              :out :string :err :string}))

(def deadline-ms 20000)
(def start (System/currentTimeMillis))
(def outcome
  (try
    (await-ready child port (constantly false) :deadline-ms deadline-ms)
    :unexpected-ready
    (catch clojure.lang.ExceptionInfo e
      (ex-data e))
    (finally
      (p/destroy-tree child))))
(def elapsed (- (System/currentTimeMillis) start))

(assert (map? outcome) (str "expected a diagnostic ex-info, got " (pr-str outcome)))
(assert (= :child-exited (:reason outcome)) (str "expected child-exited, got " (pr-str outcome)))
(assert (= 7 (:exit outcome)) (str "expected exit 7, got " (pr-str outcome)))
(assert (clojure.string/includes? (:stderr outcome) "simulated boot failure")
        (str "expected captured stderr to explain the failure, got " (pr-str (:stderr outcome))))
(assert (< elapsed (/ deadline-ms 2))
        (str "expected early diagnostic failure well inside the " deadline-ms "ms deadline, took " elapsed "ms"))

(println (str "log-split readiness dead-child: detected exit " (:exit outcome)
              " in " elapsed "ms (deadline " deadline-ms "ms) with captured stderr — PASS"))
