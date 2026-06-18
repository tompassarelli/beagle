(ns cap)

^{:line 4 :file "/tmp/fsweep/cap.bclj"} (def scale 2)

^{:line 6 :file "/tmp/fsweep/cap.bclj"} (defprotocol Area
  (area [self]))

^{:line 9 :file "/tmp/fsweep/cap.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 11 :file "/tmp/fsweep/cap.bclj"} (extend-type Box
  Area
  (area [scale]
    ^{:line 13 :file "/tmp/fsweep/cap.bclj"} (box-w scale)))
