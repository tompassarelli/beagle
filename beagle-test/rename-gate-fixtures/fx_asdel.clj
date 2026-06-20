(ns fx_asdel)

^{:line 3 :file "/tmp/fx_asdel_manual.bclj"} (defn double [x]
  ^{:line 3 :file "/tmp/fx_asdel_manual.bclj"} (* x 2))

^{:line 4 :file "/tmp/fx_asdel_manual.bclj"} (defn go [input]
  ^{:line 5 :file "/tmp/fx_asdel_manual.bclj"} (as-> input acc ^{:line 6 :file "/tmp/fx_asdel_manual.bclj"} (double acc) ^{:line 7 :file "/tmp/fx_asdel_manual.bclj"} (+ acc 1)))
