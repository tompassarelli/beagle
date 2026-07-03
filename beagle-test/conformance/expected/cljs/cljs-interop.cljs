(ns test.cljs-interop)

(def parsed (js/parseInt "42"))

(def float-val (js/parseFloat "3.14"))

(def ^Boolean nan-check (js/isNaN 0))

(def ^Boolean finite-check (js/isFinite 100))

(def pi-area (js/Math.pow 3.14 2.0))

(def root (js/Math.sqrt 16.0))

(def rnd (js/Math.random))

(def floored (js/Math.floor 3.7))

(def ceiled (js/Math.ceil 3.2))

(defn log-it [^String msg]
  (js/console.log msg))

(def ^String encoded (js/encodeURIComponent "hello world"))

(def ^String decoded (js/decodeURIComponent encoded))

(defn ^String greet [^String name]
  (str "Hello, " name "!"))

(def items (vec (map inc (range 5))))

(def safe-val (try
  (/ 1 0)
  (catch :default e
    (str "error: " e))))

(defrecord Point [x y])

(defn point-x [r] (:x r))

(defn point-y [r] (:y r))

(defn ^Point make-origin []
  (->Point 0 0))

(def origin (make-origin))

(def ox (:x origin))
