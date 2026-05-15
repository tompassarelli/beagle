(when-not (= (r/safe-upper "hello") "hello") (System/exit 1))
(when-not (= (r/safe-upper nil) "N/A") (System/exit 1))
(when-not (= (r/safe-upper "world") "world") (System/exit 1))
(System/exit 0)
