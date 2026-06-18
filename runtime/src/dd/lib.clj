(ns dd.lib)

^{:line 3 :file "/tmp/defntest/dlib.bclj"} (defrecord Money [cents])

(defn money-cents [r] (:cents r))

^{:line 4 :file "/tmp/defntest/dlib.bclj"} (defn price [^Money m]
  ^{:line 4 :file "/tmp/defntest/dlib.bclj"} (money-cents m))
