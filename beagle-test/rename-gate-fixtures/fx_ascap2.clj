(ns fx_ascap2)

^{:line 6 :file "/tmp/rendered_cap2.bclj"} (def acc 1000)

^{:line 8 :file "/tmp/rendered_cap2.bclj"} (defn double [x]
  ^{:line 8 :file "/tmp/rendered_cap2.bclj"} (* x 2))

^{:line 10 :file "/tmp/rendered_cap2.bclj"} (defn go [input]
  ^{:line 10 :file "/tmp/rendered_cap2.bclj"} (as-> input acc ^{:line 10 :file "/tmp/rendered_cap2.bclj"} (double acc) ^{:line 10 :file "/tmp/rendered_cap2.bclj"} (+ acc acc)))
