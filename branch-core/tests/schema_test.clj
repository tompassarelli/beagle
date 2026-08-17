;; schema_test.clj — the store schema layer: cardinality-driven supersession,
;; refs, find-by, identity (name/rename/resolve). Mirrors the oracle's
;; schema.rkt/graph.rkt semantics.
;;   bb -cp out tests/schema_test.clj
;;
;; Ported to the recursive-Term store (S1 of the store-migration ruling): the
;; per-call `tx` argument is gone (each write is its own OCC-guarded
;; transaction), a write returns its ASSERTION OCCURRENCE COORDINATE instead of a
;; fact cid, and a predicate id is the spelling Term rather than a value-object
;; id. The bars themselves are unchanged.
(require '[fram.store :as c] '[fram.schema :as s]
         '[fram.rotation :as rot] '[fram.types :as t])

(def ctx (c/new-term-store "schema-test"))
(def sess (s/session! ctx))
(s/setup! sess)
(s/def-predicate! sess "title" "single" "literal")
(s/def-predicate! sess "tag" "multi" "literal")
(s/def-predicate! sess "depends_on" "multi" "ref")

(def tnode (s/mint-node! sess "name" "@t1"))
(s/assert! sess tnode "title" "First")
(def title1 (s/lookup sess tnode "title"))
(s/assert! sess tnode "title" "Second")           ; single -> supersede "First"
(def title2 (s/lookup sess tnode "title"))
(def title-all (s/lookup-all sess tnode "title"))
(s/assert! sess tnode "tag" "a")
(s/assert! sess tnode "tag" "b")                  ; multi -> keep both
(def tags (s/lookup-all sess tnode "tag"))
(def u (s/mint-node! sess "name" "@u1"))
(s/link! sess tnode "depends_on" u)               ; ref
(def deps (s/lookup-all sess tnode "depends_on"))
(def resolved (s/resolve-name sess "@t1"))
(def nm (s/name-of sess tnode))
(s/name! sess tnode "@t1-renamed")                ; rename -> supersede old name
(def nm2 (s/name-of sess tnode))
(def resolved2 (s/resolve-name sess "@t1-renamed"))
(def old-resolves (s/resolve-name sess "@t1"))

(def open-subj (s/mint-node! sess "kind" "open-subject"))
(s/assert! sess open-subj "open_pred" "open-value")
(def open-pid (s/resolve-predicate sess "open_pred"))

(def status-pid (s/def-predicate! sess "status" "single" "literal"))
(s/alias-predicate! sess "status" "state")
(def status-subj (s/mint-node! sess "kind" "status-subject"))
(s/assert! sess status-subj "status" "draft")
(s/assert! sess status-subj "state" "ready")
(def renamed-status-pid (s/rename-predicate! sess "status" "phase"))
(s/assert! sess status-subj "phase" "done")

(def collision-left (s/def-predicate! sess "collision_left" "multi" "literal"))
(def collision-right (s/def-predicate! sess "collision_right" "multi" "literal"))
(def alias-collision-rejected
  (try
    (s/alias-predicate! sess "collision_left" "collision_right")
    false
    (catch clojure.lang.ExceptionInfo _ true)))
(def canonical-collision-rejected
  (try
    (s/rename-predicate! sess "collision_left" "collision_right")
    false
    (catch clojure.lang.ExceptionInfo _ true)))

(def atomic-ctx (c/new-term-store "schema-test-atomic"))
(def atomic-sess (s/session! atomic-ctx))
(s/setup! atomic-sess)
(s/def-predicate! atomic-sess ":atomic_auto" "multi" "literal")
(def atomic-before-store @atomic-ctx)
(def atomic-before-dump (pr-str (c/dump-term-store atomic-ctx)))
(def auto-register-collision-rejected
  (try
    (s/register-predicate! atomic-sess "atomic_auto")
    false
    (catch clojure.lang.ExceptionInfo _ true)))
(def auto-register-store-unchanged (= atomic-before-store @atomic-ctx))
(def auto-register-dump-unchanged
  (= atomic-before-dump (pr-str (c/dump-term-store atomic-ctx))))

(def user-alias-before-store @atomic-ctx)
(def user-alias-before-dump (pr-str (c/dump-term-store atomic-ctx)))
(def user-alias-collision-rejected
  (try
    (s/alias-predicate! atomic-sess "fresh_alias_source" ":atomic_auto")
    false
    (catch clojure.lang.ExceptionInfo _ true)))
(def user-alias-store-unchanged (= user-alias-before-store @atomic-ctx))
(def user-alias-dump-unchanged
  (= user-alias-before-dump (pr-str (c/dump-term-store atomic-ctx))))

(def rename-before-store @atomic-ctx)
(def rename-before-dump (pr-str (c/dump-term-store atomic-ctx)))
(def rename-preflight-collision-rejected
  (try
    (s/rename-predicate! atomic-sess "fresh_rename_source" ":atomic_auto")
    false
    (catch clojure.lang.ExceptionInfo _ true)))
