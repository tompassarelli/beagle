(when-not (= r/result "HELLO!") (System/exit 1))
(when-not (= (r/shout "world") "WORLD!") (System/exit 1))
(System/exit 0)
