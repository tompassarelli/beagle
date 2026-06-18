(ns selfcap)

^{:line 4 :file "/tmp/fsweep/selfcap.bclj"} (def scale 3)

^{:line 6 :file "/tmp/fsweep/selfcap.bclj"} (defprotocol Area
  (area [self]))

^{:line 9 :file "/tmp/fsweep/selfcap.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 11 :file "/tmp/fsweep/selfcap.bclj"} (extend-type Box
  Area
  (area [self]
    ^{:line 13 :file "/tmp/fsweep/selfcap.bclj"} (* ^{:line 13 :file "/tmp/fsweep/selfcap.bclj"} (box-w self) scale)))
