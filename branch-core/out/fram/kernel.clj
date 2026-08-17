(ns fram.kernel
  (:require [fram.types :as t]
            [clojure.string :as str]))

(def profile-anchor :kernel/profile)

(def ^String relational-profile-kind "relational")

(def ^String observe-profile-mode "observe")

(def ^String profile-includes "includes")

(def ^String profile-violation "violates")

(def relational-profile-rules ["R1" "R2" "R3" "R4"])

(def ^String vocabulary-profile-rule "R5")

(def vocabulary-membership :member_of)

(def ^String kernel-vocabulary-prefix ":kernel/")

(defn profile-header [profile-id ^String kind ^String mode]
  (t/triple profile-id kind mode))

(defn relational-profile-declaration [^String space-id profile-id]
  (t/triple space-id profile-anchor (profile-header profile-id relational-profile-kind observe-profile-mode)))

(defn profile-rule [profile-id ^String rule]
  (t/triple profile-id profile-includes rule))

(defn- ^Boolean profile-anchor? [value]
  (= profile-anchor (t/triple-t2 value)))

(defn- ^Boolean profile-has-rule? [triples profile-id ^String rule]
  (not (empty? (filterv (fn [value] (and (= profile-id (t/triple-t1 value)) (and (= profile-includes (t/triple-t2 value)) (= rule (t/triple-t3 value))))) triples))))

(defn ^Boolean declared-relational-profile? [triples ^String space-id]
  (not (empty? (filterv (fn [value] (let [header (t/triple-t3 value)]
  (and (= space-id (t/triple-t1 value)) (and (profile-anchor? value) (and (t/triple? header) (and (= relational-profile-kind (t/triple-t2 header)) (and (= observe-profile-mode (t/triple-t3 header)) (every? (fn [^String rule] (profile-has-rule? triples (t/triple-t1 header) rule)) relational-profile-rules)))))))) triples))))

(defn- space-profile-ids [triples ^String space-id]
  (mapv (fn [value] (t/triple-t1 (t/triple-t3 value))) (filterv (fn [value] (and (= space-id (t/triple-t1 value)) (and (profile-anchor? value) (t/triple? (t/triple-t3 value))))) triples)))

(defn ^Boolean declared-vocabulary-rule? [triples ^String space-id]
  (not (empty? (filterv (fn [profile-id] (profile-has-rule? triples profile-id vocabulary-profile-rule)) (space-profile-ids triples space-id)))))

(defn- ^Boolean namespaced-vocabulary? [value]
  (if (keyword? value) (let [keyword-value value
   spelling (str keyword-value)]
  (and (str/includes? spelling "/") (not (str/starts-with? spelling kernel-vocabulary-prefix)))) false))

(defn- ^Boolean vocabulary-member? [triples term]
  (not (empty? (filterv (fn [value] (and (= term (t/triple-t1 value)) (= vocabulary-membership (t/triple-t2 value)))) triples))))

(defn vocabulary-lint-errors [triples proposition]
  (let [t2 (t/triple-t2 proposition)]
  (if (and (namespaced-vocabulary? t2) (not (vocabulary-member? triples t2))) [vocabulary-profile-rule] [])))

(defn- ^Boolean nonblank-string-or-keyword? [value]
  (or (keyword? value) (and (string? value) (> (count value) 0))))

(defn relational-admission-errors [proposition]
  (let [t1 (t/triple-t1 proposition)
   t2 (t/triple-t2 proposition)
   t3 (t/triple-t3 proposition)]
  (cond-> [] (not (and (t/atom? t1) (and (t/atom? t2) (t/atom? t3)))) (conj "R1") (not (nonblank-string-or-keyword? t1)) (conj "R2") (not (nonblank-string-or-keyword? t2)) (conj "R3") (not (t/atom? t3)) (conj "R4"))))

(defn relational-lint-errors [proposition]
  (let [t1 (t/triple-t1 proposition)
   t2 (t/triple-t2 proposition)
   t3 (t/triple-t3 proposition)
   r1 (and (t/atom? t1) (and (t/atom? t2) (t/atom? t3)))
   r2 (or (keyword? t1) (and (string? t1) (not (= "" t1))))
   r3 (or (keyword? t2) (and (string? t2) (not (= "" t2))))
   r4 (t/atom? t3)
   errors0 []
   errors1 (if r1 errors0 (conj errors0 "R1"))
   errors2 (if r2 errors1 (conj errors1 "R2"))
   errors3 (if r3 errors2 (conj errors2 "R3"))]
  (if r4 errors3 (conj errors3 "R4"))))

(defn lint-declared-profile [triples ^String space-id]
  (if (not (declared-relational-profile? triples space-id)) [] (let [vocabulary? (declared-vocabulary-rule? triples space-id)]
  (reduce (fn [violations proposition] (if (profile-anchor? proposition) violations (let [relational (relational-lint-errors proposition)
   rules (if vocabulary? (into relational (vocabulary-lint-errors triples proposition)) relational)]
  (reduce (fn [rows ^String rule] (conj rows (t/triple proposition profile-violation rule))) violations rules)))) [] triples))))

(defn ^Boolean triple-eq? [left right]
  (= left right))

(defn by-t1 [triples term]
  (filterv (fn [value] (= term (t/triple-t1 value))) triples))

(defn by-t2 [triples term]
  (filterv (fn [value] (= term (t/triple-t2 value))) triples))

(defn by-t3 [triples term]
  (filterv (fn [value] (= term (t/triple-t3 value))) triples))

(defn by-t12 [triples t1 t2]
  (filterv (fn [value] (and (= t1 (t/triple-t1 value)) (= t2 (t/triple-t2 value)))) triples))

(defn by-t23 [triples t2 t3]
  (filterv (fn [value] (and (= t2 (t/triple-t2 value)) (= t3 (t/triple-t3 value)))) triples))

(defn by-t13 [triples t1 t3]
  (filterv (fn [value] (and (= t1 (t/triple-t1 value)) (= t3 (t/triple-t3 value)))) triples))
