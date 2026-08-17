;; Spike unicode/arena frames: NOT repo code. Read-path frames whose payloads
;; carry multi-byte UTF-8 and one large string, so the wasm codec and arena run
;; without needing the (currently trapping) write path.
(require '[framrpc :as w]
         '[fram.types :as t]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(def out-dir (first *command-line-args*))
(def space (or (second *command-line-args*) "wasm-spike"))
(def manifest (atom []))
(def next-id (atom 0))

(defn emit! [name entry op payload & {:keys [page]}]
  (let [id (swap! next-id inc)
        request (w/rpc-request! space op nil page nil payload)
        bytes (w/encode-rpc-frame-v2! (w/rpc-request-frame id request))]
    (io/copy bytes (io/file out-dir (str name ".bin")))
    (swap! manifest conj (str entry " " name ".bin " (alength bytes) " " op))
    (println (format "%-26s %-2s %8d bytes id=%d op=%s" name entry
                     (alength bytes) id op))))

(def unicode "Türkçe İstanbul — 日本語 🐕 ẞ ﬁ Ω")
(def big (apply str (repeat 4096 "日本語🐕é")))

(emit! "15-scan-unicode" "q" :rpc/scan
       (w/rpc-triple-pattern! unicode nil nil))

(emit! "16-scan-keyword-unicode" "q" :rpc/scan
       (w/rpc-triple-pattern! (t/triple unicode :caractère "🐕") nil nil))

(def unicode-plan
  (let [t2 (w/rpc-query-variable! "t2")
        t3 (w/rpc-query-variable! "t3")]
    (w/rpc-query-plan!
     (w/rpc-query-find-relation! "u")
     [(w/rpc-query-stratum!
       [(w/rpc-query-rule!
         (w/rpc-query-head! "u" [t2 t3])
         [(w/rpc-query-relation!
           "triple" [(w/rpc-query-constant! unicode) t2 t3] false)])])])))

(emit! "17-query-unicode" "q" :rpc/query
       (w/rpc-query-request! unicode-plan w/query-current))

(emit! "18-scan-big-string" "q" :rpc/scan
       (w/rpc-triple-pattern! big nil nil))

(emit! "19-scan-deep-nest" "q" :rpc/scan
       (w/rpc-triple-pattern!
        (reduce (fn [inner i] (t/triple inner :depth i)) unicode (range 64))
        nil nil))

(spit (io/file out-dir "manifest.txt") (str (str/join "\n" @manifest) "\n"))
