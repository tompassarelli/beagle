(ns f3orr)

^{:line 3 :file "/tmp/f3orr.bclj"} (def base2 10)

^{:line 4 :file "/tmp/f3orr.bclj"} (defn f [{:keys [x] :or {x base}}]
  ^{:line 5 :file "/tmp/f3orr.bclj"} (+ x 1))
