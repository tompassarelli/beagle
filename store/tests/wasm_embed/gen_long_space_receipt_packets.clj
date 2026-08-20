;; Runtime-only STORERPC fixture for response preflight at the maximum SpaceId.
(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.types :as t]
         '[store.rpc :as wire])

(def output-directory (io/file (or (first *command-line-args*) ".")))
(def space (apply str (repeat wire/rpc-v2-max-space-bytes "s")))
(def request-id (atom 0))
(def manifest (atom []))

(.mkdirs output-directory)

(when-not (= wire/rpc-v2-max-space-bytes
             (alength (.getBytes space java.nio.charset.StandardCharsets/UTF_8)))
  (throw (ex-info "long SpaceId fixture is not the wire maximum" {})))

(defn emit! [name entry operation payload]
  (let [id (swap! request-id inc)
        request (wire/rpc-request! space operation nil nil nil payload)
        bytes
        (wire/encode-rpc-packet-v2!
         (wire/rpc-request-packet id request))
        filename (str name ".bin")]
    (io/copy bytes (io/file output-directory filename))
    (swap! manifest conj
           (str entry " " filename " " (alength bytes) " " operation))
    id))

(def proposition (t/triple true true true))
(def pattern (wire/rpc-triple-pattern! true true true))
(def action
  (wire/rpc-action! :rpc/assert proposition wire/rpc-subject-any))

(emit! "01-version-before" "q" :rpc/version wire/rpc-unit)
(emit! "02-scan-before" "q" :rpc/scan pattern)
(def accepted-request-id
  (emit! "03-batch-243" "t" :rpc/batch
         (wire/rpc-batch! (vec (repeat 243 action)) nil)))
(emit! "04-version-after-success" "q" :rpc/version wire/rpc-unit)
(emit! "05-scan-after-success" "q" :rpc/scan pattern)
(emit! "06-batch-244" "t" :rpc/batch
       (wire/rpc-batch! (vec (repeat 244 action)) nil))
(emit! "07-version-after-rejection" "q" :rpc/version wire/rpc-unit)
(emit! "08-scan-after-rejection" "q" :rpc/scan pattern)

(def transaction (t/transaction-coordinate space 1))
(def expected-results
  (mapv
   (fn [index]
     (wire/rpc-action-result!
      index true (t/occurrence-coordinate transaction index)))
   (range 243)))
(def expected-response
  (wire/rpc-response-packet
   accepted-request-id
   (wire/rpc-response!
    space :rpc/batch 1 nil nil
    (wire/rpc-mutation-result! expected-results))))

(io/copy (wire/encode-rpc-packet-v2! expected-response)
         (io/file output-directory "expected-03-batch-243-response.bin"))

(spit (io/file output-directory "manifest.txt")
      (str (str/join "\n" @manifest) "\n"))
(spit (io/file output-directory "manifest-empty.txt") "")
(spit (io/file output-directory "space.txt") space)
