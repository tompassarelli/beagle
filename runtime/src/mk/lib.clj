(ns mk.lib)

^{:line 3 :file "/tmp/mktest/mklib.bclj"} (defrecord Box [w])

(defn box-w [r] (:w r))

^{:line 4 :file "/tmp/mktest/mklib.bclj"} (defprotocol Maker
  (make [self]))
