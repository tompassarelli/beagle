(ns shapes)

^{:line 4 :file "/tmp/fsweep/shapes.bclj"} (defprotocol Area
  (area [self]))

^{:line 7 :file "/tmp/fsweep/shapes.bclj"} (defrecord Shape [width height])

(defn shape-width [r] (:width r))

(defn shape-height [r] (:height r))

^{:line 9 :file "/tmp/fsweep/shapes.bclj"} (extend-type Shape
  Area
  (area [self]
    ^{:line 11 :file "/tmp/fsweep/shapes.bclj"} (* ^{:line 11 :file "/tmp/fsweep/shapes.bclj"} (shape-width self) ^{:line 11 :file "/tmp/fsweep/shapes.bclj"} (shape-height self))))
