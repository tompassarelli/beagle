(ns fram.tools
  (:require [fram.types :as t]
            [fram.store :as store]
            [fram.schema :as schema]
            [fram.rotation :as rotation]
            [fram.kernel :as k]
            [fram.query :as q]
            [clojure.string :as str]))

(def Op-values #{::tell ::retract ::show ::query ::validate ::upsert-form ::set-body ::rename-def ::insert-after ::insert-before ::replace-in-body ::edit-transaction})

(defrecord PredVal [pred value])

(defn predval-pred [r] (:pred r))

(defn predval-value [r] (:value r))

(defrecord ProfileViolation [proposition rule])

(defn profileviolation-proposition [r] (:proposition r))

(defn profileviolation-rule [r] (:rule r))

(defrecord Param [name type required])

(defn param-name [r] (:name r))

(defn param-type [r] (:type r))

(defn param-required [r] (:required r))

(defrecord ToolSpec [name desc params op pred])

(defn toolspec-name [r] (:name r))

(defn toolspec-desc [r] (:desc r))

(defn toolspec-params [r] (:params r))

(defn toolspec-op [r] (:op r))

(defn toolspec-pred [r] (:pred r))

(defn- at [id]
  (if (string? id) (if (str/starts-with? id "@") id (str "@" id)) id))

(defn ^String canonical-predicate [session ^String pred]
  (let [pid (schema/resolve-predicate session pred)]
  (if (some? pid) (schema/predicate-name session pid) pred)))

(def ref-kind-fallback ["depends_on" "part_of" "relates_to" "clarifies" "amends"])

(defn- ^Boolean fallback-ref? [^String pred]
  (loop [remaining ref-kind-fallback]
  (if (empty? remaining) false (if (= pred (first remaining)) true (recur (rest remaining))))))

(defn ref-value [session ^String pred value]
  (let [canonical (canonical-predicate session pred)
   pid (schema/resolve-predicate session canonical)
   declared (if (nil? pid) nil (schema/lookup session pid schema/value-kind-predicate))
   kind (if (string? declared) declared (if (fallback-ref? canonical) "ref" "literal"))]
  (if (= "ref" kind) (at value) value)))

(defn catalog [_propositions]
  (let [subj-param [(->Param "subject" "string" true)]
   spo-params [(->Param "subject" "string" true) (->Param "predicate" "string" true) (->Param "object" "string" true)]]
  [(->ToolSpec "tell" (str "Assert the fact (subject, predicate, object). A single-valued " "predicate replaces its current value; a multi-valued one accumulates " "across repeated tells. A bare id for a reference predicate is auto-@-" "prefixed. Asserts ANY predicate, including one not yet in the vocabulary " "(predicate cardinality itself is a fact: `tell <pred> cardinality " "single|multi`).") spo-params :tell "") (->ToolSpec "retract" "Retract the exact fact (subject, predicate, object)." spo-params :retract "") (->ToolSpec "show" (str "All facts about <subject>. Predicates are entities too: " "`show <pred>` reveals its cardinality/value_kind/acyclic facts.") subj-param :show "") (->ToolSpec "ask" (str "Ad-hoc recursive query for multi-hop questions and vocabulary " "enumeration. Pass a structured JSON query object. For an ordinary query, " "`find` is a relation-name string (not a rule-head map); rules carry " "`head` and `body` objects. Aggregate queries instead use a `find` object " "with `rel`, `group`, and `agg`. " "A term is {:var \"x\"} or a constant; base relations are fact(l,p,r), " "fact-id(cid,l,p,r), and predicate(pid,spelling,canonical,cardinality,value-kind) " "(the pre-rename names triple/fact are accepted as aliases). " "Recursion and stratified negation are supported; the query is validated before it runs.") [(->Param "query" "object" true)] :query "") (->ToolSpec "validate" "Violations of the relational profile declared by this TermStore." [] :validate "") (->ToolSpec "add-def" (str "Author a graph-upstream Beagle module: add a NEW top-level def, or " "REPLACE an existing one by name (upsert by the def name). `form` is the " "whole top-level form as an EDN datum string, e.g. " "\"(defn add-two [(x Int)] Int (base (+ x 2)))\". Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "form" "string" true)] :upsert-form "") (->ToolSpec "set-body" (str "Author a graph-upstream Beagle module: replace the BODY of an existing " "defn named <name>. `body` is the new body as an EDN datum string, e.g. " "\"(* x 10)\" (params + return type are preserved). Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "name" "string" true) (->Param "body" "string" true)] :set-body "") (->ToolSpec "rename-def" (str "Author a graph-upstream Beagle module: rename a top-level def from <name> " "to <new-name> (O(1), scope-correct via refers_to, shadow-safe; references " "follow by identity). Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "name" "string" true) (->Param "new-name" "string" true)] :rename-def "") (->ToolSpec "insert-after" (str "Author a graph-upstream Beagle module: insert a NEW top-level def AFTER an " "anchor def named <after>, at a CRDT (path,tie) order-key strictly between the " "anchor and its next sibling. `form` is the whole top-level form as an EDN datum " "string, e.g. \"(defn add-two [(x Int)] Int (base (+ x 2)))\". Two concurrent " "inserts after the same anchor COMMUTE (both land at distinct ties). " "Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "after" "string" true) (->Param "form" "string" true)] :insert-after "") (->ToolSpec "insert-before" (str "Author a graph-upstream Beagle module: insert an arbitrary valid " "top-level form BEFORE the named definition anchor <before>. `form` is " "a whole EDN datum string, e.g. \"(declare register-predicate!)\". The " "form is minted as graph facts and attached through a CRDT ordered-wrapper " "edge immediately before the anchor. Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "before" "string" true) (->Param "form" "string" true)] :insert-before "") (->ToolSpec "replace-in-body" (str "Author a graph-upstream Beagle module: replace ONE interior form inside def " "<name>, WITHOUT re-emitting the whole def (the sub-def surgical edit). `old` is " "the existing interior form as an EDN datum string (the anchor — matched " "STRUCTURALLY, like an Edit old_string on the AST; must match exactly one interior " "form, else rejected). `new` is its replacement as an EDN datum string. e.g. old " "\"(when done (finish))\" new \"(when done (cleanup) (finish))\". If `old` is " "AMBIGUOUS (>1 match), the rejection lists candidates with breadcrumbs + a " "copy-pastable enclosing form for each; pass one as the OPTIONAL `within` (an " "enclosing-form EDN datum string) to narrow the search — `old` must then match " "exactly one form INSIDE `within` (structural, survives concurrent edits; prefer " "it to an occurrence index). Preserves all sibling forms + comments. " "Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "name" "string" true) (->Param "old" "string" true) (->Param "new" "string" true) (->Param "within" "string" false)] :replace-in-body "") (->ToolSpec "edit-transaction" (str "Atomically author two or more DISTINCT module-qualified definitions as one coherent graph overlay. " "`module` is the default module; any edit may carry its own `module` override. `edits` contains " "set-body, replace-in-body, or upsert-form objects; upsert identity is derived from its whole form " "and an optional `name` is only an assertion. Fram stages every edit across all touched modules, " "derives the dependency check scope from the graph, renders and type-checks only the FINAL OVERLAY, " "and rejects surviving references to removed bindings, variants, members, or record accessors. " "Success is one sealed canonical graph batch; failure emits and records nothing. " "Recompile-gated + fail-closed.") [(->Param "module" "string" true) (->Param "edits" "array" true)] :edit-transaction "")]))

(defn- spec-by-name [cat ^String name]
  (loop [cs cat]
  (if (empty? cs) nil (if (= (:name (first cs)) name) (first cs) (recur (rest cs))))))

(defn- missing-req [op args]
  (let [need-spo (or (= op :tell) (= op :retract))
   need-module (or (= op :upsert-form) (or (= op :set-body) (or (= op :rename-def) (or (= op :insert-after) (or (= op :insert-before) (or (= op :replace-in-body) (= op :edit-transaction)))))))
   e1 (if (and need-spo (or (nil? (:subject args)) (or (nil? (:predicate args)) (nil? (:object args))))) ["missing required param 'subject' and/or 'predicate' and/or 'object'"] [])
   e2 (if (and (= op :show) (nil? (:subject args))) ["missing required param 'subject'"] [])
   e3 (if (and (= op :query) (nil? (:query args))) ["missing required param 'query'"] [])
   e4 (if (and need-module (nil? (:module args))) ["missing required param 'module'"] [])
   e5 (if (and (= op :upsert-form) (nil? (:form args))) ["missing required param 'form'"] [])
   e6 (if (and (= op :set-body) (or (nil? (:name args)) (nil? (:body args)))) ["missing required param 'name' and/or 'body'"] [])
   e7 (if (and (= op :rename-def) (or (nil? (:name args)) (nil? (:new-name args)))) ["missing required param 'name' and/or 'new-name'"] [])
   e8 (if (and (= op :insert-after) (or (nil? (:after args)) (nil? (:form args)))) ["missing required param 'after' and/or 'form'"] [])
   e9 (if (and (= op :insert-before) (or (nil? (:before args)) (nil? (:form args)))) ["missing required param 'before' and/or 'form'"] [])
   e10 (if (and (= op :replace-in-body) (or (nil? (:name args)) (or (nil? (:old args)) (nil? (:new args))))) ["missing required param 'name' and/or 'old' and/or 'new'"] [])
   e11 (if (and (= op :edit-transaction) (nil? (:edits args))) ["missing required param 'edits'"] [])]
  (vec (concat e1 (concat e2 (concat e3 (concat e4 (concat e5 (concat e6 (concat e7 (concat e8 (concat e9 (concat e10 e11)))))))))))))

(defn call! [ctx cat ^String tool-name args]
  (let [tool tool-name
   spec (spec-by-name cat tool)
   session (schema/session! ctx)
   propositions (rotation/propositions (rotation/all-occurrences (schema/view session)))]
  (if (nil? spec) {:error [(str "unknown tool '" tool "' — call `tools` for the catalog")]} (let [op (:op spec)
   miss (missing-req op args)]
  (if (not (empty? miss)) {:error miss} (let [subj (:subject args)
   pred (canonical-predicate session (str (:predicate args)))
   te (at subj)]
  (cond
  (= op :tell) {:write {:op "assert" :l te :p pred :r (ref-value session pred (:object args))}}
  (= op :retract) {:write {:op "retract" :l te :p pred :r (ref-value session pred (:object args))}}
  (= op :show) {:rows (mapv (fn [value] (->PredVal (t/triple-t2 value) (t/triple-t3 value))) (k/by-t1 propositions te))}
  (= op :query) (let [result (q/run-syntax! propositions (:query args))]
  (if (q/result-ok? result) {:ok (q/result-rows result)} {:error (mapv q/error-message (q/result-errors result))}))
  (= op :validate) {:rows (mapv (fn [value] (->ProfileViolation (t/triple-t1 value) (t/triple-t3 value))) (k/lint-declared-profile propositions (store/space-id ctx)))}
  (= op :upsert-form) {:edit {:op "upsert-form" :module (:module args) :form (:form args)}}
  (= op :set-body) {:edit {:op "set-body" :module (:module args) :name (:name args) :body (:body args)}}
  (= op :rename-def) {:edit {:op "rename" :module (:module args) :name (:name args) :new-name (:new-name args)}}
  (= op :insert-after) {:edit {:op "insert-form" :module (:module args) :after (:after args) :form (:form args)}}
  (= op :insert-before) {:edit {:op "insert-before" :module (:module args) :before (:before args) :form (:form args)}}
  (= op :replace-in-body) {:edit {:op "replace-in-body" :module (:module args) :name (:name args) :old (:old args) :new (:new args) :within (:within args)}}
  (= op :edit-transaction) {:edit {:op "edit-transaction" :module (:module args) :edits (:edits args)}}
  :else {:error [(str "unhandled op for tool '" tool "'")]})))))))
