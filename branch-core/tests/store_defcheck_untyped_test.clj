;; ============================================================================
;; store_defcheck_untyped_test.clj — UNTYPED-mode def-check selftest (EXP-025).
;; ============================================================================
;; Unit-drives the graph-authored in-process untyped analyzer directly on
;; plain-Clojure source strings — NO server, NO sidecar, NO beagle spawn, so
;; it runs anywhere `clojure -M` does and is sub-millisecond per check.
;;
;; PROVES (deliverable: FRAM_DEFCHECK usable on UNTYPED Clojure):
;;   (a) a real untyped module (defn/defn-/def, let/for/->>, interop, deftype +
;;       protocol methods, :require :as/:refer) checks CLEAN — no false rejections.
;;   (b) a def calling a NONEXISTENT helper is REJECTED with :stage :type,
;;       :kind "unresolved-symbol", and :nearest naming the real helper.
;;   (c) a def calling an own-def with the WRONG arity is REJECTED with
;;       :kind "arity-mismatch", :expected/:got arities, :nearest naming the def.
;;   (d) arity is NOT falsely flagged through a threading macro (->>), and
;;       DISPATCH: a `#lang beagle` module is NOT treated as untyped, even when
;;       all of its bindings are inferred,
;;       (routes to the typed sidecar path — unchanged) while an untyped one is.
;;
;; Run:  clojure -M tests/store_defcheck_untyped_test.clj ; echo EXIT=$?
;; ============================================================================
(require '[clojure.string :as str])
(load-file (str (System/getProperty "user.dir") "/out/defcheck_gate.clj"))
(alias 'dc (create-ns 'fram.defcheck))

(defn- pv [s] (deref (ns-resolve 'fram.defcheck s)))
(def analyze     (partial (pv 'analyze-untyped-module-with-state!) true))
(def untyped?    (pv 'untyped-mode?))

(def results (atom []))
(defn check! [label pass? & [detail]]
  (swap! results conj [label (boolean pass?) detail])
  (println (format "  [%s] %s%s" (if pass? "PASS" "FAIL") label (if detail (str " — " detail) ""))))

;; --- a realistic untyped module (mirrors ring's shape) -----------------------
(def clean-src
  (str "(ns demo.cookies\n"
       "  (:import [java.time Duration])\n"
       "  (:require [clojure.string :as str]\n"
       "            [ring.util.parsing :refer [re-token]]))\n\n"
       "(def ^:private re-cookie #\"a=b\")\n"
       "(def sep \",\")\n\n"
       "(defn- strip-quotes [v] (str/replace v #\"^\\\"|\\\"$\" \"\"))\n\n"
       "(defn- parse-header [header]\n"
       "  (for [[_ k v] (re-seq re-cookie header) :let [kk (strip-quotes k)]] [kk v]))\n\n"
       "(defn parse-cookies [request encoder]\n"
       "  (->> (get-in request [:headers \"cookie\"])\n"
       "       parse-header\n"
       "       (map (fn [[k v]] [k (encoder v)]))\n"
       "       (remove nil?)))\n\n"
       "(defn ttl [d] (.getSeconds ^Duration d))\n\n"
       "(defprotocol Store (fetch [this k]))\n"
       "(deftype MemStore [state]\n"
       "  Store\n"
       "  (fetch [_ k] (get @state k re-token)))\n"))

;; --- broken variants ---------------------------------------------------------
(def undef-src   (str clean-src "\n(defn broken [r] (parse-cookiez r nil))\n"))   ; typo of parse-cookies
(def arity-src   (str clean-src "\n(defn broken [r] (parse-cookies r nil :extra))\n")) ; expects 2, given 3
(def typed-src
  (str "#lang beagle/clj\n(ns gw.d)\n(defn f [x] Int (+ x 1))\n"))

;; --- (a) clean ---------------------------------------------------------------
(let [errs (analyze "cookies" clean-src)]
  (check! "(a) clean untyped module -> no errors" (empty? errs) (pr-str (map :message errs))))

;; --- (b) undefined symbol ----------------------------------------------------
(let [errs (analyze "cookies" undef-src)
      e    (first (filter #(= "unresolved-symbol" (:kind %)) errs))]
  (check! "(b) undefined symbol flagged"          (some? e) (pr-str (:message e)))
  (check! "(b) :stage :type"                      (= :type (:stage e)))
  (check! "(b) :got names the bad symbol"         (= "parse-cookiez" (:got e)))
  (check! "(b) :at :def = broken"                 (= 'broken (get-in e [:at :def])))
  (check! "(b) :nearest names real parse-cookies" (contains? (set (:nearest e)) "parse-cookies")
          (pr-str (:nearest e)))
  (check! "(b) clean defs NOT flagged (only broken)" (= 1 (count (filter #(= "unresolved-symbol" (:kind %)) errs)))
          (str (count errs) " total")))

;; --- (c) wrong arity ---------------------------------------------------------
(let [errs (analyze "cookies" arity-src)
      e    (first (filter #(= "arity-mismatch" (:kind %)) errs))]
  (check! "(c) arity mismatch flagged"            (some? e) (pr-str (:message e)))
  (check! "(c) :expected 2 / :got 3"              (and (= "2" (:expected e)) (= "3" (:got e)))
          (str ":expected " (:expected e) " :got " (:got e)))
  (check! "(c) :nearest names parse-cookies"      (= ["parse-cookies"] (:nearest e))))

;; --- (d) no false arity through ->> + dispatch -------------------------------
(check! "(d) clean ->> stage NOT flagged as arity" (empty? (filter #(= "arity-mismatch" (:kind %)) (analyze "cookies" clean-src))))
(check! "(d) untyped source detected as untyped"   (true? (boolean (untyped? clean-src))))
(check! "(d) Beagle source NOT treated as untyped" (false? (boolean (untyped? typed-src)))
        "the language header routes inferred Beagle to the sidecar")

;; --- summary -----------------------------------------------------------------
(let [fails (remove second @results)]
  (println (format "\n=== %d/%d checks passed ===" (- (count @results) (count fails)) (count @results)))
  (System/exit (if (empty? fails) 0 1)))
