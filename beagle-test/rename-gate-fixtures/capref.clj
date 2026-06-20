(ns capref)

^{:line 4 :file "/tmp/fsweep/capref.bclj"} (def scale 2)

^{:line 6 :file "/tmp/fsweep/capref.bclj"} (defprotocol Area
  (area [self]))

^{:line 9 :file "/tmp/fsweep/capref.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 11 :file "/tmp/fsweep/capref.bclj"} (extend-type Box
  Area
  (area [b]
    ^{:line 13 :file "/tmp/fsweep/capref.bclj"} (* ^{:line 13 :file "/tmp/fsweep/capref.bclj"} (box-w b) scale)))
