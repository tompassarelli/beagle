(ns mathlib)

^{:line 5 :file "beagle-test/tests/fixtures/mathlib.bclj"} (defn add [x y]
  ^{:line 6 :file "beagle-test/tests/fixtures/mathlib.bclj"} (+ x y))

^{:line 8 :file "beagle-test/tests/fixtures/mathlib.bclj"} (def pi 3.14159)

^{:line 10 :file "beagle-test/tests/fixtures/mathlib.bclj"} (defn ^String greet [^String name]
  ^{:line 11 :file "beagle-test/tests/fixtures/mathlib.bclj"} (str "hello " name))

^{:line 13 :file "beagle-test/tests/fixtures/mathlib.bclj"} (defn untyped-inc [x]
  ^{:line 14 :file "beagle-test/tests/fixtures/mathlib.bclj"} (+ x 1))