(def rename-store-unchanged (= rename-before-store @atomic-ctx))
(def rename-dump-unchanged
  (= rename-before-dump (pr-str (c/dump-term-store atomic-ctx))))

(def stable-literal-pid (s/def-predicate! sess "stable_literal" "multi" "literal"))
(s/alias-predicate! sess "stable_literal" "stable_value")
(def stable-subj (s/mint-node! sess "kind" "stable-subject"))
(def stable-literal-occ (s/assert! sess stable-subj "stable_value" "needle"))
(def stable-ref-pid (s/def-predicate! sess "stable_ref" "multi" "ref"))
(s/alias-predicate! sess "stable_ref" "points_to")
(def stable-target (s/mint-node! sess "kind" "stable-target"))
(def stable-ref-occ (s/link! sess stable-subj "points_to" stable-target))

(defn- predicate-written [occurrence]
  (t/triple-t2 (rot/proposition-of (rot/event-at (s/view sess) occurrence))))

(def checks
  [["assert! then lookup"                  (= "First" title1)]
   ["single-valued update supersedes"      (= "Second" title2)]
   ["lookup-all shows only the live value" (= ["Second"] title-all)]
   ["multi-valued keeps all values (ord)"  (= ["a" "b"] tags)]
   ["link! ref resolves to the entity"     (= [u] deps)]
   ["resolve-name -> the entity"           (= tnode resolved)]
   ["name-of returns the name"             (= "@t1" nm)]
   ["rename supersedes the old name"       (= "@t1-renamed" nm2)]
   ["rename: id stable, new name resolves" (= tnode resolved2)]
   ["old name no longer resolves"          (nil? old-resolves)]
   ["cardinality read: single"             (= "single" (s/cardinality sess "title"))]
   ["cardinality read: multi"              (= "multi" (s/cardinality sess "tag"))]
   ["unregistered predicate defaults multi" (= "multi" (s/cardinality sess "nope"))]
   ["unknown write auto-registers canonical predicate"
    (and (= open-pid "open_pred")
         (= "open_pred" (s/predicate-name sess open-pid))
         (= [open-pid] (s/find-by sess "predicate_name" "open_pred")))]
   ["canonical and colon alias resolve one predicate id"
    (= open-pid (s/resolve-predicate sess ":open_pred"))]
   ["alias and rename preserve predicate identity"
    (and (= status-pid renamed-status-pid)
         (= status-pid (s/resolve-predicate sess "status"))
         (= status-pid (s/resolve-predicate sess "state"))
         (= status-pid (s/resolve-predicate sess "phase"))
         (= status-pid (s/resolve-predicate sess ":phase")))]
   ["rename records the old canonical spelling as an alias"
    (some #{status-pid} (s/find-by sess "predicate_alias" "status"))]
   ["aliases and rename share one logical value group"
    (and (= ["done"] (s/lookup-all sess status-subj "status"))
         (= ["done"] (s/lookup-all sess status-subj "state"))
         (= ["done"] (s/lookup-all sess status-subj "phase"))
         (= 1 (count (rot/by-t12 (s/view sess) status-subj status-pid))))]
   ["alias collision with another canonical rejects loudly"
    alias-collision-rejected]
   ["rename collision with another canonical rejects loudly"
    canonical-collision-rejected]
   ["auto-register default-alias collision rejects before mutation"
    (and auto-register-collision-rejected
         auto-register-store-unchanged
         auto-register-dump-unchanged
         (nil? (c/known-term-handle @atomic-ctx "atomic_auto")))]
   ["user alias collision rejects before registering its source"
    (and user-alias-collision-rejected
         user-alias-store-unchanged
         user-alias-dump-unchanged
         (nil? (c/known-term-handle @atomic-ctx "fresh_alias_source")))]
   ["rename collision rejects before registering its source"
    (and rename-preflight-collision-rejected
         rename-store-unchanged
         rename-dump-unchanged
         (nil? (c/known-term-handle @atomic-ctx "fresh_rename_source")))]
   ["assert and find-by resolve aliases through the stable id"
    (and (= stable-literal-pid (predicate-written stable-literal-occ))
         (= ["needle"] (s/lookup-all sess stable-subj "stable_literal"))
         (= [stable-subj] (s/find-by sess "stable_value" "needle")))]
   ["link and lookup resolve aliases through the stable id"
    (and (= stable-ref-pid (predicate-written stable-ref-occ))
         (= [stable-target] (s/lookup-all sess stable-subj "stable_ref")))]])

(let [fails (remove second checks)]
  (doseq [[nm ok] checks] (println (if ok "  [PASS] " "  [FAIL] ") nm))
  (if (empty? fails)
    (println "\nstore schema:" (count checks) "/" (count checks) "PASS")
    (do (println "\nstore schema:" (count fails) "FAILED") (System/exit 1))))
