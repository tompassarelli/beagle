;; Differential oracle runner (bb side). Generates the same case stream
;; as `kernel --dif N` (shared Splitmix64) and prints one line per case:
;;   belief alarm act dx dz
;; Byte-identical output across backends = oracle green.
(require '[kernel.rt :as rt])
(load-file (str (babashka.fs/parent *file*) "/sim_kernel.clj"))
(alias 'sim 'sim-kernel)

(let [[n-str seed-str] *command-line-args*
      n (parse-long (or n-str "1000"))
      seed (parse-long (or seed-str "12345"))
      gen (atom (long seed))
      gctx {:rng gen}
      ctx (rt/make-ctx (inc seed))]
  (dotimes [_ n]
    (let [m (sim/->MindIn (rt/rng-below gctx 64)
                          (rt/rng-below gctx 64)
                          (rt/rng-below gctx 1200)
                          (rt/rng-below gctx 1100))
          obs (sim/->Obs (rt/rng-below gctx 1001)
                         (rt/rng-below gctx 1001)
                         (- (rt/rng-below gctx 3) 1)
                         (- (rt/rng-below gctx 3) 1))
          out (sim/tick-step ctx m obs 64 64)]
      (println (:x out) (:z out) (:belief out) (:alarm out) (:act out)))))
