(ns fx_as)

^{:line 5 :file "/tmp/fx_as.bclj"} (defn double [x]
  ^{:line 5 :file "/tmp/fx_as.bclj"} (* x 2))

^{:line 7 :file "/tmp/fx_as.bclj"} (defn go [input]
  ^{:line 8 :file "/tmp/fx_as.bclj"} (as-> input acc ^{:line 9 :file "/tmp/fx_as.bclj"} (double acc) ^{:line 10 :file "/tmp/fx_as.bclj"} (+ acc 1)))
