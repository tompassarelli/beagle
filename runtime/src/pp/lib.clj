(ns pp.lib)

^{:line 3 :file "/tmp/protomtest/plib.bclj"} (defrecord Money [cents])

(defn money-cents [r] (:cents r))

^{:line 4 :file "/tmp/protomtest/plib.bclj"} (defprotocol Priced
  (price [self]))
