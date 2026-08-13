#lang racket/base

;; `!`-purity enforcement (Phase 6 — design-purity.md, thread 20260528223000).
;;
;; The static-reasoning thesis: "the absence of mutation markers means the
;; code is pure." check-purity! turns the `!`-suffix convention into a checked
;; invariant: a defn/defn- whose name lacks `!` must have a pure body (no
;; set!-form, `!`-headed call, or call to a locally tracked effectful def), one
;; direction only. Local effectfulness propagates to a fixed point so one run
;; exposes every rename boundary.
;;
;; These tests pin BOTH halves of the Phase 6.0 contract:
;;   * the pass FIRES correctly when enabled (warn/error, under strict mode);
;;   * the pass is INERT when off (the shipped default) — the dark-by-default
;;     guarantee that keeps the live consumers green.

(require rackunit
         racket/file
         beagle/private/parse
         beagle/private/check
         beagle/private/diagnostic-kind)

;; --- helpers ----------------------------------------------------------------

(define (prog* . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

;; Run type-check! capturing stderr; return the captured string.
(define (check-output prog)
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (type-check! prog))
  (get-output-string out))

;; A non-`!` defn whose body resets an atom.
(define non-bang-mutating
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn save [box v] Any (reset! box v))))

;; The same body under a `!`-named defn.
(define bang-mutating
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn save! [box v] Any (reset! box v))))

;; A non-`!` defn whose body is pure.
(define pure-defn
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn add [a b] Any (+ a b))))

;; A non-`!` defn whose body uses set! (the AST-level mutation marker).
(define non-bang-set!
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn store [box v] Any (set! box v))))

;; ============================================================================
;; (a) ENABLED: a non-`!` defn whose body mutates is flagged 'purity-leak
;; ============================================================================

