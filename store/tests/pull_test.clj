;; pull_test.clj — PULL API gate (in-process, mirrors database_test.clj bootstrap).
;; Drives pull/validate + pull/run! against a store built through the database API; no
;; network daemon. A dispatch-level test at the end boots the daemon's `db`/`schema`
;; state in-process and exercises execute-query for {:op :pull}.
;;   bb -cp out tests/pull_test.clj
(require '[store.store :as c] '[store.schema :as s])
(load-file "database.clj")   ; database readers land in `user` (pull references them as user/…)
(require 'pull)           ; the graph-authored module (out/pull.clj). MUST follow database.clj
                          ; (analysis-time qualified-symbol resolution)

(def checks (atom []))
(defn chk [nm ok] (swap! checks conj [nm (boolean ok)]))
(defn throws? [f] (try (f) false (catch Throwable _ true)))

(let [log "/tmp/pull-test.log"
      db  (new-database log)
      st  (:store db)]
  (register-pred! db "title" "single" "literal")
  (register-pred! db "status" "single" "literal")
  (register-pred! db "tag" "multi" "literal")
  (register-pred! db "depends_on" "multi" "ref")
  (register-pred! db "part_of" "single" "ref")
  (register-pred! db "rel" "multi" "ref")            ; unguarded ref: for cycle/depth tests

  ;; --- corpus ---------------------------------------------------------------
  (commit! db "u" "@x" "title" :assert "Ship v1" nil)
  (commit! db "u" "@x" "status" :assert "open" nil)
  (commit! db "u" "@x" "tag" :assert "red" nil)
  (commit! db "u" "@x" "tag" :assert "blue" nil)
  (commit! db "u" "@x" "depends_on" :link "@dep1" nil)
  (commit! db "u" "@dep1" "title" :assert "Design" nil)
  (commit! db "u" "@a" "part_of" :link "@x" nil)     ; reverse: (@a part_of @x)
  (commit! db "u" "@b" "part_of" :link "@x" nil)

  ;; --- (1) flat scalar attrs ------------------------------------------------
  (let [r (pull/run! st "@x" ["title" "status"] {})]
    (chk "flat: :store/id present" (= "@x" (:store/id r)))
    (chk "flat: single scalar title" (= "Ship v1" (get r "title")))
    (chk "flat: single scalar status" (= "open" (get r "status"))))

  ;; --- (2) single- vs multi-cardinality rendering ---------------------------
  (let [r (pull/run! st "@x" ["status" "tag"] {})]
    (chk "cardinality: single -> scalar" (string? (get r "status")))
    (chk "cardinality: multi -> vector" (vector? (get r "tag")))
    (chk "cardinality: multi values present" (= #{"red" "blue"} (set (get r "tag")))))

  ;; --- (3) nested ref recursion ---------------------------------------------
  (let [r (pull/run! st "@x" [{"depends_on" ["title"]}] {})
        deps (get r "depends_on")]
    (chk "nested: depends_on is a vector" (vector? deps))
    (chk "nested: target :store/id" (= "@dep1" (:store/id (first deps))))
    (chk "nested: target attr pulled" (= "Design" (get (first deps) "title"))))

  ;; --- (4) reverse ref ------------------------------------------------------
  (let [r (pull/run! st "@x" ["_part_of"] {})
        rev (get r "_part_of")]
    (chk "reverse: vector of subjects" (vector? rev))
    (chk "reverse: found the pointing subjects" (= #{"@a" "@b"} (set (map :store/id rev)))))

  ;; --- (5) :* wildcard ------------------------------------------------------
  (let [r (pull/run! st "@x" [:*] {})]
    (chk "wildcard: includes title" (= "Ship v1" (get r "title")))
    (chk "wildcard: includes multi tag" (= #{"red" "blue"} (set (get r "tag"))))
    (chk "wildcard: ref rendered as name string (no recursion)" (= ["@dep1"] (get r "depends_on")))
    (chk "wildcard: reserved preds hidden" (not (contains? r "name"))))

  ;; --- (6) provenance -------------------------------------------------------
  (let [r (pull/run! st "@x" ["status"] {:provenance true})
        p (get r "status")]
    (chk "prov: :val" (= "open" (:val p)))
    (chk "prov: :cid is an int" (integer? (:cid p)))
    (chk "prov: :by is the agent" (= "u" (:by p)))
    (chk "prov: :seq is an int" (integer? (:seq p)))
    (chk "prov: :ts is a wall-clock instant string" (and (some? (:ts p)) (string? (:ts p))))
    (chk "prov: :ts parses as an Instant (ISO-8601)" (some? (try (java.time.Instant/parse (:ts p)) (catch Throwable _ nil))))
    (chk "prov: live value :withdrawn false" (= false (:withdrawn p))))

  ;; --- (7) provenance surfaces a WITHDRAWN value with attribution ------------
  (retract! db "w" "@x" "tag" "red" nil "no longer relevant")
  (let [plain (pull/run! st "@x" ["tag"] {})
        prov  (pull/run! st "@x" ["tag"] {:provenance true})
        red   (first (filter #(= "red" (:val %)) (get prov "tag")))]
    (chk "withdraw: plain view drops the withdrawn value" (= #{"blue"} (set (get plain "tag"))))
    (chk "withdraw: provenance surfaces the withdrawn value" (some? red))
    (chk "withdraw: :withdrawn true" (= true (:withdrawn red)))
    (chk "withdraw: :withdrawn_by" (= "w" (:withdrawn_by red)))
    (chk "withdraw: :withdrawn_reason" (= "no longer relevant" (:withdrawn_reason red)))
    (chk "withdraw: :withdrawn_at present" (some? (:withdrawn_at red)))
    ;; the value's :ts is its OWN asserting tx wall-clock, NOT the withdrawal's; and
    ;; :withdrawn_at holds the retract SEQ (a numeric string) — the two never conflate.
    (chk "withdraw: withdrawn value still carries its own assert :ts" (some? (:ts red)))
    (chk "withdraw: :ts (assert wall-clock) distinct from :withdrawn_at (retract seq)"
         (not= (:ts red) (:withdrawn_at red))))

  ;; --- (8) as-of: historical value + historical withdrawal state ------------
  (let [r1 (commit! db "u" "@y" "status" :assert "s1" nil)
        r2 (commit! db "u" "@y" "status" :assert "s2" nil)
        atS1 (pull/run! st "@y" ["status"] {:as-of (:ok r1)})
        now  (pull/run! st "@y" ["status"] {})]
    (chk "as-of: sees the historical value at S1" (= "s1" (get atS1 "status")))
    (chk "as-of: current view sees the latest" (= "s2" (get now "status"))))
  (let [rt (commit! db "u" "@y" "tag" :assert "T" nil)
        _  (retract! db "u" "@y" "tag" "T" nil)                 ; withdrawn AFTER seqT
        atT (pull/run! st "@y" ["tag"] {:provenance true :as-of (:ok rt)})
        tv  (first (filter #(= "T" (:val %)) (get atT "tag")))]
    (chk "as-of: value withdrawn after S is live at S" (some? tv))
    (chk "as-of: withdrawal after S renders :withdrawn false at S" (= false (:withdrawn tv))))

  ;; --- (9) caps: max-depth truncation ---------------------------------------
  (commit! db "u" "@c1" "rel" :link "@c2" nil)
  (commit! db "u" "@c2" "rel" :link "@c3" nil)
  (commit! db "u" "@c3" "rel" :link "@c4" nil)
  (let [r (pull/run! st "@c1" [{"rel" :...}] {:max-depth 2})
        c2 (first (get r "rel"))
        c3 (first (get c2 "rel"))
        c4 (first (get c3 "rel"))]
    (chk "max-depth: chain expands to the cap" (and (= "@c2" (:store/id c2)) (= "@c3" (:store/id c3))))
    (chk "max-depth: node beyond the cap is truncated" (and (= "@c4" (:store/id c4)) (:store/truncated c4))))

  ;; --- (10) caps: max-nodes -> :store/truncated ------------------------------
  (let [r (pull/run! st "@x" [{"depends_on" ["title"]}] {:max-nodes 1})
        dep (first (get r "depends_on"))]
    (chk "max-nodes: budget exhausted truncates deeper subjects"
         (and (= "@dep1" (:store/id dep)) (:store/truncated dep) (not (contains? dep "title")))))

  ;; --- (11) cycle: :store/cycle stub + termination ---------------------------
  (commit! db "u" "@k1" "rel" :link "@k2" nil)
  (commit! db "u" "@k2" "rel" :link "@k1" nil)
  (let [r (pull/run! st "@k1" [{"rel" :...}] {})            ; terminating IS the evidence
        k2 (first (get r "rel"))
        back (first (get k2 "rel"))]
    (chk "cycle: revisit on current path becomes a :store/cycle stub"
         (and (= "@k1" (:store/id back)) (:store/cycle back))))

  ;; --- (12) validation: total, never throws ---------------------------------
  (chk "validate: ok pattern -> []"
       (= [] (pull/validate "@x" ["title" {"depends_on" ["title"]} "_part_of" :* {"rel" 3} {"rel" :...}]
                            {:max-depth 3 :max-nodes 10})))
  (chk "validate: pattern must be a vector" (seq (pull/validate "@x" "nope" {})))
  (chk "validate: malformed element" (seq (pull/validate "@x" [42] {})))
  (chk "validate: bad recursion token (0)" (seq (pull/validate "@x" [{"rel" 0}] {})))
  (chk "validate: bad recursion token (string)" (seq (pull/validate "@x" [{"rel" "bad"}] {})))
  (chk "validate: non-positive :max-depth" (seq (pull/validate "@x" ["title"] {:max-depth 0})))
  (chk "validate: non-positive :max-nodes" (seq (pull/validate "@x" ["title"] {:max-nodes -3})))
  (chk "validate: bad root" (seq (pull/validate 42 ["title"] {})))
  (chk "validate: never throws on garbage" (not (throws? #(pull/validate {:x 1} {:y 2} {:max-depth :bad}))))
  (chk "run: malformed pattern -> {:error}, no throw"
       (let [r (pull/run! st "@x" [42] {})] (and (map? r) (contains? r :error))))

  ;; --- (13) unknown root: sensible empty node (documented choice) ------------
  (chk "unknown root -> bare {:store/id} node, not an error"
       (= {:store/id "@nope"} (pull/run! st "@nope" ["title"] {})))

  ;; --- (14) vector root -----------------------------------------------------
  (let [r (pull/run! st ["@x" "@dep1"] ["title"] {})]
    (chk "vector root: one node per root" (and (vector? r) (= 2 (count r))))
    (chk "vector root: nodes resolve independently"
         (= ["Ship v1" "Design"] (mapv #(get % "title") r)))))

;; --- (14b) :ts SURVIVES BOOT REPLAY from the v2 log ---------------------------
;; Commit through a database (v2 log), capture the LIVE-rendered :ts, then rebuild a fresh
;; store from that log ALONE via database/replay and pull the same fact: identical :ts proves
;; the wall-clock stamp is durable (recovered from the logged :tx record), not a per-read
;; clock call. This is the "restart case" — the cheapest database re-boot idiom (replay a log
;; into a new store), no socket daemon needed.
(let [rlog "/tmp/pull-ts-replay.log"
      db   (new-database rlog)]
  (register-pred! db "title" "single" "literal")
  (commit! db "u" "@r" "title" :assert "Persisted" nil)
  (let [live    (pull/run! (:store db) "@r" ["title"] {:provenance true})
        live-ts (:ts (get live "title"))
        st2     (replay rlog)                       ; fresh store rebuilt from the log alone
        boot    (pull/run! st2 "@r" ["title"] {:provenance true})
        boot-ts (:ts (get boot "title"))]
    (chk "replay: live render carries :ts" (some? live-ts))
    (chk "replay: booted value equals live value" (= "Persisted" (:val (get boot "title"))))
    (chk "replay: same fact renders the SAME :ts after boot" (= live-ts boot-ts))))

;; --- (15) WIRE: dispatch-level {:op :pull} through the daemon's execute-query -
;; Boot the daemon's db/schema/cache state in-process (no socket) and drive the real
;; execute-query path, proving edits #2/#3 (query-request? + the :pull case branch) wire
;; the op end-to-end. If loading server.clj fails standalone (it also load-files
;; resolve.clj + requires store.{fold,query,datalog,rt}), we SKIP loudly
;; rather than fake the dispatch.
(let [loaded? (try (load-file "server.clj") true
                   (catch Throwable t
                     (println "  [SKIP]  wire dispatch: server.clj not loadable standalone —"
                              (.getMessage t))
                     false))]
  (when loaded?
    ;; Server globals don't exist at THIS file's analysis time (server loads at
    ;; runtime), so reach them through runtime `resolve` — keeps the core suite above
    ;; decoupled from server's own load-time dependencies.
    (let [db-var     (resolve 'db)
          schema-var (resolve 'schema-view)
          cache-var  (resolve 'cache)
          capture    (resolve 'capture-query-roots!)
          exec       (resolve 'execute-query)
          dlog "/tmp/pull-wire-test.log"
          dco  (new-database dlog)]
      (register-pred! dco "title" "single" "literal")
      (commit! dco "u" "@w1" "title" :assert "Wired" nil)
      (reset! @db-var dco)                      ; the daemon's global server atom
      (reset! @schema-var {})
      (reset! @cache-var {:index nil :version -1})
      (let [roots (capture)
            resp  (exec {:op :pull :root "@w1" :pattern ["title"]} roots)]
        (chk "wire: {:op :pull} dispatches through execute-query"
             (= "Wired" (get resp "title")))
        (chk "wire: response carries :store/id" (= "@w1" (:store/id resp))))
      (let [roots (capture)
            resp  (exec {:op :pull :root "@w1" :pattern [{"title" 0}]} roots)]
        (chk "wire: validation errors return the standard :error envelope"
             (and (contains? resp :error) (seq (:error resp))))))))

(let [cs @checks fails (remove second cs)]
  (doseq [[nm ok] cs] (println (if ok "  [PASS] " "  [FAIL] ") nm))
  (if (empty? fails)
    (println "\nPULL API —" (count cs) "/" (count cs) "PASS")
    (do (println "\nPULL API:" (count fails) "FAILED of" (count cs)) (System/exit 1))))
