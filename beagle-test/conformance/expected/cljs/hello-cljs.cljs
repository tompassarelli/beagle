(ns heist.hello)

(defn ^String greet [^String name]
  (str "Hello, " name "!"))

(def message (greet "Heist"))
