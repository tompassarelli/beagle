(when-not (= r/r1 "7") (System/exit 1))
(when-not (= r/r2 "error") (System/exit 1))
(when-not (= r/r3 "-7") (System/exit 1))
;; Test direct eval
(when-not (= (r/eval-expr 42) 42) (System/exit 1))
(when-not (= (r/eval-expr [:add 10 20]) 30) (System/exit 1))
(when-not (= (r/eval-expr [:mul 3 [:add 1 1]]) 6) (System/exit 1))
(when-not (nil? (r/eval-expr [:div 1 0])) (System/exit 1))
;; Nil propagation
(when-not (nil? (r/eval-expr [:add 1 [:div 1 0]])) (System/exit 1))
(System/exit 0)
