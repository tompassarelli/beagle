(ns f3or)

^{:line 3 :file "/tmp/f3or.bclj"} (def base 10)

^{:line 4 :file "/tmp/f3or.bclj"} (defn f [{:keys [x] :or {x base}}]
  ^{:line 5 :file "/tmp/f3or.bclj"} (+ x 1))
