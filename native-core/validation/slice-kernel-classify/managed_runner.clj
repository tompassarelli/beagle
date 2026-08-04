(require '[clojure.string :as str])
(require '[fram.kernel-classify :as k])
(import '[java.nio.charset StandardCharsets])

(def ^String hex-digits "0123456789abcdef")

(defn utf8-hex [^String value]
  (apply str
    (mapcat
      (fn [byte]
        (let [n (bit-and (int byte) 0xff)]
          [(.charAt hex-digits (bit-shift-right n 4))
           (.charAt hex-digits (bit-and n 0x0f))]))
      (.getBytes value StandardCharsets/UTF_8))))

(defn decode-hex [encoded]
  (when (odd? (count encoded))
    (throw (ex-info "odd-length hex string" {:encoded encoded})))
  (String.
    (byte-array
      (map
        (fn [offset]
          (unchecked-byte
            (Integer/parseInt (subs encoded offset (+ offset 2)) 16)))
        (range 0 (count encoded) 2)))
    StandardCharsets/UTF_8))

(defn emit-string [op index value]
  (println (str op "\t" index "\t" (utf8-hex value))))

(defn emit-bool [op index value]
  (println (str op "\t" index "\t" (if value "1" "0"))))

(defn emit-lease [op index lease]
  (println
    (str op "\t" index "\t"
      (utf8-hex (k/leaseparts-holder lease)) "\t"
      (k/leaseparts-exp lease) "\t"
      (k/leaseparts-epoch lease) "\t"
      (if (k/leaseparts-valid lease) "1" "0"))))

(defn require-arity [op fields expected]
  (when-not (= expected (count fields))
    (throw
      (ex-info "wrong corpus arity"
        {:op op :expected expected :actual (count fields)}))))

(defn parse-bool [value]
  (case value
    "0" false
    "1" true
    (throw (ex-info "invalid corpus boolean" {:value value}))))

(defn run-case [index fields]
  (let [op (first fields)
        args (rest fields)]
    (case op
      "string"
      (do
        (require-arity op args 1)
        (let [value (decode-hex (first args))]
          (emit-string "stripAt" index (k/strip-at value))
          (emit-bool "hasWhitespace" index (k/has-whitespace? value))
          (emit-bool "refShape" index (k/ref-shape? value))))

      "predicate"
      (do
        (require-arity op args 4)
        (let [[predicate & configured-hex] args
              predicate (decode-hex predicate)
              configured (mapv decode-hex configured-hex)]
          (emit-bool "vecMember" index (k/vec-member? configured predicate))
          (emit-bool "configuredSingle" index
            (k/configured-single? configured predicate))
          (emit-bool "emojiSingle" index (k/emoji-single? predicate))))

      "meta"
      (do
        (require-arity op args 1)
        (emit-bool "metaSingleSeed" index
          (k/meta-single-seed? (decode-hex (first args)))))

      "single"
      (do
        (require-arity op args 4)
        (let [[declared-present declared-single configured predicate] args]
          (emit-bool "singleEff" index
            (k/single-eff?
              (parse-bool declared-present)
              (parse-bool declared-single)
              (parse-bool configured)
              (decode-hex predicate)))))

      "group"
      (do
        (require-arity op args 2)
        (let [[left predicate] (map decode-hex args)]
          (emit-string "keyOfGroup" index (k/key-of-group left predicate))))

      "triple"
      (do
        (require-arity op args 3)
        (let [[left predicate right] (map decode-hex args)]
          (emit-string "keyOfTriple" index
            (k/key-of-triple left predicate right))))

      "normalize"
      (do
        (require-arity op args 2)
        (let [[value-kind value] (map decode-hex args)]
          (emit-string "normalizeRefValue" index
            (k/normalize-ref-value value-kind value))))

      "lease-subject"
      (do
        (require-arity op args 1)
        (emit-string "leaseSubject" index
          (k/lease-subject (decode-hex (first args)))))

      "lease-encode"
      (do
        (require-arity op args 3)
        (let [[holder exp epoch] args]
          (emit-string "leaseEncode" index
            (k/lease-encode
              (decode-hex holder)
              (Long/parseLong exp)
              (Long/parseLong epoch)))))

      "lease-decode"
      (do
        (require-arity op args 1)
        (emit-lease "leaseDecode" index
          (k/lease-decode (decode-hex (first args)))))

      "lease-invalid"
      (do
        (require-arity op args 0)
        (emit-lease "leaseInvalid" index (k/lease-invalid)))

      "delivery"
      (do
        (require-arity op args 1)
        (emit-bool "deliveryTrigger" index
          (k/delivery-trigger? (decode-hex (first args)))))

      (throw (ex-info "unknown corpus operation" {:op op})))))

(def corpus-path
  (or (first *command-line-args*)
      (throw (ex-info "missing corpus path" {}))))

(loop [lines (str/split-lines (slurp corpus-path))
       index 0]
  (when-let [line (first lines)]
    (if (or (str/blank? line) (str/starts-with? line "#"))
      (recur (rest lines) index)
      (do
        (run-case index (str/split line #"\|" -1))
        (recur (rest lines) (inc index))))))

(doseq [[index value] (map-indexed vector k/fallback-single)]
  (emit-string "fallbackSingle" index value))

(emit-string "keySep" 0 k/key-sep)

(doseq [[index value] (map-indexed vector k/lease-schema-lines)]
  (emit-string "leaseSchemaLine" index value))
