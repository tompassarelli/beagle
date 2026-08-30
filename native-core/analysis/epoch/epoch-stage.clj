;; epoch-stage.clj — epoch-assignment analysis, report-only.
;;
;; Pure fold: affordance-v2 report JSON (from affordance.clj beside this
;; file) in, epoch map JSON out. Never executes analyzed code, never mutates
;; anything but its output file. No codegen, obligations, or pipeline change:
;; this library only computes and reports epoch maps.
;;
;; Epoch model (the seed of the in-compiler stage):
;;   stage:<mod>/<root>      defn-level region epoch — allocation dies before
;;                           the region root returns (one arena per activation)
;;   loop:<mod>/<defn>       per-iteration epoch inside a loop body (arena
;;                           reset every iteration)
;;   callback:<mod>/<defn>   per-invocation epoch inside an inline callback
;;   caller-owned            the value IS the region's product: it leaves
;;                           through the boundary's own crossing set, so it is
;;                           allocated into the caller's active epoch (in the
;;                           compiler: a caller-passed arena)
;;   static:<mod>            module-init epoch — allocated once while the
;;                           module initializes (fixture statics, constant
;;                           tables), lives for the program (rodata candidate)
;; Anything else is a NAMED refusal (TODO-EPOCH-*) — the stage never guesses.
;;
;; Divergences from what the in-compiler version would do are recorded in the
;; output map under "divergences".

(require '[cheshire.core :as json]
         '[clojure.string :as str])

(def divergences
  ["Operates post-hoc on the affordance-v2 report (escape analysis over bin/beagle-ast JSON), not on the checked core AST inside the pipeline; the in-compiler stage would run as a lowering pass with the typed AST and real node identities in hand."
   "Loop epochs are merged per defn: the analyzer labels every loop boundary in a defn 'loop' with no instance id, so loop:<mod>/<defn> conflates sibling loops; in-compiler each loop node is its own epoch with a per-iteration arena reset."
   "caller-owned is symbolic (owner = caller-of:<root>); in-compiler it is a concrete caller-passed arena threaded by the calling convention, and the caller's epoch-assignment decides the actual region."
   "Refusals are named TODOs; the real stage must resolve each: TODO-EPOCH-MUTABLE-CELL-STORE becomes the store-owned region (case B), TODO-EPOCH-RETURN-PAST-ATTRIBUTED-REGION needs whole-program (multi-level) caller attribution, TODO-EPOCH-RAISED-ERROR needs an error-path epoch, TODO-EPOCH-CLOSURE-CAPTURE and TODO-EPOCH-UNKNOWN-FLOW stay heap/compile-error. static:<mod> assignments are module-init epochs (rodata candidates for constant fixtures); the in-compiler stage materializes them as a static region, not an arena."
   "Site enumeration inherits the analyzer's 29-construct taxonomy (hosted-dialect allocators outside it are not sites at all) and one-level caller-ownership attribution (v2 LIMITS item 7); the in-compiler stage sees every allocation the lowering emits."
   "INTERIOR/PROMOTED inputs inherit every affordance-v2 soundness caveat (LIMITS.md); the in-compiler assignment must be proof-carrying rather than fixture-gated."])

(def defn-level-classes
  #{"module-entrypoint" "compiler-stage-function" "request-dispatch-scope"
    "generation-scope" "none"})

