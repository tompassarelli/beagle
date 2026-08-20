(ns native-rpc-client
  (:require [store.rt :as rt]))

;; Tests use the same bounded client as every CLI, MCP, and gateway adapter.
(def read-packet! rt/read-rpc-packet!)

(defn request! [port request-id request]
  ;; request-id remains in this test helper's historical signature. Production
  ;; request IDs are minted centrally by store.rt and verified on response.
  (let [_ request-id]
    (rt/native-request! port request)))
