;; tools_test.clj — the CLOSED, O(1) tool catalog + dispatch.
;; Proves: (1) the catalog is exactly TWELVE tools, never minted per-predicate;
;; (2) tell/retract lower to a server-routable {:write} intent (@-normalized
;; refs); (3) reads (show/validate)
;; return rows from a TermStore snapshot; (4) `ask` reaches store.query; (5) unknown tool +
;; missing required param -> :error; (6) the seven graph-AST edit verbs dispatch to the
;; {:edit} envelope. The vocabulary is DATA (a predicate is an entity), so there are no
;; owner-of/set-owner/<pred>-list tools — `show <pred>` and `ask` reach it instead.
;;   bb -cp out tests/tools_test.clj
(require '[store.kernel :as k]
         '[store.schema :as schema]
         '[store.store :as store]
         '[store.tools :as t]
         '[store.types :as terms])

(def checks (atom []))
(defn chk [nm ok] (swap! checks conj [nm ok]))

(defn term-store [space propositions]
  (let [ctx (store/new-term-store space)]
    (if (empty? propositions)
      ctx
      (do
        (store/commit-transaction! ctx (mapv store/assert-operation propositions))
        ctx))))

(def facts
  [(terms/triple "@x" "title" "X thread")     ; single, literal
   (terms/triple "@x" "owner" "personal")     ; single, literal
   (terms/triple "@x" "depends_on" "@y")      ; multi, ref
   (terms/triple "@y" "title" "Y thread")])

(def ctx (term-store "tools-test" facts))
(def cat (t/catalog facts))
(defn has-tool? [nm] (boolean (some #(= (:name %) nm) cat)))
(defn call [tool args] (t/call! ctx cat tool args))

;; (1) CLOSED catalog — EXACTLY these twelve names, no more, no fewer, no per-predicate tools.
(def expected-names
  #{"tell" "retract" "show" "ask" "validate"
    "add-def" "set-body" "rename-def" "insert-after" "insert-before" "replace-in-body"
    "edit-transaction"})
(chk "catalog is EXACTLY the twelve closed tools" (= (set (map :name cat)) expected-names))
(chk "catalog has exactly 12 entries" (= 12 (count cat)))
(chk "no per-predicate tools minted (owner-of/set-owner/depends_on-list absent)"
     (and (not (has-tool? "owner-of")) (not (has-tool? "set-owner"))
          (not (has-tool? "depends_on-list")) (not (has-tool? "depends_on-from"))
          (not (has-tool? "threads")) (not (has-tool? "dependents-of"))))
(chk "catalog has no duplicate tool names" (= (count (map :name cat)) (count (set (map :name cat)))))

;; (2) tell/retract -> server {:write} intent, refs @-normalized by value_kind
(chk "tell (literal pred) -> assert intent, value verbatim"
     (= (:write (call "tell" {:subject "x" :predicate "owner" :object "work"}))
        {:op "assert" :l "@x" :p "owner" :r "work"}))
(chk "tell (pure-ref pred) -> assert intent, bare value @-normalized"
     (= (:write (call "tell" {:subject "x" :predicate "depends_on" :object "z"}))
        {:op "assert" :l "@x" :p "depends_on" :r "@z"}))
(chk "retract -> retract intent"
     (= (:write (call "retract" {:subject "x" :predicate "depends_on" :object "@y"}))
        {:op "retract" :l "@x" :p "depends_on" :r "@y"}))
;; An undeclared predicate defaults to literal even when prior values happen to be refs.
(let [mc [(terms/triple "@x" "tag" "@refnode") (terms/triple "@x" "tag" "plainword")]
      mctx (term-store "tools-undeclared" mc) mcat (t/catalog mc)]
  (chk "undeclared predicate keeps literal verbatim (no value-shape inference)"
       (= (:write (t/call! mctx mcat "retract" {:subject "x" :predicate "tag" :object "plainword"}))
          {:op "retract" :l "@x" :p "tag" :r "plainword"})))

;; A declaration governs the FIRST value; aliases normalize to the canonical
;; spelling before the write intent reaches the server.
(let [df (vec (concat facts
                      [(terms/triple "@friend" "predicate_name" "friend")
                       (terms/triple "@friend" "predicate_alias" ":friend")
                       (terms/triple "@friend" "value_kind" "ref")]))
      dctx (term-store "tools-declared-ref" df)
      dcat (t/catalog df)]
  (chk "declared reference predicate normalizes its first bare write"
       (= (:write (t/call! dctx dcat "tell"
                          {:subject "x" :predicate ":friend" :object "z"}))
          {:op "assert" :l "@x" :p "friend" :r "@z"}))
  (chk "shared predicate normalization resolves aliases for CLI callers"
       (= "friend" (t/canonical-predicate (schema/session! dctx) ":friend"))))

;; An explicit negative declaration wins over the transitional depends_on
;; fallback, so a literal that happens to look like an id stays literal.
(let [lf (vec (concat facts
                      [(terms/triple "@depends_on" "predicate_name" "depends_on")
                       (terms/triple "@depends_on" "value_kind" "literal")]))
      lctx (term-store "tools-explicit-literal" lf)
      lcat (t/catalog lf)]
  (chk "explicit literal overrides reference fallback"
       (= (:write (t/call! lctx lcat "tell"
                          {:subject "x" :predicate "depends_on" :object "z"}))
          {:op "assert" :l "@x" :p "depends_on" :r "z"})))

;; (3) reads from the TermStore snapshot
(chk "show @x returns its facts (pred/value rows)"
     (= (set (map (fn [r] [(:pred r) (:value r)]) (:rows (call "show" {:subject "x"}))))
        #{["title" "X thread"] ["owner" "personal"] ["depends_on" "@y"]}))
(chk "show accepts a bare id (auto-@)"
     (= (set (map :pred (:rows (call "show" {:subject "@x"})))) #{"title" "owner" "depends_on"}))
(chk "validate returns rows (no violations here -> empty)"
     (vector? (:rows (call "validate" {}))))

(let [space "tools-profile"
      profile "tools-relational"
      declarations
      (into [(k/relational-profile-declaration space profile)]
            (mapv #(k/profile-rule profile %) k/relational-profile-rules))
      propositions (conj declarations (terms/triple "" "predicate" "value"))
      profile-ctx (term-store space propositions)
      rows (:rows (t/call! profile-ctx (t/catalog propositions) "validate" {}))]
  (chk "validate reports declared relational-profile violations"
       (contains? (set (map :rule rows)) "R2")))

;; (4) ask reaches store.query (transitive over the same fold)
(def reaches-q
  {:find "reaches"
   :rules [{:head {:rel "reaches" :args [{:var "a"} {:var "b"}]}
            :body [{:rel "triple" :args [{:var "a"} "depends_on" {:var "b"}]}]}]})
(chk "ask returns :ok with the edge"    (contains? (set (:ok (call "ask" {:query reaches-q}))) ["@x" "@y"]))

;; (5) errors
(chk "unknown tool -> :error"                (contains? (call "nope" {}) :error))
(chk "tell missing object -> :error"         (contains? (call "tell" {:subject "x" :predicate "owner"}) :error))
(chk "retract missing predicate -> :error"   (contains? (call "retract" {:subject "x"}) :error))
(chk "show missing subject -> :error"        (contains? (call "show" {}) :error))
(chk "ask missing :query -> :error"          (contains? (call "ask" {}) :error))

;; (6) GRAPH-AST EDIT verbs: dispatch to the {:edit} envelope (host runs it OUT-OF-BAND).
(chk "structural edit tools present" (and (has-tool? "add-def") (has-tool? "set-body")
                                          (has-tool? "rename-def") (has-tool? "insert-after")
                                          (has-tool? "insert-before")
                                          (has-tool? "replace-in-body")
                                          (has-tool? "edit-transaction")))
(chk "add-def -> {:edit upsert-form} envelope (NOT {:write})"
     (let [r (call "add-def" {:module "schema" :form "(defn f [(x Int)] Int x)"})]
       (and (nil? (:write r))
            (= (:edit r) {:op "upsert-form" :module "schema" :form "(defn f [(x Int)] Int x)"}))))
(chk "set-body -> {:edit set-body} envelope"
     (= (:edit (call "set-body" {:module "schema" :name "cardinality" :body "\"single\""}))
        {:op "set-body" :module "schema" :name "cardinality" :body "\"single\""}))
(chk "rename-def -> {:edit rename} envelope"
     (= (:edit (call "rename-def" {:module "schema" :name "a" :new-name "b"}))
        {:op "rename" :module "schema" :name "a" :new-name "b"}))
(chk "insert-after -> {:edit insert-form} envelope"
     (= (:edit (call "insert-after" {:module "schema" :after "a" :form "(def z 1)"}))
        {:op "insert-form" :module "schema" :after "a" :form "(def z 1)"}))
(chk "insert-before -> {:edit insert-before} envelope"
     (= (:edit (call "insert-before"
                     {:module "schema" :before "setup!" :form "(declare later!)"}))
        {:op "insert-before" :module "schema" :before "setup!"
         :form "(declare later!)"}))
(chk "replace-in-body -> {:edit replace-in-body} envelope"
     (= (:edit (call "replace-in-body" {:module "schema" :name "f" :old "(a)" :new "(b)"}))
        {:op "replace-in-body" :module "schema" :name "f" :old "(a)" :new "(b)" :within nil}))
(chk "edit-transaction -> one multi-definition {:edit} envelope"
     (= (:edit (call "edit-transaction"
                     {:module "schema"
                      :edits [{:op "set-body" :name "a" :body "1"}
                              {:op "set-body" :name "b" :body "2"}]}))
        {:op "edit-transaction" :module "schema"
         :edits [{:op "set-body" :name "a" :body "1"}
                 {:op "set-body" :name "b" :body "2"}]}))
;; server-side required-param enforcement on the edit verbs (fail-closed)
(chk "add-def missing form -> :error"        (contains? (call "add-def" {:module "schema"}) :error))
(chk "set-body missing name/body -> :error"  (contains? (call "set-body" {:module "schema"}) :error))
(chk "insert-before missing before/form -> :error"
     (contains? (call "insert-before" {:module "schema"}) :error))
(chk "edit verb missing module -> :error"    (contains? (call "add-def" {:form "(def x 1)"}) :error))
(chk "edit-transaction missing edits -> :error"
     (contains? (call "edit-transaction" {:module "schema"}) :error))
(chk "edit envelope carries no single-triple :write key"
     (nil? (:write (call "set-body" {:module "schema" :name "c" :body "1"}))))

(let [cs @checks fails (filter (fn [[_ ok]] (not ok)) cs)]
  (doseq [[nm ok] cs] (println (if ok "  [PASS] " "  [FAIL] ") nm))
  (if (empty? fails)
    (println "\nstore.tools:" (count cs) "/" (count cs) "PASS")
    (do (println "\nstore.tools:" (count fails) "FAILED") (System/exit 1))))
