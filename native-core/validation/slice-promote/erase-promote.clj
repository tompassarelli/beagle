;; Driver input for the hosted-identity clause: rewrite every
;; `(bgl/promote EXPR)` to `EXPR`, paren-matched, leaving every other byte and
;; every line break alone. The erased twin therefore has the same line numbers
;; as the original, which is what lets the emitted Clojure be compared byte for
;; byte instead of "modulo formatting".
(let [[in out] *command-line-args*
      opener "(bgl/promote "]
  (spit
   out
   (loop [text (slurp in)]
     (let [start (.indexOf text opener)]
       (if (neg? start)
         text
         (let [body (+ start (count opener))
               close (loop [index body depth 1]
                       (let [character (.charAt text index)]
                         (cond
                           (= character \() (recur (inc index) (inc depth))
                           (= character \)) (if (= depth 1)
                                              index
                                              (recur (inc index) (dec depth)))
                           :else (recur (inc index) depth))))]
           (recur (str (subs text 0 start)
                       (subs text body close)
                       (subs text (inc close))))))))))
