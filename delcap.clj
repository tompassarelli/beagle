(ns delcap)

^{:line 4 :file "/tmp/fsweep/delcap.bclj"} (def b 7)

^{:line 6 :file "/tmp/fsweep/delcap.bclj"} (defprotocol Area
  (area [self]))

^{:line 9 :file "/tmp/fsweep/delcap.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 11 :file "/tmp/fsweep/delcap.bclj"} (extend-type Box
  Area
  (area [b]
    ^{:line 13 :file "/tmp/fsweep/delcap.bclj"} (box-w b)))
