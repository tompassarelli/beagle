(ns store.kernel-classify
  (:require [clojure.string :as str]))

(defn ^String strip-at [^String s]
  (if (str/starts-with? s "@") (subs s 1) s))

(defn ^Boolean has-whitespace? [^String s]
  (or (str/includes? s "\t") (str/includes? s "\n") (str/includes? s "\u000b") (str/includes? s "\f") (str/includes? s "\r") (str/includes? s " ")))

(defn ^Boolean ref-shape? [^String s]
  (and (> (count s) 1) (str/starts-with? s "@") (not (has-whitespace? s))))

(def fallback-single ["title" "owner" "lead" "driver" "source" "part_of" "do_on" "valid_until" "estimate_hours" "created_at" "updated_at" "name" "body" "created_by" "committed" "outcome" "abandoned" "superseded_by" "merged_into" "session_of" "start_time" "end_time" "clockify_id"])

(defn ^Boolean vec-member? [xs ^String s]
  (loop [i 0]
  (if (>= i (count xs)) false (if (= (nth xs i) s) true (recur (+ i 1))))))

(defn ^Boolean emoji-single? [^String p]
  (str/starts-with? p "emoji_"))

(defn ^Boolean configured-single? [configured ^String p]
  (vec-member? configured p))

(defn ^Boolean meta-single-seed? [^String p]
  (or (= p "cardinality") (= p "value_kind") (= p "name") (= p "acyclic") (= p "predicate_name")))

(defn ^Boolean single-eff? [^Boolean declared-present ^Boolean declared-single ^Boolean configured ^String p]
  (if declared-present declared-single (or configured (vec-member? fallback-single p) (emoji-single? p))))

(def ^String key-sep "\u0001")

(defn ^String key-of-group [^String l ^String p]
  (str l key-sep p))

(defn ^String key-of-triple [^String l ^String p ^String r]
  (str l key-sep p key-sep r))

(defn ^String normalize-ref-value [^String value-kind ^String r]
  (if (and (= "ref" value-kind) (not (str/starts-with? r "@")) (not (str/blank? r)) (not (has-whitespace? r))) (str "@" r) r))

(defrecord LeaseParts [holder exp epoch valid])

(defn leaseparts-holder [r] (:holder r))

(defn leaseparts-exp [r] (:exp r))

(defn leaseparts-epoch [r] (:epoch r))

(defn leaseparts-valid [r] (:valid r))

(defn ^LeaseParts lease-invalid []
  (->LeaseParts "" 0 0 false))

(defn ^String lease-subject [^String res]
  (str "@lease:" res))

(defn ^String lease-encode [^String holder exp epoch]
  (str holder "|" exp "|" epoch))

(defn ^LeaseParts lease-decode [^String v]
  (let [cut1 (str/index-of v "|")]
  (if (nil? cut1) (lease-invalid) (let [cut1-position cut1
   ^String holder (subs v 0 cut1-position)
   ^String tail (subs v (+ cut1-position 1))
   cut2 (str/index-of tail "|")]
  (if (nil? cut2) (lease-invalid) (let [cut2-position cut2
   ^String exp-s (subs tail 0 cut2-position)
   ^String epoch-s (subs tail (+ cut2-position 1))
   extra (str/index-of epoch-s "|")]
  (if (some? extra) (lease-invalid) (let [exp (parse-long exp-s)
   epoch (parse-long epoch-s)]
  (if (nil? exp) (lease-invalid) (if (nil? epoch) (lease-invalid) (let [present-exp exp
   present-epoch epoch]
  (->LeaseParts holder present-exp present-epoch true))))))))))))

(def lease-schema-lines ["@lease cardinality single" "@lease value_kind literal"])

(defn ^Boolean delivery-trigger? [^String p]
  (or (= p "to") (= p "target")))
