(ns fram.json
  "Insertion-order JSON handle for the time module (ported from los.json).
  Handle is a vector of [key val-descriptor] pairs preserving order.
  Val-descriptor is {:type :string/:null/:raw, :val s-or-nil}.")

(require '[cheshire.core :as json])

(defn parse [s]
  (let [parsed (json/parse-string s false)]
    (mapv (fn [[k v]]
            [k (cond
                 (string? v) {:type :string :val v}
                 (nil? v)    {:type :null}
                 :else       {:type :raw :val (json/generate-string v)})])
          parsed)))

(defn to-string [j]
  (let [sb (StringBuilder.)]
    (.append sb "{")
    (dotimes [i (count j)]
      (when (pos? i) (.append sb ","))
      (let [[k desc] (nth j i)]
        (.append sb (json/generate-string k))
        (.append sb ":")
        (case (:type desc)
          :string (.append sb (json/generate-string (:val desc)))
          :null   (.append sb "null")
          :raw    (.append sb (:val desc)))))
    (.append sb "}")
    (.toString sb)))

(defn get [j k]
  (some (fn [[key desc]]
          (when (= key k)
            (case (:type desc)
              :string (:val desc)
              :null   nil
              :raw    nil)))
        j))

(defn get-raw [j k]
  (some (fn [[key desc]]
          (when (= key k)
            (case (:type desc)
              :string (:val desc)
              :null   nil
              :raw    (:val desc))))
        j))

(defn put [j k value]
  (let [desc (if (nil? value) {:type :null} {:type :string :val value})
        existing (some (fn [[i [ek _]]] (when (= ek k) i))
                       (map-indexed vector j))]
    (if existing
      (assoc j existing [k desc])
      (conj j [k desc]))))

(defn put-raw [j k value]
  (let [desc (if (nil? value) {:type :null} {:type :raw :val value})
        existing (some (fn [[i [ek _]]] (when (= ek k) i))
                       (map-indexed vector j))]
    (if existing
      (assoc j existing [k desc])
      (conj j [k desc]))))

(defn empty [] [])

(defn keys [j] (mapv first j))

(defn sort-keys [j]
  (vec (sort-by first j)))
