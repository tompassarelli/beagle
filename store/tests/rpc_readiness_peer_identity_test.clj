(import '[java.net InetAddress InetSocketAddress ServerSocket Socket])

(binding [*command-line-args* []]
  (load-file "server.clj"))

(def failures (atom []))

(defn check! [label value]
  (println (str (if value "[PASS] " "[FAIL] ") label))
  (when-not value (swap! failures conj label)))

(let [server-address (InetAddress/getByName "127.0.0.1")
      external-address (InetAddress/getByName "127.0.0.2")]
  (with-open [listener (ServerSocket. 0 8 server-address)
              external (Socket.)
              self-client (Socket.)]
    (.bind external (InetSocketAddress. external-address 0))
    (let [shared-port (.getLocalPort external)
          destination (InetSocketAddress. server-address (.getLocalPort listener))]
      (.connect external destination)
      (.bind self-client (InetSocketAddress. server-address shared-port))
      (.connect self-client destination)
      (let [admitted (atom [])]
        (with-redefs-fn
          {#'server/admit-connection!
           (fn [^Socket accepted]
             (try
               (swap! admitted conj
                      [(.getHostAddress (.getInetAddress accepted))
                       (.getPort accepted)])
               (finally
                 (.close accepted))))}
          #(#'server/admit-until-client! listener self-client))
        (check! "external peer enters the accept backlog before the self-client"
                (= "127.0.0.2" (ffirst @admitted)))
        (check! "external and self peers reuse one source port on different addresses"
                (= [["127.0.0.2" shared-port]
                    ["127.0.0.1" shared-port]]
                   @admitted))
        (check! "readiness admission continues through the external peer to the self-client"
                (= 2 (count @admitted)))))))

(if (seq @failures)
  (do
    (println (str "RPC readiness peer identity: " (count @failures) " FAILED"))
    (System/exit 1))
  (println "RPC readiness peer identity: PASS"))
