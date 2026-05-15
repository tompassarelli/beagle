(when-not (= (count r/demo-result) 2) (System/exit 1))
(when-not (= (nth r/demo-result 0) "Alice") (System/exit 1))
(when-not (= (nth r/demo-result 1) "Eve") (System/exit 1))
;; Test active-only filters correctly
(let [active (r/active-only [["A" 1 true] ["B" 2 false] ["C" 3 true]])]
  (when-not (= (count active) 2) (System/exit 1)))
;; Test fill-score replaces nil
(let [filled (r/fill-score [["A" nil true] ["B" 50 true]])]
  (when-not (= (nth (nth filled 0) 1) 0) (System/exit 1))
  (when-not (= (nth (nth filled 1) 1) 50) (System/exit 1)))
;; Test top-scorers threshold
(let [tops (r/top-scorers [["A" 90 true] ["B" 50 true] ["C" 81 true]])]
  (when-not (= (count tops) 2) (System/exit 1)))
(System/exit 0)
