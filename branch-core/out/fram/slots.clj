(ns fram.slots)

(def empty-positions [])

(def empty-slots [])

(defn fresh-slots [width]
  (loop [slots empty-slots
   position 0]
  (if (>= position width) slots (recur (conj slots (atom empty-positions)) (inc position)))))

(defn slot-of [value width]
  (mod (hash value) width))

(defn slot-add! [slots slot position]
  (do
  (swap! (nth slots slot) conj position)
  slots))

(defn slot-positions [slots slot]
  (deref (nth slots slot)))
