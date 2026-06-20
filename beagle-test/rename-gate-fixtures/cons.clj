(ns cons
  (:require [prov :refer [seedling double]]))

^{:line 6 :file "/tmp/xmod/cons_r.bclj"} (defn go [input]
  ^{:line 7 :file "/tmp/xmod/cons_r.bclj"} (as-> input seedling ^{:line 7 :file "/tmp/xmod/cons_r.bclj"} (prov/double seedling) ^{:line 7 :file "/tmp/xmod/cons_r.bclj"} (+ seedling 1)))
