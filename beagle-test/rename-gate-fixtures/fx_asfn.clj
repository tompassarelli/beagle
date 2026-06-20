(ns fx_asfn)

^{:line 6 :file "/tmp/fx_asfn_r.bclj"} (defn triple [x]
  ^{:line 6 :file "/tmp/fx_asfn_r.bclj"} (* x 2))

^{:line 8 :file "/tmp/fx_asfn_r.bclj"} (defn go [input]
  ^{:line 8 :file "/tmp/fx_asfn_r.bclj"} (as-> input acc ^{:line 8 :file "/tmp/fx_asfn_r.bclj"} (triple acc) ^{:line 8 :file "/tmp/fx_asfn_r.bclj"} (triple acc)))
