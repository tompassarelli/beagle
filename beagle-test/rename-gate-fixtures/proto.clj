(ns proto)

^{:line 4 :file "/tmp/fsweep/proto.bclj"} (defprotocol Drawable
  (draw [self])
  (bbox [self]))

^{:line 8 :file "/tmp/fsweep/proto.bclj"} (defrecord Box [w h])

(defn box-w [r] (:w r))

(defn box-h [r] (:h r))

^{:line 10 :file "/tmp/fsweep/proto.bclj"} (extend-type Box
  Drawable
  (draw [self]
    ^{:line 12 :file "/tmp/fsweep/proto.bclj"} (str ^{:line 12 :file "/tmp/fsweep/proto.bclj"} (box-w self)))
  (bbox [self]
    ^{:line 13 :file "/tmp/fsweep/proto.bclj"} (* ^{:line 13 :file "/tmp/fsweep/proto.bclj"} (box-w self) ^{:line 13 :file "/tmp/fsweep/proto.bclj"} (box-h self))))
