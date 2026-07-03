#!/usr/bin/env bb
;; fuzz/harness/gate.clj — nightly pass/fail policy over a harness report.edn.
;;
;; The harness (harness.clj) is a pure classifier: it emits report.edn +
;; shrunk repros and ALWAYS exits 0. This gate applies the campaign policy on
;; top of that report, so the fail/green decision lives in one auditable place
;; and the harness stays free of CI concerns.
;;
;; POLICY — a divergence bucket is FATAL when:
;;   - class is :emission                        → ALWAYS fatal (backend output
;;                                                  divergence, zero tolerance)
;;   - class is :acceptance / :diagnostic AND its
;;     signature is NOT in the allowlist          → fatal (a new checker-tail
;;                                                  bucket not yet triaged)
;; An allowlisted :acceptance/:diagnostic bucket is the known checker-message
;; precision tail — benign, GREEN.
;;
;; Usage:
;;   gate.clj --report <report.edn> --allowlist <known-buckets.txt> [--repros <dir>]
;;
;; Exit 0 = GREEN (no fatal buckets); exit 1 = RED (>=1 fatal bucket).
;; On RED, prints each fatal bucket + its shrunk-repro path (for artifact upload).

(require '[clojure.edn :as edn]
         '[clojure.string :as str]
         '[babashka.fs :as fs])

(defn parse-args [argv]
  (loop [m {} argv (vec argv)]
    (if (empty? argv)
      m
      (let [k (first argv) v (second argv)]
        (if (str/starts-with? (str k) "--")
          (recur (assoc m (keyword (subs k 2)) v) (drop 2 argv))
          (recur m (rest argv)))))))

(def opts          (parse-args *command-line-args*))
(def report-path   (:report opts))
(def allowlist-path (:allowlist opts))
(def repros-dir    (:repros opts))

(when (or (nil? report-path) (nil? allowlist-path))
  (binding [*out* *err*]
    (println "usage: gate.clj --report <report.edn> --allowlist <file> [--repros <dir>]"))
  (System/exit 2))

(defn load-allowlist [path]
  (if (fs/exists? path)
    (->> (str/split-lines (slurp path))
         (map str/trim)
         (remove str/blank?)
         (remove #(str/starts-with? % "#"))
         set)
    #{}))

(def allow  (load-allowlist allowlist-path))
(def report (edn/read-string (slurp report-path)))
(def divs   (:divergences report))
(def target (:target report))

;; Corpus extension for locating repros, mirrors harness.clj.
(def corpus-ext
  (case target "clj" ".bclj" "js" ".bjs" "nix" ".bnix" ".bclj"))

;; Collapse per-file divergences to unique buckets (class + signature).
(def buckets
  (->> divs
       (map (fn [d] {:class (:class d) :signature (:signature d) :detail (:detail d)}))
       distinct
       vec))

(defn fatal? [{:keys [class signature]}]
  (cond
    (= class :emission) true                       ; always fatal
    (contains? allow signature) false              ; known checker-tail
    :else true))                                   ; new acceptance/diagnostic bucket

(def fatal-buckets (filter fatal? buckets))
(def allowed-buckets (remove fatal? buckets))

(println (str "gate: target=" target
              " total=" (:total report)
              " ok=" (:ok report)
              " divergence-buckets=" (count buckets)
              " (allowlisted=" (count allowed-buckets)
              " fatal=" (count fatal-buckets) ")"))

(when (seq allowed-buckets)
  (println (str "gate: " (count allowed-buckets) " allowlisted (known checker-tail) bucket(s):"))
  (doseq [b allowed-buckets]
    (println (str "  [ok/known] " (name (:class b)) " " (:signature b)))))

(when (seq fatal-buckets)
  (println "")
  (println (str "gate: " (count fatal-buckets) " FATAL bucket(s) — NEW divergence(s) on this run:"))
  (doseq [b fatal-buckets]
    (let [reason (if (= (:class b) :emission)
                   "emission (zero tolerance)"
                   "acceptance/diagnostic not in allowlist")
          repro  (when repros-dir (str repros-dir "/" (:signature b) corpus-ext))]
      (println (str "  [FATAL] " (name (:class b)) " " (:signature b) " — " reason))
      (println (str "          detail: " (:detail b)))
      (when (and repro (fs/exists? repro))
        (println (str "          repro:  " repro))))))

(println "")
(if (seq fatal-buckets)
  (do (println "gate: RED — new divergence(s) require investigation.") (System/exit 1))
  (do (println "gate: GREEN — no fatal divergence buckets.") (System/exit 0)))
