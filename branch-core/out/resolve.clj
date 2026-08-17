#!/usr/bin/env bb
;; ============================================================================
;; Turtle #5 — the identity steal: references store IDENTITY, not spelling.
;; ============================================================================
;; A real LEXICAL resolver adds `refers_to <binding-node-id>` to each reference,
;; pointing it at the *correct* binding under shadowing (nearest enclosing scope),
;; not merely a binding with the right spelling. Binding occurrence = a symbol
;; leaf: a top-level def name, a fn/defn param, or a let/loop binding.
;;
;; With references carrying identity:
;;   - rename is O(1): edit ONE binding's name; references render via refers_to.
;;   - rename is EXACT under shadowing: a shadowed inner `red` is a different node
;;     than the outer def, so renaming one leaves the other alone — which text
;;     (sed) structurally cannot do.
;;   - "orphaned reference after delete" is a query (refers_to → a dead node).
;;
;;   bb -cp ~/code/fram/out src/resolve.clj resolve <edn>...
;;   bb -cp ~/code/fram/out src/resolve.clj rename <old> <new> <target> <edn>...
;;   bb -cp ~/code/fram/out src/resolve.clj delete <name> <target> <edn>...
;; ============================================================================
(ns resolve
  (:require [clojure.edn :as edn] [clojure.string :as str]
            [fram.datalog :as d] [cheshire.core :as json]   ; datalog+json: the `callgraph` mode
            [fram.rotation :as rot] [fram.txn :as txn] [fram.types :as t]
            [resolve-ident :as ri]   ; S2: node identity + the store/rotation read-write handle
            [resolve-core :as rc]    ; M1 Cut A: the CRDT order-key algebra + form vocabulary, in Beagle
            [resolve-read :as rr]    ; M1 Cut B: the view-relative read layer + ordered-tree navigation, in Beagle
            [resolve-binds :as rb]   ; M1 Cut C: what a binding form binds (patterns, params, let/for vectors)
            [resolve-modules :as rm] ; M1 Cut D: one module's frame + its import/export surface
            [resolve-render :as rv]  ; M1 Cut E: render a node back to source + the anchor search
            [resolve-query :as rq]   ; M1 Cut F: the code queries — call graph, blast closure, dead private
            [resolve-walk :as rw]    ; M1 Cut G: the lexical walk — every reference to its nearest binding
            [resolve-corpus :as rco] ; M1 Cut L: the corpus/store frame + fresh/warm resolver pipelines
            [resolve-mint :as rmi]   ; M1 Cut I: the mint/author layer — a datum enters the store as facts
            [resolve-verbs :as rvb]))  ; M1 Cut H: the authoring verbs — an edit is a fact operation

