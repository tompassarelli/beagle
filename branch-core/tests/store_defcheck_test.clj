#!/usr/bin/env bb
;; ============================================================================
;; store_defcheck_test.clj — the incremental def-level check selftest (A2).
;; ============================================================================
;; Drives the graph-authored defcheck gate + bin/fram-defcheck-server
;; over a THROWAWAY server booted on a /tmp arena log, with trap-kill and a
;; :status sanity assertion (the daemon's :log MUST be our selftest log before any
;; result is trusted). NEVER touches 7977/48942/48950. Boots its own sidecar on a
;; dedicated port and tears it down.
;;
;; PROVES (adapter-v2 spec gap 3, deliverable 4):
;;   (a) a BAD def is caught by the incremental check with the correct STRUCTURED
;;       error (:stage :type, :expected/:got, :at {:def}, repair-grade message).
;;   (b) a def that type-checks ALONE but breaks a caller in ANOTHER module is
;;       NOT flagged by check-def on the edited module, and IS caught by
;;       whole-tree-check (:stage :gate) — the authority split.
;;   (c) TIMING: a warm incremental check on this arena is under target
;;       (<5s hard, <1s ideal; measured ~0.05s).
;;
;; Run:  bb tests/store_defcheck_test.clj  >/tmp/defcheck.out 2>&1 ; echo EXIT=$?
;; ============================================================================
(require '[clojure.string :as str]
         '[clojure.java.io :as io]
         '[babashka.process :as proc])

(def repo (str (System/getProperty "user.dir")))
(def arena "/tmp/fram-a2-selftest")
(def code-log (str arena "/.fram/code.log"))
(def sidecar-port 49062)

;; --- hermetic arena modules --------------------------------------------------
(def modules
  {"derive"
   (str "#lang beagle/clj\n(ns gw.derive)\n\n"
        "(defn obj-of\n"
        "  [(triples (Vec (Vec String)))\n"
        "   (te String)\n"
        "   (p String)]\n"
        "  String\n"
        "  (reduce (fn [(acc String) (t (Vec String))] String\n"
        "            (if (and (= (nth t 0) te) (= (nth t 1) p)) (nth t 2) acc)) \"\" triples))\n\n"
        "(defn classify\n"
        "  [(triples (Vec (Vec String)))\n"
        "   (te String)\n"
        "   (opts Any)]\n"
        "  String\n"
        "  \"ready\")\n\n"
        ";; individually FINE (Int in, Int out); a landmine for gw.projections/use-tag.\n"
        "(defn tag [(x String)] Int 42)\n")
   "projections"
   (str "#lang beagle/clj\n(ns gw.projections)\n\n(require gw.derive :as d)\n\n"
        "(defn condition-of\n"
        "  [(triples (Vec (Vec String)))\n"
        "   (te String)\n"
        "   (opts Any)]\n"
        "  String\n"
        "  (d/classify triples te opts))\n\n"
        ";; BROKEN CALLER: d/tag returns Int, but this is annotated String. The break\n"
        ";; lives HERE, not in gw.derive — only a whole-tree check sees it.\n"
        "(defn use-tag [(x String)] String (d/tag x))\n")
   "badcalc"
   (str "#lang beagle/clj\n(ns gw.badcalc)\n\n"
        ";; self-contained return-type error: body is Int, annotated String.\n"
        "(defn oops [(x Int)] String (+ x 1))\n")})

;; --- helpers -----------------------------------------------------------------
(defn log! [& xs] (apply println xs) (flush))
(defn port-pids [p]
  (->> (:out (proc/sh "bash" "-c" (str "ss -tlnpH 'sport = :" p "' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u")))
       str/split-lines (remove str/blank?) vec))
(defn kill-port! [p]
  (doseq [pid (port-pids p)] (proc/sh "bash" "-c" (str "kill " pid " 2>/dev/null; sleep 0.2; kill -9 " pid " 2>/dev/null || true"))))
(defn free-port []
  (some (fn [p] (when (empty? (port-pids p)) p)) (range 49050 49090)))

(def results (atom []))
(defn check! [label pass? & [detail]]
  (swap! results conj [label (boolean pass?) detail])
  (log! (format "  [%s] %s%s" (if pass? "PASS" "FAIL") label (if detail (str " — " detail) ""))))

;; --- boot arena + server ------------------------------------------------
(proc/sh "bash" "-c" (str "rm -rf " arena))
(io/make-parents (io/file (str arena "/gw/x")))
(doseq [[m src] modules] (spit (str arena "/gw/" m ".bclj") src))
;; bin/fram-ingest-code resolves the Beagle-pinned racket itself and fails
;; loud without it; predict that here and SKIP (CI runners carry no toolchain).
(when-not (or (System/getenv "FRAM_RACKET")
              (let [bh (or (System/getenv "BEAGLE_HOME")
                           (str (System/getProperty "user.home") "/code/beagle"))
                    p (try (str/trim (:out (proc/sh {:out :string :err :string}
                                                    "direnv" "exec" bh "which" "racket")))
                           (catch Throwable _ ""))]
                (not (str/blank? p))))
  (println "SKIP — missing prerequisite: Beagle-pinned racket (set FRAM_RACKET, or direnv+beagle)")
  (System/exit 0))
(log! "ingesting arena modules ->" code-log)
(let [r (proc/sh {:dir repo} "bin/fram-ingest-code" (str arena "/gw") "--out" code-log)]
  (when-not (zero? (:exit r)) (log! "INGEST FAILED:" (:err r)) (System/exit 3)))

(def database-port (free-port))
(log! "booting throwaway server on" database-port)
(proc/sh {:dir repo :extra-env {"FRAM_SERVER_PORT" (str database-port) "FRAM_LOG" code-log}} "bin/fram-up")
(Thread/sleep 3000)

(defn database [req]
  (with-open [s (java.net.Socket.)]
    (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int database-port)) 3000)
    (let [w (io/writer (.getOutputStream s)) rd (io/reader (.getInputStream s))]
      (.write w (str (pr-str req) "\n")) (.flush w)
      (clojure.edn/read-string (.readLine rd)))))

