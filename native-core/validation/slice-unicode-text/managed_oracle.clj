(ns native.unicode-text-oracle)

(defn lower-root [value]
  (.toLowerCase ^String value java.util.Locale/ROOT))

(defn letter-decimal-runs [value]
  (re-seq #"[\p{L}\p{Nd}]+" value))

(defn codepoint-string [value]
  (String. (Character/toChars value)))

(defn age-boundary-source []
  (str (codepoint-string 0x1e4d0) "-"
       (codepoint-string 0x1e4f0) "-"
       (codepoint-string 0x2ebf0) "-"
       (codepoint-string 0x10d40)))

(defn age-boundary-runs []
  [(codepoint-string 0x1e4d0) (codepoint-string 0x1e4f0)])
