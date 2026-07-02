(ns test.cljs-interop)

^{:line 7 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def parsed ^{:line 7 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/parseInt "42"))

^{:line 9 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def float-val ^{:line 9 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/parseFloat "3.14"))

^{:line 11 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ^Boolean nan-check ^{:line 11 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/isNaN 0))

^{:line 13 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ^Boolean finite-check ^{:line 13 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/isFinite 100))

^{:line 16 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def pi-area ^{:line 16 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/Math.pow 3.14 2.0))

^{:line 18 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def root ^{:line 18 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/Math.sqrt 16.0))

^{:line 20 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def rnd ^{:line 20 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/Math.random))

^{:line 22 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def floored ^{:line 22 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/Math.floor 3.7))

^{:line 24 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ceiled ^{:line 24 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/Math.ceil 3.2))

^{:line 27 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (defn log-it [^String msg]
  ^{:line 28 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/console.log msg))

^{:line 31 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ^String encoded ^{:line 31 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/encodeURIComponent "hello world"))

^{:line 33 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ^String decoded ^{:line 33 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (js/decodeURIComponent encoded))

^{:line 36 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (defn ^String greet [^String name]
  ^{:line 37 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (str "Hello, " name "!"))

^{:line 39 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def items ^{:line 39 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (vec ^{:line 39 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (map inc ^{:line 39 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (range 5))))

^{:line 42 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def safe-val ^{:line 43 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (try
  ^{:line 44 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (/ 1 0)
  (catch :default e
    ^{:line 46 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (str "error: " e))))

^{:line 49 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (defrecord Point [x y])

(defn point-x [r] (:x r))

(defn point-y [r] (:y r))

^{:line 51 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (defn ^Point make-origin []
  ^{:line 52 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (->Point 0 0))

^{:line 54 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def origin ^{:line 54 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (make-origin))

^{:line 56 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (def ox ^{:line 56 :file "beagle-test/tests/fixtures/cljs-interop.bcljs"} (:x origin))
