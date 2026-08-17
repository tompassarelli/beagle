(ns fram.graal-server
  (:require [server :as server])
  (:gen-class))

(defn -main [& arguments]
  (reset! server/runtime-engine :rpc/graal)
  (apply server/-main arguments))
