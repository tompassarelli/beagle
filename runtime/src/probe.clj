(ns probe)

^{:line 3 :file "/tmp/ffz/probe.bclj"} (defrecord Container [w h])

(defn container-w [r] (:w r))

(defn container-h [r] (:h r))

^{:line 4 :file "/tmp/ffz/probe.bclj"} (defn area [^Container b]
  ^{:line 4 :file "/tmp/ffz/probe.bclj"} (* ^{:line 4 :file "/tmp/ffz/probe.bclj"} (box-w b) ^{:line 4 :file "/tmp/ffz/probe.bclj"} (box-h b)))
