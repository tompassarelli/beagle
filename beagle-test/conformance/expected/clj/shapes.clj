(ns shapes)

^{:line 5 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (defrecord Circle [radius])

(defn circle-radius [r] (:radius r))

^{:line 6 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (defrecord Rect [width height])

(defn rect-width [r] (:width r))

(defn rect-height [r] (:height r))

^{:line 8 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (defn circle-area [^Circle c]
  ^{:line 9 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (* ^{:line 9 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (circle-radius c) ^{:line 9 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (circle-radius c)))

^{:line 11 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (defn rect-area [^Rect r]
  ^{:line 12 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (* ^{:line 12 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (rect-width r) ^{:line 12 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/shapes.bclj"} (rect-height r)))
