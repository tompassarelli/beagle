;; Runtime-only STORERPC fixture for lease-response preflight atomicity.
(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.types :as t]
         '[store.rpc :as wire])

(def output-directory (io/file (or (first *command-line-args*) ".")))
(def space "store-wasm-lease-preflight")
(def request-id (atom 0))
(def manifest (atom []))

(.mkdirs output-directory)

(defn emit! [name entry operation payload]
  (let [request (wire/rpc-request! space operation nil nil nil payload)
        bytes
        (wire/store-rpc-encode-packet-v2!
         (wire/store-rpc-request-packet (swap! request-id inc) request))
        filename (str name ".bin")]
    (io/copy bytes (io/file output-directory filename))
    (swap! manifest conj
           (str entry " " filename " " (alength bytes) " " operation))))

(def resource
  (nth (iterate #(t/triple % 0 0) :lease/deep-resource) 253))
(def pattern (wire/rpc-triple-pattern! nil :kernel/lease nil))

(emit! "01-version-before" "q" :rpc/version wire/rpc-unit)
(emit! "02-scan-before" "q" :rpc/scan pattern)
(emit! "03-lease-acquire-deep" "t" :rpc/lease-acquire
       (wire/rpc-lease-acquire! resource "holder" 60000))
(emit! "04-version-after" "q" :rpc/version wire/rpc-unit)
(emit! "05-scan-after" "q" :rpc/scan pattern)

(spit (io/file output-directory "manifest.txt")
      (str (str/join "\n" @manifest) "\n"))
(spit (io/file output-directory "manifest-empty.txt") "")
(spit (io/file output-directory "space.txt") space)
