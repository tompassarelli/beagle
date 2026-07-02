(ns shapes)

^{:line 5 :file "beagle-test/tests/fixtures/shapes.bclj"} (defrecord Circle [radius])

(defn circle-radius [r] (:radius r))

^{:line 6 :file "beagle-test/tests/fixtures/shapes.bclj"} (defrecord Rect [width height])

(defn rect-width [r] (:width r))

(defn rect-height [r] (:height r))

^{:line 8 :file "beagle-test/tests/fixtures/shapes.bclj"} (defn circle-area [^Circle c]
  ^{:line 9 :file "beagle-test/tests/fixtures/shapes.bclj"} (* ^{:line 9 :file "beagle-test/tests/fixtures/shapes.bclj"} (circle-radius c) ^{:line 9 :file "beagle-test/tests/fixtures/shapes.bclj"} (circle-radius c)))

^{:line 11 :file "beagle-test/tests/fixtures/shapes.bclj"} (defn rect-area [^Rect r]
  ^{:line 12 :file "beagle-test/tests/fixtures/shapes.bclj"} (* ^{:line 12 :file "beagle-test/tests/fixtures/shapes.bclj"} (rect-width r) ^{:line 12 :file "beagle-test/tests/fixtures/shapes.bclj"} (rect-height r)))
