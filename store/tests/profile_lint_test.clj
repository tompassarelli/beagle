;; W19a slice 1: turtles-native declaration, advisory relational lint, and P3.
;;   env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp out tests/profile_lint_test.clj
;;   BEAGLE_STORE_PROFILE_CORPUS=docs/private/w19a-corpus/coordination.log ...
(require '[clojure.edn :as edn]
         '[clojure.java.io :as io]
         '[store.kernel :as kernel]
         '[store.types :as t])

(def space-id "north-corpus")
(def profile-id "relational-v1")
(def declaration (kernel/relational-profile-declaration space-id profile-id))
(def rule-triples (mapv #(kernel/profile-rule profile-id %)
                        kernel/relational-profile-rules))
(def profile-triples (into [declaration] rule-triples))

(defn violation-rules [violations]
  (mapv t/triple-t3 violations))

(defn lint-one [proposition]
  (violation-rules
   (kernel/lint-declared-profile
    (conj profile-triples proposition) space-id)))

;; R5 is opt-in, so it needs a second profile that lists it beside R1-R4.
(def vocabulary-profile-id "relational-vocabulary-v1")
(def vocabulary-profile-triples
  (into [(kernel/relational-profile-declaration space-id
                                                vocabulary-profile-id)]
        (mapv #(kernel/profile-rule vocabulary-profile-id %)
              (conj kernel/relational-profile-rules
                    kernel/vocabulary-profile-rule))))

(defn lint-vocabulary [propositions]
  (violation-rules
   (kernel/lint-declared-profile
    (into vocabulary-profile-triples propositions) space-id)))

(def fact-profile-id "fact-v1")
(def fact-profile-kind "fact-oriented")
(def fact-profile-declaration
  (t/triple space-id kernel/profile-anchor
            (kernel/profile-header fact-profile-id fact-profile-kind
                                   kernel/observe-profile-mode)))
(def fact-profile-triples
  [fact-profile-declaration
   (kernel/profile-rule fact-profile-id
                        kernel/fact-normal-form-profile-rule)])

(defn lint-facts [propositions]
  (violation-rules
   (kernel/lint-declared-profile
    (into fact-profile-triples propositions) space-id)))

(def namespaced-predicate (keyword "contact" "email"))
(def namespaced-write
  (t/triple "Alice" namespaced-predicate "alice@example.com"))
(def membership-assertion
  (t/triple namespaced-predicate kernel/vocabulary-membership
            :contact_relations))
(def kernel-write (t/triple "north-corpus" :kernel/tx-sequence 1842))

(def scoped-contact-relation
  (t/triple :contactable_at :within "directory-a"))
(def fact-relationships
  [(t/triple scoped-contact-relation kernel/vocabulary-membership
             :relationships)
   (t/triple "Alice" scoped-contact-relation "alice@example.com")])
(def reified-field-memberships
  (mapv #(t/triple % kernel/vocabulary-membership :relationships)
        [:relation :subject :slot :value]))
(def opaque-row-id "contact-row-01")
(def reified-contact-row
  [(t/triple opaque-row-id :relation :contactable_at)
   (t/triple opaque-row-id :subject "Alice")
   (t/triple opaque-row-id :slot "address")
   (t/triple opaque-row-id :value "alice@example.com")])
(def implicit-contact
  (t/triple "Alice" :contactable_at "alice@example.com"))

(def negative-corpus
  [(t/triple (t/triple "nested" "subject" 1) "predicate" "value")
   (t/triple "" "predicate" "value")
   (t/triple "subject" 7 "value")
   (t/triple "subject" "predicate" (t/triple "nested" "value" 1))
   (t/->Triple "subject" "predicate" nil)
   (t/->Triple "subject" "predicate" [])
   ;; A namespace-shaped spelling has no bootstrap privilege after the amendment.
   (t/triple "north-corpus" (keyword "space" "profile")
             (t/triple "legacy" "relational" "observe"))])

(defn p3-agrees? [proposition]
  (= (sort (kernel/relational-admission-errors proposition))
     (sort (kernel/relational-lint-errors proposition))))

(def checks
  [["profile declaration uses the one primitive anchoring predicate"
    (= kernel/profile-anchor (t/triple-t2 declaration))]
   ["profile header and R1-R4 are ordinary reachable triples"
    (kernel/declared-relational-profile? profile-triples space-id)]
   ["missing one declared rule leaves the profile unbound"
    (not (kernel/declared-relational-profile?
          (vec (butlast profile-triples)) space-id))]
   ["undeclared spaces preserve freeform behavior"
    (empty? (kernel/lint-declared-profile negative-corpus space-id))]
   ["primitive anchor alone receives the bootstrap exemption"
    (= ["R1" "R4"] (lint-one (last negative-corpus)))]
   ["relational R1-R4 accept north's string-predicate write shape"
    (empty? (lint-one (t/triple "@thread" "progress" "")))]
   ["P3 admission and lint verdicts agree on the differential corpus"
    (every? p3-agrees? negative-corpus)]
   ["negative corpus exercises every relational rule"
    (= #{"R1" "R2" "R3" "R4"}
       (set (mapcat kernel/relational-lint-errors negative-corpus)))]
   ["R5 binds only where the profile lists it"
    (and (kernel/declared-vocabulary-rule? vocabulary-profile-triples space-id)
         (not (kernel/declared-vocabulary-rule? profile-triples space-id)))]
   ["R5 rejects a namespaced predicate whose membership is unasserted"
    (= ["R5"] (lint-vocabulary [namespaced-write]))]
   ["R5 accepts the same predicate once its membership is asserted"
    (empty? (lint-vocabulary [namespaced-write membership-assertion]))]
   ["a space that omits R5 keeps its namespaced spellings"
    (empty? (lint-one namespaced-write))]
   ["R5 exempts the engine's primitive :kernel/ vocabulary"
    (empty? (lint-vocabulary [kernel-write]))]
   ["FNF-only profile admits an explicitly membered recursive relation Term"
    (and (not (kernel/declared-relational-profile?
               fact-profile-triples space-id))
         (empty? (lint-facts fact-relationships)))]
   ["FNF rejects an opaque relation/subject/slot/value fact row"
    (= ["FNF" "FNF" "FNF" "FNF"]
       (lint-facts (into reified-field-memberships
                         reified-contact-row)))]
   ["FNF rejects an implicit unmembered relation"
    (= ["FNF"] (lint-facts [implicit-contact]))]
   ["FNF rejects namespaced domain vocabulary despite explicit membership"
    (= ["FNF"] (lint-facts [namespaced-write membership-assertion]))]
   ["non-FNF profiles leave fact-oriented admission out of scope"
    (empty? (lint-one implicit-contact))]
   ["FNF leaves closed kernel and RPC vocabulary out of scope"
    (empty? (lint-facts [kernel-write
                         (t/triple "north-corpus" :rpc/request "open")]))]])

(defn read-corpus [path]
  (with-open [reader (io/reader path)]
    (doall (map edn/read-string (line-seq reader)))))

(defn row-triple [row]
  (t/triple (:l row) (:p row) (:r row)))

(defn apply-row [live row]
  (let [proposition (row-triple row)]
    (if (= "retract" (:op row))
      (disj live proposition)
      (conj live proposition))))

(defn predicate-label [proposition]
  (pr-str (t/triple-t2 proposition)))

(defn corpus-census! [path]
  (let [rows (read-corpus path)
        asserted (mapv row-triple (filter #(= "assert" (:op %)) rows))
        live (vec (reduce apply-row #{} rows))
        lint-input (into profile-triples live)
        violations (kernel/lint-declared-profile lint-input space-id)
        by-predicate (frequencies
                      (map #(predicate-label (t/triple-t1 %)) violations))
        p3-mismatches (count (remove p3-agrees? asserted))]
    (println "CORPUS" path)
    (println "ROWS" (count rows))
    (println "ASSERT_WRITES" (count asserted))
    (println "LIVE_PROPOSITIONS" (count live))
    (println "PROFILE_VIOLATIONS" (count violations))
    (println "P3_MISMATCHES" p3-mismatches)
    (println "VIOLATIONS_BY_PREDICATE")
    (if (empty? by-predicate)
      (println "<none>\t0")
      (doseq [[predicate count] (sort-by key by-predicate)]
        (println (str predicate "\t" count))))))

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\nprofile lint:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\nprofile lint:" (count failures) "FAILED")
      (System/exit 1))))

(when-let [path (System/getenv "BEAGLE_STORE_PROFILE_CORPUS")]
  (corpus-census! path))
