(ns sim-kernel)

nil

^{:line 14 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord MindIn [x z belief alarm])

(defn mindin-x [r] (:x r))

(defn mindin-z [r] (:z r))

(defn mindin-belief [r] (:belief r))

(defn mindin-alarm [r] (:alarm r))

^{:line 15 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord Obs [well_threat social well_dx well_dz])

(defn obs-well_threat [r] (:well_threat r))

(defn obs-social [r] (:social r))

(defn obs-well_dx [r] (:well_dx r))

(defn obs-well_dz [r] (:well_dz r))

^{:line 16 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord BeliefOut [belief alarm])

(defn beliefout-belief [r] (:belief r))

(defn beliefout-alarm [r] (:alarm r))

^{:line 17 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord Decision [act dx dz])

(defn decision-act [r] (:act r))

(defn decision-dx [r] (:dx r))

(defn decision-dz [r] (:dz r))

^{:line 19 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_IDLE 0)

^{:line 20 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_WANDER 1)

^{:line 21 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_AVOID 2)

^{:line 22 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_FLEE 3)

^{:line 23 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_DIG 4)

^{:line 25 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ALARM_MAX 1000)

^{:line 26 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long RISE_THRESHOLD 220)

^{:line 27 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long DECAY 9)

^{:line 28 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WARY_AT 250)

^{:line 29 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ALARMED_AT 500)

^{:line 30 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long PANIC_AT 750)

^{:line 31 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long DIG_RELIEF 320)

^{:line 33 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long clamp-alarm [^long a]
  ^{:line 34 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 35 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> a ALARM_MAX) ALARM_MAX
  ^{:line 36 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< a 0) 0
  :else a))

^{:line 39 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^BeliefOut belief-update
  "EMA toward the observed threat, then the alarm escalation machine." [^Ctx ctx ^MindIn m ^Obs obs]
  ^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [observed ^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_threat obs) ^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right ^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:social obs) 2))
   belief ^{:line 43 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 43 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief m) ^{:line 43 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right ^{:line 43 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- observed ^{:line 43 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief m)) 3))
   rising ^{:line 44 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> belief RISE_THRESHOLD)
   alarm ^{:line 45 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if rising ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm m) ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right belief 4)) ^{:line 47 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 47 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm m) DECAY))]
  ^{:line 48 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->BeliefOut belief ^{:line 48 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-alarm alarm))))

^{:line 50 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^Decision decide
  "Alarm level picks the behavior; rng only for wander." [^Ctx ctx ^MindIn m ^BeliefOut b ^Obs obs]
  ^{:line 53 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 54 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 54 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) PANIC_AT) ^{:line 55 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_DIG 0 0)
  ^{:line 56 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 56 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) ALARMED_AT) ^{:line 57 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_FLEE ^{:line 57 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 57 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dx obs) 2) ^{:line 57 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 57 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dz obs) 2))
  ^{:line 58 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 58 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) WARY_AT) ^{:line 59 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_AVOID ^{:line 59 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dx obs) ^{:line 59 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dz obs))
  :else ^{:line 61 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [roll ^{:line 61 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 8)]
  ^{:line 62 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 62 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< roll 3) ^{:line 63 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [dx ^{:line 63 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 63 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1)
   dz ^{:line 64 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 64 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1)]
  ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_WANDER dx dz)) ^{:line 66 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_IDLE 0 0)))))

^{:line 68 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long dig-relief
  "Digging vents alarm." [^long alarm]
  ^{:line 71 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [a ^{:line 71 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- alarm DIG_RELIEF)]
  ^{:line 72 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 72 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< a 0) 0 a)))

^{:line 74 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord StepOut [x z belief alarm act])

(defn stepout-x [r] (:x r))

(defn stepout-z [r] (:z r))

(defn stepout-belief [r] (:belief r))

(defn stepout-alarm [r] (:alarm r))

(defn stepout-act [r] (:act r))

^{:line 76 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long clamp-coord [^long v ^long maxv]
  ^{:line 77 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 78 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< v 0) 0
  ^{:line 79 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> v ^{:line 79 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- maxv 1)) ^{:line 79 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- maxv 1)
  :else v))

^{:line 82 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^StepOut tick-step
  "One mind, one tick: belief -> decision -> applied movement and dig\n  relief. Returns the world-lifetime next state (+ the act for the\n  harness: hash fold, dig application, render color)." [^Ctx ctx ^MindIn m ^Obs obs ^long max-x ^long max-z]
  ^{:line 87 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [b ^{:line 87 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (belief-update ctx m obs)
   d ^{:line 88 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (decide ctx m b obs)
   alarm ^{:line 89 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 89 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 89 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:act d) ACT_DIG) ^{:line 90 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (dig-relief ^{:line 90 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b)) ^{:line 91 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b))]
  ^{:line 92 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->StepOut ^{:line 92 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 92 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 92 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:x m) ^{:line 92 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:dx d)) max-x) ^{:line 93 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 93 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 93 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:z m) ^{:line 93 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:dz d)) max-z) ^{:line 94 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief b) alarm ^{:line 96 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:act d))))