(defn run []
  ;; SAFETY: refuse to run unless the daemon serves OUR selftest log.
  (let [st (database {:op :status})]
    (when-not (str/includes? (str (:log st)) "fram-a2-selftest")
      (log! "SAFETY ABORT: server :" database-port " serves" (:log st) "— not the selftest arena") (System/exit 4))
    (log! "server OK —" (pr-str (select-keys st [:version :log]))))

  ;; Load the primitive with explicit scratch ports + a private gwdir.
  (load-file (str repo "/out/defcheck_gate.clj"))
  (let [ns' (find-ns 'fram.defcheck)
        gv  (fn [s] (ns-resolve ns' s))
        ctor (deref (gv '->DefcheckState))
        state (ctor database-port sidecar-port (str arena "/gwdir") true nil nil true)
        ensure-state! (deref (gv 'ensure-sidecar-with-state!))
        prime-state! (deref (gv 'prime-gwdir-with-state!))
        modules-state (deref (gv 'live-modules-with-state))
        errors-state (deref (gv 'check-module-errors-any-with-state!))
        check-state (deref (gv 'check-def-with-state!))
        whole-state (deref (gv 'whole-tree-check-with-state!))]
    (let [ensure! #(ensure-state! state)
          prime! #(prime-state! state)
          modules #(modules-state state)
          errors #(errors-state state %)
          check-def #(check-state %1 %2 ensure! errors)
          whole-tree-check #(whole-state ensure! prime! modules errors)]
        (prime!)   ; siblings on disk so cross-module resolution is live

        ;; (a) bad def caught incrementally, structured -------------------------
        (let [e (check-def "badcalc" "oops")]
          (check! "(a) bad def returns an error"        (some? e) (pr-str (select-keys (or e {}) [:stage :message])))
          (check! "(a) :stage :type"                    (= :type (:stage e)))
          (check! "(a) :at :def = oops"                 (= "oops" (get-in e [:at :def])))
          (check! "(a) :expected String / :got Int"     (and (= "String" (:expected e)) (= "Int" (:got e)))
                  (str ":expected " (:expected e) " :got " (:got e)))
          (check! "(a) repair-grade :message"           (and (:message e) (re-find #"(?i)oops|return|String" (str (:message e))))
                  (:message e)))

        ;; (b) individually-fine-breaks-caller: incremental misses, gate catches
        (let [edited (check-def "derive" "tag")
              gate   (whole-tree-check)
              proj-break (some (fn [x] (and (= "projections" (get-in x [:at :module]))
                                            (= "String" (:expected x)) (= "Int" (:got x)))) (:errors gate))]
          (check! "(b) edited module derive checks CLEAN" (nil? edited) (pr-str edited))
          (check! "(b) whole-tree-check FLAGS a break"    (some? gate) (str ":stage " (:stage gate)))
          (check! "(b) :stage :gate"                      (= :gate (:stage gate)))
          (check! "(b) caller break IS in projections"    (some? proj-break)
                  (str (count (:errors gate)) " gate error(s)")))

        ;; illustrative: checking the CALLER's own module DOES catch it (not blind)
        (check! "(b') check-def projections/use-tag catches it" (some? (check-def "projections" "use-tag")))

        ;; (c) timing — warm incremental check under target --------------------
        (check-def "derive" "classify")  ; warm once
        (let [ts (vec (for [_ (range 10)]
                        (let [t0 (System/nanoTime)] (check-def "derive" "classify") (/ (- (System/nanoTime) t0) 1e6))))
              med (nth (sort ts) 5)
              mn  (apply min ts)]
          (check! "(c) warm check < 5000ms (hard target)"  (< med 5000) (format "median %.1fms min %.1fms" med mn))
          (check! "(c) warm check < 1000ms (ideal target)" (< med 1000) (format "median %.1fms" med))))))

(defn -main []
  (try (run)
       (catch Throwable t (log! "EXCEPTION:" (.getMessage t)) (swap! results conj ["harness" false (.getMessage t)]))
       (finally
         (log! "teardown: killing server" database-port "+ sidecar" sidecar-port)
         (kill-port! database-port) (kill-port! sidecar-port)))
  (let [fails (filter (comp not second) @results)]
    (log! (format "\n=== %d/%d checks passed ===" (- (count @results) (count fails)) (count @results)))
    (System/exit (if (empty? fails) 0 1))))

(-main)
