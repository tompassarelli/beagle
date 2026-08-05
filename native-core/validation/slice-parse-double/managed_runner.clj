(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[native.parse-double-managed :as fixture])
(import '(java.nio.charset StandardCharsets))

(defn decode-hex [text]
  (when (odd? (count text))
    (throw (ex-info "odd-length hex input" {:hex text})))
  (String.
    (byte-array
      (map (fn [position]
             (unchecked-byte
               (Integer/parseInt (subs text position (+ position 2)) 16)))
           (range 0 (count text) 2)))
    StandardCharsets/UTF_8))

(let [[corpus-path] *command-line-args*]
  (when (nil? corpus-path)
    (throw (ex-info "usage: managed_runner.clj CORPUS" {})))
  (with-open [reader (io/reader corpus-path)]
    (doseq [line (line-seq reader)]
      (let [[case-id input-hex expected-present-text expected-bits-text]
            (str/split line #"\t" -1)
            text (decode-hex input-hex)
            value (fixture/parse-value text)
            actual-present (some? value)
            predicate-present (fixture/parsed? text)
            actual-bits (if actual-present
                          (Double/doubleToLongBits (double value))
                          0)
            expected-present (= "1" expected-present-text)
            expected-bits (Long/parseUnsignedLong expected-bits-text 16)]
        (when (not= actual-present predicate-present)
          (throw (ex-info "parse-value and parsed? disagree" {:case case-id})))
        (when (or (not= actual-present expected-present)
                  (not= actual-bits expected-bits))
          (throw
            (ex-info "managed parse-double differs from the JVM corpus"
              {:case case-id
               :expected-present expected-present
               :actual-present actual-present
               :expected-bits expected-bits-text
               :actual-bits (format "%016x" actual-bits)})))
        (printf "%s\t%d\t%016x%n"
          case-id (if actual-present 1 0) actual-bits)))))
