(ns fx_cond)

^{:line 5 :file "/tmp/fx_cond.bclj"} (defn double [x]
  ^{:line 5 :file "/tmp/fx_cond.bclj"} (* x 2))

^{:line 7 :file "/tmp/fx_cond.bclj"} (defn go [input ^Boolean flag]
  ^{:line 8 :file "/tmp/fx_cond.bclj"} (cond-> input flag ^{:line 9 :file "/tmp/fx_cond.bclj"} (double) ^{:line 10 :file "/tmp/fx_cond.bclj"} (> input 0) ^{:line 10 :file "/tmp/fx_cond.bclj"} (double)))
