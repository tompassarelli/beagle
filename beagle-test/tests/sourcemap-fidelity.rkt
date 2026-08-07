#lang racket/base

;; =============================================================================
;; Sourcemap fidelity benchmark
;; =============================================================================
;;
;; Authoritative benchmark for diagnostic source-location accuracy. Each
;; entry is a small bnix/bclj source fragment with a *known* type-or-parse
;; error at a *known* line in the AUTHOR's source. The harness parses,
;; type-checks, captures the first beagle-diagnostic, and asserts the
;; reported (error-line) matches the expected line.
;;
;; Reported "actual line" follows what end-users (and tooling consumers of
;; the JSON error stream) see:
;;
;;   1. error-format.rkt write-json-error first reads 'error-line from the
;;      diagnostic's details hash (populated only when raise-diag was given
;;      #:src). When present, that line is what's emitted.
;;   2. When absent, it falls back to (syntax-line stx) of the top-level
;;      form's syntax — i.e. the WHOLE form's first line, not the
;;      offending sub-expression. This is the load-bearing degradation
;;      called out in the inventory.
;;
;; The benchmark scores both as "actual line" with that same fallback so the
;; numbers reflect the user-visible diagnostic, not internal state.
;;
;; Strategy (recorded 2026-06-01):
;;
;;   srcloc preservation in beagle (HEAD 6fefc09) has known gaps in
;;   parse-time rewrites — every (parse-expr (list …)) site in
;;   parse-list-form (parse.rkt:2099-2140, 2069-2085, 2061-2063) passes
;;   a synthesized bare list to parse-expr, which short-circuits
;;   store-src! because the bare list is not a syntax object.
;;
;;   This benchmark exercises the 10 most user-visible cascades from
;;   those gaps. Phase C ("rewrite-arm wrap helper" — single helper +
;;   16 callsite changes, ~S–M cost) must improve the pass rate vs the
;;   pre-fix baseline measured here.
;;
;; Acceptance gate:
;;   - Baseline pass rate must be measured before the rewrite-arm fix.
;;   - Post-fix pass rate must exceed baseline by >= 50 percentage points.
;;   - All "direct AST" control cases must remain at 100%.
;;
;; Phase C result (2026-06-01): baseline 5/11 (45.5%) → post-fix 11/11 (100%).
;; Pass rate gain: +54.5pp. Fix surface:
;;   - ast.rkt:store-src! first-wins guard (synthesized-rewrite path no
;;     longer clobbers inner srcloc with surface sugar's loc).
;;   - parse.rkt:rewrite-as helper + current-form-stx parameter set in
;;     parse-expr immediately before parse-list-form dispatch.
;;   - parse.rkt: 16 callsite changes in the gap arms (when/when-not/
;;     if-not/unless/-> /->>/as->/cond->/cond->>/some->/some->>/if-let/
;;     when-let/if-some/when-some/fmt) — each now passes a syntax-tagged
;;     synthesized datum so sub-form srclocs survive.
;;   - parse.rkt:thread-step-insert + lower-binding-cond — accept the
;;     original sub-syntax objects (steps, rest items, val expression) so
;;     downstream srclocs propagate naturally instead of being lost when
;;     re-cons'd.
;;   - check.rkt:check-one-arg — prefer call-src over arg-src when both
;;     are available. Reflects that the callee demanding the wrong type
;;     is the operative blame point (matches the threading-family
;;     expected lines).
;;   - ast.rkt:current-body-locs-table + body-loc-at — positional
;;     srcloc anchor for bare-symbol body tails (defn return-type
;;     diag's `(last body)` is often a symbol, which store-src! refuses
;;     by interning policy).
;;
;; Known limitations (NOT covered by current benchmark entries; would
;; require additional fixture work and / or scope expansion to address):
;;
;;   1. Inner structural records (cond-clause, match-clause, catch-clause,
;;      case-clause, for-binding, let-binding, arity-clause, impl-method,
;;      param, scalar-predicate, map/seq-destructure) are built via
;;      parse helpers that bypass parse-expr, so they are never stored in
;;      src-table. Diagnostics that need their srcloc must navigate to a
;;      child whose srcloc IS preserved (e.g. cond-clause-test); most
;;      already do, so this is latent rather than user-visible. Closing it
;;      cleanly requires either teaching store-src! to accept these record
;;      types or routing them through parse-expr.
;;
;;   2. SQL target diagnostic sites (check.rkt:793,800,807,821,831,839,
;;      847,866,981 — 8 sites in sql-* arms) raise without `#:src`, so
;;      they fall back to top-of-form positioning. The SQL target is in
;;      the gated tier and not exercised by this benchmark.
;;
;;   3. Typed JS template-splice (check.rkt:1707) and type-bound
;;      (check.rkt:2179) sites also omit `#:src`. JS target is in the
;;      demoted/gated tier; not exercised here.
;;
;;   4. emit-clj reader metadata: synthesized AST nodes from the
;;      rewrite arms now carry correct srcloc, so the existing
;;      emit-clj metadata emit (^{:line N :file F}) automatically
;;      reflects the right line for those expansions. No code change
;;      needed; this is a free downstream win from the parse-time fix.
;;
;;   5. emit-nix has no srcloc consumer (intentional — Nix has no
;;      metadata facility). Diagnostics on Nix output are sourced from
;;      AST srcloc directly; no separate emit-side gap.

(require rackunit
         racket/file
         racket/list
         racket/string
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/ast)

(provide benchmark-entries
         run-benchmark
         capture-first-diagnostic)

;; =============================================================================
;; Helpers
;; =============================================================================

;; Write SOURCE to a temp file (with explicit #lang line so read-beagle-syntax
;; numbers match the file's line numbers) and return its path.
;;
;; IMPORTANT: read-beagle-syntax has an off-by-one when #lang is absent (the
;; rewind+port-count-lines! re-init combo shifts line numbers by 1). All
;; fixtures here include a #lang line on line 1; that means line N in the
;; source string body (counted from the #lang line itself) matches line N
;; reported by syntax-line on the parsed forms.
(define (write-fixture source [lang "#lang beagle/clj"])
  (define tmp (make-temporary-file "sourcemap-bench-~a.bclj"))
  (call-with-output-file tmp
    (lambda (out)
      (display lang out) (newline out)
      (display source out))
    #:exists 'truncate/replace)
  tmp)

;; Parse + type-check FIXTURE-PATH; capture the first diagnostic raised.
;; Returns (vector 'diag KIND ERROR-LINE TOP-STX-LINE MSG ERROR-COL) on
;;   diagnostic,
;; (vector 'parse-err KIND #f #f MSG #f) on parse error,
;; (vector 'no-err #f #f #f #f #f) if no error fires.
;; (All result vectors are 6-wide so slot 5 — error-col — is always safe.)
(define (capture-first-diagnostic fixture-path)
  (with-handlers
    ([beagle-parse-error?
      (lambda (e)
        (vector 'parse-err
                (beagle-parse-error-kind e)
                #f
                #f
                (exn-message e)
                #f))])
    (define forms (read-beagle-syntax fixture-path))
    (define prog (parse-program forms))
    (define result (box (vector 'no-err #f #f #f #f #f)))
    (with-handlers
      ([beagle-diagnostic?
        (lambda (e)
          (define d (beagle-diagnostic-details e))
          (set-box! result
                    (vector 'diag
                            (beagle-diagnostic-kind e)
                            (hash-ref d 'error-line #f)
                            #f
                            (exn-message e)
                            (hash-ref d 'error-col #f))))])
      (type-check-with-locs! prog
        (lambda (e stx)
          (cond
            [(beagle-diagnostic? e)
             (define d (beagle-diagnostic-details e))
             (set-box! result
                       (vector 'diag
                               (beagle-diagnostic-kind e)
                               (hash-ref d 'error-line #f)
                               (syntax-line stx)
                               (exn-message e)
                               (hash-ref d 'error-col #f)))]
            [else
             (set-box! result
                       (vector 'exn 'exn-fail #f #f (exn-message e) #f))]))))
    (unbox result)))

;; Compute the "effective" line — what write-json-error would emit. This
;; mirrors error-format.rkt:103 (`(or error-line (syntax-line stx))`).
(define (effective-line result)
  (case (vector-ref result 0)
    [(diag) (or (vector-ref result 2) (vector-ref result 3))]
    [else #f]))

;; The precise per-node column the diagnostic carries (0-based, matching
;; Racket's syntax-column). #f when no diagnostic / no column.
(define (effective-col result)
  (case (vector-ref result 0)
    [(diag) (vector-ref result 5)]
    [else #f]))

;; =============================================================================
;; Benchmark entries
;; =============================================================================
;;
;; Each entry is a hash:
;;   id       — symbol
;;   category — symbol describing the gap class
;;   src      — string body (no leading #lang; harness prepends one)
;;   expected — expected error line number in the file (1-indexed, INCLUDING
;;              the leading #lang line). The fixture-writer puts the body
;;              starting at line 2, so author intent of "the error is on
;;              the 3rd body line" should be encoded as expected=4.
;;   why      — brief reason / what the diagnostic should blame
;;   kind     — expected diagnostic kind (sanity check, not asserted unless
;;              the entry needs it)

(define benchmark-entries
  (list
   ;; -------------------------------------------------------------------------
   ;; 1. (when c body) — body type error. Should blame body's actual line.
   ;; -------------------------------------------------------------------------
   (hash 'id 'when-body-type-error
         'category 'sugar-when-body
         'src "(defn g [n: Int] -> Nil nil)
(defn f [x: Int] -> Nil
  (when true
    (g \"boom\")))"
         ;; Layout (1-indexed):
         ;;   1: #lang beagle/clj
         ;;   2: (defn g …)
         ;;   3: (defn f …)
         ;;   4:   (when true
         ;;   5:     (g \"boom\"))
         'expected 5
         'why "type-mismatch on (g \"boom\") arg — blame line of (g …)"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 2. (when c body) — condition is non-Bool. Should blame c's actual line.
   ;; -------------------------------------------------------------------------
   ;; NOTE: beagle's `when` is permissive about non-Bool conditions (Clojure
   ;; truthiness). Restate as a stricter cast: pass the literal as an arg
   ;; that demands Bool — `(when (+ 1 2) …)` will not error, but if we use
   ;; `(if (+ 1 2) …)` we expect no error either. We instead exercise the
   ;; `if` arms' "predicate must be Bool"-style check via a type-annotation
   ;; chain. If beagle does not enforce predicate=Bool the entry degrades
   ;; to a kind-mismatch that the harness records but does not double-count.
   (hash 'id 'when-condition-non-bool
         'category 'sugar-when-condition
         'src "(defn need-string [s: String] -> Nil nil)
(defn f [] -> Nil
  (when
    (need-string 42)
    nil))"
         ;; The type-error is on `42` (or on `(need-string 42)`). Author intent:
         ;; the line of the call `(need-string 42)` should be blamed, not the
         ;; `when` line.
         ;;   1: #lang
         ;;   2: (defn need-string …)
         ;;   3: (defn f [] -> Nil
         ;;   4:   (when
         ;;   5:     (need-string 42)
         ;;   6:     nil))
         'expected 5
         'why "arg type-mismatch on (need-string 42) — blame the inner call's line"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 3. (if-let [x v] then else) — type error in then. Blame then's line.
   ;; -------------------------------------------------------------------------
   (hash 'id 'if-let-then-type-error
         'category 'sugar-if-let
         'src "(defn g [n: Int] -> Nil nil)
(defn f [opt: Int?] -> Nil
  (if-let [x opt]
    (g \"boom\")
    nil))"
         ;;   1: #lang
         ;;   2: (defn g …)
         ;;   3: (defn f …)
         ;;   4:   (if-let [x opt]
         ;;   5:     (g \"boom\")
         ;;   6:     nil))
         'expected 5
         'why "type-mismatch in then-branch — blame the then-branch call's line"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 4. (-> 1 (foo) (bar)) — bar takes a wrong type. Blame bar's line.
   ;; -------------------------------------------------------------------------
   (hash 'id 'thread-first-mid-step-mismatch
         'category 'sugar-thread-first
         'src "(defn double [n: Int] -> Int (+ n n))
(defn need-string [s: String] -> Nil nil)
(defn f [] -> Nil
  (-> 1
      (double)
      (need-string)))"
         ;;   1: #lang
         ;;   2: (defn double …)
         ;;   3: (defn need-string …)
         ;;   4: (defn f …)
         ;;   5:   (-> 1
         ;;   6:       (double)
         ;;   7:       (need-string)))
         'expected 7
         'why "need-string can't accept Int — blame the (need-string) step's line"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 5. (some-> x (foo)) — foo's typed return chains into next step badly.
   ;; -------------------------------------------------------------------------
   (hash 'id 'some-thread-first-mid-step-mismatch
         'category 'sugar-some-thread-first
         'src "(defn double [n: Int] -> Int (+ n n))
(defn need-string [s: String] -> Nil nil)
(defn f [opt: Int?] -> Nil
  (some-> opt
          (double)
          (need-string)))"
         ;;   1: #lang
         ;;   2: (defn double …)
         ;;   3: (defn need-string …)
         ;;   4: (defn f …)
         ;;   5:   (some-> opt
         ;;   6:           (double)
         ;;   7:           (need-string)))
         'expected 7
         'why "need-string can't accept Int — blame the (need-string) step's line"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 6. (cond t1 r1 t2 r2 :else d) flat-pair — type error in r1.
   ;; -------------------------------------------------------------------------
   (hash 'id 'cond-flat-pair-result-mismatch
         'category 'cond-clause-result
         'src "(defn g [n: Int] -> Nil nil)
(defn f [] -> Nil
  (cond
    true (g \"boom\")
    :else nil))"
         ;;   1: #lang
         ;;   2: (defn g …)
         ;;   3: (defn f …)
         ;;   4:   (cond
         ;;   5:     true (g \"boom\")
         ;;   6:     :else nil))
         'expected 5
         'why "type-mismatch in r1 — blame the line of (g \"boom\")"
         'kind 'type-mismatch)

   ;; -------------------------------------------------------------------------
   ;; 7. (get m :k) literal-key — m is not a record. Blame get's line.
   ;; -------------------------------------------------------------------------
   (hash 'id 'get-literal-key-non-record
         'category 'kw-access-via-get
         'src "(defrecord Point
  [x: Int
   y: Int])
(defn f [p: Point] -> String
  (get p :x))"
         ;;   1: #lang
         ;;   2-4: (defrecord …)
         ;;   5: (defn f …)
         ;;   6:   (get p :x))
         ;; Expected: line 5 or line 6. The actual mismatch is the return-type
         ;; lie at the `-> String` site (line 5) since field x: Int. We expect
         ;; the diagnostic to point at line 6 (where the get is) — the body
         ;; expression that produced the wrong type.
         'expected 6
         'why "return-type mismatch at body (get p :x) — line of get"
         'kind 'return-type)

   ;; -------------------------------------------------------------------------
   ;; 8. (:k m) shorthand — round-trip fidelity with #7.
   ;; -------------------------------------------------------------------------
   (hash 'id 'kw-shorthand-non-record
         'category 'kw-access-shorthand
         'src "(defrecord Point
  [x: Int
   y: Int])
(defn f [p: Point] -> String
  (:x p))"
         ;;   1: #lang
         ;;   2-4: (defrecord …)
         ;;   5: (defn f …)
         ;;   6:   (:x p))
         'expected 6
         'why "return-type mismatch at body (:x p) — line of kw-access"
         'kind 'return-type)

   ;; -------------------------------------------------------------------------
   ;; 9. (defn f [x: Int] -> String x) — return-type mismatch. Blame x's
   ;;    position (or `->` line). The canonical "where the lie was made".
   ;; -------------------------------------------------------------------------
   (hash 'id 'defn-return-type-mismatch
         'category 'defn-direct
         'src "(defn f [x: Int] -> String
  x)"
         ;;   1: #lang
         ;;   2: (defn f [x: Int] -> String
         ;;   3:   x)
         ;; The mismatch is "body returns Int but `->` says String". Body's
         ;; last expr is `x` at line 3. The check.rkt:706 diagnostic uses
         ;; `#:src (src-for (last body))` — but bare symbol `x` is rejected
         ;; by store-src! (not stored, line 76 of ast.rkt). So srcloc is
         ;; missing; falls back to top-stx line = 2.
         ;; Expected (what user *wants*): line 3 (the body expression).
         'expected 3
         'why "return-type mismatch — blame the body's last expression"
         'kind 'return-type)

   ;; -------------------------------------------------------------------------
   ;; 10. Inline (:keyword target) — same case as #7/#8 with different layout.
   ;;     This entry is the "control" for the kw-access shorthand to confirm
   ;;     it produces an IDENTICAL diagnostic position as the literal-key form.
   ;; -------------------------------------------------------------------------
   (hash 'id 'kw-shorthand-multiline
         'category 'kw-access-shorthand-multiline
         'src "(defrecord Point
  [x: Int
   y: Int])
(defn f [p: Point] -> String
  (:x
   p))"
         ;;   1: #lang
         ;;   2-4: (defrecord …)
         ;;   5: (defn f …)
         ;;   6:   (:x
         ;;   7:    p))
         ;; The kw-access form spans lines 6-7; the "where the lie was made"
         ;; is line 6 (the start of (:x …)).
         'expected 6
         'why "return-type mismatch — blame line of the (:x p) form"
         'kind 'return-type)

   ;; -------------------------------------------------------------------------
   ;; CONTROL — direct (if c t e) with body-call mismatch. Should report
   ;; the inner call's line (line 5). The direct `if` arm DOES preserve
   ;; srcloc; if this regresses, the rewrite-arm fix broke something
   ;; orthogonal.
   ;; -------------------------------------------------------------------------
   (hash 'id 'control-if-direct-body-mismatch
         'category 'control-direct-if
         'src "(defn g [n: Int] -> Nil nil)
(defn f [x: Int] -> Nil
  (if true
    (g \"boom\")
    nil))"
         ;;   1: #lang
         ;;   2: (defn g …)
         ;;   3: (defn f …)
         ;;   4:   (if true
         ;;   5:     (g \"boom\")
         ;;   6:     nil))
         'expected 5
         'why "control — direct if arm preserves srcloc"
         'kind 'type-mismatch)))

;; =============================================================================
;; Harness
;; =============================================================================

(define (run-benchmark #:label [label "current"]
                       #:verbose? [verbose? #t])
  (define total (length benchmark-entries))
  (define pass 0)
  (define misses '())
  (define start-ms (current-inexact-milliseconds))
  (for ([entry (in-list benchmark-entries)])
    (define id (hash-ref entry 'id))
    (define cat (hash-ref entry 'category))
    (define src (hash-ref entry 'src))
    (define expected (hash-ref entry 'expected))
    (define why (hash-ref entry 'why))
    (define fixture (write-fixture src))
    (define result (capture-first-diagnostic fixture))
    (delete-file fixture)
    (define eff (effective-line result))
    (cond
      [(equal? eff expected)
       (set! pass (add1 pass))
       (when verbose?
         (printf "  PASS ~a  (~a)  line=~a~n" id cat eff))]
      [else
       (set! misses (cons (list id cat expected eff result) misses))
       (when verbose?
         (define res-tag (vector-ref result 0))
         (printf "  FAIL ~a  (~a)  expected=~a actual=~a [~a]~n"
                 id cat expected eff res-tag)
         (printf "    why: ~a~n" why)
         (when (memq res-tag '(diag parse-err))
           (printf "    kind: ~a  msg: ~a~n"
                   (vector-ref result 1) (vector-ref result 4))))]))
  (define elapsed (- (current-inexact-milliseconds) start-ms))
  (printf "~n=== Sourcemap fidelity benchmark: ~a ===~n" label)
  (printf "  total:    ~a~n" total)
  (printf "  PASS:     ~a/~a (~a%)~n"
          pass total
          (real->decimal-string (* 100.0 (/ pass total)) 1))
  (printf "  elapsed:  ~ams~n" (real->decimal-string elapsed 1))
  (when (pair? misses)
    (printf "  misses:~n")
    (for ([m (in-list (reverse misses))])
      (printf "    ~a (~a): expected line ~a, got ~a~n"
              (car m) (cadr m) (caddr m) (cadddr m))))
  (values pass total elapsed))

;; =============================================================================
;; Tests
;; =============================================================================

(test-case "benchmark runs and produces a result"
  (define-values (pass total elapsed) (run-benchmark #:verbose? #f))
  (check-true (number? pass))
  (check-true (>= pass 0))
  (check-equal? total (length benchmark-entries)))

(test-case "control case (direct if) passes"
  ;; The direct-if control must hold up: if it ever fails, the harness or
  ;; the parser broke something orthogonal to the rewrite-arm fix.
  (define entry
    (findf (lambda (e) (eq? (hash-ref e 'id) 'control-if-direct-body-mismatch))
           benchmark-entries))
  (check-true (hash? entry))
  (define fixture (write-fixture (hash-ref entry 'src)))
  (define result (capture-first-diagnostic fixture))
  (delete-file fixture)
  (define expected (hash-ref entry 'expected))
  (check-equal? (effective-line result) expected
                (format "direct-if control should report line ~a; got ~v"
                        expected result)))

;; --- Column fidelity (gate #4: preserve error-col through canonicalization) -
;;
;; Precise line and precise column come from the SAME src-loc, so the
;; invariant is: whenever a diagnostic carries a precise line (from #:src),
;; it must also carry a precise column. Before this work, src-loc-col was
;; captured but never propagated (raise-diag dropped it; every consumer read
;; col from the whole top-level form). These tests pin the propagation.

(test-case "precise column propagates wherever a precise line does"
  (for ([entry (in-list benchmark-entries)])
    (define fixture (write-fixture (hash-ref entry 'src)))
    (define result (capture-first-diagnostic fixture))
    (delete-file fixture)
    (when (eq? (vector-ref result 0) 'diag)
      (define line (vector-ref result 2))  ; precise error-line (from #:src)
      (define col  (effective-col result))
      (when line
        (check-true (number? col)
                    (format "~a: precise line ~a but no precise column"
                            (hash-ref entry 'id) line))))))

(test-case "column points at the offending sub-expression, not the whole form"
  ;; Both fixtures blame the call `(g "boom")` which is indented 4 spaces on
  ;; its line, so the precise column is 4 (0-based). A degraded column would
  ;; report the enclosing `(defn f …)` form's column (0).
  (for ([id (in-list '(control-if-direct-body-mismatch when-body-type-error))])
    (define entry (findf (lambda (e) (eq? (hash-ref e 'id) id))
                         benchmark-entries))
    (define fixture (write-fixture (hash-ref entry 'src)))
    (define result (capture-first-diagnostic fixture))
    (delete-file fixture)
    (check-equal? (effective-col result) 4
                  (format "~a: expected column 4 (the `(g …)` call), got ~v"
                          id (effective-col result)))))

;; --- Origin / canonical model (Lean SourceInfo 3-state) ---------------------

(test-case "src-loc origin/canonical model"
  (define s (datum->syntax #f 'x (list "f.bclj" 7 3 99 1)))
  (define l (stx->src-loc s))
  (check-equal? (src-loc-line l) 7)
  (check-equal? (src-loc-col l) 3)
  (check-equal? (src-loc-origin l) 'original)
  (check-false (src-loc-canonical l))
  (check-true (loc-blamable? l) "original positions are always blamable")
  ;; synthetic, non-canonical: generated glue, NOT blamable
  (define syn (synthetic-src-loc l))
  (check-equal? (src-loc-origin syn) 'synthetic)
  (check-false (src-loc-canonical syn))
  (check-false (loc-blamable? syn))
  ;; synthetic, canonical: trustworthy blame point (Lean fromRef canonical)
  (define cano (synthetic-src-loc l #:canonical? #t))
  (check-equal? (src-loc-origin cano) 'synthetic)
  (check-true (src-loc-canonical cano))
  (check-true (loc-blamable? cano))
  ;; line/col/source survive synthetic derivation
  (check-equal? (src-loc-line cano) 7)
  (check-equal? (src-loc-col cano) 3)
  (check-equal? (src-loc-source cano) "f.bclj"))

;; Allow running this file standalone to print the benchmark report:
(module+ main
  (run-benchmark #:label "baseline (HEAD)"))
