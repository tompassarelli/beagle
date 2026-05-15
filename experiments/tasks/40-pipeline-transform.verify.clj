(when-not (= r/result [3 5 7]) (System/exit 1))
(when-not (= (r/process-scores [10 11 12 13]) [11 13]) (System/exit 1))
(when-not (= (r/process-scores []) []) (System/exit 1))
(System/exit 0)
