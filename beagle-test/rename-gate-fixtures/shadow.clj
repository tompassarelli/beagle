(ns shadow)

^{:line 4 :file "/tmp/fsweep/shadow.bclj"} (def b 99)

^{:line 6 :file "/tmp/fsweep/shadow.bclj"} (defprotocol Area
  (area [self]))

^{:line 9 :file "/tmp/fsweep/shadow.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 11 :file "/tmp/fsweep/shadow.bclj"} (defn other []
  b)

^{:line 13 :file "/tmp/fsweep/shadow.bclj"} (extend-type Box
  Area
  (area [b]
    ^{:line 15 :file "/tmp/fsweep/shadow.bclj"} (box-w b)))