(defn- node-reference-predicate? [predicate]
  (and (string? predicate)
       (or (= "child" predicate)
           (= "tail" predicate)
           (rc/ord-pos? predicate)
           (boolean (re-matches #"(?:f|seg|comment)\d+" predicate)))))

(when-not (ns-resolve 'resolve-corpus 'node-reference-predicate?)
  (intern 'resolve-corpus 'node-reference-predicate? node-reference-predicate?))

;; --- bound resolution state (DYNAMIC, inert root) ---------------------------
;; Every piece of computed resolution state lives in a dynamic var with an INERT
;; root binding (nil / empty atom). `resolve-edn!` rebinds them all to a FRESH
;; store before loading EDN, so the resolver runs over an ARBITRARY bound store
;; (a server's warm in-memory store) — not a load-time global. The CLI path calls
;; `resolve-edn!` inside the same binding scope and therefore observes the same
;; store-local state and semantics. Predicate/marker VALUE IDS are
;; store-local (cnf interns ids per store), so they MUST be recomputed against
;; the fresh store and are dynamic too — keeping a root-store value id would write
;; a foreign id into store B (the load-bearing seam GATE B guards).
;; S2: `ctx` is the TermStore atom exposed to store-level callers; `rctx` is the
;; authoring/read Graph over that same store. `tx` and `SUP` have no successor in
;; the frame store: transactions are frames, and retractions create occurrence-native
;; withdrawal records. They survive ONLY as bound Vars for the external shim surface.
(def ^:dynamic ctx nil)
(def ^:dynamic rctx nil)
(def ^:dynamic tx  nil)
(def ^:dynamic SUP nil)

;; Lift a bare store into the handle every layer below reads.
(defn graph
  ([store] (ri/graph! store {}))
  ([store writers] (ri/graph! store writers)))
;; *reject!* — how a verb signals an UNACCEPTABLE edit (collision / no-capture /
;; nothing-to-do / shape violation). The CLI path (-main) wants a process exit code;
;; a LONG-LIVED server running the verb in-process must NOT die on a rejected edit —
;; it binds *reject!* to throw, converting the exit into a catchable signal. Default
;; = real exit (verbatim CLI behavior). Verb arms call (*reject!* code) — or
;; (*reject!* code detail) to hand the driver a structured disambiguation payload
;; (replace-in-body's candidates/:within remedy) — instead of (System/exit code), so
;; the same verb body serves both drivers. The default ignores the detail (the CLI
;; exits); the server binding threads it into the ex-info it throws so `handle`
;; surfaces the candidates to the model.
(def ^:dynamic *reject!* (fn [code & _] (System/exit code)))
;; *resolve-walk?* — does resolve-warm-store! run the whole-corpus lexical walk
;; (run-resolution!, ~the dominant verb-setup cost)? The walk WRITES refers_to over
;; every module. The MINIMAL-OP authoring path (server :edit-min) does NOT need that
;; walk: set-body/upsert-form assert and withdraw structural propositions without
;; reading refers_to, and
;; rename's no-capture check reads refers_to that the server has ALREADY materialized
;; on the store (the clone inherits it) — so re-walking is pure waste AND would double
;; the inherited edges. Bound false by do-edit-min => corpus tables only, no walk. The
;; CLI/text path + cold materialize leave it true (verbatim whole-corpus resolution).
(def ^:dynamic *resolve-walk?* true)
;; *corpus-scope* — restrict corpus-from-store!'s EXPENSIVE per-module FRAME builds
;; (module-defs/types/accessors) to this set of module-name strings, while still
;; deriving the full src/module list + the cheap cross-module export/type/accessor
;; export tables for EVERY module. A verb that edits ONE module (set-body/upsert-form)
;; only reads its OWN module's frame (def-binding/form-for-victim), so building 11
;; modules' frames is waste. nil => full frames for every module (verbatim behavior;
;; rename, which walks consumers' require/frame tables cross-module, leaves it nil).
(def ^:dynamic *corpus-scope* nil)
;; *corpus-cache* — when bound (by the server), the module->entity-ids map to use INSTEAD of the
;; O(total) name-fact reduce in corpus-from-store!. The server maintains it incrementally (add the
;; commit's new named nodes to their module — O(delta)), so the per-verb corpus build drops from
;; O(total-app) to O(edited-module-frame). Valid because the verb's clone == the committed store at
;; clone time, which the cache reflects. nil => full reduce (cold path, reads, the CLI). Just the
;; `groups` map (module-src -> [entity-ids]); frames are still derived (scoped) from it.
(def ^:dynamic *corpus-cache* nil)
(def ^:dynamic file->ents (atom {}))

(defn load-edn [path]
  (rco/load-edn! rctx file->ents path))

;; --- fact-graph accessors --------------------------------------------------
;; render-mode marker predicate value-ids — DYNAMIC, rebound (recomputed against
;; the fresh store) inside `resolve-edn!`; store-local ids must match their store.
(def ^:dynamic Vp nil) (def ^:dynamic KIND nil) (def ^:dynamic REFERS nil)
(def ^:dynamic BOUND nil)   ; #(a) the DURABLE identity edge `bound_to` (persisted; reference -> binding's @mod#int)
(def ^:dynamic FIXED nil) (def ^:dynamic QUAL nil)   ; render-mode markers
(def ^:dynamic CTOR nil)    ; a `->Name` auto-constructor ref: render `->` + the type's name
(def ^:dynamic ACC  nil)    ; a synth field accessor `<lower(Name)>-<field>`: stores the field
;; --- read-time path-selection: the "default-main view" -----------------------
;; A node's live (l,p) group MAY hold
;; more than one fact, and choosing one is a VIEW decision. Today there is exactly one view —
;; default-main — and its policy is "first live". `select-main-1` is THE explicit selection
;; point: it does NOT prove uniqueness, it SELECTS the default-main member of a possibly-multi
;; group. Routing the former bare `(first …)` take-firsts through it makes the selection named
;; rather than silently buried; when first-class views land (VIEWS_AND_BRANCHES §8) this is
;; where a `view` argument attaches (thread E: it now does, via `*view*`).
;; *view* — the read-side attach point first-class views land on (VIEWS_AND_BRANCHES §8;
;; thread E). nil = the privileged default-main view (today's only view): elect the whole
;; group, byte-identical to before. Bound to a view-subject NAME = a named branch overlay:
;; restrict the election to the cids that view selects ((view selects @cid) facts), so the
;; resolver renders a *branch's* line of the code, isolated from main and sibling branches.
(def ^:dynamic *view* nil)
;; M1 Cut B — the view-relative READ layer is now Beagle (src/resolve_read.bclj).
;; The ^:dynamic vars STAY here: server.clj and server tests `binding`
;; them by qualified name (resolve/ctx, resolve/rctx, resolve/*view*, ...), and a var cannot be
;; moved to another namespace without breaking that — a value alias would no
;; longer see the binding, and a :refer alias leaves resolve/ctx unresolvable
;; (qualified-symbol lookup is findInternedVar, which ignores referred vars). So
;; each name below is a one-line wrapper that reads the dynamic state and hands
;; it to the ported function explicitly. Docstrings live with the logic.
(defn view-cids      [v cids]  (rr/view-cids rctx v cids))
(defn select-main-1  [cids]    (rr/select-main-1 rctx *view* cids))
(defn select-causal-1 [cids]   (rr/select-causal-1 rctx *view* cids))

(defn pred-val [e pname] (rr/pred-val rctx *view* e pname))
(defn kind-of  [e] (rr/kind-of rctx *view* e))                           ; default-main kind of node e
(defn sym-val  [e] (rr/sym-val rctx *view* e))                           ; default-main spelling of a symbol
;; ---- CRDT order keys (#36): positions as DATA, insert-anywhere commute ----------
;; A child-position predicate is "f<path>~<tie>": path = logoot int-vector (dense — a
;; path strictly between any two always exists), tie = the child node's atomic name-int
;; (unique -> concurrent same-gap inserts get DISTINCT keys -> both land -> commute).
;; Compare by (path, tie). DUAL parser: also reads the OLD "f<int>" format (path
;; [(inc i)*STEP], tie 0) so the resolver keeps working during corpus migration.
;; Library confirmed standalone in cnf_ordkey_test.clj (Stage A, 12/12).
;; #36 CRDT ORDER KEYS — now Beagle (src/resolve_core.bclj), aliased here so every
;; call site in this file, in server.clj and in server tests keeps
;; its unqualified spelling. ord-parse returns a resolve-core/OrdKey record; it
;; answers :path and :tie exactly as the map it replaced did.
(def ORD-STEP rc/ORD-STEP)
(defn ord-parse [predicate]
  (or (rc/ord-parse predicate)
      (when (string? predicate)
        (when-let [[_ path tie]
                   (re-matches #"f(\d+(?:\.\d+)*)~(t[A-Za-z0-9_-]+)" predicate)]
          {:path (mapv parse-long (str/split path #"\.")) :tie tie}))))
(defn ord-pos? [predicate] (some? (ord-parse predicate)))
(def ord-str rc/ord-str)
(def ord-veccmp rc/ord-veccmp)
(defn- ord-tie-key [tie]
  (if (integer? tie) [0 tie] [1 (str tie)]))
(defn ord-cmp [x y]
  (let [c (ord-veccmp (:path x) (:path y))]
    (if (zero? c)
      (compare (ord-tie-key (:tie x)) (ord-tie-key (:tie y)))
      c)))
(def ord-append rc/ord-append)
(def ord-between rc/ord-between)

(defn ordered-children [e] (rr/ordered-children rctx e))   ; fN children, in CRDT-key (path,tie) order
(defn ordered-segs [e] (rr/ordered-segs rctx e))           ; Turtle #6: a comment node's segN children, in order
(defn head-sym [e] (rr/head-sym rctx *view* e))
(defn unwrap-meta [e] (rr/unwrap-meta rctx *view* e))      ; D2: peel leading (#%meta …) wrappers off a bound form
(defn bound-target [L] (rr/bound-target rctx *view* BOUND L))   ; DURABLE identity edge (bound_to)
(defn refers-target [L] (rr/refers-target rctx *view* BOUND REFERS L)) ; bound_to, else derived refers_to
(defn live-node? [e] (rr/live-node? rctx KIND e))

;; --- binding extraction -----------------------------------------------------
(def PARAM-FORMS rc/PARAM-FORMS)   ; have a [param] vector
(def DEF-FORMS   rc/DEF-FORMS)    ; module value binding: (def name T val)
(def VALUE-DEFS  rc/VALUE-DEFS)    ; value-shaped forms, including nested fn/fn*
(def TOPLEVEL-VALUE-DEFS rc/TOPLEVEL-VALUE-DEFS) ; actual module bindings
(def TYPE-DEFS   rc/TYPE-DEFS)
;; EFFECT-DEFS — top-level forms whose effect is a REGISTRATION (a multimethod method,
;; a defmulti dispatch table, a protocol extension) rather than a fresh value binding.
;; They ARE addressable (read-def surfaces them: defmethod as `M:dispatch`, extensions
;; per target block) and they MUST be writable — the fix a real Clojure issue needs is
;; often exactly one such form (malli-01 = a new `(defmethod accept 'bytes? …)`). The old
;; write-def gate accepted only VALUE-DEFS, so it rejected defmethod with the wrong
;; medicine ("wrap it as (def <name> (defmethod …))" — a multimethod registration is a
;; top-level effect, not a value, so the wrap misleads the model into churn).
(def EXTEND-FORMS rc/EXTEND-FORMS)
(def EFFECT-DEFS  rc/EFFECT-DEFS)
;; every top-level head write-def / upsert-form accepts.
(def WRITABLE-DEFS rc/WRITABLE-DEFS)
(def writable-def-head? rc/writable-def-head?)
;; a writable form whose IDENTITY is its def-name (def/defn/type/protocol/defmulti) — as
;; opposed to defmethod (name+dispatch) and the extend forms (head+target), which key
;; differently and coexist under a shared head/name.
(defn named-def-head? [h] (rc/named-def-head? h))
;; extend-target-lint — REPAIR-GRADE canon lint for extend-protocol / extend-type.
;; In these two macros the TARGET positions (the type/class being extended, and — for
;; extend-protocol — each type in the type/method alternation) must be class SYMBOLS
;; resolvable at MACROEXPANSION. The classic footgun is a LIST in target position:
;;   (extend-protocol Foldable (class (byte-array 0)) (fold [this] ...))
;; extend-protocol/extend-type partition their body by SYMBOL targets vs method forms; a
;; runtime expression there silently MIS-PARTITIONS — the byte-array target never gets the
;; impl, no error fires, the oracle stays red (EXP-025 p2g ring-01 autopsy, 3 red attempts).
;; The correct idiom for a runtime class is a SEPARATE top-level `extend` call:
;;   (extend (Class/forName "[B") ProtocolName {:method-name (fn [args] ...)})
;; plain `extend` DOES take expression targets, so it is NOT linted (that's the fix, not the bug).
;;
;; Detection (per the b4/8d4be17 body-shape): walk everything after the head. A METHOD FORM
;; is a seq whose SECOND element is a param VECTOR `(m [args] body)` or an arity-list
;; `(m ([args] body) ([a b] body))`. A SYMBOL is a legal designator. A seq that is NOT a
;; method form sitting where a designator belongs = a runtime-expression target -> reject.
(defn extend-target-lint [form] (rc/extend-target-lint form))
(def LET-FORMS   rc/LET-FORMS)
(def FOR-FORMS   rc/FOR-FORMS)             ; binding vector carries :when/:while/:let modifiers
(def MATCH-FORMS rc/MATCH-FORMS)                    ; (match expr [pattern body] ...) — patterns bind + ref ctors
;; M1 Cut C — the binding extractor is now Beagle (src/resolve_binds.bclj):
;; what a destructuring pattern / param vector / let-or-for binding vector /
;; match pattern BINDS, and in what order. Wrappers as in Cut B — the ^:dynamic
;; state stays here and is handed over explicitly.
(defn brackets?         [e] (rb/brackets? rctx *view* e))
(defn map-node?         [e] (rb/map-node? rctx *view* e))
(defn collect-bind-syms [node]    (rb/collect-bind-syms rctx *view* node))  ; symbol leaves a pattern binds
(defn collect-or-vals   [node]    (rb/collect-or-vals rctx *view* node))    ; :or DEFAULT value-exprs (live refs)
(defn param-binds       [bracket] (rb/param-binds rctx *view* bracket))     ; parameter names from [(x T) y]
;; let/loop bindings are SEQUENTIAL — binding i's value (and :or defaults) see bindings
;; 0..i-1. let-bind-pairs returns ORDERED entries [bind-syms value-node or-default-vals]
;; so walk/capture can build the frame incrementally (a flat outer-scope walk misses
;; sibling shadowing — a real capture / mis-resolve bug).
(defn let-bind-pairs    [bracket] (rb/let-bind-pairs rctx *view* bracket))
(defn for-bind-pairs    [bracket] (rb/for-bind-pairs rctx *view* bracket))  ; [:bind syms vnode orvals] | [:expr node]
(defn frame-of          [bsyms]   (rb/frame-of rctx *view* bsyms))
(defn match-pat-binds   [pat]     (rb/match-pat-binds rctx *view* pat))     ; the NON-head leaves of a (Ctor a b) pattern

;; --- the lexical walk: resolve each reference to its nearest binding ---------
;; resolution counters — DYNAMIC (fresh atoms per `resolve-edn!` call), so a
;; long-lived server's repeated resolves don't accumulate across runs.
(def ^:dynamic n-resolved (atom 0)) (def ^:dynamic n-unresolved (atom 0))
(def ^:dynamic n-xmod (atom 0)) (def ^:dynamic n-type (atom 0))
(def ^:dynamic n-comment (atom 0))               ; Turtle #6: comment identifier mentions resolved
;; S3.3 scoped-walk instrumentation — count the TOP-LEVEL FORMS the walk visited and
;; the modules it walked, so a caller (the server's gate) can prove a scoped re-resolve
;; is genuinely O(edit-scope): it walks only the affected modules' forms, not O(corpus).
(def ^:dynamic n-forms-walked (atom 0)) (def ^:dynamic walked-modules (atom #{}))
(def ^:dynamic *xresolve* (fn [_] nil))          ; cross-module value resolver: name -> {:node :mode :alias}
(def ^:dynamic *tresolve* (fn [_] nil))          ; type-name -> type-def node (module-local)
(def ^:dynamic *aresolve* (fn [_] nil))          ; accessor-name `point-x` -> [type-def-leaf field-string]
;; M1 Cut G — THE LEXICAL WALK is now Beagle (src/resolve_walk.bclj): the whole
;; descend-and-bind engine (walk / walk-all / walk-fn-arity / walk-pat-heads /
;; walk-quasi / walk-quasi-seq, the binding writes bind! / bind-xmod! /
;; bound-render!, the type-position resolvers, the comment resolver and the
;; per-src driver). As in Cuts B–F the ^:dynamic vars STAY here — server.clj
;; and server tests `binding` them by qualified name — so `walk-env` reads the
;; dynamic state at call time and hands it over as ONE explicit record. Docstrings
;; and the per-def rationale live with the logic, in the module header.
(defn walk-env []
  (rw/->Walk rctx *view* REFERS BOUND FIXED QUAL CTOR ACC
             n-resolved n-unresolved n-xmod n-type n-comment
             *xresolve* *tresolve* *aresolve*))
(defn bind! [L target] (rw/bind! (walk-env) L target))
(defn bind-xmod! [node x] (rw/bind-xmod! (walk-env) node x))
;; ->Name / map->Name auto-constructor prefix in a spelling (bare OR alias-qualified), else nil.
(def ctor-prefix rc/ctor-prefix)
(defn bound-render! [node nm bt] (rw/bound-render! (walk-env) node nm bt))
(defn walk-type [node] (rw/walk-type! (walk-env) node))
(defn walk [node scope] (rw/walk! (walk-env) node (vec scope)))
(defn walk-all [nodes scope] (rw/walk-all! (walk-env) (vec nodes) (vec scope) rw/walk!))
(defn walk-fn-arity [forms scope] (rw/walk-fn-arity! (walk-env) (vec forms) (vec scope) rw/walk!))
(defn walk-pat-heads [pat scope] (rw/walk-pat-heads! (walk-env) pat (vec scope) rw/walk!))
(defn walk-quasi [node scope quoted?] (rw/walk-quasi! (walk-env) node (vec scope) quoted? rw/walk! rw/walk-quasi-seq!))
(defn walk-quasi-seq [children scope quoted?] (rw/walk-quasi-seq! (walk-env) (vec children) (vec scope) quoted? rw/walk!))

;; module frame = all top-level defs (so forward references resolve) ----------
;; M1 Cut D — one module's frame + its import/export surface is now Beagle
;; (src/resolve_modules.bclj). Wrappers as in Cuts B/C; the entity list comes out
;; of the ^:dynamic `file->ents` atom here and is handed over explicitly.
(defn unwrap-def [form] (rm/unwrap-def rctx *view* form))
(defn module-defs [src] (rm/module-defs rctx *view* (rco/file-entities file->ents src)))
;; --- cross-module: parse ns/:require (imports) and js/export (exports) -------
(defn forms-of [src] (rm/forms-of rctx *view* (rco/file-entities file->ents src)))
(defn ns-form [src] (rm/ns-form rctx *view* (rco/file-entities file->ents src)))
(defn module-name [src] (rm/module-name rctx *view* (rco/file-entities file->ents src)))
(defn merge-import-opts [acc modn kids] (rm/merge-import-opts rctx *view* acc modn (vec kids)))
(defn parse-require [src] (rm/parse-require rctx *view* (rco/file-entities file->ents src)))   ; {:refer {name->mod}, :as {alias->mod}, :rename {local->[mod srcname]}}
(defn module-exports [src] (rm/module-exports rctx *view* (rco/file-entities file->ents src))) ; {exported-name -> binding-node}
(defn logical-name-leaf [node] (rm/logical-name-leaf rctx *view* node))
(defn type-name-leaf [d] (rm/type-name-leaf rctx *view* d))                   ; a type def's name-leaf, (Name Params) head unwrapped
(defn module-types [src] (rm/module-types rctx *view* (rco/file-entities file->ents src)))     ; {type-name -> name-leaf}
(defn module-accessors [src] (rm/module-accessors rctx *view* (rco/file-entities file->ents src)))  ; {"point-x" -> [Point-name-leaf "x"]}

;; --- corpus tables (DYNAMIC, inert root) ------------------------------------
;; The loaded sources + every frame/export table derived from them. INERT at root
;; (nil / empty), COMPUTED inside `resolve-edn!` from the FRESHLY-loaded srcs of
;; the bound store. Functions that read these (def-binding, make-xresolve,
;; re-resolve!, the mode dispatch) read the dynamic value at call time, so they
;; see the per-run tables — never a stale load-time global.
(def ^:dynamic srcs [])
(def ^:dynamic file-modframe {})
(def ^:dynamic file-typeframe {})
(def ^:dynamic file-accessors {})
(defn def-binding [src nm] (rco/def-binding file-modframe file-typeframe src nm))  ; value OR type
;; module-name -> {exported-name -> binding-node}
;; beagle modules carry an (ns ...) form but export IMPLICITLY (no js/export), so
;; fall back to ALL top-level defs as the export surface. JS modules with explicit
;; js/export use those. (Clojure semantics agree: a public def IS exported.)
(def ^:dynamic global-exports {})
;; module-name -> {type-name -> type-def name-leaf}
;; types export implicitly too; a consumer's :refer/:as of a record/union/protocol
;; resolves here. Without it, a foreign type child in a structural
;; `(binding-form T)` declaration never tracks a rename and a cross-module delete
;; of the type false-reports 'safe'.
(def ^:dynamic global-type-exports {})
;; module-name -> {"point-x" -> [type-name-leaf field]}
;; synthesized field accessors export too; the cross-module half of the local *aresolve*,
;; so a record rename carries c/point-x / :refer'd point-x (parallel to global-type-exports).
(def ^:dynamic global-accessor-exports {})
(defn make-xresolve [src]
  (rco/make-xresolve rctx *view* (rco/file-entity-map file->ents)
                     global-exports global-type-exports global-accessor-exports src))
;; --- Turtle #6: resolve identifier mentions INSIDE comments -----------------
;; A comment is a sequence of text + symbol-candidate segments. A symbol segment
;; that EXACTLY names an in-scope binding (module def / type / refer-import) gets
;; a refers_to edge — so it renders the binding's CURRENT name and renames with
;; it, exactly like code. A `red-zone` token is one symbol (≠ `red`) and a quoted
;; `"red"` was demoted to text by beagle's lexer, so neither resolves: the rename
;; win without the sed corruption. Module scope (comments-in-bodies are a follow-up).
;; M1 Cut G — the comment resolver and the per-src walk driver are Beagle too
;; (src/resolve_walk.bclj). `walk-corpus` packages the four corpus tables the
;; driver reads; `make-xresolve` lives in resolve_corpus and receives the current
;; global export tables as explicit parameters, then is handed over as the
;; per-src resolver factory, which
;; is why the ^:dynamic *xresolve*/*tresolve*/*aresolve* are no longer rebound on
;; this path — the module builds each src's three resolvers itself. re-resolve! still
;; binds them, and reads them through walk-env.
(defn walk-corpus [] (rco/walk-corpus (vec srcs) file-modframe file-typeframe file-accessors (rco/file-entity-map file->ents)))
(defn cbind! [L target] (rw/cbind! (walk-env) L target))
(defn resolve-comment [e src] (rw/resolve-comment! (walk-env) (walk-corpus) e src))
(defn walk-comments [src] (rw/walk-comments! (walk-env) (walk-corpus) src))
;; the lexical walk over a CHOSEN subset of srcs (reads bound tables). The
;; cross-module tables (global-exports / file-typeframe / ...) are already bound
;; from the WHOLE corpus, so each walked module's imports resolve against every
;; other module's exports exactly as a full walk would — we just restrict WHICH
;; modules we re-walk (and re-write refers_to for). This is the resolver half of
;; S3.3 scoped re-resolve: full tables, partial walk.
(defn run-resolution-over! [walk-srcs]
  (rw/run-resolution-over! (walk-env) (walk-corpus) (vec walk-srcs) make-xresolve
                           n-forms-walked walked-modules))
(defn run-resolution! []        ; the lexical walk over every bound src (reads bound tables)
  (rw/run-resolution! (walk-env) (walk-corpus) make-xresolve n-forms-walked walked-modules))

;; #(a) LIFT — make the materialized refers_to identity-COMPLETE: every DURABLE bound_to
;; edge (leaf -> binding node) must be reflected as a refers_to edge, so identity-first reads
;; (render / callers / callgraph, which read refers_to) follow a renamed or cold-restarted
;; binding even for references the SPELLING walk cannot re-derive — a comment mention whose
;; word no longer names any def, or a same-module reference whose def spelling has moved.
;; The walk (walk / bound-render!) already resolves the references it reaches, WITH their
;; render markers; this only fills the GAP: a bound leaf with no live refers_to gets a plain
;; refers_to to its durable target. Warm-only (refers_to is a derived resolve-pred, re-cut
;; each materialize). Idempotent: leaves already resolved are skipped.
(defn lift-bound-to-refers! [] (rco/lift-bound-to-refers! rctx KIND BOUND REFERS))

(defn- install-corpus-tables! [tables]
  (let [[modframe typeframe accessors exports type-exports accessor-exports]
        (rco/corpus-table-values tables)]
    (set! file-modframe modframe)
    (set! file-typeframe typeframe)
    (set! file-accessors accessors)
    (set! global-exports exports)
    (set! global-type-exports type-exports)
    (set! global-accessor-exports accessor-exports)))

(defn- install-warm-corpus! [groups tables]
  (reset! file->ents groups)
  (set! srcs (rco/table-srcs tables))
  (install-corpus-tables! tables))

(defn- corpus-state []
  (rco/->CorpusState rctx *view* KIND BOUND REFERS file->ents
                     *corpus-cache* *corpus-scope* *resolve-walk?*
                     (vec srcs)
                     (fn [loaded] (set! srcs loaded))
                     install-corpus-tables!
                     install-warm-corpus!
                     run-resolution!
                     run-resolution-over!
                     (fn [line] (binding [*out* *err*] (println line)))))

(defn- sync-authoring-view! [context]
  (let [open @(rr/builder context)
        coordinate (txn/builder-coordinate open)]
    (ri/with-view!
     context
     (rot/staged (rot/project! (ri/store-of context))
                 (t/triple-t1 coordinate)
                 (t/triple-t3 coordinate)
                 (txn/builder-operations open)))))

;; The compiled ports still call ri's immediate-write surface; redirect those Vars
;; to rctx's one builder for the duration of a resolver run.
(def ^:private authoring-write-lock (Object.))
(defn- with-authoring-writes! [context body]
  (locking authoring-write-lock
    (let [original-open ri/open
        original-mint! ri/mint!
        original-assert-on! ri/assert-on!
        original-commit! ri/commit!
        original-assert! ri/assert!
        original-retire! ri/retire!
        builder (rr/builder context)]
    (with-redefs [ri/open
                  (fn [graph]
                    (if (identical? graph context) builder (original-open graph)))
                  ri/mint!
                  (fn [graph target-builder]
                    (if (and (identical? graph context)
                             (identical? target-builder builder))
                      (let [node (txn/mint! builder)]
                        (ri/ordinal! context node)
                        node)
                      (original-mint! graph target-builder)))
                  ri/assert-on!
                  (fn [target-builder subject predicate value]
                    (if (identical? target-builder builder)
                      (let [occurrence (txn/assert! builder (t/triple subject predicate value))]
                        (sync-authoring-view! context)
                        occurrence)
                      (original-assert-on! target-builder subject predicate value)))
                  ri/commit!
                  (fn [graph target-builder]
                    (if (and (identical? graph context)
                             (identical? target-builder builder))
                      context
                      (original-commit! graph target-builder)))
                  ri/assert!
                  (fn [graph subject predicate value]
                    (if (identical? graph context)
                      (rr/assert! context subject predicate value)
                      (original-assert! graph subject predicate value)))
                  ri/retire!
                  (fn [graph occurrence]
                    (if (identical? graph context)
                      (when-let [proposition (ri/proposition-at context occurrence)]
                        (let [withdrawal (txn/retract! builder proposition)]
                          (sync-authoring-view! context)
                          withdrawal))
                      (original-retire! graph occurrence)))]
      (body)))))

(defn- with-corpus-state! [store-or-graph body]
  (let [store (if (map? store-or-graph) (ri/store-of store-or-graph) store-or-graph)
        context (rr/context! store)
        ids (rco/corpus-predicate-ids context)]
    (binding [ctx store
            rctx context
            file->ents (atom {})
            Vp (:Vp ids) KIND (:KIND ids) REFERS (:REFERS ids) BOUND (:BOUND ids)
            FIXED (:FIXED ids) QUAL (:QUAL ids)
            CTOR (:CTOR ids) ACC (:ACC ids)
            n-resolved (atom 0) n-unresolved (atom 0) n-xmod (atom 0) n-type (atom 0) n-comment (atom 0)
            n-forms-walked (atom 0) walked-modules (atom #{})
            srcs [] file-modframe {} file-typeframe {} file-accessors {}
            global-exports {} global-type-exports {} global-accessor-exports {}]
      (let [result (with-authoring-writes! context body)]
        (when (pos? (txn/operation-count (rr/builder context)))
          (rr/commit! context))
        result))))

(defn- corpus-host [] (rco/->CorpusHost with-corpus-state! load-edn corpus-state))

;; ============================================================================
;; resolve-edn! — the RUNNABLE pipeline over an ARBITRARY bound store.
;; Binds a FRESH store (ctx/tx/SUP + predicate value-ids recomputed against it),
;; a fresh file->ents atom, and fresh counters; load-edn's `edn-paths` into that
;; bound store; computes + binds the corpus tables from those srcs; runs the
;; resolution driver; then invokes `body` WITHIN the binding scope (so CLI
;; dispatch — rename/delete/extract/author — and tests read the bound state).
;; The store is local to this call: a server resolving over its warm store gets a
;; clean store B every time, and NOTHING leaks to the inert root binding.
;; ============================================================================
(defn resolve-edn!
  ([edn-paths] (resolve-edn! edn-paths (fn [])))
  ([edn-paths body] (rco/resolve-edn! (corpus-host) (vec edn-paths) body)))

;; ============================================================================
;; S3.2 — resolve WARM, over the server's live store (no EDN reload).
;; The server holds a populated store whose AST nodes are entities carrying the
;; same kind/v/fN facts an --emit-edn projection has, PLUS a `name` fact
;; `@<module>#<int>` (fram.schema/name!). Grouping there is by the name prefix,
;; not by load-edn's per-src tracking — so the ONLY thing that differs from the
;; EDN path is how the corpus structure (file->ents/srcs + frame/export tables)
;; is DERIVED. Everything downstream (module-defs/forms-of/run-resolution!/...)
;; reads file->ents + ctx, which are the bound store, so it is reused verbatim.
;; ============================================================================
;; module of `@kernel#127` -> "kernel" ; the server names every node `@<mod>#<int>`.
(defn name->module [nm]
  (rco/name->module nm))
;; corpus-from-store! — from the BOUND, already-populated store, derive the SAME
;; corpus structure resolve-edn! computes from EDN: file->ents grouped by module,
;; srcs = the module list, then the per-module frame/export tables (reusing
;; module-defs/module-types/module-accessors/module-exports/module-name — they
;; read @file->ents + ctx, which now ARE the warm store). `set!` (not root) so
;; nothing leaks past the binding scope, exactly like resolve-edn!.
(defn corpus-from-store! [] (rco/corpus-from-store! (corpus-state)))

;; ============================================================================
;; S3.3 scoped-classifier helpers — computed from the BOUND warm corpus (call
;; under a binding that has run corpus-from-store!, e.g. with-resolve-read or
;; resolve-modules!'s body). These let the server classify an edit by its
;; binding-SET delta (the load-bearing correctness point), not by syntactic site.
;; ============================================================================
;; module-src-of: the corpus `src` (= module-name string, in the warm path) for a
;; node entity-id, via its module prefix. corpus-from-store! keys srcs by module
;; name, so the `src` and the module name coincide there.
;; module-export-set: every NAME module M makes resolvable to a consumer — the value
;; exports (js/export or, beagle-implicit, all top-level defs) UNION the type exports
;; (records/unions/protocols + variants) UNION the synth field-accessor names. This is
;; precisely the surface a consumer's :refer/:as/:rename can bind, so a change to THIS
;; set is exactly what forces a consumer re-walk; an internal body edit leaves it fixed.
(defn module-export-set [src]
  (rco/module-export-set rctx *view* (rco/file-entity-map file->ents) src))
;; import-graph: {module -> #{modules it imports}} over the whole corpus, from each
;; module's (ns :require ...) / bare (require ...). Consumers of M = the modules whose
;; import-set contains M (the reverse edge). Used to widen the dirty set when M's
;; export-set changed: M PLUS everyone importing M re-resolves.
(defn module-imports [src]
  (rco/module-imports rctx *view* (rco/file-entity-map file->ents) src))
(defn import-graph []
  (rco/import-graph rctx *view* (rco/file-entity-map file->ents) (vec srcs)))
;; module-has-macro?: does M define a defmacro at top level? A macro edit can change
;; how OTHER modules expand, so its blast radius isn't bounded by the import graph —
;; the server falls back to a whole-corpus re-resolve (sound; dormant in fram, which
;; has zero defmacro).
(defn module-has-macro? [src]
  (rco/module-has-macro? rctx *view* (rco/file-entity-map file->ents) src))

;; resolve-warm-store! — bind ctx=the server's store (+ a fresh tx + the value-ids
;; recomputed against THAT store — store-local ids must match their store, the
;; same seam GATE B guards), derive the corpus FROM the store, run the lexical
;; walk (writing refers_to into the store), then invoke body within the scope.
;; Mirror of resolve-edn! with the ONLY change being the corpus source. The store
;; is supplied (the server's warm `co`), not minted, and is mutated in place: the
;; warm refers_to edges callers-of / blast-radius read come straight from here.
(defn resolve-warm-store!
  ([store] (resolve-warm-store! store (fn [])))
  ([store body] (rco/resolve-warm-store! (corpus-host) store body)))

;; ============================================================================
;; S3.3 — resolve-modules! : SCOPED re-resolve over the warm store.
;; Identical store-binding + corpus derivation to resolve-warm-store! (so it sees
;; the FULL cross-module export/import tables — M's imports resolve against every
;; module's exports), but only WALKS (and writes refers_to for) `module-set`. The
;; caller (the server) is responsible for stripping the affected modules' prior
;; refers_to first (resolve-warm-store! re-walks the whole corpus, so the server's
;; whole-corpus strip suffices there; the scoped path strips only module-set). The
;; module list is exposed via `body` (corpus-from-store! sets `srcs` = all modules,
;; so a caller can read it under the binding) and `module-set` selects the walk.
;; module-set is a set of module-name strings (the `@<module>#` prefix), matching
;; the keys `srcs` carries after corpus-from-store!. An empty set walks nothing
;; (a pure table rebuild) — sound when the server classified no module dirty.
;; ============================================================================
(defn resolve-modules!
  ([store module-set] (resolve-modules! store module-set (fn [])))
  ([store module-set body] (rco/resolve-modules! (corpus-host) store module-set body)))

;; --- projection: emit EDN for beagle --render, names resolved via refers_to --
;; follow refers_to transitively (re-export chains: a (js/export name) re-export is
;; itself a reference) to the ULTIMATE binding, and render its current name.
;; M1 Cut E — the render-back-to-source layer is now Beagle (src/resolve_render.bclj).
(defn ultimate [B] (rv/ultimate rctx *view* BOUND REFERS B))        ; follow refers_to to the node that HOLDS the name
(defn binding-name [B] (rv/binding-name rctx *view* BOUND REFERS B))

;; ============================================================================
;; AUTHORING — mint a NEW datum subtree into the SAME Term store (the inverse of
;; facts-roundtrip's datum->facts projection). This is what makes add-def / set-body a
;; graph operation, not a text splice: a Clojure EDN datum (the structured edit
;; spec the agent emits, e.g. `(defn add-two [(x Int)] Int (+ x 2))`) is walked
;; into fresh entities carrying `kind`/`v`/`fN` structural propositions — exactly the reader-datum
;; shape --emit-edn projects — and registered in file->ents so extract-file! emits
;; them. The wrapper/body fN propositions are then asserted (append) or withdrawn
;; (replace), reusing the rename template; the live view excludes withdrawn assertions.
;; The renderer reconstructs purely from fN/tail, so a minted subtree round-trips
;; byte-stable, and any reference in it resolves via the SAME lexical walk (a fresh
;; pass over forms-of after minting), giving scope-correctness for free.
;; ============================================================================
;; M1 Cut I — THE MINT LAYER is Beagle (src/resolve_mint.bclj). As in Cuts B–H the
;; ^:dynamic vars STAY here, so `mint-env` reads the dynamic state at call time and
;; hands it over as ONE record; `file->ents` rides as the ATOM ITSELF (register!
;; must mutate the var the projection reads, not a snapshot).
(defn mint-env [] (rmi/->Mint rctx KIND Vp file->ents *view* BOUND REFERS FIXED))
(defn register! [src e] (rmi/register! (mint-env) src e))
;; leaf-kind: the reader `kind` for a Clojure scalar (mirrors datum->facts:55-64).
;; Beagle reads [..] as (#%brackets ..) and {..} as (#%map ..), so a vector/map datum
;; in the spec is minted as a `list` headed by that desugaring symbol — identical to
;; what --emit-edn produces, keeping the projection lossless.
(defn mint-leaf! [src kind v] (rmi/mint-leaf! (mint-env) src kind v))
;; mint-datum! — THE MINT (M1 Cut I; logic + the per-branch re-encoding rationale
;; in src/resolve_mint.bclj). An EDN datum becomes fresh entities carrying
;; kind/v/fN structural propositions in deterministic file-local allocation order.
;; Reader metadata, regex and set objects are re-encoded as the
;; `(#%meta …)` / `(#%regex …)` / `(#%set …)` nodes beagle's own reader produces.
(defn mint-datum! [src d] (rmi/mint-datum! (mint-env) src d))

;; the body fN edges of a defn form = the consecutive fN child propositions whose slot is
;; AFTER the params bracket (everything --emit-edn put at f5,f6,... in `defn` :122).
(defn fN-facts [parent] (rmi/fN-facts (mint-env) parent))  ; -> [[N assertion-occurrence child-node] ...] over LIVE fN edges, ordered
;; Retract a live structural proposition without a replacement value. The kernel
;; records the withdrawal target occurrence; no domain proposition is manufactured.
(defn retire-fact! [oldc] (rmi/retire-fact! (mint-env) oldc))

;; --- delete projection: omit a top-level form + its subtree, renumber siblings ---
;; The renderer reads fN children CONSECUTIVELY and includes only nodes reachable from
;; the root, so deleting a form means (a) skip its whole subtree (else its orphaned root
;; would compete with the real wrapper) and (b) re-emit the wrapper's surviving forms at
;; consecutive fN (a gap would truncate the file). Pure projection — the store is not mutated.
(defn wrapper-of [src]
  (rmi/wrapper-of rctx *view* (rco/file-entity-map file->ents) src))
(defn structural-kids [n] (rmi/structural-kids rctx n))
(defn descendants [root] (rmi/structural-descendants rctx root))
(defn form-for-victim [src victim]
  (rmi/form-for-victim rctx *view* (rco/file-entity-map file->ents) unwrap-def src victim))
;; extract-file! — THE PROJECTION (M1 Cut I; line construction, the #36 wrapper
;; renumber and the reachability filter all in src/resolve_mint.bclj). Only the
;; writer + `binding [*out* w]` scaffolding stays here — a host dynamic var cannot
;; change namespace — so the module returns the LINES and this printlns them, one
;; per line, byte-for-byte as before.
(defn emit-env []
  (rmi/emit-env rctx *view* BOUND REFERS FIXED
                (rco/file-entity-map file->ents) unwrap-def))
(defn- restore-scalar-integers [lines]
  (let [ordinal->node (into {} (map (fn [[node ordinal]] [ordinal node]) @(:ordinals rctx)))]
    (mapv
     (fn [line]
       (if-not (str/starts-with? line "[")
         line
         (let [[entity predicate _ :as row] (edn/read-string line)
               node (get ordinal->node entity)
               event (when node
                       (first (rr/events-by-subject-predicate rctx node predicate)))
               value (when event (rr/event-value event))]
           (if (and (integer? value)
                    (not (node-reference-predicate? predicate)))
             (pr-str [entity predicate value])
             (pr-str row)))))
     lines)))
(defn extract-file! [src out-path]
  (spit out-path
        (str (str/join "\n"
                       (restore-scalar-integers
                        (rmi/extract-lines! (emit-env) src)))
             "\n")))

;; render output dir honors *resolve-out* (default $RESOLVE_OUT, then /tmp) so
;; concurrent gate runs / agents don't collide on a global /tmp/resolved-*.edn —
;; the gates set it to a per-run temp dir. *resolve-out* is the IN-PROCESS override
;; (System/getenv can't be set at runtime, so the warm-store driver binds this var
;; to route the verb's projection into a per-run dir without re-launching bb).
(defn out-path [src] (rmi/out-path src))

;; --- no-capture invariant ---------------------------------------------------
;; capture-refs — the LEXICAL DUAL of the def-vs-def collision guard (M1 Cut I;
;; logic in src/resolve_mint.bclj). Renaming def B to `new` is UNSOUND if a
;; reference to B would, after rendering as `new`, be captured by a LOCAL binding
;; `new` in scope at that reference — e.g. (def src 1)(defn f [dst] (+ dst src)),
;; rename src->dst yields (+ dst dst). It reuses walk's EXACT frame construction,
;; so the check is scope-precise. `scope` is vec'd here: the module threads
;; cons-lists, Cut G's walk (and now this) uses an innermost-first vector.
(defn capture-refs [node scope B new] (rmi/capture-refs (mint-env) node (vec scope) B new))

;; --- authoring support (used by the upsert-form / set-body case arms) -------
;; re-resolve!: after a mint, the module frame is stale (a new def, or a new body's
;; references). Recompute every module's frame + re-walk forms so fresh references
;; carry refers_to. Idempotent — bind! only adds an edge where one resolves.
;; PARTIAL port (M1 Cut I): the three per-src frame tables come from
;; rmi/re-resolve-frames; the `binding` of *xresolve*/*tresolve*/*aresolve* IS the
;; dynamic scope the re-walk reads and cannot change namespace, so it stays here.
(defn re-resolve! []
  (let [frames    (rmi/re-resolve-frames (vec srcs) module-defs module-types module-accessors)
        modframe  (:modframe frames)
        typeframe (:typeframe frames)
        accessors (:accessors frames)]
    (doseq [src srcs]
      (binding [*xresolve* (make-xresolve src)
                *tresolve* (fn [nm] (get (get typeframe src) nm))
                *aresolve* (fn [nm] (get (get accessors src) nm))]
        (walk-all (forms-of src) (list (get modframe src)))
        (walk-comments src)))))
;; author-emit! — project every src, then report to stderr (M1 Cut I; the report
;; lines in src/resolve_mint.bclj). `detail` is printed as a VALUE, never str'd.
(defn author-emit! [op detail]
  (doseq [src srcs] (extract-file! src (out-path src)))
  (binding [*out* *err*]
    (doseq [line (rmi/author-emit-lines op detail (vec srcs) out-path)] (println line))))

;; ============================================================================
;; STANDALONE AUTHORING VERBS — the SAME arm bodies as the -main case, lifted to
;; named functions so BOTH drivers can run them: the TEXT path (-main, over
;; resolve-edn! of emit-edn(text)) AND the GRAPH path (run-verb-warm!, over a
;; LOG-booted warm store via resolve-warm-store!). They are store-agnostic by
;; construction — they read the dynamic ctx/tx/SUP/srcs/frame tables and write
;; via the assertion/retraction helpers and mint-datum!, never touching text — so the same code
;; runs unchanged under either binding scope.
;;
;; *project-srcs* selects which module(s) author-emit! / extract-file! project.
;; The TEXT path projects EVERY src (whole-corpus EDN round-trip, the old shape).
;; The GRAPH path binds it to just the affected module — render-from-store needs
;; only that one, and projecting the 11-module warm corpus would be wasteful.
;; Default = nil => "all srcs" (verbatim text-path behavior).
(defn- emit-srcs [] (rmi/emit-srcs (vec srcs)))
;; *capture-only?* — the MINIMAL-OP graph edit (server :edit-min) runs the verb ONLY
;; to capture its structural assertion/retraction operations; it does NOT want the verb's two heavy
;; downstream SIDE EFFECTS: (1) re-resolve! (a whole-corpus lexical re-walk that
;; writes DERIVED refers_to edges — discarded, since the server re-resolves SCOPED
;; over the real store after the commit), and (2) author-emit-scoped! (rendering the
;; module's resolved EDN to disk — the minimal path commits store operations, not text).
;; Bound true by do-edit-min so the verb does its graph work and stops. The CLI/text
;; path leaves it false => verbatim behavior (re-resolve + project EDN).
(def ^:dynamic *capture-only?* false)
;; Like author-emit!, but only over the verb environment's selected sources. The
;; closure constructed by verb-env carries the caller's output directory and
;; project-source selection; projection stays on the host path so scalar integers
;; are restored before the rows reach disk.
(defn author-emit-scoped! [resolve-out project-srcs op detail]
  (when-not *capture-only?*
    (let [selected-srcs (rmi/emit-srcs-for project-srcs (vec srcs))
          output-path (fn [src] (rmi/out-path-for resolve-out src))]
      (doseq [src selected-srcs]
        (extract-file! src (output-path src)))
      (binding [*out* *err*]
        (doseq [line (rmi/author-emit-lines op detail selected-srcs output-path)]
          (println line))))))

;; D1: resolve a scope to its target module at a dot-SEGMENT boundary. A raw substring
;; filter (str/includes?) collides a module with any sibling it PREFIXES — scope
;; "cheshire.generate" matched BOTH "cheshire.generate" AND "cheshire.generate_seq" ->
;; rejected as ambiguous (code 3), leaving the module unauthorable. But scope may
;; legitimately be the SHORT module name ("schema" for module "fram.schema"), which the
;; old substring also bridged, so a naive `=` over-tightens (0 matches). The right rule
;; matches only on a `.`-delimited segment boundary: scope equals the module, or is a
;; trailing dotted-suffix of it ("schema" ⊴ "fram.schema" ✓; "cheshire.generate" ⋬
;; "…generate_seq" ✗). Test both the raw src string (warm store keys srcs by module name)
;; and its ns-form module name (the EDN/CLI path keys srcs by the `@file` value) — each
;; direction covers short↔qualified without reopening the prefix-sibling collision.
(defn- scope-match? [src scope]
  (rmi/scope-match? module-name src scope))
(defn- scope->srcs [scope] (rmi/scope->srcs module-name (vec srcs) scope))

;; datum->canon / node->canon / verb-env are defined further down; forward-declare so
;; the upsert victim finder can compare a NEW datum's dispatch/target against an
;; EXISTING node's — both reduce to the SAME canonical vector, so the match is
;; representation-independent.
(declare datum->canon node->canon verb-env)
;; writable-victim / writable-disp-name — WHICH existing top-level form an upsert
;; replaces (nil -> APPEND), and what to call it. M1 Cut J: both are Beagle now
;; (src/resolve_verbs.bclj), next to their only caller, verb-upsert-form!. Nothing
;; in them was host-bound — they read the corpus through the ported read/module
;; layers and compare through datum->canon, which moved in step 1. These wrappers
;; stay for the ns-qualified surface (server.clj calls
;; resolve/writable-disp-name).
(defn writable-victim [src datum] (rvb/writable-victim (verb-env) src datum))
(defn writable-disp-name [datum] (rvb/writable-disp-name datum))
;; render-sym — the spelling a symbol node RENDERS as (mirrors extract-file!'s
;; reference-rendering): a resolved reference shows its binding's CURRENT name
;; (mode-adjusted: ctor prefix, x/qualifier, :rename keep-spelling); an unresolved /
;; literal symbol shows its stored v. Matching the anchor against the RENDERED
;; spelling (not the stored v) is what makes the model's old-form — read off the
;; current source text — line up with the graph even after a prior graph rename.
(defn render-sym [e] (rv/render-sym rctx *view* BOUND REFERS FIXED e))
;; canonical comparison form — structural, formatting-insensitive. Leaf -> [:leaf kind
;; spelling]; list -> [:list child-canon...]. Both an anchor DATUM (as clojure.edn read
;; it) and a graph NODE canonicalize into the SAME shape, re-encoding EDN nil/bool/
;; keyword the beagle way (mint-datum!'s conventions: beagle reads .b* via Racket, so
;; nil/true/false/:kw are all SYMBOL leaves) so `nil`/`true`/`:foo` match their storage.
;; M1 Cut J: the LOGIC is Beagle now (src/resolve_verbs.bclj) — it lives with the two
;; verbs that consume it. This wrapper stays because resolve.clj-local callers
;; (writable-victim's wrapper) and the port's ns-qualified surface use it.
(defn datum->canon [d] (rvb/datum->canon d))
;; anchor-matches — single POST-ORDER pass over a def form's subtree that computes each
;; node's canon EXACTLY ONCE (O(N), not O(N^2) — a naive "canonize every candidate" re-walks
;; each subtree per candidate and blows up on a 10k-node mega-def). Returns every
;; [parent pos-literal edge-cid child-node] fN edge whose child's canon equals `target`.
;; Children are visited in CRDT (ord-key) order so the list canon matches datum order.
;; The def-form ROOT itself is never a candidate (only CHILDREN are recorded) — replacing
;; a whole top-level def is upsert-form's job, not this verb's.
(defn ord-edges [n] (rv/ord-edges rctx n))   ; [ord-key pos-lit cid child] fN edges of n, CRDT-ordered
(defn anchor-matches [root target] (rv/anchor-matches rctx *view* BOUND REFERS FIXED root target))

;; ============================================================================
;; AUTO-DISAMBIGUATION (019f22bd-137d) — on an ambiguous/failed anchor, hand the
;; model a STRUCTURED remedy instead of a bare match count. Two mechanisms:
;;   (1) :candidates on REJECT — per match site, a parent-chain breadcrumb + a
;;       copy-pastable enclosing form (:within) that isolates THAT occurrence.
;;   (2) :within scope-narrowing — the caller supplies an enclosing anchor; the
;;       :old match must be unique WITHIN it. Fail-closed at every level (exactly
;;       one match or reject). Structural, not ordinal — survives concurrent edits.
;; ============================================================================
;; node->str / node->canon — render a graph node back to source. node->str is a
;; compact, copy-pastable STRING (references via their CURRENT name, like render-sym;
;; structural fN children only, CRDT-ordered; comments/tails omitted). node->canon is
;; the SAME canonical shape datum->canon + anchor-match-sites compute, so a suggested
;; :within is SELF-VALIDATING: we offer it only when (datum->canon (edn/read it)) ==
;; the node's canon (round-trips) AND it matches exactly one interior form.
(defn node->str [n] (rv/node->str rctx *view* BOUND REFERS FIXED n))
(defn node->canon [n] (rv/node->canon rctx *view* BOUND REFERS FIXED n))
;; anchor-match-sites — anchor-matches, but each match also carries its ENCLOSING
;; ANCESTOR CHAIN (def-root .. immediate-parent, descent order) so a reject can build
;; breadcrumbs + a distinctive :within suggestion. Still ONE O(N) post-order pass
;; (canon computed once per node). Returns [{:parent :pos :cid :child :chain} ...];
;; the search ROOT itself is never a candidate (only its interior children).
(defn anchor-match-sites [root target] (rv/anchor-match-sites rctx *view* BOUND REFERS FIXED root target))
;; DISAMBIG-CAP — at most this many candidates in a reject payload (report the total).
(def DISAMBIG-CAP rc/DISAMBIG-CAP)
;; M1 Cut J: the whole anchor-disambiguation payload builder — crumb-label,
;; reject-candidate and disambig-payload — is Beagle now (src/resolve_verbs.bclj),
;; beside verb-replace-in-body!, its only caller. They were private here and nothing
;; outside called them, so nothing is left behind but this note: the clojure.edn
;; read-string round-trip that makes a :within suggestion SELF-VALIDATING crosses the
;; Beagle boundary through both check and emit-clj, so the guard moved with the logic.
;; wrap-forms — the wrapper's top-level form edges in CRDT (path,tie) order.
;; -> [[{:path :tie} cid child] ...]. Dual-parse (old f<int> + new f<path>~tie).
;; M1 Cut J: the logic is Beagle (src/resolve_verbs.bclj) — it was a Verb closure
;; only because the ord algebra used to live here, and rc/ord-parse + rc/ord-cmp
;; moved in Cut A. This wrapper stays for the ns-qualified surface
;; (server.clj and tests/store_delete_reorder_test.clj).
(defn wrap-forms [parent]
  (->> (rr/events-by-subject rctx parent)
       (keep (fn [event]
               (when-let [key (ord-parse (rr/event-predicate event))]
                 [key (rot/occurrence-of event) (rr/event-value event)])))
       (sort-by first ord-cmp)
       vec))

;; ============================================================================
;; M1 Cut H — THE VERB LAYER is now Beagle (src/resolve_verbs.bclj): every
;; authoring verb's invariant order, reject codes/messages, fact mutations and
;; emit reporting. As in Cuts B–G the ^:dynamic vars STAY here (server.clj
;; and tests/*.clj `binding` them by qualified name), so `verb-env` reads the
;; dynamic state at call time and hands it over as ONE explicit record — together
;; with the resolve.clj-local helpers the verbs call (mint/retire/extract/
;; capture-refs/…), which ride as function VALUES exactly as Cut G's xres/tres/
;; ares did. `binding [*out* *err*]` cannot move namespace, so stderr reporting is
;; the `warn` closure, called once per LINE to preserve deterministic diagnostics.
;; *reject!* is passed at BOTH arities: callers bind it as `(fn [code] …)` (the
;; unit tests) or `(fn [code & [detail]] …)` (the server), so each call site keeps
;; the arity the original used — 1 everywhere but replace-in-body's structured
;; disambiguation payload. Docstrings + per-def rationale live in the module header.
;; ============================================================================
(defn verb-env
  ([] (verb-env nil nil))
  ([resolve-out project-srcs]
   (let [output-path (fn [src] (rmi/out-path-for resolve-out src))]
     (rvb/make-verb!
      {:ctx rctx :view *view* :KIND KIND :Vp Vp
       :srcs srcs :capture-only? *capture-only?*
       :emit-srcs (rmi/emit-srcs-for project-srcs (vec srcs))
       :reject! *reject!*
       :author-emit (fn [op detail]
                      (author-emit-scoped! resolve-out project-srcs op detail))
       :extract-file extract-file!
       :out-path output-path
       :def-binding def-binding :typeframe file-typeframe :modframe file-modframe
       :forms-of forms-of :module-name module-name :parse-require parse-require
       :capture-refs capture-refs :ultimate ultimate :BOUND BOUND :REFERS REFERS
       :wrapper-of wrapper-of :form-for-victim form-for-victim
       :descendants descendants :retire retire-fact! :reresolve re-resolve!
       :ents (rco/file-entity-map file->ents) :mint mint-datum!
       :register register! :scope-srcs scope->srcs :fn-facts fN-facts
       :FIXED FIXED}))))

;; rename — every INVARIANT + fact mutation from the old `rename` case arm.
(defn verb-rename! [old new target] (rvb/verb-rename! (verb-env) old new target))


;; upsert-form — add/replace a top-level def from an EDN datum spec (M1 Cut H;
;; logic in src/resolve_verbs.bclj). A REPLACE reuses the victim's CRDT path (new
;; tie) and retires the victim's edge; an APPEND lands strictly after the last form.
(defn- term-order-tie [node]
  (let [encoder (.withoutPadding (java.util.Base64/getUrlEncoder))]
    (str "t" (.encodeToString encoder (.getBytes (pr-str node) "UTF-8")))))

(defn- widen-pending-order! [scope]
  (when-let [src (first (rmi/scope->srcs module-name (vec srcs) scope))]
    (when-let [wrapper (wrapper-of src)]
      (doseq [event (rr/events-by-subject rctx wrapper)
              :let [predicate (rr/event-predicate event)]
              :when (and (string? predicate) (str/ends-with? predicate "~PENDING"))]
        (let [value (rr/event-value event)
              path (subs predicate 1 (- (count predicate) (count "~PENDING")))]
          (txn/retract! (rr/builder rctx) (rot/proposition-of event))
          (sync-authoring-view! rctx)
          (rr/assert! rctx wrapper (str "f" path "~" (term-order-tie value)) value))))))

(defn verb-upsert-form! [scope datum]
  (let [result (rvb/verb-upsert-form! (verb-env) scope datum)]
    (when *capture-only?* (widen-pending-order! scope))
    result))

;; insert-form — the CRDT MIDDLE-INSERT (#36): a def AFTER an anchor def, at a path
;; strictly between the anchor and its next sibling (M1 Cut H). Concurrent inserts
;; after the same anchor compute the same path -> distinct tie -> both land (commute).
(defn verb-insert-form! [scope after-name datum] (rvb/verb-insert-form! (verb-env) scope after-name datum))

;; insert-comment — author a standalone LINE comment (Turtle #6) leading/trailing an
;; anchor def (M1 Cut H): a kind="comment" node + one `text` seg (the lexeme, which
;; renders verbatim) + the `commentN` edge that attaches it to the anchor FORM.
(defn verb-insert-comment! [scope anchor-name text placement]
  (rvb/verb-insert-comment! (verb-env) scope anchor-name text placement))


;; set-body — replace a def/defn's body with a freshly-minted body datum (M1 Cut H;
;; logic in src/resolve_verbs.bclj). Handles BOTH shapes: an executable body follows
;; `[params] Return` and optional `:raises Error`; a plain value-def's body is its
;; final meaningful slot, after any positional type and docstring.
(defn verb-set-body! [name scope datum] (rvb/verb-set-body! (verb-env) name scope datum))

;; verb-replace-in-body! — swap ONE interior form of def `name` (matched by `old-datum`)
;; for `new-datum` (M1 Cut H; logic in src/resolve_verbs.bclj). Reuses the matched edge's
;; EXACT position literal (integer fN preserved -> byte-stable), so the def is never
;; re-minted and every sibling form + attached comment survives. Optional `within-datum`
;; narrows the search to the (unique) enclosing form it matches — fail-closed at every
;; level. On an ambiguous/absent match the reject carries a structured disambiguation
;; payload (:candidates + :within suggestions) via *reject!*.
(defn verb-replace-in-body!
  ([name scope old-datum new-datum] (verb-replace-in-body! name scope old-datum new-datum nil))
  ([name scope old-datum new-datum within-datum]
   (rvb/verb-replace-in-body! (verb-env) name scope old-datum new-datum within-datum)))

;; delete — remove a top-level def by name (M1 Cut H; logic in
;; src/resolve_verbs.bclj). Graph-native + fail-closed: the effect withdraws
;; the wrapper's fN form-edge assertion(s) pointing at the deleted form(s), so the
;; minimal-op harvest sees a RETRACT and the render reachability filter drops the
;; orphaned subtree — ONE mechanism, both drivers. A delete that would ORPHAN a
;; surviving reference REFUSES (no facts mutated).
(defn verb-delete! [name scope] (rvb/verb-delete! (verb-env) name scope))

;; reorder — MOVE a def to a new position by RE-SPELLING its wrapper order key
;; (M1 Cut H; logic in src/resolve_verbs.bclj), NOT by re-minting the form:
;; insert+delete would churn node identity. `:after nil`/"" moves it to the FRONT.
(defn verb-reorder! [name scope after-name] (rvb/verb-reorder! (verb-env) name scope after-name))


;; ============================================================================
;; run-verb-warm! — THE GRAPH EDIT PATH. Run an authoring verb over a LOG-booted
;; warm store (NOT emit-edn of text). `store` is `(migrate-flat->co code.log)`'s
;; :store; resolve-warm-store! binds ctx=store + tx + the store-local value-ids +
;; corpus-from-store! (srcs/frames derived from the store's `name` facts), runs
;; the lexical walk, then invokes our body. Inside that scope we bind
;; *project-srcs* to the affected module and call the SAME verb function the text
;; path calls — asserting/withdrawing structural propositions against log-resident node identity,
;; projecting render EDN for ONLY that module. NO src/fram/*.bclj is ever read:
;; the corpus, the verb's targets, and the projection all come from the store.
;;
;; `spec` is {:op "rename"|"upsert-form"|"set-body" + verb args + optional
;; :resolve-out (the in-process projection dir; bound to *resolve-out* so the
;; verb's extract-file! writes resolved EDN there without re-launching bb)}.
;; Returns the affected module name (so the caller renders + commits exactly that
;; module). The store is mutated IN PLACE; the caller renders the affected module
;; FROM the projected EDN — the .bclj is downstream of the log.
;; ============================================================================
;; M1 Cut H — the OP TABLE is now Beagle (rvb/dispatch-verb!). What stays here is
;; the dynamic scaffolding it runs inside: *resolve-out* (the in-process projection
;; dir) and *project-srcs* (the affected module, so the verb projects ONLY that one
;; instead of the whole warm corpus) are ^:dynamic vars, and a var cannot change
;; namespace. Inside that scope the dispatch is ordinary — the SAME verb functions
;; the text path calls, over the LOG-booted warm store.
(defn run-verb-warm! [store spec]
  (let [module (:module spec)]
    (resolve-warm-store!
     store
     (fn []
       (rvb/dispatch-verb!
        (verb-env (:resolve-out spec)
                  (when module
                    (rmi/scope->srcs module-name (vec srcs) module)))
        spec)))
    module))

;; ============================================================================
;; call graph — the scope-correct calls_defn edges + transitive blast radius.
;; ============================================================================
;; Factored out of the `callgraph` MODE so the server's warm :blast/:concern-overlap,
;; the offline `callgraph` mode, and codegraph/src/callgraph.bclj all share ONE derivation
;; (call-edges) and ONE reaches closure (blast-closure) — the per-query throwaway-store
;; rebuild now lives in exactly one place (decision J: "one implementation shared by
;; concern-overlap and who-calls").

;; call-edges — scope-correct defn->defn edges over the CURRENTLY BOUND corpus
;; (srcs/file-modframe + materialized refers_to must already be in scope — call under
;; with-resolve-read / resolve-edn!). A "call" is any resolved reference inside a
;; top-level defn's body whose binding (via refers_to, transitively) is itself a
;; top-level defn; the caller is that enclosing defn. Edges are keyed on the binding's
;; NODE entity-id (@mod#int identity — rename-stable, scope-correct: same-named fns in
;; different modules are distinct nodes, so they never false-merge). Returns
;; {:defn-meta {leaf -> {:key :file :module :name}} :edges [[caller-leaf callee-leaf]]
;; :defn-set #{leaf}} — the server joins footprint @concern->@node against :edges; the
;; CLI maps leaf->:key for JSON.
(defn call-edges [] (rq/call-edges rctx *view* BOUND REFERS (vec srcs) file-modframe (rco/file-entity-map file->ents)))

;; blast-closure — transitive blast radius over a set of [caller callee] edges via Fram
;; Datalog: blast(D) = {x | x transitively calls D} = D's transitive callers (who breaks
;; if D changes). Edge keys are any hashable (node-ids for the warm path, "src#leaf"
;; strings for JSON). Returns {:reaches #{[x y]} :blast {callee -> #{transitive-callers}}}.
;; The ONE reaches implementation; the throwaway recursion store lives only here.
(defn blast-closure [edges] (rq/blast-closure! (vec edges)))

;; binding-privacy — {binding-leaf -> :public | :private} over the CURRENTLY BOUND corpus.
;; A top-level `def-`/`defn-` is PRIVATE; every other top-level value binding (def/defn/
;; defonce/fn/…) is PUBLIC — a reachability ROOT. Keyed on the binding NODE (identity), so
;; same-spelling bindings in different modules stay DISTINCT (a private `helper` in mod A is a
;; different node than a public `helper` in mod B). Call under with-resolve-read / resolve-edn!.
(defn binding-privacy [] (rq/binding-privacy rctx *view* (vec srcs) (rco/file-entity-map file->ents)))

;; dead-private-bindings — the identity-keyed STRATIFIED-Datalog code query. Over the
;; scope-correct call graph (call-edges), derive the PRIVATE top-level bindings UNREACHABLE
;; from any PUBLIC binding. Two strata via fram.datalog/run-strata:
;;   (1) POSITIVE + RECURSIVE live reachability — live(x) seeded from every public root
;;       (is-root self-loop), grown along calls(x,y); a reachable private chain is live.
;;   (2) NEGATED dead — dead(p) :- private(p), ¬live(p). An unreachable private recursive
;;       cycle is NEVER seeded by a root, so positive reachability skips it -> it is dead.
;; Because everything is keyed on the @mod#int NODE, same-spelling cross-module bindings are
;; classified independently. Returns the set of dead private binding leaves. `privacy` maps
;; leaf -> :public|:private (binding-privacy); a leaf absent from it (e.g. a protocol method)
;; is treated as a non-private root, never dead.
(defn dead-private-bindings [cg privacy] (rq/dead-private-bindings! cg privacy))

;; ============================================================================
;; CLI entry. Slice the edn paths off *command-line-args* per mode (the old
;; `(def srcs ...)` slice), then run the WHOLE pipeline + mode dispatch inside
;; one `resolve-edn!` binding scope, so dispatch reads the freshly-bound store /
;; tables / counters exactly as the old top-level code did. GUARDED: loaded as a
;; library (no recognized mode), nothing runs — no load-edn over mis-sliced args.
(def MODES rc/MODES)
(defn -main [& args]
  (rvb/run-cli!
   {:resolve-edn resolve-edn!
    :srcs (fn [] (vec srcs))
    :counter (fn [k] (get {:resolved (deref n-resolved) :xmod (deref n-xmod)
                           :type (deref n-type) :unresolved (deref n-unresolved)
                           :comment (deref n-comment)} k))
    :extract (fn [src] (extract-file! src (out-path src)))
    :out-path out-path
    :file-ents (fn [src] (get (deref file->ents) src))
    :kind-of kind-of :refers-target refers-target
    :rename! verb-rename! :delete! verb-delete! :reorder! verb-reorder!
    :upsert! verb-upsert-form! :set-body! verb-set-body!
    :replace-in-body! verb-replace-in-body!
    :call-edges call-edges :blast-closure blast-closure
    :binding-privacy binding-privacy :dead-private-bindings dead-private-bindings}
   (vec args)))

;; GUARD: run the pipeline only when invoked as a CLI with a recognized mode.
;; Loaded as a library (no mode arg, or an unrecognized one), this is a no-op —
;; so a server can `require`/load this file and call `resolve-edn!` over its own
;; warm store without the old top-level load-edn crashing on mis-sliced args.
(when (MODES (first *command-line-args*)) (apply -main *command-line-args*))
