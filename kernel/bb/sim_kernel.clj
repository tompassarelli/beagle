(ns sim-kernel)

nil

^{:line 14 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord MindIn [x z belief alarm])

(defn mindin-x [r] (:x r))

(defn mindin-z [r] (:z r))

(defn mindin-belief [r] (:belief r))

(defn mindin-alarm [r] (:alarm r))

^{:line 15 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord Obs [well_threat social well_dx well_dz wolf_near wolf_dx wolf_dz wolf_here])

(defn obs-well_threat [r] (:well_threat r))

(defn obs-social [r] (:social r))

(defn obs-well_dx [r] (:well_dx r))

(defn obs-well_dz [r] (:well_dz r))

(defn obs-wolf_near [r] (:wolf_near r))

(defn obs-wolf_dx [r] (:wolf_dx r))

(defn obs-wolf_dz [r] (:wolf_dz r))

(defn obs-wolf_here [r] (:wolf_here r))

^{:line 17 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord BeliefOut [belief alarm])

(defn beliefout-belief [r] (:belief r))

(defn beliefout-alarm [r] (:alarm r))

^{:line 18 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord Decision [act dx dz])

(defn decision-act [r] (:act r))

(defn decision-dx [r] (:dx r))

(defn decision-dz [r] (:dz r))

^{:line 20 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_IDLE 0)

^{:line 21 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_WANDER 1)

^{:line 22 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_AVOID 2)

^{:line 23 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_FLEE 3)

^{:line 24 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ACT_DIG 4)

^{:line 26 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ALARM_MAX 1000)

^{:line 27 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long RISE_THRESHOLD 220)

^{:line 28 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long DECAY 9)

^{:line 29 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WARY_AT 250)

^{:line 30 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long ALARMED_AT 500)

^{:line 31 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long PANIC_AT 750)

^{:line 32 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long DIG_RELIEF 320)

^{:line 34 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long clamp-alarm [^long a]
  ^{:line 35 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 36 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> a ALARM_MAX) ALARM_MAX
  ^{:line 37 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< a 0) 0
  :else a))

^{:line 40 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WOLF_FEAR_AT 250)

^{:line 42 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^BeliefOut belief-update
  "EMA toward the observed threat, then the alarm escalation machine.\n  Predator presence (wolf_near, 0..1000) is direct fear — no EMA lag." [^Ctx ctx ^MindIn m ^Obs obs]
  ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [observed ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 46 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_threat obs) ^{:line 47 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right ^{:line 47 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:social obs) 2) ^{:line 48 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:wolf_near obs))
   belief ^{:line 49 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 49 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief m) ^{:line 49 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right ^{:line 49 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- observed ^{:line 49 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief m)) 3))
   rising ^{:line 50 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> belief RISE_THRESHOLD)
   alarm ^{:line 51 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if rising ^{:line 52 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 52 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm m) ^{:line 52 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (bit-shift-right belief 4)) ^{:line 53 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 53 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm m) DECAY))]
  ^{:line 54 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->BeliefOut belief ^{:line 54 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-alarm alarm))))

^{:line 56 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^Decision decide
  "Alarm level picks the behavior; rng only for wander. A predator in\n  range overrides everything except cornered panic — flee AWAY from\n  the wolf, not the well." [^Ctx ctx ^MindIn m ^BeliefOut b ^Obs obs]
  ^{:line 61 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 62 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 62 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) PANIC_AT) ^{:line 63 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_DIG 0 0)
  ^{:line 64 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 64 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:wolf_near obs) WOLF_FEAR_AT) ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_FLEE ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:wolf_dx obs) 2) ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 65 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:wolf_dz obs) 2))
  ^{:line 66 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 66 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) ALARMED_AT) ^{:line 67 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_FLEE ^{:line 67 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 67 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dx obs) 2) ^{:line 67 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (* ^{:line 67 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dz obs) 2))
  ^{:line 68 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= ^{:line 68 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b) WARY_AT) ^{:line 69 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_AVOID ^{:line 69 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dx obs) ^{:line 69 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:well_dz obs))
  :else ^{:line 71 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [roll ^{:line 71 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 8)]
  ^{:line 72 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 72 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< roll 3) ^{:line 73 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [dx ^{:line 73 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 73 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1)
   dz ^{:line 74 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 74 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1)]
  ^{:line 75 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_WANDER dx dz)) ^{:line 76 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->Decision ACT_IDLE 0 0)))))

^{:line 78 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long dig-relief
  "Digging vents alarm." [^long alarm]
  ^{:line 81 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [a ^{:line 81 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- alarm DIG_RELIEF)]
  ^{:line 82 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 82 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< a 0) 0 a)))

^{:line 84 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord StepOut [x z belief alarm act alive spawn])

(defn stepout-x [r] (:x r))

(defn stepout-z [r] (:z r))

(defn stepout-belief [r] (:belief r))

(defn stepout-alarm [r] (:alarm r))

(defn stepout-act [r] (:act r))

(defn stepout-alive [r] (:alive r))

(defn stepout-spawn [r] (:spawn r))

