;; store_invariant_test.clj — the one-engine invariant: the store kernel is
;; DOMAIN-AGNOSTIC. Fails if any life-os or code vocabulary appears in kernel
;; CODE (comments stripped — the header legitimately names forbidden terms as
;; examples of what must not leak in).
;;   bb store_invariant_test.clj
(require '[clojure.string :as str])

(def src (slurp "src/store/store.bclj"))
;; strip each line from its first `;` (beagle comment) — no `;` occurs in code strings here.
(def code (->> (str/split-lines src)
               (map (fn [l] (let [i (str/index-of l ";")] (if i (subs l 0 i) l))))
               (str/join "\n")
               str/lower-case))

;; life-os (app A) + code-as-facts (app B) DATA vocabulary. NOT the language
;; pragma `#lang beagle` — `beagle` is the language, not a domain term.
(def forbidden
  ["thread" "title" "owner" "clock" "driver" "work_phase" "work-phase"
   "depends_on" "relates_to" "session" "estimate" "outcome" "abandoned"
   "committed" "assignee" "param" "lambda" " ast " "binding" "defrecord-fn"])

(def hits (filterv (fn [w] (str/includes? code w)) forbidden))

(if (empty? hits)
  (println "store domain-agnostic invariant: PASS — kernel code mentions no domain vocabulary")
  (do (println "store domain-agnostic invariant: FAIL — leaked:" hits) (System/exit 1)))
