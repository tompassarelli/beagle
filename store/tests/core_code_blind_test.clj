#!/usr/bin/env bb
;; core_code_blind_test.clj — the fold guard (corrected, predicate-precise).
;;
;; INVARIANT: store-core (src/store/*.bclj — the GENERIC facts + Datalog engine) must
;; stay BLIND to beagle-as-SUBJECT. This exists so that folding codegraph (beagle
;; source code-intelligence) into this repo cannot let beagle-shaped logic seep into
;; the generic core once the cross-repo friction that used to enforce that seam is gone.
;;
;; TWO axes of "depends on beagle" must NOT be confused:
;;   axis 1 (cosmetic) — store-core is AUTHORED in beagle. `(defn ..)`, `(ns ..)`,
;;       `(:require ..)` appear as IMPLEMENTATION. Fine. Dissolves on a reimplementation
;;       in another language. This guard must NOT flag it.
;;   axis 2 (real)     — store-core reasons OVER beagle syntax as DATA: "defn"/"defrecord"/
;;       "beagle-file" as QUOTED string literals it matches/dispatches on. Survives a
;;       reimplementation = genuine subject-matter coupling. THIS is the only leak we ban.
;;
;; Falsifiable test for the ban-set: "would this token survive a reimplementation
;; in another language?"
;;   `(defn f [..] ..)`            -> dissolves -> axis 1 -> NOT banned.
;;   `(contains? DEF-FORMS "defn")`-> survives  -> axis 2 -> BANNED.
;;
;; The ban-set MIRRORS codegraph's actual beagle-as-subject signature (resolve.clj's
;; PARAM-FORMS/TYPE-DEFS/... string-head sets). It deliberately does NOT include generic
;; graph vocabulary (calls, refers_to — domain-neutral edge labels any facts domain may
;; use) nor beagle import keywords (:require/:as/:refer — those appear in store's OWN ns
;; forms as axis-1 implementation). It matches QUOTED tokens in CODE (comment lines skipped),
;; anchored to the quotes, never bare substrings (so "recalls"/"syscalls"/prose don't trip).
;;
;; The folded codegraph module lives OUTSIDE src/store/ (its own build target) and is
;; intentionally exempt — its whole job is beagle-as-subject.

(require '[clojure.string :as str])

(def core-dir "src/store")

;; beagle-as-subject form heads — unambiguous code-structure markers with no generic
;; meaning in a facts engine. Matched only as DOUBLE-QUOTED string literals.
(def banned-quoted
  ["defn" "defn-" "defmacro" "def-" "defonce"
   "defrecord" "deftype" "defprotocol" "definterface" "defunion"
   "extend-type" "extend-protocol" "letfn"])

;; the beagle AST wrapper node — store-core would never legitimately name it (quoted or bare).
(def banned-bare ["beagle-file"])

(def quoted-re
  (re-pattern (str "\"(" (str/join "|" banned-quoted) ")\"")))
(def bare-re
  (re-pattern (str "\\b(" (str/join "|" banned-bare) ")\\b")))

(defn comment-line? [line]
  (str/starts-with? (str/triml line) ";"))

(defn scan-file [path]
  (->> (str/split-lines (slurp path))
       (map-indexed (fn [i line] [(inc i) line]))
       (remove (fn [[_ line]] (comment-line? line)))
       (keep (fn [[n line]]
               (when (or (re-find quoted-re line) (re-find bare-re line))
                 [path n (str/trim line)])))))

(def core-files
  (->> (file-seq (clojure.java.io/file core-dir))
       (filter #(.isFile %))
       (map #(.getPath %))
       (filter #(str/ends-with? % ".bclj"))
       sort))

(def hits (mapcat scan-file core-files))

(println "== core-code-blind guard ==")
(println (str "  scanned " (count core-files) " generic-core files under " core-dir "/"))
(if (empty? hits)
  (do
    (println "  PASS — store-core is blind to beagle-as-subject (axis-2 clean).")
    (println "         (axis-1 authored-in-beagle usage is correctly ignored.)"))
  (do
    (println "  FAIL — beagle-as-subject leaked into the generic core:")
    (doseq [[f n line] hits]
      (println (str "    " f ":" n "  " line)))
    (System/exit 1)))
