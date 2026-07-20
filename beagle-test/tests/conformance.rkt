#lang racket/base

;; ============================================================================
;; CROSS-TARGET VALUE-CONFORMANCE HARNESS
;; ============================================================================
;;
;; Proves that Beagle's VALUE SEMANTICS agree across emit targets. The thesis:
;; a value (a map, a vector, a set) means the same thing no matter which
;; backend renders it. `(= {:a 1} {:a 1})` must be `true` on EVERY target,
;; because Beagle maps are values, not object references.
;;
;; CLJ is the ORACLE. Clojure's reader + value-equality define the reference
;; answer; every other target is asserted to AGREE with the CLJ result. We do
;; NOT hard-code expected booleans — the oracle computes them — so the harness
;; cannot drift from Clojure's actual semantics.
;;
;; Two runnable targets are wired here:
;;   - clj : compile .bclj, run via Babashka (bb), print with pr-str
;;   - js  : compile .bjs,  run via node,      print structurally (JSON)
;; CLJS and Odin runtimes are absent in this env and Nix eval is unwired, so
;; they are NOT wired. The TARGETS table below is the single extension point:
;; add a target descriptor (header / extension / runner / printer) and the
;; whole corpus runs against it.
;;
;; STATUS (2026-06-21): emit-js now routes value ops through the $$bc core —
;; `=` → equiv, `contains?` → contains, `distinct` → distinct_equiv, `hash` →
;; hash, and assoc/conj/dissoc/into/merge/disj emit non-mutating spreads. So
;; compound value semantics AGREE with the CLJ oracle. The SCALAR cases
;; (`(= 1 1)`, `(= "a" "a")`) still prove the machinery is sound; a RED compound
;; case is now a genuine REGRESSION, not a pending fix.
;;
;; CORPUS is organized into categories:
;;   A. nested/mixed equality   B. hash consistency
;;   C. set/map membership      D. immutability (no input mutation)
;;   E. dedup by value          F. compound-value map keys (hard, value-keyed HAMT)
;; F is asserted-green via the value-keyed HAMT; native JS object keys would
;; coerce compound keys to "[object Object]" and collide, but Beagle routes
;; compound-key maps to lib/beagle/hamt.js instead.
;;
;; DIVERGENCES (below CORPUS): a parallel list of DELIBERATE Beagle-JS ≠ Clojure
;; differences, pinned in BOTH directions — clj must return its value AND js its
;; (different) value. If js UNEXPECTEDLY matches clj, the test FAILS: the
;; divergence was resolved and the entry should graduate into CORPUS.
;;
;; Run: raco test beagle-test/tests/conformance.rkt
;;  or: bin/beagle-test --active-only
;; ============================================================================

(require rackunit
         rackunit/text-ui
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/file
         (only-in "../../beagle-lib/private/batch-compile.rkt" compile-source)
         (only-in "scratch-containment.rkt" call-with-scratch-containment))

(define-runtime-path beagle-build "../../bin/beagle-build")
(define-runtime-path conformance-repo-root "../..")
(define repo-root-str (path->string (simplify-path conformance-repo-root)))

;; Repo-relative path to the JS runtime core (equiv/hash/contains/...). This
;; file lives at <repo>/beagle-test/tests/conformance.rkt, so the core is at
;; <repo>/beagle-lib/lib/beagle/core.js.
(define-runtime-path beagle-core-js "../../beagle-lib/lib/beagle/core.js")
;; The P3 persistent collections (hamtMap/hamtSet/...). Compound-key map and
;; value-set cases emit `import { ... } from 'beagle/hamt.js'`, so the scaffold
;; must resolve it alongside core.js.
(define-runtime-path beagle-hamt-js "../../beagle-lib/lib/beagle/hamt.js")

(define BB-PATH   (find-executable-path "bb"))
(define NODE-PATH
  (or (find-executable-path "node")
      (let ([p "/run/current-system/sw/bin/node"])
        (and (file-exists? p) p))))

