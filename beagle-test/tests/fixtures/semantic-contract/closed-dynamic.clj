(ns semantic-contract.closed-dynamic)

(defn dyn-string [^String value]
  value)

(defn dyn-int [value]
  value)

(defn dyn-bool [^Boolean value]
  value)

(defn dyn-vector [value]
  value)

(defn dyn-map [value]
  value)

(defn round-trip [value]
  value)

(defn ^String observe [value]
  (if (string? value) (str "string:" value) (if (integer? value) (str "int:" value) (if (boolean? value) (str "bool:" value) (if (vector? value) (str "vec:" (count value)) (if (map? value) "map" "unreachable"))))))
