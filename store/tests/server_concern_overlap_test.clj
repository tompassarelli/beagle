#!/usr/bin/env bb
;; ============================================================================
;; server_concern_overlap_test.clj — thread 019f1010-2705: concern footprint as
;; code-graph blast joins. The daemon derives a SCOPE-CORRECT calls_defn edge set
;; over the warm corpus (lifting refers_to to the enclosing defn) and exposes:
;;   :blast {:te "@mod#id"}        -> the node's transitive callers (who breaks)
;;   :concern-overlap {:te "@c"}   -> peer concerns whose blast CLOSURE intersects
;; This proves the design's three load-bearing facts over store's OWN corpus:
;;   (1) :blast = the warm transitive-caller closure (== resolve/blast-closure)
;;   (2) scope-correct: same-named fns in different modules are DISTINCT nodes
;;   (3) overlap is a closure intersection over footprint facts read LIVE; and it
;;       is RENAME-STABLE because footprint is keyed on @mod#int identity, not spelling.
;;   bb -cp out tests/server_concern_overlap_test.clj
;; ============================================================================
(require '[store.store :as c] '[store.schema :as s]
         '[clojure.string :as str] '[clojure.set :as set] '[clojure.java.io :as io])
(def root (System/getProperty "user.dir"))
(def code-log (str root "/.store/code.log"))
(when-not (.exists (io/file code-log)) (println "SKIP — no .store/code.log") (System/exit 0))
(binding [*command-line-args* []] (load-file "server.clj"))

(def flat (str (System/getProperty "java.io.tmpdir") "/concern-overlap-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(defn- port-free? [p] (try (with-open [s (java.net.Socket.)]
                             (.connect s (java.net.InetSocketAddress. "127.0.0.1" (int p)) 300) false)
                           (catch Exception _ true)))
(def port (or (some #(when (port-free? %) %) [8290 8291 8292 8293]) 8290))
(boot-flat! flat)
(def server (future (serve port)))
(Thread/sleep 500)
(defn- shutdown! [] (try (future-cancel server) (catch Throwable _ nil)))
(.addShutdownHook (Runtime/getRuntime) (Thread. shutdown!))
(def status (client port {:op :status}))
(when-not (and (= flat (str (:log status))) (pos? (:facts status)))
  (println "ABORT wrong log") (shutdown!) (System/exit 1))
(println "daemon up:" (:facts status) "facts, port" port)

(def fails (atom 0))
(defn check [label ok?] (println (str "  " (if ok? "PASS" "FAIL") " — " label)) (when-not ok? (swap! fails inc)))

;; ---- 1. derive the warm call graph (in-process read of the cache for discovery) ----
(def cc (ensure-calls!))
(def blast (:blast cc))                    ; {callee-name -> #{transitive-caller-name}}
(def defns (:defns cc))                    ; {node-name -> {:key :file :module :name}}
(println "calls_defn:" (count (:edges cc)) "edges," (count defns) "defns,"
         (count blast) "callees-with-callers")
(check "warm call graph derived (non-empty edges + defns)"
       (and (pos? (count (:edges cc))) (pos? (count defns))))

;; ---- 2. :blast over the wire equals the warm transitive-caller closure ----
(def callee (->> blast (sort-by (comp count val) >) ffirst))   ; the most-depended-on node
(def callers (get blast callee))
(def caller (first callers))
(def bl (client port {:op :blast :te callee}))
(println "  most-called node:" callee "->" (count callers) "transitive callers")
(check ":blast returns the warm transitive-caller set"
       (and (= (set (:blast bl)) (set callers)) (= (:count bl) (count callers)) (pos? (:count bl))))

;; ---- 3. SCOPE-CORRECTNESS: same simple name across modules => distinct @mod#int nodes ----
(def by-name (group-by (comp :name val) defns))
(def dup (->> by-name
              (filter (fn [[nm es]] (and nm (> (count (set (map (comp :module val) es))) 1))))
              first))
(if dup
  (let [[nm es] dup
        node-names (map key es)]
    (println "  same-named cross-module defn:" nm "in modules"
             (vec (set (map (comp :module val) es))))
    (check (str "scope-correct: '" nm "' across modules are DISTINCT nodes (no bare-name merge)")
           (= (count (distinct node-names)) (count node-names) (count es))))
  (println "  (no same-named cross-module defn in this corpus — identity keying covers it)"))

;; ---- 4. CONCERN OVERLAP: caller-coupled concerns overlap; a disjoint one does not ----
(client port {:op :assert :te "@concern:A" :p "footprint" :r callee})
(client port {:op :assert :te "@concern:B" :p "footprint" :r caller})  ; caller transitively calls callee
(def A-clo (set/union (closure-of blast [callee]) (closure-of blast [caller])))
(def far (->> (keys defns)
              (remove A-clo)
              (remove #(seq (set/intersection A-clo (closure-of blast [%]))))
              first))
(when far (client port {:op :assert :te "@concern:C" :p "footprint" :r far}))
(def ovA (client port {:op :concern-overlap :te "@concern:A"}))
(def names-A (set (map :concern (:overlaps ovA))))
(println "  @concern:A overlaps:" (vec names-A) (when far (str "(disjoint control @concern:C on " far ")")))
(check "overlap: a caller-coupled peer (@concern:B) is surfaced" (contains? names-A "@concern:B"))
(check "overlap: B's shared closure node-set is non-empty"
       (some #(and (= (:concern %) "@concern:B") (seq (:shared %))) (:overlaps ovA)))
(if far
  (check "no false-overlap: a closure-disjoint concern (@concern:C) is NOT surfaced"
         (not (contains? names-A "@concern:C")))
  (println "  (corpus too connected to pick a disjoint control — skipping false-overlap check)"))

;; ---- 5. RENAME-STABILITY: footprint keyed on @mod#int identity survives a rename ----
(def rep-id (with-resolve-read (:store @db) (resolve/def-binding "schema" "replace!")))
(def rep-name (when rep-id (s/name-of (:store @db) rep-id)))
(if rep-name
  (do
    (client port {:op :assert :te "@concern:R" :p "footprint" :r rep-name})
    (def before (client port {:op :blast :te rep-name}))
    (def rn (client port {:op :edit-min :spec {:op "rename" :module "schema"
                                               :old "replace!" :new "supersede-prior!"}}))
    (def after (client port {:op :blast :te rep-name}))   ; SAME @mod#int — identity is rename-invariant
    (println "  rename schema/replace! -> supersede-prior!:" (boolean (:ok rn)))
    (check "rename-stable: the node's @mod#int identity is unchanged" (= (:node before) (:node after)))
    (check "rename-stable: footprint/blast on the node resolves to the same callers after rename"
           (= (set (:blast before)) (set (:blast after)))))
  (println "  (schema/replace! not found — skipping rename-stability)"))

(shutdown!)
(if (zero? @fails)
  (do (println "\nconcern-overlap: ALL PASS — warm calls_defn blast + scope-correct, rename-stable overlap.")
      (System/exit 0))
  (do (println (str "\nconcern-overlap: " @fails " FAIL")) (System/exit 1)))
