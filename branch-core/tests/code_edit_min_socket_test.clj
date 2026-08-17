;; ============================================================================
;; code_edit_min_socket_test.clj — #14: the socket :edit-min path EXPOSES the proven
;; concurrency and does NOT hang. Two CONCURRENT, DISJOINT set-body edits through the
;; daemon socket must BOTH commit (no false-conflict) and return promptly (no hang).
;;
;; This is the socket counterpart to the 150-pair in-process commute: handle now runs
;; :edit-min OUTSIDE the outer dlock, so do-edit-min's compute is lock-free (concurrent)
;; and only its commit serializes. HARD deref timeout => a regression (re-serialization
;; or a true hang) FAILS FAST instead of hanging the test/CI. No Beagle, no render.
;;   bb -cp out code_edit_min_socket_test.clj
;; ============================================================================
(require '[fram.store :as c] '[fram.schema :as s] '[clojure.edn :as edn] '[clojure.java.io :as io])
(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(when-not (.exists (io/file code-log)) (println "SKIP — no .fram/code.log") (System/exit 0))
(binding [*command-line-args* []] (load-file "server.clj"))   ; also a paren/load check on handle
(def flat (str (System/getProperty "java.io.tmpdir") "/edit-min-socket-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(defn- port-free? [p] (try (with-open [s (java.net.Socket.)]
                             (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false)
                           (catch Exception _ true)))
(def port (or (some #(when (port-free? %) %) [8230 8231 8232 8233]) 8230))
(boot-flat! flat)
(def server (future (serve port)))
(Thread/sleep 500)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))
(def status (client port {:op :status}))
(when-not (and (= flat (str (:log status))) (pos? (:facts status)))
  (println "ABORT wrong log") (shutdown!) (System/exit 1))
(println "daemon up:" (:facts status) "facts, port" port)

;; two DISJOINT same-module bodies (cardinality vs lookup) — different (te,p) groups.
(def body-card (edn/read-string "(if (some? (c/value-id ctx pname)) \"socket-card-marker\" \"multi\")"))
(def body-lookup (edn/read-string "(first (lookup-all ctx subj pname))"))

;; fire BOTH concurrently through the socket; hard 90s deref so a hang fails fast.
(def t0 (System/nanoTime))
(def fa (future (client port {:op :edit-min :spec {:op "set-body" :module "schema" :name "cardinality" :datum body-card}})))
(def fb (future (client port {:op :edit-min :spec {:op "set-body" :module "schema" :name "lookup" :datum body-lookup}})))
(def ra (deref fa 90000 :TIMEOUT))
(def rb (deref fb 90000 :TIMEOUT))
(def ms (/ (- (System/nanoTime) t0) 1e6))
(shutdown!)

(def fails (atom 0))
(defn chk [nm ok] (if ok (println "  [PASS]" nm) (do (swap! fails inc) (println "  [FAIL]" nm "—" (pr-str [ra rb])))))
(println (format "\nconcurrent socket :edit-min pair returned in %.0f ms" ms))
(chk "edit A returned (no hang)" (not= :TIMEOUT ra))
(chk "edit B returned (no hang)" (not= :TIMEOUT rb))
(chk "edit A committed (:ok)" (boolean (:ok ra)))
(chk "edit B committed (:ok)" (boolean (:ok rb)))
(chk "neither false-conflicted (disjoint (te,p) groups commute through the socket)"
     (and (not (:reject ra)) (not (:reject rb))))
(println (str "\n---- #14 socket exposure: " (if (zero? @fails) "ALL PASS — concurrent socket :edit-min commutes, no hang" (str @fails " FAIL")) " ----"))
(System/exit (if (zero? @fails) 0 1))