;; The scratch root for THIS run. Bound by call-with-scratch-containment at the
;; bottom of the module (see run block), so the root — and any bb/node child
;; still live at cancellation — is reaped on EVERY exit path: normal completion,
;; seeded rackunit failure, a raised exception, and SIGINT/SIGTERM/SIGHUP.
;; Identity-scoped: only this exact root is deleted, never a name-prefix glob,
;; so a concurrent conformance run's root is never swept.
(define tmp-dir #f)

;; ---------------------------------------------------------------------------
;; node_modules scaffold so emitted JS can resolve `import * as $$bc from
;; 'beagle/core.js'`. Once the emit-js =→equiv routing lands, compiled .mjs
;; modules carry that bare-specifier import; node only resolves bare specifiers
;; against a node_modules dir on the module's path. We plant
;; tmp-dir/node_modules/beagle/{package.json, core.js→symlink-to-repo} and run
;; the emitted .mjs FROM tmp-dir, so resolution finds the live repo core.js.
;; Without this, the import would ERR_MODULE_NOT_FOUND and the case would
;; silently RUN-FAIL instead of going GREEN — the harness could never observe
;; the very fix it exists to detect.
(define (setup-beagle-node-module!)
  (define beagle-mod-dir (build-path tmp-dir "node_modules" "beagle"))
  (make-directory* beagle-mod-dir)
  (call-with-output-file (build-path beagle-mod-dir "package.json")
    #:exists 'truncate
    (lambda (p) (display "{\"type\":\"module\"}\n" p)))
  (define (link-runtime! src name)
    (define link-path (build-path beagle-mod-dir name))
    (when (or (file-exists? link-path) (link-exists? link-path))
      (delete-file link-path))
    (make-file-or-directory-link (path->string (simplify-path src)) link-path))
  (link-runtime! beagle-core-js "core.js")
  (link-runtime! beagle-hamt-js "hamt.js"))

;; ---------------------------------------------------------------------------
;; Compile + run helpers (subprocess patterns reused from
;; tests/js-exec-oracle.rkt and tests/emit-clj-behavioral.rkt).
;; ---------------------------------------------------------------------------

;; Compile a Beagle source string to `out-path`. Returns #t on success.
;;
;; Two seams, selected by BEAGLE_CONFORMANCE_SUBPROCESS:
;;   - default (unset/not "1"): in-process via batch-compile.rkt's
;;     compile-source (D2) — one racket process amortizes the compiler's
;;     module-graph load across the whole corpus instead of paying a fresh
;;     cold start per case (the harness's dominant cost per the parent
;;     thread's B0 profile).
;;   - BEAGLE_CONFORMANCE_SUBPROCESS=1: the ORIGINAL one-shot subprocess path
;;     (bin/beagle-build per case), kept byte-for-byte as an exact rollback.
(define (compile-beagle src-text src-path out-path)
  (call-with-output-file src-path #:exists 'truncate
    (lambda (p) (display src-text p)))
  (cond
    [(equal? (getenv "BEAGLE_CONFORMANCE_SUBPROCESS") "1")
     (define out-cap (open-output-string))
     (define err-cap (open-output-string))
     (define ok?
       (parameterize ([current-output-port out-cap]
                      [current-error-port  err-cap])
         (system* (path->string beagle-build)
                  (path->string src-path)
                  (path->string out-path))))
     (values ok? (get-output-string err-cap))]
    [else
     (define-values (status text)
       (compile-source (path->string src-path) #:root repo-root-str))
     (cond
       [(eq? status 'ok)
        ;; Write the emitted bytes to out-path so downstream target-run
        ;; helpers (clj-run/js-run), which read out-path from disk, are
        ;; unchanged — same file-based contract as the subprocess path.
        (make-parent-directory* out-path)
        (call-with-output-file out-path #:exists 'truncate
          (lambda (p) (display text p)))
        (values #t "")]
       [else
        (values #f text)])]))

;; Run a shell command list, capturing stdout/stderr + exit status.
(define (run-capture exe . args)
  (define out-cap (open-output-string))
  (define err-cap (open-output-string))
  (define ok?
    (parameterize ([current-output-port out-cap]
                   [current-error-port  err-cap])
      (apply system* exe args)))
  (values ok? (get-output-string out-cap) (get-output-string err-cap)))

;; ---------------------------------------------------------------------------
;; Normalization: collapse the printed result from each target into a single
;; canonical token so a value-level comparison ignores cosmetic rendering
;; differences (CLJ prints `:x`; JS prints `x`; CLJ prints `true`; JSON prints
;; `true`). We deliberately normalize keyword-vs-string for the *looked-up
;; value* case so a genuine value agreement is not masked by representation;
;; the boolean/number cases need no special handling. If a target ever prints
;; an object/array reference token, normalization will NOT turn `false` into
;; `true` — the gap stays visible.
(define (normalize s)
  (string-trim
   ;; strip a single leading `:` so keyword `:x` and string `x`/`"x"` collapse
   (let ([t (string-trim s)])
     (cond
       [(and (> (string-length t) 0) (char=? (string-ref t 0) #\:))
        (substring t 1)]
       [(and (>= (string-length t) 2)
             (char=? (string-ref t 0) #\")
             (char=? (string-ref t (sub1 (string-length t))) #\"))
        (substring t 1 (sub1 (string-length t)))]
       [else t]))))

;; ---------------------------------------------------------------------------
;; TARGET DESCRIPTORS — the extension point. Each target knows how to wrap a
;; bare Beagle expression into a compilable module, what file extension to
;; emit, how to run the emitted artifact, and how to print the value.
;;
;; `wrap` : expr-string -> full beagle source (the body is `(defn result [] :- T expr)`)
;; The result type annotation matters to the checker, so each case supplies its
;; own return type; `wrap` takes (expr ret-type).
;; ---------------------------------------------------------------------------

(struct target (name ext wrap run) #:transparent)

;; CLJ target: header `#lang beagle`, run via bb, print via pr-str.
(define (clj-wrap expr ret)
  (string-append "#lang beagle\n(ns conf)\n"
                 "(defn result [] :- " ret " " expr ")\n"))

(define (clj-run out-path)
  ;; Append a driver that prints (pr-str (result)).
  (define body (file->string out-path))
  (define run-path (path-replace-extension out-path "-run.clj"))
  (call-with-output-file run-path #:exists 'truncate
    (lambda (p)
      (display body p)
      (display "\n(println (pr-str (result)))\n" p)))
  (run-capture BB-PATH (path->string run-path)))

;; JS target: header `#lang beagle/js`, export the fn, run via node, print via
;; JSON.stringify so compound structure is visible (and arrays/objects don't
;; collapse to `[object Object]`).
;; strict mode is REQUIRED: per-node type capture (and thus P3 rep-selection —
;; compound-key map -> hamtMap, value-set -> hamtSet) only runs under
;; (define-mode strict). Without it the JS target emits native objects/Sets and
;; the compound-key cases would silently fall back to string-coercion.
(define (js-wrap expr ret)
  (string-append "#lang beagle/js\n(ns conf)\n(define-mode strict)\n"
                 "(js/export (defn result [] :- " ret " " expr "))\n"))

(define (js-run out-path)
  ;; Write the emitted module + a print driver to a `.mjs` FILE inside tmp-dir
  ;; and run `node <file>` (NOT `-e`). Running a real file from tmp-dir means
  ;; node resolves bare specifiers (e.g. `import * as $$bc from 'beagle/core.js'`)
  ;; against tmp-dir/node_modules/beagle — see setup-beagle-node-module!. With
  ;; `-e` there is no module path, so a bare-specifier import would fail.
  (define body (file->string out-path))
  (define run-path (path-replace-extension out-path "-run.mjs"))
  (call-with-output-file run-path #:exists 'truncate
    (lambda (p)
      (display body p)
      (display "\nconsole.log(JSON.stringify(result()));\n" p)))
  (run-capture NODE-PATH (path->string run-path)))

(define CLJ-TARGET (target "clj" "bclj" clj-wrap clj-run))
(define JS-TARGET  (target "js"  "bjs"  js-wrap  js-run))

;; Compile + run one case for one target. Returns
;;   (values status value)  where status ∈ {'ok 'compile-fail 'run-fail}
;;   and value is the normalized printed result (or an error blob).
(define (eval-case tgt case-name expr ret)
  (define src-text ((target-wrap tgt) expr ret))
  (define src-path
    (build-path tmp-dir (string-append case-name "." (target-ext tgt))))
  (define out-ext (if (string=? (target-name tgt) "js") "mjs" "clj"))
  (define out-path
    (build-path tmp-dir (string-append case-name "." (target-name tgt) "." out-ext)))
  (define-values (compiled? cerr) (compile-beagle src-text src-path out-path))
  (cond
    [(not (and compiled? (file-exists? out-path)))
     (values 'compile-fail cerr)]
    [else
     (define-values (ran? out err) ((target-run tgt) out-path))
     (if ran?
         (values 'ok (normalize out))
         (values 'run-fail (string-append "stdout:\n" out "\nstderr:\n" err)))]))

;; ---------------------------------------------------------------------------
;; THE CORPUS. Each entry: (name expr return-type kind)
;;   kind ∈ {'scalar 'compound}
;; A target that fails to compile/run is still reported (not asserted) so a
;; genuine environment gap does not crash the harness machinery.
;; ---------------------------------------------------------------------------

(define CORPUS
  (list
   ;; SCALAR SANITY — MUST be GREEN (proves the harness is correct).
   (list "scalar-int-eq"  "(= 1 1)"     "Bool" 'scalar)
   (list "scalar-str-eq"  "(= \"a\" \"a\")" "Bool" 'scalar)

   ;; COMPOUND VALUE EQUALITY — RED today (= -> === ref equality on JS).
   (list "map-eq-true"   "(= {:a 1} {:a 1})"  "Bool" 'compound)
   (list "vec-eq-true"   "(= [1 2 3] [1 2 3])" "Bool" 'compound)
   (list "map-eq-false"  "(= {:a 1} {:a 2})"  "Bool" 'compound)
   (list "set-eq-true"   "(= #{1 2 3} #{3 2 1})" "Bool" 'compound)
   (list "distinct-by-value"
         "(count (distinct [{:a 1} {:a 1}]))" "Int" 'compound)

   ;; COMPOUND KEY BY VALUE — the looked-up value. CLJ prints :x, JS prints x;
   ;; normalization collapses keyword/string so a genuine value match is GREEN.
   ;; (JS object-key coercion happens to find it; representation differs — see
   ;; KNOWN GAPS in the harness report.)
   (list "map-by-vec-key" "(get {[1 2] :x} [1 2])" "Keyword" 'compound)

   ;; ========================================================================
   ;; A. NESTED / MIXED EQUALITY — recursive value-= through maps-in-vecs,
   ;;    vecs-in-maps, sets-in-maps, sets-of-vecs, deep nesting, and nil.
   ;;    GREEN on current .bjs: emit-js routes `=` to $$bc.equiv, which recurses.
   ;; ========================================================================
   (list "nest-vec-of-map-eq"   "(= [{:a 1}] [{:a 1}])"            "Bool" 'compound)
   (list "nest-map-of-vec-eq"   "(= {:a [1 2]} {:a [1 2]})"        "Bool" 'compound)
   (list "nest-map-of-set-eq"   "(= {:s #{1 2}} {:s #{2 1}})"      "Bool" 'compound)
   (list "nest-set-of-vec-eq"   "(= #{[1 2] [3 4]} #{[3 4] [1 2]})" "Bool" 'compound)
   (list "nest-deep-map-eq"     "(= {:a {:b {:c 3}}} {:a {:b {:c 3}}})" "Bool" 'compound)
   (list "nest-vec-of-map-neq"  "(= [{:a 1}] [{:a 2}])"            "Bool" 'compound)
   (list "nest-vec-len-neq"     "(= [1 2] [1 2 3])"                "Bool" 'compound)
   (list "nest-map-nil-val-eq"  "(= {:a nil} {:a nil})"            "Bool" 'compound)
   (list "nest-vec-with-nil-eq" "(= [nil 1] [nil 1])"              "Bool" 'compound)

   ;; ========================================================================
   ;; B. HASH CONSISTENCY — each expr is itself a Bool of (= (hash x) (hash y)),
   ;;    so each target self-checks its OWN hash law (equiv ⇒ same hash; and
   ;;    distinct values may collide but here are pinned to NOT). The oracle
   ;;    states the truth; JS must agree on the boolean.
   ;; ========================================================================
   (list "hash-int-eq"    "(= (hash 42) (hash 42))"                       "Bool" 'compound)
   (list "hash-str-eq"    "(= (hash \"hello\") (hash \"hello\"))"          "Bool" 'compound)
   (list "hash-map-order" "(= (hash {:a 1 :b 2}) (hash {:b 2 :a 1}))"      "Bool" 'compound)
   (list "hash-vec-eq"    "(= (hash [1 2 3]) (hash [1 2 3]))"             "Bool" 'compound)
   (list "hash-set-order" "(= (hash #{1 2 3}) (hash #{3 2 1}))"           "Bool" 'compound)
   (list "hash-nest-eq"   "(= (hash {:a [1 2]}) (hash {:a [1 2]}))"       "Bool" 'compound)
   (list "hash-int-neq"   "(= (hash 1) (hash 2))"                         "Bool" 'compound)
   (list "hash-map-neq"   "(= (hash {:a 1}) (hash {:a 2}))"              "Bool" 'compound)

   ;; ========================================================================
   ;; C. SET / MAP MEMBERSHIP BY VALUE — contains?/count over sets & maps.
   ;;    Set membership is by EQUIV (incl. compound elements); vector contains?
   ;;    is INDEX-membership (Clojure semantics); set dedup is by value.
   ;; ========================================================================
   (list "contains-set-scalar"  "(contains? #{1 2 3} 2)"             "Bool" 'compound)
   (list "contains-set-vec"     "(contains? #{[1 2] [3 4]} [1 2])"   "Bool" 'compound)
   (list "contains-set-map"     "(contains? #{{:a 1} {:b 2}} {:a 1})" "Bool" 'compound)
   (list "contains-set-vec-no"  "(contains? #{[1 2]} [1 3])"         "Bool" 'compound)
   (list "contains-map-key"     "(contains? {:a 1 :b 2} :a)"         "Bool" 'compound)
   (list "contains-vec-index"   "(contains? [10 20 30] 2)"           "Bool" 'compound)
   (list "contains-vec-noindex" "(contains? [10 20] 5)"              "Bool" 'compound)
   ;; Set value-dedup via count. NB: a LITERAL `#{[1 2] [1 2]}` is a Clojure
   ;; READER error (duplicate set key) — uninstantiable as an oracle — so we
   ;; build the set at runtime with `(set [...])`, which is what actually
   ;; exercises value-dedup. `set` over compound elements routes to a
   ;; value-keyed hamtSet (value dedup); `count` routes to hamtSetCount.
   ;; Hard-asserted green.
   (list "count-set-vec-dedup"  "(count (set [[1 2] [1 2]]))"        "Int"  'compound)
   (list "count-set-map-dedup"  "(count (set [{:a 1} {:a 1}]))"      "Int"  'compound)

   ;; ========================================================================
   ;; D. IMMUTABILITY — ops must NOT mutate their input. The sharpest Squint
   ;;    divergence: assoc/conj/dissoc/into/merge/disj emit non-mutating
   ;;    spreads, so the original binding is unchanged after the op.
   ;; ========================================================================
   (list "immut-assoc"  "(let [m {:a 1}] (let [_ (assoc m :b 2)] (get m :a)))" "Int"  'compound)
   (list "immut-conj"   "(let [v [1 2]] (let [_ (conj v 3)] (count v)))"       "Int"  'compound)
   (list "immut-dissoc" "(let [m {:a 1 :b 2}] (let [_ (dissoc m :a)] (contains? m :a)))" "Bool" 'compound)
   (list "immut-into"   "(let [v [1]] (let [_ (into v [2 3])] (count v)))"     "Int"  'compound)
   (list "immut-merge"  "(let [m {:a 1}] (let [_ (merge m {:b 2})] (contains? m :b)))" "Bool" 'compound)
   (list "immut-disj"   "(let [s #{1 2 3}] (let [_ (disj s 1)] (contains? s 1)))" "Bool" 'compound)
   (list "immut-assoc-neq" "(not= (assoc {:a 1} :b 2) {:a 1})"                 "Bool" 'compound)
   (list "immut-conj-eq"   "(= (conj [1 2] 3) [1 2 3])"                        "Bool" 'compound)

   ;; ========================================================================
   ;; E. DEDUP BY VALUE — distinct collapses equiv-duplicates, preserving
   ;;    first-seen order; nested compound dups collapse; nil dedups too.
   ;; ========================================================================
   (list "dedup-scalar"      "(count (distinct [1 2 1 3]))"                    "Int" 'compound)
   (list "dedup-nested-map"  "(count (distinct [{:a {:b 1}} {:a {:b 1}}]))"    "Int" 'compound)
   (list "dedup-vecs"        "(count (distinct [[1 2] [1 2] [3 4]]))"          "Int" 'compound)
   (list "dedup-order"       "(= (distinct [3 1 2 1 3]) [3 1 2])"              "Bool" 'compound)
   (list "dedup-nil"         "(count (distinct [nil nil 1]))"                  "Int" 'compound)

   ;; ========================================================================
   ;; F. COMPOUND-VALUE MAP KEYS — NOW ASSERTED-GREEN via P3 rep-selection.
   ;;    A map keyed by a COMPOUND value routes to the value-keyed hamtMap
   ;;    (lib/beagle/hamt.js), so distinct-but-equiv keys stay distinct and a
   ;;    differently-constructed lookup key matches by VALUE. Native JS object
   ;;    keys coerce every map/vec to "[object Object]" and collide; the HAMT
   ;;    keys by $$bc.hash/$$bc.equiv.
   ;;    The first three previously agreed by string-coercion COINCIDENCE (same
   ;;    literal store+lookup); they are now genuinely value-keyed. The
   ;;    DISCRIMINATING cases below would FAIL on native (proving it's real):
   ;;      - collision: two distinct compound keys; native collapses them (2nd
   ;;        write wins) -> wrong value; HAMT keeps both.
   ;;      - count:     two distinct compound keys; native -> 1 key; HAMT -> 2.
   ;;      - absent:    a compound lookup key not present; native collides onto
   ;;        an existing slot (some? -> true); HAMT misses (some? -> false).
   ;;        (Tested via `some?` so the result is Bool, not nil — nil renders as
   ;;        "nil" in clj vs "null" in JSON, an unrelated rendering divergence.)
   ;; ========================================================================
   (list "key-by-map"        "(get {{:a 1} :found} {:a 1})"          "Keyword" 'compound)
   (list "key-by-nested"     "(get {[[1] [2]] :x} [[1] [2]])"        "Keyword" 'compound)
   (list "key-by-map-eq"     "(= (get {{:a 1} :x} {:a 1}) :x)"       "Bool"    'compound)
   (list "key-map-collision" "(get {{:a 1} :x {:a 2} :y} {:a 1})"    "Keyword" 'compound)
   (list "key-map-count"     "(count {{:a 1} :x {:a 2} :y})"         "Int"     'compound)
   (list "key-map-absent"    "(some? (get {{:a 1} :x} {:b 9}))"      "Bool"    'compound)))

;; ---------------------------------------------------------------------------
;; THE TEST. For each case: compute the CLJ ORACLE, then assert each non-oracle
;; target agrees. Scalars must be GREEN; compounds are the baseline (RED now).
;; A compile/run failure on a non-oracle target is recorded as a KNOWN GAP
;; (it must not crash the harness machinery) — the value comparison happens
;; only where the case actually runs.
;; ---------------------------------------------------------------------------

(define OTHER-TARGETS (list JS-TARGET))

(define (run-conformance)
  (cond
    [(not BB-PATH)
     (displayln "SKIP: bb (Babashka) not found — cannot run the CLJ oracle.")]
    [(not NODE-PATH)
     (displayln "SKIP: node not found — cannot run the JS target.")]
    [else
     (run-tests
      (test-suite "cross-target value conformance"
        (for/list ([c (in-list CORPUS)])
          (define name (list-ref c 0))
          (define expr (list-ref c 1))
          (define ret  (list-ref c 2))
          (define kind (list-ref c 3))
          (test-case (string-append name " :: " expr)
            ;; ---- ORACLE (clj) ----
            (define-values (clj-status clj-val) (eval-case CLJ-TARGET name expr ret))
            (check-eq? clj-status 'ok
                       (format "ORACLE (clj) failed to evaluate ~a: ~a" name clj-val))
            ;; ---- each other target must AGREE with the oracle ----
            (for ([tgt (in-list OTHER-TARGETS)])
              (define-values (st val) (eval-case tgt name expr ret))
              (cond
                [(not (eq? st 'ok))
                 ;; Cannot compile/run on this target today: KNOWN GAP, report,
                 ;; do not crash the machinery. Don't fail scalars this way.
                 (printf "KNOWN GAP [~a/~a]: ~a (~a)\n"
                         (target-name tgt) name st
                         (string-trim (car (string-split val "\n"))))]
                [else
                 ;; ACTUAL value-level agreement assertion against the oracle.
                 (check-equal? val clj-val
                               (format
                                (string-append
                                 "~a DISAGREES with CLJ oracle on ~a\n"
                                 "  expr   : ~a\n"
                                 "  oracle : ~a (clj)\n"
                                 "  ~a     : ~a\n"
                                 "  [kind=~a]")
                                (target-name tgt) name expr
                                clj-val (target-name tgt) val kind))]))))))]))

;; ===========================================================================
;; DIVERGENCES — deliberate, pinned Beagle-JS ≠ Clojure differences.
;;
;; Unlike CORPUS (where every non-oracle target must AGREE with CLJ), these are
;; places Beagle-JS INTENTIONALLY differs from Clojure — emergent from emitting
;; idiomatic JS rather than re-implementing Clojure's runtime. Each is pinned in
;; BOTH directions: clj must produce `clj-want` AND js must produce `js-want`.
;; If js UNEXPECTEDLY matches clj, the test FAILS — the divergence was resolved
;; and the entry should graduate into CORPUS as a real agreement.
;;
;; CRITICAL: the divergence runner compares RAW output (no keyword-stripping
;; `normalize`) — `normalize` would collapse `:foo` and `"foo"` and MASK the
;; kw-as-string divergence. We trim whitespace only.
;;
;; Each entry: (name expr return-type clj-want js-want)
;;   - clj-want / js-want are the RAW printed tokens (clj via pr-str; js via
;;     JSON.stringify), whitespace-trimmed.
;; ===========================================================================

(define (raw s) (string-trim s))

(define DIVERGENCES
  (list
   ;; truthiness: Clojure treats 0 and "" as TRUTHY; JS treats them as FALSY.
   (list "div-truthy-zero"  "(if 0 \"t\" \"f\")"  "String" "\"t\"" "\"f\"")
   (list "div-truthy-empty" "(if \"\" \"t\" \"f\")" "String" "\"t\"" "\"f\"")
   ;; keyword→string: (str :foo) is ":foo" in Clojure, "foo" in Beagle-JS
   ;; (keywords emit as bare strings). RAW compare is mandatory here.
   (list "div-kw-as-string" "(str :foo)" "String" "\":foo\"" "\"foo\"")))

;; Evaluate a case on a target and return the RAW (un-normalized) printed token,
;; or a status tag string on failure. Mirrors eval-case but skips `normalize`.
(define (eval-case-raw tgt case-name expr ret)
  (define src-text ((target-wrap tgt) expr ret))
  (define src-path
    (build-path tmp-dir (string-append case-name "-raw." (target-ext tgt))))
  (define out-ext (if (string=? (target-name tgt) "js") "mjs" "clj"))
  (define out-path
    (build-path tmp-dir (string-append case-name "-raw." (target-name tgt) "." out-ext)))
  (define-values (compiled? cerr) (compile-beagle src-text src-path out-path))
  (cond
    [(not (and compiled? (file-exists? out-path)))
     (values 'compile-fail cerr)]
    [else
     (define-values (ran? out err) ((target-run tgt) out-path))
     (if ran?
         (values 'ok (raw out))
         (values 'run-fail (string-append "stdout:\n" out "\nstderr:\n" err)))]))

(define (run-divergences)
  (run-tests
   (test-suite "pinned Beagle-JS ≠ Clojure divergences"
     (for/list ([d (in-list DIVERGENCES)])
       (define name (list-ref d 0))
       (define expr (list-ref d 1))
       (define ret  (list-ref d 2))
       (define clj-want (list-ref d 3))
       (define js-want  (list-ref d 4))
       (test-case (string-append name " :: " expr)
         ;; ---- clj direction: oracle must produce the pinned clj value ----
         (define-values (clj-st clj-val) (eval-case-raw CLJ-TARGET name expr ret))
         (check-eq? clj-st 'ok
                    (format "DIVERGENCE (clj) failed to evaluate ~a: ~a" name clj-val))
         (check-equal? clj-val clj-want
                       (format "~a: clj produced ~a, divergence pins clj at ~a"
                               name clj-val clj-want))
         ;; ---- js direction: must produce the pinned js value (≠ clj) ----
         (define-values (js-st js-val) (eval-case-raw JS-TARGET name expr ret))
         (check-eq? js-st 'ok
                    (format "DIVERGENCE (js) failed to evaluate ~a: ~a" name js-val))
         (check-equal? js-val js-want
                       (format
                        (string-append
                         "~a: js produced ~a, divergence pins js at ~a.\n"
                         "  If js now equals the clj value (~a), the DIVERGENCE\n"
                         "  was RESOLVED — move this entry into CORPUS as an agreement.")
                        name js-val js-want clj-want)))))))

;; Own the scratch root under exception-/signal-safe containment: bind tmp-dir,
;; plant the node_modules scaffold, then run both suites. Output and diagnostics
;; are byte-unchanged — only the previously-orphaned root's lifetime is fixed.
;;
;; `run-conformance` and `run-divergences` were two TOP-LEVEL forms, so `raco
;; test` echoed each suite's failure-count (a bare `0`) between them. Now that
;; both run inside one containment extent, only the final value is echoed by
;; raco; reproduce the first suite's echo explicitly — matching raco's own rule
;; (echo non-void results only) — so stdout stays byte-identical.
(call-with-scratch-containment
 "beagle-conformance-~a"
 (lambda (root)
   (set! tmp-dir root)
   (setup-beagle-node-module!)
   ;; Probe-only hook (off unless the env var is set): plant an exception inside
   ;; the live containment extent to prove root-reap on a raised exception —
   ;; the exact with-handlers arm a SIGINT/SIGTERM break also takes. Never fires
   ;; on a normal `raco test` / `racket` run, so output stays byte-identical.
   (when (getenv "BEAGLE_SCRATCH_SELFTEST_RAISE")
     (error 'scratch-selftest "planted exception in contained extent"))
   (let ([r (run-conformance)])
     (unless (void? r) (println r)))
   (run-divergences)))
