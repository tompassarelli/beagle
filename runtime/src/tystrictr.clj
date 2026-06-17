(ns tystrictr)

^{:line 3 :file "/tmp/tystrictr.bclj"} (defrecord Pt [x y])

(defn pt-x [r] (:x r))

(defn pt-y [r] (:y r))

^{:line 4 :file "/tmp/tystrictr.bclj"} (def ^Pt origin ^{:line 4 :file "/tmp/tystrictr.bclj"} (Point 0 0))
