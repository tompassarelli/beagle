;; native_core_reingest_probe.clj — per-module graph re-ingest round-trip probe.
;;   bb -cp out scripts/native_core_reingest_probe.clj \
;;      <port> <space-id> <scratch-root> <manifest.tsv> [<page-limit>]
;; One pinned corpus scan serves every module: draining per module would not be
;; version-pinned across the set.
(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[framrpc :as wire]
         '[fram.code-reader :as code-reader]
         '[fram.rt :as rt]
         '[fram.types :as t])

(def ^:private args (vec *command-line-args*))

(when (< (count args) 4)
  (binding [*out* *err*]
    (println "usage: native_core_reingest_probe.clj <port> <space> <scratch-root> <manifest.tsv> [page-limit]"))
  (System/exit 2))

(def port (Long/parseLong (nth args 0)))
(def space (nth args 1))
(def checkout-root (nth args 2))
(def manifest-path (nth args 3))
(def page-limit (when-let [v (get args 4)] (Long/parseLong v)))

;; The scratch copy, not the origin, is the oracle: an actively edited source tree
;; would otherwise be compared against bytes that were never ingested.
(def manifest
  (into {} (for [line (str/split-lines (slurp manifest-path))
                 :when (not (str/blank? line))
                 :let [[m orig copy] (str/split line #"\t" 3)]]
             [m {:origin orig :copy copy}])))

(def beagle
  (or (not-empty (str (System/getenv "FRAM_BEAGLE")))
      (str (System/getProperty "user.home") "/code/beagle/main/bin/beagle")))

(defn- strip-ws [s] (str/replace s #"[ \t\r\n]" ""))

(defn- first-divergence [a b]
  (let [al (str/split-lines a)
        bl (str/split-lines b)]
    (loop [i 0]
      (cond
        (and (>= i (count al)) (>= i (count bl))) nil
        (>= i (count al)) {:line (inc i) :committed nil :rendered (nth bl i)}
        (>= i (count bl)) {:line (inc i) :committed (nth al i) :rendered nil}
        (not= (nth al i) (nth bl i))
        {:line (inc i) :committed (nth al i) :rendered (nth bl i)}
        :else (recur (inc i))))))

(defn- module-names [corpus]
  (->> (:triples corpus)
       (keep (fn [tr]
               (let [s (t/triple-t1 tr)]
                 (when (and (= "file" (t/triple-t2 tr))
                            (string? s)
                            (str/starts-with? s "@")
                            (str/ends-with? s "#root"))
                   (subs s 1 (- (count s) 5))))))
       distinct sort vec))

;; Cross-check against TermCodecV1's depth bound directly, independent of the
;; reader's own derived maximum-page-limit.
(defn- page-limit-accepted? [n]
  (try
    (-> (rt/native-call! port space :rpc/scan
                         (wire/rpc-triple-pattern! nil nil nil) nil
                         (wire/rpc-page-request! n nil) nil)
        rt/require-native-success!)
    true
    (catch Throwable e (not= :term-depth-exceeded (:code (ex-data e))))))

(def effective-page-limit
  (or page-limit
      (loop [lo 1 hi 4096]
        (if (>= (inc lo) hi)
          lo
          (let [mid (quot (+ lo hi) 2)]
            (if (page-limit-accepted? mid) (recur mid hi) (recur lo mid)))))))
(println (format "probe: largest page limit the wire accepts = %d"
                 effective-page-limit))

(println "probe: draining one pinned whole-corpus snapshot …")
(def corpus (code-reader/read-corpus-snapshot! port space effective-page-limit))
(println (format "probe: version=%d pages=%d triples=%d"
                 (:version corpus) (:pages corpus) (count (:triples corpus))))

(def modules (module-names corpus))
(println (format "probe: %d module(s) registered in the corpus: %s"
                 (count modules) (str/join " " modules)))

(def expected-modules (vec (sort (keys manifest))))
(def missing (vec (remove (set modules) expected-modules)))

(def results
  (vec
   (concat
    (for [m missing]
      {:module m :ingested false :verdict :not-ingested})
    (for [m modules]
      (try
        (let [snap (code-reader/module-snapshot-from-corpus! checkout-root m corpus)
              rendered (code-reader/render-module! beagle snap)
              source (:source rendered)
              committed-path (get-in manifest [m :copy])
              committed (slurp (io/file committed-path))
              exact? (= committed source)
              layout? (= (strip-ws committed) (strip-ws source))]
          (spit (io/file checkout-root "rendered" (str m ".rendered")) source)
          {:module m
           :ingested true
           :triples (count (:triples snap))
           :root (get-in snap [:snapshot :root])
           :committed-path (get-in manifest [m :origin])
           :verdict (cond exact? :byte-exact
                          layout? :layout-only
                          :else :token-loss)
           :committed-lines (count (str/split-lines committed))
           :rendered-lines (count (str/split-lines source))
           :where (when-not exact? (first-divergence committed source))})
        (catch Throwable e
          {:module m :ingested true :verdict :error
           :error (str (.getMessage e) " " (pr-str (ex-data e)))}))))))

(println)
(println "MODULE                    INGESTED  TRIPLES  VERDICT       LINES(committed->rendered)  FIRST DIVERGENCE")
(doseq [{:keys [module ingested triples verdict committed-lines rendered-lines where error]} results]
  (println (format "%-24s  %-8s  %7s  %-12s  %-26s  %s"
                   module
                   (if ingested "yes" "NO")
                   (str (or triples "-"))
                   (name verdict)
                   (if committed-lines
                     (str committed-lines " -> " rendered-lines)
                     "-")
                   (cond
                     error (str "ERROR: " error)
                     where (str "line " (:line where)
                                " committed=" (pr-str (:committed where))
                                " rendered=" (pr-str (:rendered where)))
                     :else "-"))))

(println)
(doseq [[verdict group] (sort-by key (group-by :verdict results))]
  (println (format "  %-12s %d module(s)" (name verdict) (count group))))

(spit (str checkout-root "/probe-results.edn") (pr-str results))
(println (str "\nprobe: per-module detail -> " checkout-root "/probe-results.edn"))

(System/exit (if (some #(= :error (:verdict %)) results) 1 0))
