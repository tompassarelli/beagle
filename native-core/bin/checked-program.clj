(ns native.checked-program
  (:require [cheshire.core :as json])
  (:import [java.math BigInteger]
           [java.security MessageDigest]))

(def schema-version 3)

(defn- canonical-value [value]
  (cond
    (map? value)
    (into (sorted-map)
      (map (fn [[key child]] [key (canonical-value child)]) value))

    (sequential? value)
    (mapv canonical-value value)

    :else value))

(defn projection-digest [ast]
  (let [payload (dissoc ast "projectionSha256")
        canonical-json (json/generate-string (canonical-value payload))
        digest (MessageDigest/getInstance "SHA-256")]
    (.update digest (.getBytes canonical-json "UTF-8"))
    (str "sha256:" (format "%064x" (BigInteger. 1 (.digest digest))))))

(defn with-projection-digest [ast]
  (assoc ast "projectionSha256" (projection-digest ast)))

(defn- checked-program-error! [consumer source-path path detail data]
  (throw
    (ex-info
      (str consumer " rejected checked-program schemaVersion " schema-version
           " at " path ": " detail ": " source-path)
      (merge {:source-path source-path
              :schema-version schema-version
              :path path}
             data))))

(defn- validate-binding-constraint-contract!
  [value consumer source-path path]
  (when (contains? value "constraint")
    (when-not (contains? value "constraintSynchronous")
      (checked-program-error! consumer source-path path
        "binding/field declaration is missing checker-owned constraintSynchronous"
        {:constraint (get value "constraint")}))
    (let [constraint (get value "constraint")
          synchronous (get value "constraintSynchronous")]
      (when-not (instance? Boolean synchronous)
        (checked-program-error! consumer source-path path
          "constraintSynchronous must be a boolean"
          {:constraint-synchronous synchronous}))
      (when-not (= (some? constraint) synchronous)
        (checked-program-error! consumer source-path path
          (if (some? constraint)
            "non-null constraint requires a positive synchronous proof"
            "null constraint requires constraintSynchronous false")
          {:constraint constraint
           :constraint-synchronous synchronous})))))

(defn- validate-record-update-contract!
  [value consumer source-path path]
  (when (= "with" (get value "node"))
    (when-not (contains? value "recordUpdate")
      (checked-program-error! consumer source-path path
        "with node is missing checker-owned recordUpdate" {}))
    (when-let [contract (get value "recordUpdate")]
      (when-not (and (map? contract)
                     (= #{"recordName" "fieldOrder" "validator"}
                        (set (keys contract)))
                     (string? (get contract "recordName"))
                     (not-empty (get contract "recordName"))
                     (sequential? (get contract "fieldOrder"))
                     (every? #(and (string? %) (not-empty %))
                       (get contract "fieldOrder"))
                     (= (count (get contract "fieldOrder"))
                        (count (distinct (get contract "fieldOrder"))))
                     (or (nil? (get contract "validator"))
                         (and (string? (get contract "validator"))
                              (not-empty (get contract "validator")))))
        (checked-program-error! consumer source-path path
          (str "recordUpdate must be null or exactly "
               "{recordName:string, fieldOrder:[string...], validator:string|null}")
          {:record-update contract})))))

(defn- validate-record-field-access-contract!
  [value consumer source-path path]
  (when (= "kw-access" (get value "node"))
    (when-not (contains? value "recordFieldAccess")
      (checked-program-error! consumer source-path path
        "kw-access node is missing checker-owned recordFieldAccess" {}))
    (when-let [contract (get value "recordFieldAccess")]
      (when-not (and (map? contract)
                     (= #{"recordName"} (set (keys contract)))
                     (string? (get contract "recordName"))
                     (not-empty (get contract "recordName")))
        (checked-program-error! consumer source-path path
          "recordFieldAccess must be null or exactly {recordName:string}"
          {:record-field-access contract})))))

(defn- validate-structural-contracts!
  [value consumer source-path path]
  (cond
    (map? value)
    (do
      (validate-binding-constraint-contract! value consumer source-path path)
      (validate-record-update-contract! value consumer source-path path)
      (validate-record-field-access-contract! value consumer source-path path)
      (doseq [[key child] value]
        (validate-structural-contracts! child consumer source-path
          (str path "." key))))

    (sequential? value)
    (doseq [[position child] (map-indexed vector value)]
      (validate-structural-contracts! child consumer source-path
        (str path "[" position "]")))))

(defn require-checked-program! [ast source-path consumer]
  (when-not (= "beagle.checked-program" (get ast "kind"))
    (throw
      (ex-info
        (str consumer " requires a checked Beagle program: " source-path)
        {:source-path source-path
         :kind (get ast "kind")})))
  (when-not (= schema-version (get ast "schemaVersion"))
    (throw
      (ex-info
        (str consumer " requires checked-program schemaVersion " schema-version
             ", got " (get ast "schemaVersion") ": " source-path)
        {:source-path source-path
         :expected-schema-version schema-version
         :schema-version (get ast "schemaVersion")})))
  (let [expected (get ast "projectionSha256")
        actual (projection-digest ast)]
    (when-not (= expected actual)
      (throw
        (ex-info
          (str consumer " requires an authentic checked-program projection; "
               "projectionSha256 does not match its canonical payload: "
               source-path)
          {:source-path source-path
           :projection-sha256 expected
           :computed-projection-sha256 actual}))))
  (validate-structural-contracts! ast consumer source-path "$")
  ast)