^{:line 87 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^long clamp-coord [^long v ^long maxv]
  ^{:line 88 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (cond
  ^{:line 89 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< v 0) 0
  ^{:line 90 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> v ^{:line 90 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- maxv 1)) ^{:line 90 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- maxv 1)
  :else v))

^{:line 93 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^StepOut tick-step
  "One mind, one tick: belief -> decision -> applied movement, dig\n  relief, and the lifecycle verdicts: a wolf standing HERE eats you\n  one time in four; a calm, unhunted mind occasionally raises a\n  child. Returns world-lifetime next state (+ act, alive, spawn for\n  the harness: hash fold, digs, render, compaction-with-births)." [^Ctx ctx ^MindIn m ^Obs obs ^long max-x ^long max-z]
  ^{:line 100 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [b ^{:line 100 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (belief-update ctx m obs)
   d ^{:line 101 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (decide ctx m b obs)
   alarm ^{:line 102 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 102 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 102 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:act d) ACT_DIG) ^{:line 103 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (dig-relief ^{:line 103 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b)) ^{:line 104 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:alarm b))
   eaten ^{:line 105 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and ^{:line 105 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> ^{:line 105 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:wolf_here obs) 0) ^{:line 106 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 106 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 4) 0))
   calm ^{:line 107 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and ^{:line 107 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= alarm 0) ^{:line 107 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< ^{:line 107 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief b) 60))
   born ^{:line 108 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and calm ^{:line 108 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (not eaten) ^{:line 108 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 108 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 64) 0))]
  ^{:line 109 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->StepOut ^{:line 109 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 109 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 109 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:x m) ^{:line 109 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:dx d)) max-x) ^{:line 110 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 110 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 110 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:z m) ^{:line 110 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:dz d)) max-z) ^{:line 111 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:belief b) alarm ^{:line 113 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:act d) ^{:line 114 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (not eaten) born)))

nil

^{:line 125 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord WolfIn [x z energy fed])

(defn wolfin-x [r] (:x r))

(defn wolfin-z [r] (:z r))

(defn wolfin-energy [r] (:energy r))

(defn wolfin-fed [r] (:fed r))

^{:line 126 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord WolfObs [scent prey_dx prey_dz prey_near])

(defn wolfobs-scent [r] (:scent r))

(defn wolfobs-prey_dx [r] (:prey_dx r))

(defn wolfobs-prey_dz [r] (:prey_dz r))

(defn wolfobs-prey_near [r] (:prey_near r))

^{:line 127 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defrecord WolfOut [x z energy fed howl alive spawn])

(defn wolfout-x [r] (:x r))

(defn wolfout-z [r] (:z r))

(defn wolfout-energy [r] (:energy r))

(defn wolfout-fed [r] (:fed r))

(defn wolfout-howl [r] (:howl r))

(defn wolfout-alive [r] (:alive r))

(defn wolfout-spawn [r] (:spawn r))

^{:line 130 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WOLF_DRAIN 1)

^{:line 131 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WOLF_FEED_GAIN 250)

^{:line 132 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WOLF_SATED_AT 700)

^{:line 133 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (def ^long WOLF_HOWL_AFTER 120)

^{:line 135 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (defn ^WolfOut wolf-step
  "One wolf, one tick: wolves SHADOW THE HERD — they follow the fear\n  gradient whenever there is scent (prey_dx/dz points toward the most\n  afraid nearby cell), but only hunger makes them eat. Long-starved\n  wolves sometimes howl; zero energy is starvation; the sated whelp.\n  The verdicts drive generated compaction-with-births." [^Ctx ctx ^WolfIn w ^WolfObs obs ^long max-x ^long max-z]
  ^{:line 142 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (let [energy ^{:line 142 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (max 0 ^{:line 142 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 142 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:energy w) WOLF_DRAIN))
   hungry ^{:line 143 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (< energy WOLF_SATED_AT)
   tracking ^{:line 144 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> ^{:line 144 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:scent obs) 0)
   dx ^{:line 145 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if tracking ^{:line 145 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:prey_dx obs) ^{:line 145 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 145 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1))
   dz ^{:line 146 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if tracking ^{:line 146 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:prey_dz obs) ^{:line 146 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (- ^{:line 146 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 3) 1))
   feeding ^{:line 147 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and hungry ^{:line 147 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> ^{:line 147 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:prey_near obs) 0))
   energy2 ^{:line 148 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if feeding ^{:line 148 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (min 1000 ^{:line 148 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ energy WOLF_FEED_GAIN)) energy)
   fed ^{:line 149 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if feeding 0 ^{:line 149 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (inc ^{:line 149 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:fed w)))
   howl ^{:line 150 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (if ^{:line 150 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and hungry ^{:line 151 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> fed WOLF_HOWL_AFTER) ^{:line 152 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 152 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 32) 0)) 1 0)]
  ^{:line 155 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (->WolfOut ^{:line 155 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 155 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 155 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:x w) dx) max-x) ^{:line 156 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (clamp-coord ^{:line 156 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (+ ^{:line 156 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (:z w) dz) max-z) energy2 fed howl ^{:line 160 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (> energy2 0) ^{:line 161 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (and ^{:line 161 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (>= energy2 800) ^{:line 162 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (= ^{:line 162 :file "/home/tom/code/beagle/kernel/src/sim_kernel.bgl"} (kernel.rt/rng-below ctx 64) 0)))))
