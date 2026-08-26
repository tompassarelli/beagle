(ns demo.offset)

(defn tail-offset [text amount]
  (let [offset (+ amount 1)]
    (subs text offset)))
