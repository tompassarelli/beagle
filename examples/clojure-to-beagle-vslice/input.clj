(ns demo.parity)

(declare odd-step)

(defn even-step [n]
  (if (zero? n)
    true
    (odd-step (dec n))))

(defn odd-step [n]
  (if (zero? n)
    false
    (even-step (dec n))))
