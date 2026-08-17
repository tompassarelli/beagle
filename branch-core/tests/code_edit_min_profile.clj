;; profile: break corpus-from-store! into grouping vs per-src table builds; and time a SINGLE-module table build.
(require '[fram.store :as c] '[fram.schema :as s] '[clojure.java.io :as io] '[clojure.edn :as edn])
(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(binding [*command-line-args* []] (load-file "server.clj"))
(require '[resolve :as r])

(def flat (str (System/getProperty "java.io.tmpdir") "/edit-min-profile-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(def database (migrate-flat->database flat))
(def st (:store database))
(defn ms [t0] (/ (- (System/nanoTime) t0) 1e6))

(let [t (c/begin-tx! st "prof")
      sup (or (c/value-id st "supersedes") (c/value! st "supersedes"))]
  (c/set-supersedes-pred! st sup)
  (binding [r/ctx st r/rctx (r/graph st) r/tx t r/SUP sup
            r/file->ents (atom {})
            r/Vp (c/value! st "v") r/KIND (c/value! st "kind") r/REFERS (c/value! st "refers_to")
            r/FIXED (c/value! st "keep_spelling") r/QUAL (c/value! st "qualifier")
            r/CTOR (c/value! st "ctor_prefix") r/ACC (c/value! st "accessor_field")
            r/n-resolved (atom 0) r/n-unresolved (atom 0) r/n-xmod (atom 0) r/n-type (atom 0) r/n-comment (atom 0)
            r/n-forms-walked (atom 0) r/walked-modules (atom #{})
            r/srcs [] r/file-modframe {} r/file-typeframe {} r/file-accessors {}
            r/global-exports {} r/global-type-exports {} r/global-accessor-exports {}]
    ;; grouping only (file->ents + srcs)
    (let [t0 (System/nanoTime)
          NAME (c/value-id r/ctx "name")
          groups (reduce (fn [acc cid]
                           (let [cl (c/fact-of r/ctx cid) nm (c/literal r/ctx (:r cl)) m (r/name->module nm)]
                             (if m (update acc m (fnil conj []) (:l cl)) acc)))
                         {} (c/by-p r/ctx NAME))]
      (reset! r/file->ents groups)
      (set! r/srcs (vec (keys groups)))
      (println (format "grouping (by-p NAME):       %.1f ms   srcs=%d" (ms t0) (count r/srcs))))
    ;; full per-src table build (all 11 modules)
    (let [t1 (System/nanoTime)]
      (set! r/file-modframe  (into {} (map (fn [s] [s (r/module-defs s)]) r/srcs)))
      (set! r/file-typeframe (into {} (map (fn [s] [s (r/module-types s)]) r/srcs)))
      (set! r/file-accessors (into {} (map (fn [s] [s (r/module-accessors s)]) r/srcs)))
      (println (format "per-src tables (ALL 11):    %.1f ms" (ms t1))))
    ;; single-module table build (schema only)
    (let [one (first (filter #(re-find #"schema" %) r/srcs))
          t2 (System/nanoTime)]
      (r/module-defs one) (r/module-types one) (r/module-accessors one)
      (println (format "single-module tables (%s): %.1f ms" one (ms t2))))))
(println "DONE") (System/exit 0)