(test-case "warn: non-`!` defn with a `!`-call warns about a purity leak"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output non-bang-mutating))
    (check-regexp-match #rx"warning: purity leak" o)
    (check-regexp-match #rx"'save'" o)
    (check-regexp-match #rx"reset!" o)
    (check-regexp-match #rx"rename to 'save!'" o)))

(test-case "warn: non-`!` defn with set! warns about a purity leak"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output non-bang-set!))
    (check-regexp-match #rx"warning: purity leak" o)
    (check-regexp-match #rx"'store'" o)
    (check-regexp-match #rx"set!" o)))

(test-case "error: non-`!` defn with a `!`-call raises a 'purity-leak diagnostic"
  (define e
    (with-handlers ([beagle-diagnostic? values])
      (parameterize ([current-purity-enforcement 'error])
        (type-check! non-bang-mutating))
      'no-error-raised))
  (check-pred beagle-diagnostic? e
              (format "expected beagle-diagnostic, got ~v" e))
  (check-eq? (beagle-diagnostic-kind e) 'purity-leak)
  (define d (beagle-diagnostic-details e))
  (check-equal? (hash-ref d 'error-code) "E019")
  (check-equal? (hash-ref d 'cause) "type-error"))

;; ============================================================================
;; (b) ENABLED: a `!`-named defn with the same mutating body is NOT flagged
;;     (the converse rule — opting in is always allowed)
;; ============================================================================

(test-case "warn: `!`-named defn with a mutating body is not flagged"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output bang-mutating))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "error: `!`-named defn with a mutating body does not raise"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! bang-mutating)))))

;; ============================================================================
;; (c) ENABLED: a pure non-`!` defn is NOT flagged
;; ============================================================================

(test-case "warn: pure non-`!` defn is not flagged"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output pure-defn))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "error: pure non-`!` defn does not raise"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! pure-defn)))))

;; ============================================================================
;; (d) DARK BY DEFAULT: with BEAGLE_PURITY off, nothing is flagged (inert).
;;     This is the Phase 6.0 ship guarantee — the pass cannot turn into a new
;;     diagnostic for any consumer until a later phase raises the default.
;; ============================================================================

(test-case "off: non-`!` mutating defn produces no purity output (inert)"
  (parameterize ([current-purity-enforcement 'off])
    (define o (check-output non-bang-mutating))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "off: non-`!` mutating defn never raises (inert)"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'off])
       (type-check! non-bang-mutating)))))

;; ============================================================================
;; Gating: mode + descent edge cases
;; ============================================================================

(test-case "dynamic mode is exempt even with the flag on (mode gate)"
  (define dyn
    (prog* '(ns t.app) '(define-mode dynamic) '(define-target clj)
           '(defn save [box v] Any (reset! box v))))
  (parameterize ([current-purity-enforcement 'warn])
    ;; dynamic mode short-circuits the whole checker; no purity output.
    (define o (check-output dyn))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "warn: a mutation nested in let/if/do is still caught (descends)"
  (define nested
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn refresh [box v] Any
              (let [x v]
                (if x
                    (do (reset! box x) x)
                    x)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output nested))
    (check-regexp-match #rx"purity leak" o)
    (check-regexp-match #rx"'refresh'" o)))

(test-case "warn: locally effectful defs propagate through every purity boundary"
  (define indirect
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn write-cache [box v] Any (reset! box v))
           '(defn refresh-cache [box v] Any (write-cache box v))
           '(defn run-refresh [box v] Any (refresh-cache box v))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output indirect))
    (check-equal? (length (regexp-match* #rx"warning: purity leak" o)) 3)
    (check-regexp-match #rx"'write-cache'" o)
    (check-regexp-match #rx"'refresh-cache'" o)
    (check-regexp-match #rx"'run-refresh'" o)))

(test-case "warn: calls through pure local defs remain pure"
  (define pure-chain
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn add-one [x] Any (+ x 1))
           '(defn add-two [x] Any (add-one (add-one x)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output pure-chain))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "warn: a mutation inside an inner fn still counts (effects run in the call)"
  (define inner
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn make-handler [box] Any
              (fn [v] Any (reset! box v)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output inner))
    (check-regexp-match #rx"purity leak" o)
    (check-regexp-match #rx"'make-handler'" o)))

(test-case "warn: structural descent finds effects in rescue, doto, and threading"
  (define structural
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn rescue-primary [box v] Any
              (rescue (reset! box v) nil))
           '(defn rescue-fallback [box v] Any
              (rescue v (reset! box v)))
           '(defn touch [box v] Any
              (doto box (reset! v)))
           '(defn threaded [box v] Any
              (-> box (reset! v)))
           '(defn routed [box] Any
              (target-case :clj (reset! box nil)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output structural))
    (check-equal? (length (regexp-match* #rx"warning: purity leak" o)) 5)
    (for ([name '(rescue-primary rescue-fallback touch threaded routed)])
      (check-regexp-match (regexp (format "'~a'" name)) o))))

(test-case "quoted mutation syntax is data, not an effect"
  (define quoted-mutation
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn mutation-data [box v] Any
              (quote (reset! box v)))))
  (parameterize ([current-purity-enforcement 'warn])
    (check-false
     (regexp-match? #rx"purity leak" (check-output quoted-mutation)))))

(test-case "profile zero keeps purity analysis disabled"
  (parameterize ([current-check-profile 0]
                 [current-purity-enforcement 'warn])
    (define out (open-output-string))
    (parameterize ([current-error-port out])
      (check-purity! non-bang-mutating))
    (check-equal? (get-output-string out) "")))

(test-case "transient ownership is lexical, linear, and escape-safe"
  (define (violations . forms)
    (map purity-violation-name
         (purity-violations
          (apply prog* '(ns t.owner) '(define-mode strict)
                 '(define-target clj) forms))))
  ;; An established owner may flow through nested transient-family calls, and
  ;; a fresh origin may be consumed immediately without first being bound.
  (check-equal?
   (violations
    '(defn build [xs flag] Any
       (let [owned (transient xs)]
         (if flag (conj! owned 1) (conj! owned 2))
         (persistent!
          (pop! (disj! (conj! owned 1) 1))))))
   '())
  (check-equal?
   (violations '(defn direct-freeze [xs] Any (persistent! (transient xs))))
   '())
  (check-equal?
   (violations
    '(defn direct-pipeline [xs] Any
       (persistent! (conj! (transient xs) 1))))
   '())
  (check-equal?
   (violations
    '(defn map-build [xs] Any
       (let [owned (transient xs)]
         (persistent! (dissoc! (assoc! owned :k 1) :k)))))
   '())
  ;; Borrowed receivers remain effects even beside a valid local owner.
  (check-equal?
   (violations
    '(defn mixed [borrowed xs] Any
       (let [owned (transient xs)]
         (conj! borrowed 1)
         (persistent! (conj! owned 2)))))
   '(mixed))
  ;; Owners cannot escape directly, through alias/result bindings, closures,
  ;; containers, unknown calls, or conditional acquisition.
  (for ([form
         (in-list
          '((defn direct [xs] Any (transient xs))
            (defn result [xs] Any
              (let [owned (transient xs)] (conj! owned 1)))
            (defn alias [xs] Any
              (let [owned (transient xs)
                    alias owned]
                (persistent! alias)))
            (defn mutator-alias [xs] Any
              (let [owned (transient xs)
                    changed (conj! owned 1)]
                (persistent! changed)))
            (defn closure [xs] Any
              (let [owned (transient xs)]
                (fn [] Any (conj! owned 1))))
            (defn container [xs] Any
              (let [owned (transient xs)] [owned]))
            (defn unknown [xs] Any
              (let [owned (transient xs)] (consume owned)))
            (defn branch-acquire [xs flag] Any
              (let [selected (if flag (transient xs) (transient xs))]
                (persistent! selected)))))])
    (check-equal? (violations form) (list (cadr form))))
  ;; persistent! consumes the owner; subsequent mutation is invalid.
  (check-equal?
   (violations
    '(defn after-freeze [xs] Any
       (let [owned (transient xs)
             frozen (persistent! owned)]
         (conj! owned 1)
         frozen)))
   '(after-freeze)))

(test-case "module effect edges honor lexical binding identity"
  (define p
    (prog* '(ns t.scope) '(define-mode strict) '(define-target clj)
           '(defn writer [cell] Any (reset! cell nil))
           '(defn sink! [value] Any (reset! value nil))
           '(defn parameter-shadow [writer value] Any (writer value))
           '(defn bang-parameter-shadow [sink! value] Any (sink! value))
           '(defn let-shadow [value] Any
              (let [writer (fn [x] Any x)] (writer value)))
           '(defn comprehension-shadow [values] Any
              (for [writer values] (writer nil)))
           '(defn side-effect-loop-shadow [values] Any
              (doseq [writer values] (writer nil)))
           '(defn catch-shadow [] Any
              (try nil (catch (writer Exception) (writer nil))))))
  (check-equal? (map purity-violation-name (purity-violations p)) '(writer))
  ;; Use the source reader here: Racket datum brackets cannot represent a
  ;; Beagle map destructuring target faithfully.
  (define destructure-p
    (parse-program/bytes
     (string->bytes/utf-8
      (string-append
       "#lang beagle/clj\n"
       "(ns t.scope.destructure)\n"
       "(define-mode strict)\n"
       "(defn writer [(cell Any)] Any (reset! cell nil))\n"
       "(defn destructure-shadow [(m (Map Keyword Any))] Any\n"
       "  (let [{:keys [writer] :or {writer writer}} m]\n"
       "    (writer nil)))\n"))
     #:source-path "purity-destructure.bgl"))
  (check-equal? (map purity-violation-name (purity-violations destructure-p))
                '(writer)))

(test-case "primitive transient recognition honors module and external bindings"
  (define module-shadow
    (prog* '(ns t.owner.module-shadow) '(define-mode strict) '(define-target clj)
           '(defn transient [value] Any value)
           '(defn expose [xs] Any (persistent! (transient xs)))))
  (check-equal? (map purity-violation-name (purity-violations module-shadow))
                '(expose))
  (define external-shadow
    (prog* '(ns t.owner.external-shadow) '(define-mode strict)
           '(define-target clj) '(declare-extern transient Any)
           '(defn expose [xs] Any (persistent! (transient xs)))))
  (check-equal? (map purity-violation-name (purity-violations external-shadow))
                '(expose)))

(test-case "nested publishing definitions are effects and cannot retain owners"
  (define p
    (prog* '(ns t.owner.publish) '(define-mode strict) '(define-target clj)
           '(defn publish [xs] Any
              (let [owned (transient xs)]
                (defn retained [] Any owned)
                nil))))
  (define violations (purity-violations p))
  (check-equal? (map purity-violation-name violations) '(publish))
  (check-equal?
   (map purity-witness-marker
        (purity-violation-witnesses (car violations)))
   '(definition-publication transient-escape)))

(test-case "-main is exempt: the entry-point contract name cannot carry `!`"
  (define entry
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn run! [(v Any)] Any (reset! (atom nil) v))
           '(defn -main [& (args (Vec String))] Any (run! args))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output entry))
    (check-false (regexp-match? #rx"purity leak" o)))
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! entry)))))

(test-case "plain Clojure main remains a checked purity boundary"
  (define non-entry
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn store-roundtrip?! [] Bool true)
           '(defn main [] Nil (do (store-roundtrip?!) nil))))
  (define e
    (with-handlers ([beagle-diagnostic? values])
      (parameterize ([current-purity-enforcement 'error])
        (type-check! non-entry))
      'no-error-raised))
  (check-pred beagle-diagnostic? e
              (format "expected beagle-diagnostic, got ~v" e))
  (check-eq? (beagle-diagnostic-kind e) 'purity-leak))

(test-case "checked-program projection applies the purity boundary"
  (define located-mutating
    (parse-program
     (list
      (datum->syntax #f '(ns t.app) (vector "purity-location.bclj" 1 0 #f #f))
      (datum->syntax #f '(define-mode strict)
                     (vector "purity-location.bclj" 2 0 #f #f))
      (datum->syntax #f '(define-target clj)
                     (vector "purity-location.bclj" 3 0 #f #f))
      (datum->syntax #f '(defn save [box v] Any (reset! box v))
                     (vector "purity-location.bclj" 4 2 #f #f)))))
  (define diagnostics '())
  (define locations '())
  (parameterize ([current-purity-enforcement 'error])
    (type-check-with-locs!
     located-mutating
     (lambda (e loc-stx)
       (set! diagnostics (cons e diagnostics))
       (set! locations (cons loc-stx locations)))))
  (check-equal? (length diagnostics) 1)
  (check-pred beagle-diagnostic? (car diagnostics))
  (check-eq? (beagle-diagnostic-kind (car diagnostics)) 'purity-leak)
  (check-true (syntax? (car locations)))
  (check-equal? (syntax-source (car locations)) "purity-location.bclj")
  (check-equal? (syntax-line (car locations)) 4)
  (check-equal? (syntax-column (car locations)) 2))

(test-case "purity analysis returns ordered definitions and exact witnesses"
  (define path (make-temporary-file "beagle-purity-witness-~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file path
        (lambda (out)
          (display
           (string-append
            "#lang beagle\n"
            "(ns t.witness)\n"
            "\n"
            "(defn save [(cell (Atom Int)) (value Int)] Int\n"
            "  (store cell value))\n"
            "\n"
            "(defn store [(cell (Atom Int)) (value Int)] Int\n"
            "  (reset! cell value))\n"
            "\n"
            "(defn write\n"
            "  ([(cell (Atom Int))] Int (reset! cell 0))\n"
            "  ([(cell (Atom Int)) (value Int)] Int (reset! cell value)))\n")
           out))
        #:exists 'truncate/replace)
      (define violations (purity-violations (parse-program/file path)))
      (check-equal? (map purity-violation-name violations)
                    '(save store write))
      (check-equal?
       (map (lambda (violation)
              (syntax-line (purity-violation-definition-stx violation)))
            violations)
       '(4 7 10))
      ;; Multi-arity `write` remains one boundary. Its two authored clauses
      ;; retain their distinct witnesses in source order.
      (check-equal?
       (map (lambda (violation)
              (length (purity-violation-witnesses violation)))
            violations)
       '(1 1 2))
      (define witnesses
        (map (lambda (violation)
               (purity-witness-stx
                (car (purity-violation-witnesses violation))))
             violations))
      (check-equal? (map syntax->datum witnesses)
                    '((store cell value)
                      (reset! cell value)
                      (reset! cell 0)))
      (check-equal? (map syntax-line witnesses) '(5 8 11))
      (check-equal? (map syntax-column witnesses) '(2 2 27))
      (for ([witness (in-list witnesses)])
        (check-true (exact-positive-integer? (syntax-position witness)))
        (check-true (exact-positive-integer? (syntax-span witness)))))
    (lambda () (delete-file path))))

(test-case "source-less purity analysis does not fabricate witness syntax"
  (define violations (purity-violations non-bang-mutating))
  (check-equal? (length violations) 1)
  (check-false
   (purity-witness-stx
    (car (purity-violation-witnesses (car violations))))))

(test-case "export wrappers retain their authored purity boundary"
  (define source
    (string-append
     "#lang beagle/js\n"
     "(ns t.exported)\n"
     "(js/export\n"
     "  (defn save [(cell (Atom Int)) (value Int)] Int\n"
     "    (reset! cell value)))\n"))
  (define prog
    (parse-program/bytes (string->bytes/utf-8 source)
                         #:source-path "purity-export.bjs"))
  (define violations (purity-violations prog))
  (check-equal? (length violations) 1)
  (define violation (car violations))
  (check-equal? (purity-violation-name violation) 'save)
  (check-equal? (syntax-line (purity-violation-definition-stx violation)) 3)
  (check-equal? (car (syntax->datum
                      (purity-violation-definition-stx violation)))
                'js/export)
  (define witness
    (purity-witness-stx (car (purity-violation-witnesses violation))))
  (check-equal? (syntax->datum witness) '(reset! cell value))
  (check-equal? (syntax-line witness) 5))

;; ============================================================================
;; Diagnostic-kind wiring
;; ============================================================================

(test-case "purity-leak maps to the type-error cause class"
  (check-eq? (kind->cause-class 'purity-leak) 'type-error))

(test-case "purity-leak stamps error code E019"
  (check-equal? (kind->error-code 'purity-leak) "E019"))
