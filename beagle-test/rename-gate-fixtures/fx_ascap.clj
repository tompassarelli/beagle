(ns fx_ascap)

^{:line 6 :file "/tmp/rendered_raw.bclj"} (def total 100)

^{:line 8 :file "/tmp/rendered_raw.bclj"} (defn double [x]
  ^{:line 8 :file "/tmp/rendered_raw.bclj"} (* x 2))

^{:line 10 :file "/tmp/rendered_raw.bclj"} (defn use-module []
  total)

^{:line 12 :file "/tmp/rendered_raw.bclj"} (defn go [input]
  ^{:line 12 :file "/tmp/rendered_raw.bclj"} (as-> input total ^{:line 12 :file "/tmp/rendered_raw.bclj"} (double total) ^{:line 12 :file "/tmp/rendered_raw.bclj"} (+ total 1)))
