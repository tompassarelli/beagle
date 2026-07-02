(ns kitchen-sink)

^{:line 7 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defrecord Point [x y])

(defn point-x [r] (:x r))

(defn point-y [r] (:y r))

^{:line 8 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defrecord Line [start end])

(defn line-start [r] (:start r))

(defn line-end [r] (:end r))

;; Shape = Circle | Square
(defrecord Circle [radius])
(defrecord Square [side])

^{:line 16 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (def Color-values #{:red :green :blue})

^{:line 19 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (def ^Point origin ^{:line 19 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (Point 0 0))

^{:line 21 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (def tau 6.28)

^{:line 24 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn distance [^Point p]
  ^{:line 25 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (let [dx ^{:line 25 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (point-x p)
   dy ^{:line 26 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (point-y p)]
  ^{:line 27 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (+ ^{:line 27 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (* dx dx) ^{:line 27 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (* dy dy))))

^{:line 30 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn ^String classify [n]
  ^{:line 31 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (cond
  ^{:line 32 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (< n 0) "negative"
  ^{:line 33 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (= n 0) "zero"
  :else "positive"))

^{:line 37 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn shape-size [s]
  ^{:line 38 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (let [match__0 s]
  (cond
    (instance? Circle match__0) (let [c (:radius match__0)] (circle-radius c))
    (instance? Square match__0) (let [q (:side match__0)] (square-side q)))))

^{:line 43 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn log-point [^Point p]
  ^{:line 44 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (if ^{:line 44 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (> ^{:line 44 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (point-x p) 0) ^{:line 45 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (do
  ^{:line 46 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (println "positive x")
  ^{:line 47 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (println ^{:line 47 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (str "x=" ^{:line 47 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (point-x p))))))

^{:line 50 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn squares [ns]
  ^{:line 51 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (for [n ns]
  ^{:line 51 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (* n n)))

^{:line 54 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn factorial [n]
  ^{:line 55 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (loop [i n
   acc 1]
  ^{:line 57 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (if ^{:line 57 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (<= i 1) acc ^{:line 59 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (recur ^{:line 59 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (- i 1) ^{:line 59 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (* acc i)))))

^{:line 62 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn safe-div [a b]
  ^{:line 63 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (try
  ^{:line 64 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (/ a b)
  (catch Exception e
    0)))

^{:line 69 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn color-name [c]
  ^{:line 70 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (case c
    :red "Red"
    :green "Green"
    :blue "Blue"
    nil))

^{:line 77 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn ^Point move-right [^Point p]
  ^{:line 78 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (assoc p :x ^{:line 78 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (+ ^{:line 78 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (point-x p) 1)))

^{:line 81 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn apply-twice [f x]
  ^{:line 82 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (f ^{:line 82 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (f x)))

^{:line 85 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn print-all [items]
  ^{:line 86 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (doseq [item items]
  ^{:line 87 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (println item)))

^{:line 90 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn first-or-default [xs]
  ^{:line 91 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (let [x ^{:line 91 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (first xs)]
  ^{:line 92 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (if x x 0)))

^{:line 95 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (defn ^Boolean mutual-test []
  ^{:line 96 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (letfn [(even? [n] (if (= n 0) true (odd? (- n 1))))
          (odd? [n] (if (= n 0) false (even? (- n 1))))]
  ^{:line 100 :file "/home/tom/code/beagle/.worktrees/oracle-gate/beagle-test/tests/fixtures/kitchen-sink.bclj"} (even? 10)))
