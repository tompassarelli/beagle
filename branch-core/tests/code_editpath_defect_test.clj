;; ============================================================================
;; code_editpath_defect_test.clj — EXP-025 edit-path smoke regressions (D1 + D2).
;; ============================================================================
;; Repro-derived from ~/code/after-text/docs/private/EXP-025-editpath-smoke-2026-07-04.md
;; ("Defects found"). Drives the WARM :edit-min set-body path — the SAME path the
;; mcp__fram__set-body tool commits through — over a throwaway daemon booted on a
;; freshly-ingested synthetic corpus, and asserts the two authoring defects are fixed:
;;
;;   D1  scope prefix-collision: module "pkg.gen" is a substring of sibling
;;       "pkg.gen_seq", so the old (str/includes? % scope) filter matched BOTH and
;;       rejected the shorter module as ambiguous (code 3) — unauthorable. Now the
;;       scope resolves by EXACT module identity (scope->srcs), like the :render path.
;;   D2  metadata-on-name: a value-def whose NAME carries reader metadata —
;;       (def ^:dynamic *chunk-size* 32) / (def ^{:dynamic true :private true} *date-format* nil)
;;       — ingests a (#%meta …) node in the name slot, so the old bare `sym-val` anchor
;;       scan never matched the name -> no body slots -> reject (code 5). Now the scan
;;       unwraps a leading #%meta wrapper (unwrap-meta) to reach the bound symbol.
;;
;; Plus a regression: a plain defn set-body in the UNAMBIGUOUS sibling still commits.
;;
;; Runs on the JVM (clojure -M), NOT bare bb — the daemon + verbs need production's
;; LispReader (see tests/code_write_def_test.clj). Needs the Beagle CLI to ingest
;; (BEAGLE_HOME / FRAM_BEAGLE); SKIPs cleanly if Beagle can't be resolved.
;;
;;   BEAGLE_HOME=$HOME/code/beagle/main \
;;     clojure -M tests/code_editpath_defect_test.clj ; echo EXIT=$?
;; ============================================================================
(require '[fram.store :as c] '[fram.schema :as s]
         '[clojure.string :as str] '[clojure.edn :as edn] '[clojure.java.io :as io]
         '[clojure.java.shell :as sh])

(def root (System/getProperty "user.dir"))
(def home (System/getProperty "user.home"))

;; --- Beagle resolution; SKIP if the CLI cannot be found ----------------------
(def beagle-home (or (System/getenv "BEAGLE_HOME") (str home "/code/beagle/main")))
(def beagle-bin (or (System/getenv "FRAM_BEAGLE") (str beagle-home "/bin/beagle")))
(when-not (.canExecute (io/file beagle-bin))
  (println "SKIP — no Beagle CLI (set FRAM_BEAGLE / BEAGLE_HOME)") (System/exit 0))

;; --- synthesize a corpus with the two risky shapes, ingest -> a flat code.log -----
;; pkg/gen.bclj + pkg/gen_seq.bclj under one --root => modules "pkg.gen" (⊂ "pkg.gen_seq").
(def work (str (System/getProperty "java.io.tmpdir") "/editpath-defect-" (System/nanoTime)))
(.mkdirs (io/file (str work "/pkg")))
(spit (str work "/pkg/gen.bclj")
      (str "(ns pkg.gen)\n"
           "(def ^:dynamic *chunk-size* 32)\n"                          ; D2: earmuffed dynamic var
           "(def ^{:dynamic true :private true} *date-format* nil)\n"   ; D2: map-metadata private var
           "(defn plain-fn [x] (+ x 1))\n"))                            ; D1 target (ambiguous scope) + plain-defn regression
(spit (str work "/pkg/gen_seq.bclj")
      (str "(ns pkg.gen_seq)\n"
           "(defn seq-fn [x] (* x 2))\n"))                              ; regression target (UNambiguous scope)

(def log (str work "/code.log"))
(def env (assoc (into {} (System/getenv))
                "BEAGLE_HOME" beagle-home "FRAM_BEAGLE" beagle-bin))
(let [r (sh/sh "bb" "-cp" "out" "bin/fram-ingest-code"
               (str work "/pkg/gen.bclj") (str work "/pkg/gen_seq.bclj")
               "--root" work "--out" log
               :env env :dir root)]
  (when-not (and (zero? (:exit r)) (.exists (io/file log)))
    (println "SKIP — ingest failed (Beagle unavailable?):\n" (:out r) (:err r))
    (System/exit 0)))

;; --- boot a throwaway warm daemon over the log on a verified-free port >= 49010 ---
(binding [*command-line-args* []] (load-file "server.clj"))
(defn- port-free? [p] (try (with-open [s (java.net.Socket.)]
                             (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false)
                           (catch Exception _ true)))
(def port (or (some #(when (port-free? %) %) (range 49020 49060)) 49020))
(boot-flat! log)
(def server (future (serve port)))
(Thread/sleep 700)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))

(def status (client port {:op :status}))
(when-not (pos? (or (:facts status) 0))
  (println "ABORT: daemon not serving facts" (pr-str status)) (shutdown!) (System/exit 1))
(println "daemon up:" (:facts status) "facts, port=" port "\n")

;; --- assertion harness (code_write_def_test style) ---------------------------------
(def failures (atom 0))
(defn- check [label ok? detail]
  (println (format "  [%s] %s%s" (if ok? "PASS" "FAIL") label (if ok? "" (str "  <-- " detail))))
  (when-not ok? (swap! failures inc)))
;; set-body through the warm :edit-min wire op (the mcp__fram__set-body path).
(defn- set-body [module name body]
  (client port {:op :edit-min :spec {:op "set-body" :module module :name name
                                     :datum (edn/read-string body)}}))
(defn- committed? [resp] (and (:ok resp) (pos? (or (:ops resp) 0))))

(println "=== D1 — set-body on a module whose name PREFIXES a sibling (was: code 3) ===")
(let [resp (set-body "pkg.gen" "plain-fn" "(do (+ x 5))")]
  (check "prefix-sibling scope 'pkg.gen' resolves to exactly one module + commits"
         (committed? resp) (pr-str resp)))

(println "\n=== D2 — set-body on a value-def whose NAME carries metadata (was: code 5) ===")
(let [resp (set-body "pkg.gen" "*chunk-size*" "(do 64)")]
  (check "^:dynamic *chunk-size* set-body finds the meta-wrapped anchor + commits"
         (committed? resp) (pr-str resp)))
(let [resp (set-body "pkg.gen" "*date-format*" "(do \"yyyy\")")]
  (check "^{:dynamic true :private true} *date-format* set-body commits"
         (committed? resp) (pr-str resp)))

(println "\n=== regression — plain defn set-body in the UNambiguous sibling still works ===")
(let [resp (set-body "pkg.gen_seq" "seq-fn" "(do (* x 3))")]
  (check "plain defn set-body (no meta, unambiguous scope) commits"
         (committed? resp) (pr-str resp)))

(println (format "\n==== %s : %d failure(s) ====" (if (zero? @failures) "PASS" "FAIL") @failures))
(shutdown!)
(System/exit (if (zero? @failures) 0 1))