(defn parse-root
  "Boundary label -> root defn name. Labels look like:
   'materialize-program (via emit-instruction)',
   'defn function-valid-ssa? (via caller ... of ...)', 'printable-ascii'."
  [nm]
  (-> nm
      (str/replace-first #"^defn " "")
      (str/split #" \(via" 2)
      first
      str/trim))

(defn region-root-of
  "defn D (qualified mod/name) -> its defn-level region root name, via the
   boundary model: roots ownership first, then caller attribution, else self."
  [roots attributed qual-defn]
  (let [bare (peek (str/split qual-defn #"/"))]
    (or (some (fn [[rk rv]]
                (cond (= rk qual-defn) (peek (str/split rk #"/"))
                      (some #(= % qual-defn) (get rv "owned"))
                      (peek (str/split rk #"/"))
                      :else nil))
              roots)
        (some-> (get attributed qual-defn) (get "boundary") parse-root)
        bare)))

(defn refusal-reason [site]
  (let [route  (get site "route")
        detail (str (get site "detail"))]
    (cond
      (= route "stored")                     "TODO-EPOCH-MUTABLE-CELL-STORE"
      (= route "captured")                   "TODO-EPOCH-CLOSURE-CAPTURE"
      (and (= route "returned")
           (str/includes? detail "raised"))  "TODO-EPOCH-RAISED-ERROR"
      (= route "returned")                   "TODO-EPOCH-RETURN-PAST-ATTRIBUTED-REGION"
      :else                                  "TODO-EPOCH-UNKNOWN-FLOW")))

(defn assign
  "One site -> {:assignment {...}} or {:refusal {...}}. Total: every site
   gets exactly one of the two; unanticipated shapes refuse, never guess."
  [roots attributed site]
  (let [verdict  (get site "verdict")
        class    (get-in site ["boundary" "class"])
        bname    (get-in site ["boundary" "name"])
        module   (get site "module")
        d        (get site "defn")
        qual     (str module "/" d)
        crossing (get site "crossing")
        base     {"site" (get site "site")
                  "defn" d
                  "construct" (get site "construct")
                  "allocates" (get site "allocates")}]
    (cond
      ;; static/module-init epoch: the site is lexically module-level (a
      ;; fixture static or constant table) — allocated once while the module
      ;; initializes, program lifetime. Correct verdict, not a refusal.
      (or (= class "module-def")
          (and (= "stored" (get site "route"))
               (str/includes? (str (get site "detail")) "module-level")))
      {:assignment (assoc base
                          "epoch" (str "static:" module)
                          "kind" "static"
                          "basis" "module-level static: allocated once at module init, program lifetime (rodata candidate for constant fixtures)")}

      (and (= verdict "INTERIOR") (= class "loop-body"))
      {:assignment (assoc base
                          "epoch" (str "loop:" module "/" d)
                          "kind" "loop"
                          "parentEpoch" (str "stage:" module "/"
                                             (region-root-of roots attributed qual))
                          "basis" "INTERIOR to loop body: dies within one iteration")}

      (and (= verdict "INTERIOR") (= class "inline-callback-body"))
      {:assignment (assoc base
                          "epoch" (str "callback:" module "/" d)
                          "kind" "loop"
                          "parentEpoch" (str "stage:" module "/"
                                             (region-root-of roots attributed qual))
                          "basis" "INTERIOR to callback body: dies within one invocation")}

      (and (= verdict "INTERIOR") (contains? defn-level-classes class))
      (let [root (parse-root bname)]
        {:assignment (assoc base
                            "epoch" (str "stage:" module "/" root)
                            "kind" "stage"
                            "attributed" (boolean (get-in site ["boundary" "attributed"]))
                            "basis" (str "INTERIOR to " class " region rooted at " root))})

      (= verdict "PROMOTED")
      (let [root (parse-root bname)]
        {:assignment (assoc base
                            "epoch" (str "stage:" module "/" root)
                            "kind" "stage"
                            "attributed" (boolean (get-in site ["boundary" "attributed"]))
                            "basis" (str "PROMOTED: crossed " (get site "escapesFrom")
                                         ", provably interior to " root "'s region"))})

      (and (= verdict "ESCAPES") crossing)
      (let [root (if (contains? defn-level-classes class)
                   (parse-root bname)
                   (region-root-of roots attributed qual))]
        {:assignment (assoc base
                            "epoch" (str "caller-of:" module "/" root)
                            "kind" "caller-owned"
                            "ownerRoot" root
                            "retainingType" (get site "retainingType")
                            "identity" (get site "identity")
                            "basis" (str "crosses " root "'s own crossing set ("
                                         (get site "detail") "): the region's product, "
                                         "allocated into the caller's epoch"))})

      (= verdict "ESCAPES")
      {:refusal (assoc base
                       "reason" (refusal-reason site)
                       "route" (get site "route")
                       "detail" (get site "detail")
                       "retainingType" (get site "retainingType")
                       "identity" (get site "identity"))}

      :else
      {:refusal (assoc base
                       "reason" "TODO-EPOCH-UNCLASSIFIED"
                       "detail" (str "unanticipated verdict shape: " verdict "/" class))})))

(defn with-validity-binding
  "Attach exactly one validity binding to a site result.

   A successful epoch assignment is semantic: its currentness is the named
   epoch that the fold proved. A refusal is structural: it records the exact
   observed site shape without pretending that semantic currentness was proved."
  [{:keys [assignment refusal] :as result}]
  (cond
    assignment
    {:assignment
     (assoc assignment
            "validityBinding"
            {"kind" "SEMANTIC"
             "currentness" {"kind" "EPOCH"
                             "name" (get assignment "epoch")}
             "basis" (get assignment "basis")})}

    refusal
    {:refusal
     (assoc refusal
            "validityBinding"
            {"kind" "STRUCTURAL"
             "shape" {"verdict" (get refusal "verdict" "ESCAPES")
                      "route" (get refusal "route" "unknown")
                      "reason" (get refusal "reason")}})}

    :else
    (throw (ex-info "epoch site result must contain exactly one outcome"
                    {:result result}))))

(defn build-tree
  "Epoch tree: module -> stage epochs -> loop/callback children, with
   per-epoch allocation counts and per-stage caller-owned production."
  [item modules assignments roots]
  (let [static-counts  (frequencies (keep #(when (= "static" (get % "kind")) (get % "epoch")) assignments))
        stage-counts   (frequencies (keep #(when (= "stage" (get % "kind")) (get % "epoch")) assignments))
        inner          (filter #(#{"loop"} (get % "kind")) assignments)
        inner-by-parent (group-by #(get % "parentEpoch") inner)
        caller-counts  (frequencies (keep #(when (= "caller-owned" (get % "kind"))
                                             (str "stage:" (-> (get % "epoch")
                                                               (str/replace-first "caller-of:" ""))))
                                          assignments))
        root-classes   (into {} (map (fn [[k v]]
                                       [(str "stage:" k) (get v "class")]) roots))
        stage-ids      (sort (distinct (concat (keys stage-counts)
                                               (keys inner-by-parent)
                                               (keys caller-counts)
                                               (keys root-classes))))]
    {"id" (str "module:" (first modules))
     "kind" "module"
     "item" item
     "children"
     (vec
      (concat
       (for [[sid n] (sort static-counts)]
         {"id" sid "kind" "static" "allocations" n})
       (for [sid stage-ids]
            {"id" sid
             "kind" "stage"
             "class" (get root-classes sid "attributed/none")
             "allocations" (get stage-counts sid 0)
             "callerOwnedProduced" (get caller-counts sid 0)
             "children" (vec (for [[eid es] (sort-by key
                                              (group-by #(get % "epoch")
                                                        (get inner-by-parent sid [])))]
                               {"id" eid
                                "kind" (if (str/starts-with? eid "callback:") "callback" "loop")
                                "allocations" (count es)}))})))}))

(defn render-tree [tree]
  (let [sb (StringBuilder.)]
    (.append sb (format "%s%n" (get tree "id")))
    (doseq [st (get tree "children")]
      (if (= "static" (get st "kind"))
        (.append sb (format "  %-72s alloc %3d%n"
                            (str (get st "id") "  [module-init static]")
                            (get st "allocations")))
        (.append sb (format "  %-72s alloc %3d   caller-owned produced %3d%n"
                            (str (get st "id") "  [" (get st "class") "]")
                            (get st "allocations")
                            (get st "callerOwnedProduced"))))
      (doseq [lp (get st "children")]
        (.append sb (format "    %-70s alloc %3d%n" (get lp "id") (get lp "allocations")))))
    (str sb)))

(let [[report-path out-path] *command-line-args*
      _ (when-not (and report-path out-path)
          (binding [*out* *err*]
            (println "usage: bb epoch-stage.clj <affordance-v2-report.json> <out-epoch-map.json>"))
          (System/exit 2))
      report     (json/parse-string (slurp report-path))
      item       (get report "item")
      modules    (get report "modules")
      sites      (get report "sites")
      roots      (get-in report ["boundaries" "roots"])
      attributed (get-in report ["boundaries" "callerAttributed"])
      results    (mapv #(with-validity-binding (assign roots attributed %)) sites)
      assignments (into [] (keep :assignment) results)
      refusals    (into [] (keep :refusal) results)
      total      (count sites)
      _ (assert (= total (+ (count assignments) (count refusals)))
                "fold is not total over sites")
      kind-counts (frequencies (map #(get % "kind") assignments))
      per-epoch   (into (sorted-map) (frequencies (map #(get % "epoch") assignments)))
      refusal-profile (into (sorted-map) (frequencies (map #(get % "reason") refusals)))
      refusal-rate (if (zero? total) 0.0 (double (/ (count refusals) total)))
      tree        (build-tree item modules assignments roots)
      epoch-map   {"item" item
                   "generated" (str (java.time.LocalDate/now))
                   "stage" "epoch-stage.clj S1 — pure fold over affordance-v2 report"
                   "input" report-path
                   "totalSites" total
                   "assigned" (count assignments)
                   "refused" (count refusals)
                   "refusalRate" refusal-rate
                   "assignedByKind" kind-counts
                   "refusalProfile" refusal-profile
                   "perEpochAllocations" per-epoch
                   "epochTree" tree
                   "assignments" assignments
                   "refusals" refusals
                   "divergences" divergences}]
  (spit out-path (json/generate-string epoch-map {:pretty true}))
  (println (str "== epoch map: " item))
  (println (format "sites %d | assigned %d (%.1f%%) | refused %d (%.1f%%)"
                   total (count assignments) (* 100.0 (- 1.0 refusal-rate))
                   (count refusals) (* 100.0 refusal-rate)))
  (println (str "assigned by kind: "
                (str/join ", " (map (fn [[k v]] (str k " " v)) (sort kind-counts)))))
  (when (seq refusal-profile)
    (println "refusal profile:")
    (doseq [[r n] (sort-by (comp - val) refusal-profile)]
      (println (format "  %4d  %s" n r))))
  (println)
  (println "epoch tree (allocation counts):")
  (print (render-tree tree))
  (println)
  (println (str "map written: " out-path)))
