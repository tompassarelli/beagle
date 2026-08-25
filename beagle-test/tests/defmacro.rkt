#lang racket/base

;; Tests for `defmacro` — the canonical macro definition form.
;;
;; `defmacro` evaluates its body in Beagle's pure compile-time environment.
;; The reader wraps `` `X ``, `,X`, and `,@X` as `(quasiquote X)`,
;; `(unquote X)`, and `(unquote-splicing X)` for that evaluator.

(require racket/file
         racket/list
         rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/module-interface
         beagle/private/macros)

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (parse-prog/source source-path . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)
                 #:source-path source-path))

(define (parse-source-text source)
  (define tmp (make-temporary-file "beagle-macro-source-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp
        (lambda (out) (display source out))
        #:exists 'truncate)
      (parse-program (read-beagle-syntax tmp) #:source-path tmp))
    (lambda () (delete-file tmp))))

(define (br . xs) (cons BRACKET-TAG xs))

(test-case "defmacro: real reader returns the caller Syntax unchanged"
  (define source
    (string->bytes/utf-8
     (string-append
      "#lang beagle/clj\n"
      "(ns syntax.membrane)\n"
      "(defmacro identity [form] form)\n"
      "(def out (identity (+ 1 2)))\n")))
  (define source-id "syntax-membrane.bclj")
  (define prog
    (parse-program/bytes source
                         #:source-path source-id
                         #:source-id source-id))
  (define forms
    (read-beagle-syntax/bytes source-id source #:source-id source-id))
  (define out-stx
    (for/first ([form (in-list forms)]
                #:when (equal? (take (syntax->datum form) 2) '(def out)))
      form))
  (define call-stx (stx-ref (stx-subs out-stx) 2))
  (define call-syntax (racket-syntax->beagle-syntax call-stx source))
  (define caller-child (cadr (syntax-list-children call-syntax)))
  (define expanded (expand-fully (program-macros prog) call-syntax))
  (check-eq? expanded caller-child)
  (check-equal?
   (reader-metadata-source-bytes (beagle-syntax-reader-metadata expanded))
   #"(+ 1 2)")
  (check-equal? (beagle-syntax-span expanded) (stx->src-loc (stx-ref (stx-subs call-stx) 1))))

;; --- (a) basic unquote ----------------------------------------------------

(test-case "defmacro: inc1 expands quasiquote+unquote"
  ;; (defmacro inc1 [x] `(+ ,x 1))
  ;; (inc1 5) → (+ 5 1)
  (define p (parse-prog
             `(defmacro inc1 ,(br 'x)
                (quasiquote (+ (unquote x) 1)))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq? (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(5 1)))

(test-case "defmacro: body is evaluated in the pure compile-time environment"
  (define p (parse-prog
             `(defmacro inc-built ,(br 'x)
                (list (quote +) x 1))
             '(def y (inc-built 5))))
  (define value (def-form-value (car (program-forms p))))
  (check-true (call-form? value))
  (check-eq? (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(5 1)))

(test-case "defmacro: top-level do output flattens into definitions"
  (define p
    (parse-prog
     `(defmacro define-pair ,(br 'left 'right)
        (quasiquote
         (do (def (unquote left) 1)
             (def (unquote right) 2))))
     '(define-pair alpha beta)))
  (check-equal? (map def-form-name (program-forms p)) '(alpha beta)))

(test-case "defmacro: expression-position do remains an expression"
  (define p
    (parse-prog
     `(defmacro two-values ,(br)
        (quasiquote (do 1 2)))
     '(def value (two-values))))
  (define value (def-form-value (car (program-forms p))))
  (check-true (do-form? value))
  (check-equal? (do-form-body value) '(1 2)))

(test-case "defmacro: compile-time error keeps macro name and message"
  (check-exn (lambda (e)
               (and (regexp-match? #rx"macro reject: body raised an error"
                                   (exn-message e))
                    (regexp-match? #rx"schema needs fields" (exn-message e))))
    (lambda ()
      (parse-prog
       `(defmacro reject ,(br 'x) (error "schema needs fields"))
       '(reject value)))))

;; --- (b) unquote of a vector binding --------------------------------------

(test-case "defmacro: my-let unquotes a bracketed binding"
  ;; (defmacro my-let [bindings body] `(let ,bindings ,body))
  ;; (my-let [a Any 1] a) → (let [a Any 1] a)
  (define p (parse-prog
             `(defmacro my-let ,(br 'bindings 'body)
                (quasiquote (let (unquote bindings) (unquote body))))
             `(def y (my-let ,(br 'a 'Any 1) a))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  (check-true (let-form? value))
  (check-equal? (length (let-form-bindings value)) 1)
  (check-eq? (let-binding-name (car (let-form-bindings value))) 'a)
  (check-equal? (let-binding-value (car (let-form-bindings value))) 1))

;; --- (c) unquote-splicing into a do-block ---------------------------------

(test-case "defmacro: do-each splices a bracketed-vec into surrounding do"
  ;; (defmacro do-each [items body] `(do ,@items ,body))
  ;; (do-each [(println "a") (println "b")] (println "done"))
  ;;   → (do (println "a") (println "b") (println "done"))
  (define p (parse-prog
             `(defmacro do-each ,(br 'items 'body)
                (quasiquote (do (unquote-splicing items) (unquote body))))
             `(def y (do-each ,(br '(println "a") '(println "b"))
                              (println "done")))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  ;; do-form expected
  (check-true (do-form? value))
  (check-equal? (length (do-form-body value)) 3))

;; --- (d) nested quasi-quote -----------------------------------------------
;;
;; `(`(a ,,x b)) — only the inner `,,` reaches level 0. Reading top-down:
;;   level 0: outer quasiquote opens → level 1
;;   level 1: inner quasiquote opens → level 2
;;   level 2: first unquote → level 1 (stays as data)
;;   level 1: second unquote → level 0 (fires; emits x's value)
;; Result: `(a ,VAL b) = (quasiquote (a (unquote VAL) b))
;;
;; We register the macro and inspect its expansion via expand-fully on a
;; raw registry to avoid downstream parse semantics for stray
;; quasiquote/unquote.

(test-case "defmacro: nested quasiquote — only one level unquotes"
  (define reg (make-macro-registry))
  ;; (defmacro outer [x] `(`(a ,,x b)))
  (register-macro! reg 'outer 'defmacro '(x)
                   '(quasiquote
                     (quasiquote
                      (a (unquote (unquote x)) b))))
  (define expanded (expand-fully reg '(outer 99)))
  ;; Expect (quasiquote (a (unquote 99) b))
  (check-equal? expanded '(quasiquote (a (unquote 99) b))))

(test-case "imported macro qualification follows lexical declaration scope"
  (define qualified
    (qualify-imported-macro-template
     (list 'quasiquote
           (list 'let (br 'x 'Any 'x)
                 (list 'helper 'x)))
     '()
     (hasheq 'x #t 'helper #t)
     'provider))
  (check-equal?
   qualified
   (list 'quasiquote
         (list 'let (br 'x 'Any 'provider/x)
               (list 'provider/helper 'x)))))

(test-case "imported macro qualification resolves structural type slots at definition site"
  (define qualified
    (qualify-imported-macro-template
     (list 'quasiquote
           (list 'fn
                 (br 'x 'Box)
                 (list 'Result 'Box)
                 'x))
     '()
     (hasheq 'Box #t 'Result #t)
     'provider))
  (check-equal?
   qualified
   (list 'quasiquote
         (list 'fn
               (br 'x 'provider/Box)
               (list 'provider/Result 'provider/Box)
               'x))))

(test-case "defmacro: declaration shape is local and flattened metadata is stray"
  (define reg (make-macro-registry))
  (define declaration-name-body
    `(map
      (fn ,(br 'field 'Any) Any
        (if (list? field)
            (if (= (count field) 2)
                (syntax-name field)
                (if (= (count field) 3)
                    (syntax-name field)
                    (error "Invalid field declaration: " field
                           "\n\nEach field must be one complete form:\n  (name Type validator)")))
            (error "Invalid field declaration: " field
                   "\n\nEach field must be one complete form:\n  (name Type validator)")))
      fields))
  (register-macro! reg 'field-names 'defmacro '(fields) declaration-name-body)
  (check-equal?
   (expand-macro
    reg
    'field-names
    (list (br '(id String valid-id?) '(name String valid-name?))))
   '(id name))
  (check-exn
   (lambda (e)
     (and (exn:fail? e)
          (regexp-match? #rx"Invalid field declaration: valid-id-wire\\?"
                         (exn-message e))
          (regexp-match? #rx"Each field must be one complete form"
                         (exn-message e))))
   (lambda ()
     (expand-macro
      reg
      'field-names
      (list (br '(id String) 'valid-id-wire?))))))

(test-case "defmacro: syntax-error-at points at the stray caller declaration"
  (define source
    (string-append
     "(defmacro field-names [fields]\n"
     "  (map-indexed\n"
     "   (fn [i Int field Any] Any\n"
     "     (if (list? field)\n"
     "         (syntax-name field)\n"
     "         (syntax-error-at fields i\n"
     "           \"Invalid field declaration: \" field\n"
     "           \"\\n\\nEach field must be one complete form:\\n  (name Type validator)\")))\n"
     "   fields))\n"
     "(field-names [(id String)\n"
     "              valid-id-wire?])\n"))
  (with-handlers
      ([beagle-parse-error?
        (lambda (e)
          (check-eq? (beagle-parse-error-kind e)
                     'macro-expansion-parse-error)
          (check-regexp-match #rx"Invalid field declaration: valid-id-wire\\?"
                              (exn-message e))
          (define details (beagle-parse-error-details e))
          (check-equal? (hash-ref details 'macro-name) "field-names")
          (check-equal? (hash-ref details 'stray-form) "valid-id-wire?")
          (check-equal? (hash-ref details 'error-line) 11)
          (check-equal? (hash-ref details 'error-col) 14)
          (check-equal? (hash-ref details 'error-span) 14))])
    (parse-source-text source)
    (fail "source-local macro rejection unexpectedly parsed")))

(test-case "defmacro: syntax-error-at targets a complete wrong-arity list declaration"
  (define source
    (string-append
     "(defmacro field-names [fields]\n"
     "  (map-indexed\n"
     "   (fn [i Int field Any] Any\n"
     "     (if (list? field)\n"
     "         (if (= (count field) 2)\n"
     "             (syntax-name field)\n"
     "             (if (= (count field) 3)\n"
     "                 (syntax-name field)\n"
     "                 (syntax-error-at fields i\n"
     "                   \"Invalid field declaration: \" field)))\n"
     "         (syntax-error-at fields i\n"
     "           \"Invalid field declaration: \" field)))\n"
     "   fields))\n"
     "(field-names [(id String valid-id? extra)])\n"))
  (with-handlers
      ([beagle-parse-error?
        (lambda (e)
          (check-regexp-match
           #rx"Invalid field declaration: \\(id String valid-id\\? extra\\)"
           (exn-message e))
          (define details (beagle-parse-error-details e))
          (check-equal? (hash-ref details 'stray-form)
                        "(id String valid-id? extra)")
          (check-equal? (hash-ref details 'error-line) 14)
          (check-equal? (hash-ref details 'error-col) 14)
          (check-equal? (hash-ref details 'error-pos) 451)
          (check-equal? (hash-ref details 'error-span) 27))])
    (parse-source-text source)
    (fail "wrong-arity source-local macro declaration unexpectedly parsed")))

(test-case "defmacro: source-local collection diagnostics preserve delimiters and spans"
  (for ([case (in-list
               (list (list "[id String]" #rx"\\[id String\\]" 11)
                     (list "{:keys [id]}" #rx"\\{:keys \\[id\\]\\}" 12)))])
    (define form (car case))
    (define form-rx (cadr case))
    (define expected-span (caddr case))
    (define source
      (string-append
       "(defmacro reject-first [fields]\n"
       "  (syntax-error-at fields 0 \"Invalid field declaration: \" (first fields)))\n"
       "(reject-first [" form "])\n"))
    (define expected-pos
      (add1 (caar (regexp-match-positions form-rx source))))
    (with-handlers
        ([beagle-parse-error?
          (lambda (e)
            (check-regexp-match
             (regexp (string-append "Invalid field declaration: "
                                    (regexp-quote form)))
             (exn-message e))
            (define details (beagle-parse-error-details e))
            (check-equal? (hash-ref details 'stray-form) form)
            (check-equal? (hash-ref details 'error-line) 3)
            (check-equal? (hash-ref details 'error-col) 15)
            (check-equal? (hash-ref details 'error-pos) expected-pos)
            (check-equal? (hash-ref details 'error-span) expected-span))])
      (parse-source-text source)
      (fail "source-local collection rejection unexpectedly parsed"))))

;; --- (f) arity error ------------------------------------------------------

(test-case "defmacro: arity mismatch errors"
  (check-exn #rx"expected 2 arg"
    (lambda ()
      (parse-prog
       `(defmacro pair ,(br 'x 'y) (quasiquote ((unquote x) (unquote y))))
       '(def z (pair 1))))))

;; --- additional sanity: defmacro without quasiquote ----------------------

(test-case "defmacro: literal body (no quasiquote) behaves like safe template"
  ;; (defmacro id [x] x) — no quasiquote, just direct substitution.
  (define p (parse-prog
             `(defmacro id ,(br 'x) x)
             '(def y (id 42))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-equal? (def-form-value f) 42))

(test-case "defmacro: zero-argument raw adapter remains explicitly lossy"
  (define reg (make-macro-registry))
  (register-macro! reg 'answer 'defmacro '()
                   '(quasiquote (+ 40 2)))
  (check-equal? (expand-macro reg 'answer '()) '(+ 40 2)))

;; --- additional sanity: defmacro duplicate registration errors ------------

(test-case "defmacro: duplicate definition errors"
  (check-exn exn:fail?
    (lambda ()
      (parse-prog
       `(defmacro dup ,(br 'x) (quasiquote (unquote x)))
       `(defmacro dup ,(br 'y) (quasiquote (unquote y)))))))

;; --- Phase D edge cases ---------------------------------------------------
;;
;; Coverage for splice-position, container-position, and stray-form
;; behavior that Phase C's six spec deliverables didn't directly hit.

(define MAP-T '#%map)

(test-case "defmacro: splice in middle of list"
  ;; (defmacro middle [xs] `(a ,@xs b))
  ;; (middle [1 2]) → (a 1 2 b)
  (define reg (make-macro-registry))
  (register-macro! reg 'middle 'defmacro '(xs)
                   '(quasiquote (a (unquote-splicing xs) b)))
  (check-equal? (expand-fully reg `(middle ,(br 1 2)))
                '(a 1 2 b)))

(test-case "defmacro: empty splice collapses cleanly"
  ;; (defmacro maybe [xs] `(do ,@xs done))
  ;; (maybe []) → (do done)
  (define reg (make-macro-registry))
  (register-macro! reg 'maybe 'defmacro '(xs)
                   '(quasiquote (do (unquote-splicing xs) done)))
  (check-equal? (expand-fully reg `(maybe ,(br)))
                '(do done)))

(test-case "defmacro: splice in vec preserves bracket tag"
  ;; (defmacro vec-it [xs] `[head ,@xs tail])
  ;; (vec-it [1 2]) → [head 1 2 tail] (preserving #%brackets tag)
  (define reg (make-macro-registry))
  (register-macro! reg 'vec-it 'defmacro '(xs)
                   (list 'quasiquote
                         (list BRACKET-TAG 'head
                               (list 'unquote-splicing 'xs)
                               'tail)))
  (check-equal? (expand-fully reg `(vec-it ,(br 1 2)))
                (cons BRACKET-TAG '(head 1 2 tail))))

(test-case "defmacro: splice in map preserves map tag"
  ;; (defmacro map-it [pairs] `{:a 1 ,@pairs :z 99})
  ;; The reader emits `{…}` as (#%map …). The evaluator preserves that tag,
  ;; so splicing inside a map literal is supported. The
  ;; key/value pairing inside the map remains the user's responsibility.
  (define reg (make-macro-registry))
  (register-macro! reg 'map-it 'defmacro '(pairs)
                   ;; Build the template structurally — Racket's own QQ would
                   ;; mis-treat the nested (quasiquote (,MAP-T ...)) as level-2.
                   (list 'quasiquote
                         (list MAP-T ':a 1
                               (list 'unquote-splicing 'pairs)
                               ':z 99)))
  (check-equal? (expand-fully reg `(map-it ,(br ':k1 ':v1)))
                (list MAP-T ':a 1 ':k1 ':v1 ':z 99)))

(test-case "defmacro: unquote in map key position"
  ;; (defmacro keyed [k v] `{,k ,v})
  ;; Quasiquote treats map elements as a flat list, so both key and value
  ;; positions are unquotable. The keyword-key constraint is a downstream
  ;; (parse-time) check on the post-expansion map literal, not an evaluator
  ;; concern: macro expansion produces (#%map :foo 42); parse-map-literal
  ;; then validates :foo as a keyword key.
  (define reg (make-macro-registry))
  (register-macro! reg 'keyed 'defmacro '(k v)
                   (list 'quasiquote
                         (list MAP-T
                               (list 'unquote 'k)
                               (list 'unquote 'v))))
  (check-equal? (expand-fully reg '(keyed :foo 42))
                (list MAP-T ':foo 42)))

(test-case "defmacro: stray unquote at top level errors"
  ;; `(def x ,y)` outside any quasiquote must surface a clear error.
  (check-exn #rx"unquote.*outside quasiquote"
    (lambda ()
      (parse-prog
       '(def y 1)
       '(def x (unquote y))))))

(test-case "defmacro: stray unquote-splicing at top level errors"
  (check-exn #rx"unquote-splicing.*outside quasiquote"
    (lambda ()
      (parse-prog
       '(def ys (vector 1 2))
       '(def x (unquote-splicing ys))))))

(test-case "defmacro: stray quasiquote at top level errors"
  ;; `(def x `(a ,b c))` — beagle's quasiquote is macro-template-only;
  ;; using it at the top level for data construction is rejected with
  ;; a clear pointer toward `'(…)` / `'[…]` / `'{…}` inert containers.
  (check-exn #rx"quasiquote.*outside defmacro body"
    (lambda ()
      (parse-prog
       '(def b 99)
       '(def x (quasiquote (a (unquote b) c)))))))

;; =============================================================================
;; Cross-file macro imports
;; =============================================================================

(define macrolib-fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "macrolib.bjs")))

(define macro-definition-site-fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "macro-definition-site.bjs")))

(define macro-definition-site-provider
  (let ([prog
         (parse-program
          (read-beagle-syntax macro-definition-site-fixture-source)
          #:source-path macro-definition-site-fixture-source)])
    (type-check! prog)
    (module-source
     'macro-definition-site
     macro-definition-site-fixture-source
     #f
     (program->module-interface
      prog
      #:source-id macro-definition-site-fixture-source))))

(define (parse-imported-define-box require-spec invocation)
  (parse-program
   (map (lambda (form) (datum->syntax #f form))
        (list
         '(define-target js)
         (list 'ns 'test-consumer (list ':require require-spec))
         (list 'defrecord 'Box (br 'value 'Int))
         (list 'defn 'normalize (br 'value 'Int) 'Int 'value)
         invocation))
   #:source-path "test-consumer.bjs"
   #:module-resolver
   (lambda (namespace _importer)
     (and (eq? namespace 'macro-definition-site)
          macro-definition-site-provider))))

(define (check-imported-define-box prog expected-prefix expected-name
                                   [expected-type-prefix expected-prefix])
  (check-not-exn (lambda () (type-check! prog)))
  (define generated (last (program-forms prog)))
  (check-true (def-form? generated))
  (check-eq? (def-form-name generated) expected-name)
  (check-eq? (type-prim-name (def-form-type generated))
             (string->symbol (format "~a/Box" expected-type-prefix)))
  (define ctor-call (def-form-value generated))
  (check-true (call-form? ctor-call))
  (define ctor-ref (call-form-fn ctor-call))
  (check-true (qualified-ref? ctor-ref))
  (check-eq? (qualified-ref-qualifier ctor-ref) expected-prefix)
  (check-eq? (qualified-ref-name ctor-ref) '->Box)
  (define helper-call (car (call-form-args ctor-call)))
  (check-true (call-form? helper-call))
  (define helper-ref (call-form-fn helper-call))
  (check-true (qualified-ref? helper-ref))
  (check-eq? (qualified-ref-qualifier helper-ref) expected-prefix)
  (check-eq? (qualified-ref-name helper-ref) 'normalize))

(test-case "cross-file defmacro: qualified name works"
  (check-not-exn
    (lambda ()
      (parse-prog/source macrolib-fixture-source
       '(define-target js)
       (list 'ns 'test-consumer (list ':require (br 'macrolib)))
       '(def x (macrolib/when-pos 5 42))))))

(test-case "cross-file defmacro: bare name via :refer works"
  (check-not-exn
    (lambda ()
      (parse-prog/source macrolib-fixture-source
       '(define-target js)
       (list 'ns 'test-consumer (list ':require (br 'macrolib ':refer (br 'when-pos))))
       '(def x (when-pos 5 42))))))

(test-case "cross-file defmacro: :as alias works"
  (check-not-exn
    (lambda ()
      (parse-prog/source macrolib-fixture-source
       '(define-target js)
       (list 'ns 'test-consumer (list ':require (br 'macrolib ':as 'm)))
       '(def x (m/when-pos 5 42))))))

(test-case "cross-file defmacro: :as keeps provider definition-site references"
  (check-imported-define-box
   (parse-imported-define-box
    (br 'macro-definition-site ':as 'provider)
    '(provider/define-box aliased "provider"))
   'provider
   'aliased
   'macro-definition-site))

(test-case "cross-file defmacro: :refer keeps provider definition-site references"
  (check-imported-define-box
   (parse-imported-define-box
    (br 'macro-definition-site ':refer (br 'define-box))
    '(define-box referred "provider"))
   'macro-definition-site
   'referred))

(test-case "cross-file defmacro: canonical catch keeps its binder local"
  (define prog
    (parse-program
     (map
      (lambda (form) (datum->syntax #f form))
      (list
       '(define-target js)
       (list 'ns 'test-consumer
             (list ':require (br 'macro-definition-site ':as 'provider)))
       '(def recovered String (provider/recover-message "ok"))))
     #:source-path "test-consumer.bjs"
     #:module-resolver
     (lambda (namespace _importer)
       (and (eq? namespace 'macro-definition-site)
            macro-definition-site-provider))))
  (define generated (last (program-forms prog)))
  (define recovered (def-form-value generated))
  (define clause (car (try-form-catches recovered)))
  (define message-call (car (catch-clause-body clause)))
  (check-eq? (catch-clause-name clause) 'caught)
  (check-eq? (car (call-form-args message-call)) 'caught)
  (check-not-exn (lambda () (type-check! prog))))
