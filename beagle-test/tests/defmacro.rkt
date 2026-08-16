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
  ;; (my-let [a 1] a) → (let [a 1] a)
  (define p (parse-prog
             `(defmacro my-let ,(br 'bindings 'body)
                (quasiquote (let (unquote bindings) (unquote body))))
             `(def y (my-let ,(br 'a 1) a))))
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

;; --- (e) hygiene: gensym-protected template binder ------------------------

(test-case "defmacro: swap renames template-introduced tmp to avoid capture"
  ;; (defmacro swap [a b] `(let [tmp ,a] (set! ,a ,b) (set! ,b tmp)))
  ;; If hygiene works, `tmp` is gensym'd in both binder and reference
  ;; positions — the resulting let-binding name is not the literal symbol
  ;; `tmp`.
  (define reg (make-macro-registry))
  (register-macro! reg 'swap 'defmacro '(a b)
                   (list 'quasiquote
                         (list 'let
                               (cons BRACKET-TAG
                                     (list 'tmp (list 'unquote 'a)))
                               (list 'set! (list 'unquote 'a) (list 'unquote 'b))
                               (list 'set! (list 'unquote 'b) 'tmp))))
  (define expanded (expand-fully reg '(swap foo bar)))
  ;; expanded ≈ (let [G tmp-gensym foo] (set! foo bar) (set! bar tmp-gensym))
  (check-true (pair? expanded))
  (check-eq? (car expanded) 'let)
  (define bindings (cadr expanded))
  ;; bindings should be a bracketed-vec
  (check-true (and (pair? bindings) (eq? (car bindings) BRACKET-TAG)))
  (define binder-name (cadr bindings))
  ;; gensym means the binder is NOT the literal symbol `tmp`
  (check-false (eq? binder-name 'tmp))
  ;; The binding value is the substituted parameter
  (check-eq? (caddr bindings) 'foo)
  ;; The trailing `tmp` reference is renamed to the SAME gensym
  (define trailing-set! (cadddr expanded))
  (check-eq? (caddr trailing-set!) binder-name))

(test-case "defmacro: computed references follow renamed template binders"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'computed-ref 'defmacro '()
   (list 'let
         (br 'body (list 'list (list 'quote '+) (list 'quote 'm) 1))
         (list 'quasiquote
               (list 'fn (br 'm) (list 'unquote 'body)))))
  (define expanded (expand-fully reg '(computed-ref)))
  (define binder-name (cadr (cadr expanded)))
  (define body (caddr expanded))
  (check-false (eq? binder-name 'm))
  (check-eq? (car body) '+)
  (check-eq? (cadr body) binder-name))

(test-case "defmacro: typed local hygiene preserves type and constraint metadata"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'typed-local 'defmacro '()
   (list 'quasiquote
         (list 'let (br (list 'shifted 'Int 'positive?) 1)
               (list '+ 'shifted 1))))
  (define expanded (expand-fully reg '(typed-local)))
  (define bindings (cadr expanded))
  (define binder-name (car (cadr bindings)))
  (check-false (eq? binder-name 'shifted))
  (check-eq? (cadr (cadr bindings)) 'Int)
  (check-eq? (caddr (cadr bindings)) 'positive?)
  (check-eq? (cadr (caddr expanded)) binder-name))

(test-case "defmacro: constrained fn hygiene renames binding slot zero only"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'constrained-fn 'defmacro '()
   (list 'quasiquote
         (list 'fn
               (br (list 'item 'Int 'positive?))
               'Int
               'item)))
  (define expanded (expand-fully reg '(constrained-fn)))
  (define parameter (cadr (cadr expanded)))
  (define binder-name (car parameter))
  (check-false (eq? binder-name 'item))
  (check-eq? (cadr parameter) 'Int)
  (check-eq? (caddr parameter) 'positive?)
  (check-eq? (cadddr expanded) binder-name))

(test-case "defmacro: let hygiene starts after its own incoming expression"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-let 'defmacro '()
   (list 'quasiquote
         (list 'let (br 'x 'x) 'x)))
  (define expanded (expand-fully reg '(scoped-let)))
  (define bindings (cadr expanded))
  (define binder-name (cadr bindings))
  (check-false (eq? binder-name 'x))
  (check-eq? (caddr bindings) 'x)
  (check-eq? (caddr expanded) binder-name))

(test-case "defmacro: nested shadowing gives each binder its lexical scope"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'nested-shadow 'defmacro '()
   (list 'quasiquote
         (list 'let (br 'x 1)
               (list 'let (br 'x 'x) 'x)
               'x)))
  (define expanded (expand-fully reg '(nested-shadow)))
  (define outer-name (cadr (cadr expanded)))
  (define inner (caddr expanded))
  (define inner-bindings (cadr inner))
  (define inner-name (cadr inner-bindings))
  (check-false (eq? outer-name 'x))
  (check-false (eq? inner-name 'x))
  (check-false (eq? outer-name inner-name))
  (check-eq? (caddr inner-bindings) outer-name)
  (check-eq? (caddr inner) inner-name)
  (check-eq? (cadddr expanded) outer-name))

(test-case "defmacro: typed parameter metadata stays in pre-binding scope"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-parameter 'defmacro '()
   (list 'quasiquote
         (list 'fn (br (list 'x 'Int 'x)) 'Bool 'x)))
  (define expanded (expand-fully reg '(scoped-parameter)))
  (define parameter (cadr (cadr expanded)))
  (define binder-name (car parameter))
  (check-false (eq? binder-name 'x))
  (check-eq? (cadr parameter) 'Int)
  (check-eq? (caddr parameter) 'x)
  (check-eq? (caddr expanded) 'Bool)
  (check-eq? (cadddr expanded) binder-name))

(test-case "defmacro: lexical binders do not suppress definition-site aliases"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-aliases 'defmacro '()
   (list 'quasiquote
         (list 'fn
               (br (list 'x 'Int 'predicate))
               'Bool
               (list 'helper 'x))))
  (define aliases (make-hasheq))
  (define expanded
    (parameterize ([current-module-def-names
                    (hasheq 'predicate #t 'helper #t)]
                   [current-hygiene-alias-table aliases])
      (expand-fully reg '(scoped-aliases))))
  (define parameter (cadr (cadr expanded)))
  (define binder-name (car parameter))
  (check-eq? (caddr parameter) 'predicate__hyg)
  (check-eq? (car (cadddr expanded)) 'helper__hyg)
  (check-eq? (cadr (cadddr expanded)) binder-name)
  (check-eq? (hash-ref aliases 'predicate) 'predicate__hyg)
  (check-eq? (hash-ref aliases 'helper) 'helper__hyg))

(test-case "defmacro: same-spelling RHS remains a free definition-site reference"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-definition 'defmacro '()
   (list 'quasiquote (list 'let (br 'x 'x) 'x)))
  (define aliases (make-hasheq))
  (define expanded
    (parameterize ([current-module-def-names (hasheq 'x #t)]
                   [current-hygiene-alias-table aliases])
      (expand-fully reg '(scoped-definition))))
  (define binder-name (cadr (cadr expanded)))
  (check-eq? (caddr (cadr expanded)) 'x__hyg)
  (check-eq? (caddr expanded) binder-name)
  (check-eq? (hash-ref aliases 'x) 'x__hyg))

(test-case "imported macro qualification follows lexical declaration scope"
  (define qualified
    (qualify-imported-macro-template
     (list 'quasiquote
           (list 'let (br 'x 'x)
                 (list 'helper 'x)))
     '()
     (hasheq 'x #t 'helper #t)
     'provider))
  (check-equal?
   qualified
   (list 'quasiquote
         (list 'let (br 'x 'provider/x)
               (list 'provider/helper 'x)))))

(test-case "imported macro qualification resolves structural type slots at definition site"
  (define qualified
    (qualify-imported-macro-template
     (list 'quasiquote
           (list 'fn
                 (br (list 'x 'Box))
                 (list 'Result 'Box)
                 'x))
     '()
     (hasheq 'Box #t 'Result #t)
     'provider))
  (check-equal?
   qualified
   (list 'quasiquote
         (list 'fn
               (br (list 'x 'provider/Box))
               (list 'provider/Result 'provider/Box)
               'x))))

(test-case "metadata-wrapped macro definitions freshen their real name and parameters"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'define-helper 'defmacro '(value)
   (list 'quasiquote
         (list 'defn
               (list '#%meta ':private 'helper)
               (br (list 'tmp 'Int))
               'Int
               (list '+ 'tmp (list 'unquote 'value)))))
  (define expanded (expand-fully reg '(define-helper tmp)))
  (define metadata-name (cadr expanded))
  (define generated-name (caddr metadata-name))
  (define generated-param (car (cadr (caddr expanded))))
  (define generated-body (list-ref expanded 4))
  (check-equal? (take metadata-name 2) '(#%meta :private))
  (check-not-eq? generated-name 'helper)
  (check-not-eq? generated-param 'tmp)
  (check-eq? (cadr generated-body) generated-param)
  (check-eq? (caddr generated-body) 'tmp))

(test-case "defmacro: sequential binding forms expose only prior declarations"
  (for ([head (in-list '(loop with-open))])
    (define reg (make-macro-registry))
    (register-macro!
     reg 'scoped-sequence 'defmacro '()
     (list 'quasiquote
           (list head (br 'x 'x 'y 'x) 'y)))
    (define expanded (expand-fully reg '(scoped-sequence)))
    (define bindings (cadr expanded))
    (define x-name (cadr bindings))
    (define y-name (list-ref bindings 3))
    (check-false (eq? x-name 'x))
    (check-false (eq? y-name 'y))
    (check-eq? (caddr bindings) 'x)
    (check-eq? (list-ref bindings 4) x-name)
    (check-eq? (caddr expanded) y-name)))

(test-case "defmacro: dynamic binding names remain existing Var references"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-dynamic 'defmacro '()
   (list 'quasiquote
         (list 'binding
               (br (list '*limit* 'Int '*limit*) '*limit*)
               '*limit*)))
  (define aliases (make-hasheq))
  (define expanded
    (parameterize ([current-module-def-names (hasheq '*limit* #t)]
                   [current-hygiene-alias-table aliases])
      (expand-fully reg '(scoped-dynamic))))
  (define declaration (cadr (cadr expanded)))
  (check-eq? (car declaration) '*limit*)
  (check-eq? (cadr declaration) 'Int)
  (check-eq? (caddr declaration) '*limit*)
  (check-eq? (caddr (cadr expanded)) '*limit*)
  (check-eq? (caddr expanded) '*limit*)
  (check-false (hash-has-key? aliases '*limit*)))

(test-case "defmacro: comprehension and conditional declarations are scoped"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-for 'defmacro '()
   (list 'quasiquote
         (list 'for
               (br (list 'x 'Int 'x)
                   'values
                   ':let (br (list 'y 'Int 'y) 'x)
                   ':when 'y)
               'y)))
  (define expanded-for (expand-fully reg '(scoped-for)))
  (define clauses (cadr expanded-for))
  (define x-declaration (cadr clauses))
  (define x-name (car x-declaration))
  (define y-bindings (list-ref clauses 4))
  (define y-declaration (cadr y-bindings))
  (define y-name (car y-declaration))
  (check-eq? (caddr x-declaration) 'x)
  (check-eq? (caddr y-declaration) 'y)
  (check-eq? (caddr y-bindings) x-name)
  (check-eq? (list-ref clauses 6) y-name)
  (check-eq? (caddr expanded-for) y-name)

  (register-macro!
   reg 'scoped-if 'defmacro '()
   (list 'quasiquote
         (list 'if-let (br (list 'x 'Int 'x) 'x) 'x 'x)))
  (define expanded-if (expand-fully reg '(scoped-if)))
  (define conditional-bindings (cadr expanded-if))
  (define conditional-declaration (cadr conditional-bindings))
  (define conditional-name (car conditional-declaration))
  (check-eq? (caddr conditional-declaration) 'x)
  (check-eq? (caddr conditional-bindings) 'x)
  (check-eq? (caddr expanded-if) conditional-name)
  (check-eq? (cadddr expanded-if) 'x))

(test-case "defmacro: letfn, catch, rescue, and as-> bind only their bodies"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'scoped-letfn 'defmacro '()
   (list 'quasiquote
         (list 'letfn
               (br (list 'left (br (list 'x 'Int 'x)) 'Int
                         (list 'right 'x))
                   (list 'right (br (list 'y 'Int 'y)) 'Int 'y))
               (list 'left 1))))
  (define expanded-letfn (expand-fully reg '(scoped-letfn)))
  (define functions (cdr (cadr expanded-letfn)))
  (define left (car functions))
  (define right (cadr functions))
  (define left-name (car left))
  (define right-name (car right))
  (define left-parameter (cadr (cadr left)))
  (define right-parameter (cadr (cadr right)))
  (check-false (eq? left-name 'left))
  (check-false (eq? right-name 'right))
  (check-eq? (caddr left-parameter) 'x)
  (check-eq? (caddr right-parameter) 'y)
  (check-eq? (car (cadddr left)) right-name)
  (check-eq? (car (caddr expanded-letfn)) left-name)

  (register-macro!
   reg 'scoped-errors 'defmacro '()
   (list 'quasiquote
         (list 'try
               (list 'as-> 'source 'value (list 'use 'value))
               (list 'catch (list 'error 'Exception)
                     (list 'rescue 'fallback 'cause
                           (list 'handle 'error 'cause))))))
  (define expanded-errors (expand-fully reg '(scoped-errors)))
  (define as-form (cadr expanded-errors))
  (define as-name (caddr as-form))
  (define catch-form (caddr expanded-errors))
  (define catch-name (car (cadr catch-form)))
  (define rescue-form (caddr catch-form))
  (define rescue-name (caddr rescue-form))
  (check-eq? (cadr as-form) 'source)
  (check-eq? (cadr (cadddr as-form)) as-name)
  (check-eq? (cadr (cadr catch-form)) 'Exception)
  (check-eq? (cadr rescue-form) 'fallback)
  (check-eq? (cadr (cadddr rescue-form)) catch-name)
  (check-eq? (caddr (cadddr rescue-form)) rescue-name))

(test-case "defmacro: declaration shape is local and flattened metadata is stray"
  (define reg (make-macro-registry))
  (define declaration-name-body
    `(map
      (fn ,(br 'field) Any
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
     "   (fn [i field] Any\n"
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
     "   (fn [i field] Any\n"
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
          (check-equal? (hash-ref details 'error-pos) 443)
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

(define (parse-imported-define-box require-spec invocation)
  (parse-prog/source
   macro-definition-site-fixture-source
   '(define-target js)
   (list 'ns 'test-consumer (list ':require require-spec))
   (list 'defrecord 'Box (br (list 'value 'Int)))
   (list 'defn 'normalize (br (list 'value 'Int)) 'Int 'value)
   invocation))

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
  (check-eq? (call-form-fn ctor-call)
             (string->symbol (format "~a/->Box" expected-prefix)))
  (define helper-call (car (call-form-args ctor-call)))
  (check-true (call-form? helper-call))
  (check-eq? (call-form-fn helper-call)
             (string->symbol (format "~a/normalize" expected-prefix))))

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
