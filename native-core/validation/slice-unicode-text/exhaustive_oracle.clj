(ns native.unicode-text-exhaustive-oracle
  (:import [java.io BufferedOutputStream]
           [java.nio.charset StandardCharsets]
           [java.util Locale]
           [java.util.regex Pattern]))

(def unicode-scalar-pattern
  (Pattern/compile "[\\p{L}\\p{Nd}]+"))

(defn scalar-string ^String [^long codepoint]
  (String. (Character/toChars (int codepoint))))

(defn emit-record!
  [^BufferedOutputStream output
   ^long codepoint]
  (let [source (scalar-string codepoint)
        member (.matches (.matcher ^Pattern unicode-scalar-pattern source))
        lowered (.toLowerCase ^String source Locale/ROOT)
        bytes (.getBytes ^String lowered StandardCharsets/UTF_8)
        length (alength bytes)]
    (when (> length 255)
      (throw (ex-info "lowercase mapping exceeds record encoding"
                      {:codepoint codepoint :length length})))
    (.write output (if member 1 0))
    (.write output length)
    (.write output bytes 0 length)))

(defn -main [& _]
  (let [output (BufferedOutputStream. System/out (* 1024 1024))]
    (loop [codepoint 0]
      (when (<= codepoint 0x10ffff)
        (when-not (<= 0xd800 codepoint 0xdfff)
          (emit-record! output codepoint))
        (recur (unchecked-inc codepoint))))
    (.flush output)))

(apply -main *command-line-args*)
