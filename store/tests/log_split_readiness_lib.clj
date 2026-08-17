;; Shared test-harness readiness contract for spawning a scratch child
;; process (e.g. a split-log JVM server) and waiting for it to become
;; live and speaking the wire protocol — replacing a fixed sleep budget with
;; an observable, bounded loop. Test-only: no production behavior changes.
;;
;; Contract:
;;   - child liveness:     fail immediately once the spawned process has
;;                         exited, instead of continuing to poll a corpse
;;                         until an arbitrary timeout elapses.
;;   - protocol readiness: poll `(ready? port)` until it reports true.
;;   - bounded deadline:   never wait past `:deadline-ms`, even while the
;;                         child is alive — a genuinely hung boot must
;;                         still fail loudly, not spin forever.
;;   - diagnostics:        both failure modes throw ex-info carrying either
;;                         the child's captured exit/stdout/stderr (dead
;;                         child) or the elapsed wait and port (deadline),
;;                         so a flake is debuggable from the test's own
;;                         failure output rather than a bare "timed out".
(require '[babashka.process :as p])

(defn scratch-process-env
  "The current process environment with live telemetry routing removed, plus
  scratch-test overrides. Tests that select their own coordination log must not
  silently compose it with an unrelated ambient telemetry log."
  ([]
   (dissoc (into {} (System/getenv)) "BEAGLE_STORE_TELEMETRY_LOG"))
  ([overrides]
   (merge (scratch-process-env) overrides)))

(defn await-ready
  "Block until (ready? port) is true, the child process (from
  babashka.process/process, NOT deref'd) exits, or deadline-ms elapses —
  whichever comes first. Returns :ready on success; throws ex-info
  otherwise."
  [child port ready? & {:keys [deadline-ms poll-ms]
                        :or {deadline-ms 30000 poll-ms 50}}]
  (let [deadline (+ (System/currentTimeMillis) deadline-ms)]
    (loop []
      (cond
        (ready? port)
        :ready

        (not (p/alive? child))
        (let [{:keys [exit out err]} @child]
          (throw (ex-info "child exited before becoming ready"
                           {:reason :child-exited :exit exit :stdout out :stderr err})))

        (> (System/currentTimeMillis) deadline)
        (throw (ex-info (str "readiness deadline exceeded (" deadline-ms "ms), child still alive")
                         {:reason :deadline-exceeded :deadline-ms deadline-ms :port port}))

        :else
        (do (Thread/sleep poll-ms) (recur))))))

(defn free-port
  "An OS-assigned ephemeral port, free at the instant of the call. Used in
  place of a random guess so concurrent test runs (this harness's own
  parallel instances, or unrelated processes on a shared box) don't
  collide on a scratch server port — a bind failure is a different
  defect than a slow/dead boot and would otherwise masquerade as one."
  []
  (with-open [s (java.net.ServerSocket. 0)]
    (.getLocalPort s)))

(defn- delete-tree [^java.io.File f]
  (when (.isDirectory f)
    (doseq [c (.listFiles f)] (delete-tree c)))
  (.delete f))

(defn cleanup-scratch
  "Recursively remove a scratch-state directory. Safe to call even if the
  path is already gone."
  [path]
  (when (and path (.exists (java.io.File. ^String path)))
    (delete-tree (java.io.File. ^String path))))
