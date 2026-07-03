#!/usr/bin/env bb
;; fuzz/harness/harness.clj — differential fuzzing harness for beagle dual compilers.
;;
;; Runs the Racket oracle and the self-hosted compiler over a corpus of beagle
;; source files (.bclj / .bjs / .bnix), classifies divergences into
;; :acceptance / :diagnostic / :emission / :ok, shrinks repros via greedy
;; delta-debug, and writes report.edn.
;;
;; Called from run.sh; do not run directly.
;;
;; --target clj|js|nix (default clj):
;;   oracle side — $RACKET dispatches by the file's #lang header (no extra arg)
;;   selfhost side — calls `selfhost.main emit` for clj (byte-identical to the
;;                   original harness); passes `--target <t>` for js/nix (CLI
;;                   contract from parallel port lanes; tested with stubs in
;;                   self-test.sh until the binary ships it)

(require '[clojure.java.shell :as sh-api]
         '[clojure.string :as str]
         '[clojure.java.io :as io]
         '[clojure.pprint :as pp]
         '[babashka.fs :as fs])

(import '[java.security MessageDigest]
        '[java.util.concurrent Executors])

;; ─── CLI parse ───────────────────────────────────────────────────────────────

(defn parse-args [argv]
  (loop [m {} argv (vec argv)]
    (if (empty? argv)
      m
      (let [k (first argv) v (second argv)]
        (if (str/starts-with? (str k) "--")
          (recur (assoc m (keyword (subs k 2)) v) (drop 2 argv))
          (recur m (rest argv)))))))

(def opts         (parse-args *command-line-args*))
(def corpus-dir   (:corpus opts))
(def out-dir      (:out opts))
(def jobs         (Integer/parseInt (or (:jobs opts) "4")))
(def beagle-root  (:beagle-root opts))
(def racket-bin   (:racket opts))
(def selfhost-bin (:selfhost-bin opts))
(def target       (or (:target opts) "clj"))   ;; "clj" | "js" | "nix"
(def bb-seed-cp   (str beagle-root "/self-host/seed"))

;; File extension for the chosen target
(def corpus-ext
  (case target
    "clj" ".bclj"
    "js"  ".bjs"
    "nix" ".bnix"
    ".bclj"))

;; ─── Helpers ─────────────────────────────────────────────────────────────────

(defn sha1-hex [^String s]
  (let [md (MessageDigest/getInstance "SHA-1")
        b  (.getBytes s "UTF-8")
        d  (.digest md b)]
    (str/join "" (map #(format "%02x" (bit-and % 0xff)) d))))

(defn short-sig [s] (subs (sha1-hex s) 0 12))

(defn normalize-for-sig [^String s]
  ;; Bucket-collapse normalization: generated cases differ in gensym counters,
  ;; per-case ns names, and literal values, but those never distinguish BUG
  ;; CLASSES — hashing them fragments one bug into hundreds of signatures
  ;; (each paying a full shrink). Shrunk repros keep the raw content, so
  ;; over-merging here costs nothing but a shared repro file.
  (-> s
      (str/replace #"__\d+" "__N")
      (str/replace #"case\d+" "caseN")
      (str/replace #"\d+" "N")))

(defn normalize-output [^String s]
  ;; Strip trailing whitespace per line, normalize line endings.
  (-> s
      (str/replace "\r\n" "\n")
      str/trimr))

(defn error-fingerprint [^String stderr]
  ;; Extract a stable error class string from stderr, stripping volatile parts.
  ;; Strip to the message CORE (after the last "beagle:" marker) BEFORE
  ;; truncating: the oracle's srcloc prefix otherwise eats ~40 chars of the
  ;; cap, so two identical long messages keep different 120-char windows and
  ;; compare unequal (false :diagnostic on every case/dotimes rejection).
  (let [lines (str/split-lines (or stderr ""))
        sig   (first (filter #(re-find #"(?i)error|fail|beagle:|check:|parse:|type:" %) lines))
        raw   (or sig (first lines) "unknown-error")
        i     (.lastIndexOf ^String raw "beagle:")
        core  (if (neg? i) raw (subs raw (+ i (count "beagle:"))))]
    (-> core
        ;; strip absolute paths
        (str/replace #"(?:/[^\s:\"',\(\)]+|~/[^\s:\"',\(\)]+)" "<path>")
        ;; strip numeric line/col references like :42:7 or @42:7
        (str/replace #"[@:]\d+(?::\d+)*" ":N")
        str/trim
        (#(subs % 0 (min 120 (count %)))))))

;; ─── Compiler invocations ────────────────────────────────────────────────────

(def base-env (into {} (System/getenv)))
(def oracle-env (assoc base-env "BEAGLE_EMIT_SRCLOC" "0"))

(defn run-oracle [^java.io.File file]
  ;; Run Racket oracle: BEAGLE_EMIT_SRCLOC=0 $RACKET file
  ;; #lang header in the file drives target dispatch — no extra arg needed.
  ;; Returns {:exit N :out "" :err ""}
  (sh-api/sh racket-bin (str file) :env oracle-env))

(defn run-selfhost [^java.io.File file]
  ;; Run self-hosted compiler (native binary or bb fallback).
  ;; clj: no --target flag (byte-identical to the original harness).
  ;; js/nix: pass --target <t> (contract from parallel port lanes).
  ;; Returns {:exit N :out "" :err ""}
  (let [extra-args (if (= target "clj") [] ["--target" target])]
    (if (= selfhost-bin "bb_fallback")
      (apply sh-api/sh "bb" "-cp" bb-seed-cp "-m" "selfhost.main" "emit"
             (concat extra-args [(str file)]))
      (apply sh-api/sh selfhost-bin "emit"
             (concat extra-args [(str file)])))))

;; ─── Classification ──────────────────────────────────────────────────────────

(defn classify-pair [file oracle selfhost]
  (let [o-ok (zero? (:exit oracle))
        s-ok (zero? (:exit selfhost))]
    (cond
      ;; Both accept: compare normalized stdout
      (and o-ok s-ok)
      (let [o-out (normalize-output (:out oracle))
            s-out (normalize-output (:out selfhost))]
        (if (= o-out s-out)
          {:class :ok}
          (let [o-lines (str/split-lines o-out)
                s-lines (str/split-lines s-out)
                first-diff (some (fn [[ol sl]]
                                   (when (not= ol sl)
                                     (str "oracle: " (subs ol 0 (min 60 (count ol)))
                                          " | self: " (subs sl 0 (min 60 (count sl))))))
                                 (map vector o-lines s-lines))
                ;; Signature = only the differing line pairs, normalized —
                ;; identical bug shapes across cases collapse to one bucket.
                diff-key (str/join "\n"
                                   (distinct
                                    (keep (fn [[ol sl]]
                                            (when (not= ol sl)
                                              (str (normalize-for-sig ol) "|" (normalize-for-sig sl))))
                                          (map vector o-lines s-lines))))
                tail-key (if (= (count o-lines) (count s-lines)) "" ":tail-mismatch")]
            {:class     :emission
             :signature (short-sig (str "emission:" diff-key tail-key))
             :detail    (or first-diff
                            (str "line-count: oracle=" (count o-lines) " self=" (count s-lines)))})))

      ;; One accepts, one rejects → acceptance divergence
      (not= o-ok s-ok)
      {:class     :acceptance
       :signature (short-sig (str "acceptance:" (if o-ok "oracle-ok" "self-ok")
                                  ":" (normalize-for-sig
                                       (if o-ok
                                         (error-fingerprint (:err selfhost))
                                         (error-fingerprint (:err oracle))))))
       :detail    (str "oracle=" (if o-ok "accept" "reject")
                       " selfhost=" (if s-ok "accept" "reject")
                       " | "
                       (if o-ok
                         (str "self-err: " (error-fingerprint (:err selfhost)))
                         (str "oracle-err: " (error-fingerprint (:err oracle)))))}

      ;; Both reject: compare error MESSAGE CORES, not full fingerprints —
      ;; the oracle prefixes srcloc ("main.rkt:12:7: beagle: ...") while
      ;; selfhost tags the phase ("beagle [check]: ..."); both carry the real
      ;; message after the last "beagle:" marker. Format difference alone is
      ;; not a divergence; message difference is.
      :else
      (let [o-fp (error-fingerprint (:err oracle))
            s-fp (error-fingerprint (:err selfhost))
            core (fn [^String fp]
                   (let [i (.lastIndexOf fp "beagle:")]
                     (if (neg? i) fp (str/trim (subs fp (+ i (count "beagle:")))))))]
        (if (= (core o-fp) (core s-fp))
          {:class :ok}
          {:class     :diagnostic
           :signature (short-sig (str "diagnostic:" (normalize-for-sig o-fp)
                                      "\0" (normalize-for-sig s-fp)))
           :detail    (str "oracle-err: " o-fp " | self-err: " s-fp)})))))

;; ─── Top-level form splitter ─────────────────────────────────────────────────

(defn split-top-level-forms [^String source]
  "Split beagle source into top-level forms by tracking bracket depth.
   Handles strings and line comments. Returns vector of trimmed form strings."
  (let [n (count source)]
    (loop [i       0
           depth   0
           start   0
           in-str? false
           esc?    false
           in-cmt? false
           forms   []]
      (if (>= i n)
        ;; End: capture any trailing top-level fragment
        (let [tail (str/trim (subs source start))]
          (if (str/blank? tail) forms (conj forms tail)))
        (let [c (.charAt source i)]
          (cond
            ;; Line comment: skip until newline
            in-cmt?
            (recur (inc i) depth start false false (not= c \newline) forms)

            ;; Escaped character inside string
            esc?
            (recur (inc i) depth start in-str? false false forms)

            ;; Inside string literal
            in-str?
            (cond
              (= c \\) (recur (inc i) depth start true  true  false forms)
              (= c \") (recur (inc i) depth start false false false forms)
              :else    (recur (inc i) depth start true  false false forms))

            ;; Normal parsing
            :else
            (cond
              (= c \;)  ; start line comment
              (recur (inc i) depth start false false true forms)

              (= c \")  ; start string
              (recur (inc i) depth start true false false forms)

              (or (= c \() (= c \[) (= c \{))
              (recur (inc i) (inc depth) start false false false forms)

              (or (= c \)) (= c \]) (= c \}))
              (let [nd (dec depth)]
                (if (zero? nd)
                  ;; Completed a top-level form
                  (let [form (str/trim (subs source start (inc i)))]
                    (recur (inc i) 0 (inc i) false false false
                           (if (str/blank? form) forms (conj forms form))))
                  (recur (inc i) nd start false false false forms)))

              :else
              (recur (inc i) depth start false false false forms))))))))

;; ─── Delta-debug shrinker ─────────────────────────────────────────────────────

(defn diverges? [^String content target-class target-sig]
  "Write content to a temp file, run both compilers, return true if same divergence."
  (let [tmp (java.io.File/createTempFile "beagle-shrink" corpus-ext)]
    (try
      (spit tmp content)
      (let [oracle   (run-oracle tmp)
            selfhost (run-selfhost tmp)
            result   (classify-pair tmp oracle selfhost)]
        (and (= (:class result) target-class)
             (= (:signature result) target-sig)))
      (finally
        (.delete tmp)))))

(defn shrink-forms
  "Greedy form-level shrinker: try removing each form one at a time.
   Repeat until no form can be removed. Always keeps the first form (ns decl).
   Cap at 500 compiler invocations."
  [initial-forms target-class target-sig]
  (loop [forms (vec initial-forms) pass 0 total-iters 0]
    (if (or (> total-iters 500) (<= (count forms) 1))
      forms
      (let [[new-forms improved total-iters]
            (loop [i 1  ; never remove index 0 (ns/lang declaration)
                   forms forms
                   improved false
                   iters total-iters]
              (if (or (>= i (count forms)) (> iters 500))
                [forms improved iters]
                (let [candidate (vec (concat (subvec forms 0 i)
                                             (subvec forms (inc i))))
                      content   (str/join "\n\n" candidate)]
                  (if (diverges? content target-class target-sig)
                    ;; Removed form i; stay at same index (forms shifted)
                    (recur i candidate true (inc iters))
                    ;; Can't remove; advance
                    (recur (inc i) forms improved (inc iters))))))]
        (if improved
          (recur new-forms (inc pass) total-iters)
          new-forms)))))

(defn shrink-file [^String file-path target-class target-sig]
  (let [source (slurp file-path)
        forms  (split-top-level-forms source)]
    (when (seq forms)
      (str/join "\n\n" (shrink-forms forms target-class target-sig)))))

;; ─── Bounded parallel execution ───────────────────────────────────────────────

(defn pmap-bounded [n f coll]
  (let [pool    (Executors/newFixedThreadPool (int n))
        futures (mapv (fn [x] (.submit pool ^Callable (fn [] (f x)))) coll)]
    (try
      (mapv #(.get %) futures)
      (finally
        (.shutdownNow pool)))))

;; ─── Per-file comparison ─────────────────────────────────────────────────────

(defn compare-file [^java.nio.file.Path path]
  (let [file     (io/file (str path))
        t0       (System/currentTimeMillis)
        oracle   (run-oracle file)
        selfhost (run-selfhost file)
        result   (classify-pair file oracle selfhost)
        elapsed  (- (System/currentTimeMillis) t0)]
    (merge result {:file (str path) :elapsed-ms elapsed})))

;; ─── Main ────────────────────────────────────────────────────────────────────

(defn -main []
  (when (nil? corpus-dir)
    (println "Usage: harness.clj --corpus <dir> --out <dir> --jobs N --beagle-root <dir>"
             "--racket <bin> --selfhost-bin <bin> [--target clj|js|nix]")
    (System/exit 1))

  (let [corpus-files (->> (fs/list-dir corpus-dir)
                          (filter #(str/ends-with? (str %) corpus-ext))
                          (sort-by str)
                          vec)]
    (when (empty? corpus-files)
      (binding [*out* *err*]
        (println "harness: no" corpus-ext "files in" corpus-dir))
      (System/exit 1))

    (println (str "harness: " (count corpus-files) " files, " jobs " jobs"
                  ", target=" target ", beagle-root=" beagle-root))
    (println (str "  oracle:   " racket-bin))
    (println (str "  selfhost: " selfhost-bin))

    (let [t0 (System/currentTimeMillis)
          results (pmap-bounded jobs compare-file corpus-files)
          t1 (System/currentTimeMillis)
          elapsed (- t1 t0)
          total   (count results)
          ok-cnt  (count (filter #(= :ok (:class %)) results))
          divs    (filter #(not= :ok (:class %)) results)]

      ;; Timing
      (let [per100 (when (pos? total) (long (* 100.0 (/ elapsed total))))]
        (println (str "harness: done. " total " files in " elapsed "ms"
                      (when per100 (str " (" per100 "ms/100 cases)")))))

      ;; Group divergences by signature, shrink + write repros
      (let [by-sig (group-by :signature divs)]
        (doseq [[sig examples] by-sig
                :let [ex    (first examples)
                      klass (:class ex)
                      fpath (:file ex)]]
          (let [repro (shrink-file fpath klass sig)]
            (when repro
              (let [rpath (str out-dir "/repros/" sig corpus-ext)]
                (io/make-parents rpath)
                (spit rpath repro)
                (println (str "  repro [" (name klass) "]: " rpath))))))

        ;; Write report.edn
        (let [div-records
              (mapv (fn [{:keys [file class signature detail]}]
                      {:file      (str (fs/relativize corpus-dir (fs/path file)))
                       :class     class
                       :signature (or signature "")
                       :detail    (or detail "")})
                    divs)
              report {:total       total
                      :ok          ok-cnt
                      :target      target
                      :divergences div-records}
              rpath  (str out-dir "/report.edn")]
          (spit rpath (with-out-str (pp/pprint report)))
          (println (str "harness: report → " rpath))
          (println (str "harness: total=" total " ok=" ok-cnt " divergences=" (count divs)
                        " unique-sigs=" (count by-sig))))))))

(-main)
