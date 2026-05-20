#lang racket/base

;; JavaScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/set
         "parse.rkt"
         "emit-dispatch.rkt"
         "js-capabilities.rkt")

;; --- security helpers -------------------------------------------------------

(define (escape-js-regex-slash pat)
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i (string-length pat))
       (list->string (reverse acc))]
      [(char=? (string-ref pat i) #\\)
       (if (< (+ i 1) (string-length pat))
         (loop (+ i 2) (cons (string-ref pat (+ i 1)) (cons #\\ acc)))
         (loop (+ i 1) (cons #\\ acc)))]
      [(char=? (string-ref pat i) #\/)
       (loop (+ i 1) (cons #\/ (cons #\\ acc)))]
      [else
       (loop (+ i 1) (cons (string-ref pat i) acc))])))

(define (escape-js-template-string s)
  (regexp-replace* #rx"\\$\\{"
    (regexp-replace* #rx"`" s "\\\\`")
    "\\\\${"))

;; --- identifier mangling ---------------------------------------------------

(define (mangle-name sym)
  (mangle-str (symbol->string sym)))

(define (mangle-str s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace
      (string-replace
       (string-replace
        (string-replace s "_" "__")
        "-" "_")
       "?" "_p")
      "!" "_bang")
     "=" "_eq")
    ">" "_gt")
   "<" "_lt"))

(define (mangle-prop s)
  (string-replace s "-" "_"))

;; --- infix operators -------------------------------------------------------

(define JS-INFIX-OPS
  (hash '+ "+" '- "-" '* "*" '/ "/"
        '< "<" '> ">" '<= "<=" '>= ">="
        '= "===" 'not= "!==" '== "==="
        'mod "%" 'identical? "==="))

(define JS-UNARY-OPS
  (hash 'not "!"))

(define (js-infix? sym) (hash-has-key? JS-INFIX-OPS sym))
(define (js-unary? sym) (hash-has-key? JS-UNARY-OPS sym))

;; --- core function translations --------------------------------------------

(define (emit-core-call fn-sym args)
  (define n (length args))
  (case fn-sym
    [(str) (format "(\"\".concat(~a))"
                   (string-join (map emit-expr args) ", "))]
    [(println) (format "console.log(~a)"
                       (string-join (map emit-expr args) ", "))]
    [(print) (format "process.stdout.write(~a)"
                     (if (= n 1) (emit-expr (car args))
                         (format "\"\".concat(~a)" (string-join (map emit-expr args) ", "))))]
    [(pr prn) (format "console.log(~a)"
                      (string-join (map emit-expr args) ", "))]
    [(nil?) (if (= n 1) (format "(~a == null)" (emit-expr (car args))) #f)]
    [(some?) (if (= n 1) (format "(~a != null)" (emit-expr (car args))) #f)]
    [(true?) (if (= n 1) (format "(~a === true)" (emit-expr (car args))) #f)]
    [(false?) (if (= n 1) (format "(~a === false)" (emit-expr (car args))) #f)]
    [(zero?) (if (= n 1) (format "(~a === 0)" (emit-expr (car args))) #f)]
    [(pos?) (if (= n 1) (format "(~a > 0)" (emit-expr (car args))) #f)]
    [(neg?) (if (= n 1) (format "(~a < 0)" (emit-expr (car args))) #f)]
    [(even?) (if (= n 1) (format "(~a % 2 === 0)" (emit-expr (car args))) #f)]
    [(odd?) (if (= n 1) (format "(~a % 2 !== 0)" (emit-expr (car args))) #f)]
    [(count) (if (= n 1) (format "~a.length" (emit-expr (car args))) #f)]
    [(empty?) (if (= n 1) (format "(~a.length === 0)" (emit-expr (car args))) #f)]
    [(first) (if (= n 1) (format "~a[0]" (emit-expr (car args))) #f)]
    [(second) (if (= n 1) (format "~a[1]" (emit-expr (car args))) #f)]
    [(last) (if (= n 1) (format "~a[~a.length - 1]" (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(rest) (if (= n 1) (format "~a.slice(1)" (emit-expr (car args))) #f)]
    [(nth) (cond
             [(= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
             [(= n 3) (format "(~a[~a] != null ? ~a[~a] : ~a)"
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (caddr args)))]
             [else #f])]
    [(conj) (if (>= n 2)
              (format "[...~a, ~a]"
                      (emit-expr (car args))
                      (string-join (map emit-expr (cdr args)) ", "))
              #f)]
    [(assoc) (if (>= n 3)
              (format "({...~a, ~a})"
                      (emit-expr (car args))
                      (string-join
                       (let loop ([rest (cdr args)] [acc '()])
                         (if (< (length rest) 2)
                           (reverse acc)
                           (loop (cddr rest)
                                 (cons (format "[~a]: ~a" (emit-expr (car rest)) (emit-expr (cadr rest)))
                                       acc))))
                       ", "))
              #f)]
    [(inc) (if (= n 1) (format "(~a + 1)" (emit-expr (car args))) #f)]
    [(dec) (if (= n 1) (format "(~a - 1)" (emit-expr (car args))) #f)]
    [(abs) (if (= n 1) (format "Math.abs(~a)" (emit-expr (car args))) #f)]
    [(max) (format "Math.max(~a)" (string-join (map emit-expr args) ", "))]
    [(min) (format "Math.min(~a)" (string-join (map emit-expr args) ", "))]
    [(rand) (if (= n 0) "Math.random()" #f)]
    [(rand-int) (if (= n 1) (format "Math.floor(Math.random() * ~a)" (emit-expr (car args))) #f)]
    [(vec) (if (= n 1) (format "Array.from(~a)" (emit-expr (car args))) #f)]
    [(set) (if (= n 1) (format "new Set(~a)" (emit-expr (car args))) #f)]
    [(contains?) (if (= n 2) (format "(~a in ~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(keys) (if (= n 1) (format "Object.keys(~a)" (emit-expr (car args))) #f)]
    [(vals) (if (= n 1) (format "Object.values(~a)" (emit-expr (car args))) #f)]
    [(map) (if (= n 2)
            (format "~a.map(~a)" (emit-expr (cadr args)) (emit-expr (car args)))
            #f)]
    [(filter) (if (= n 2)
               (format "~a.filter(~a)" (emit-expr (cadr args)) (emit-expr (car args)))
               #f)]
    [(reduce) (cond
               [(= n 2) (format "~a.reduce(~a)" (emit-expr (cadr args)) (emit-expr (car args)))]
               [(= n 3) (format "~a.reduce(~a, ~a)" (emit-expr (caddr args)) (emit-expr (car args)) (emit-expr (cadr args)))]
               [else #f])]
    [(reverse) (if (= n 1) (format "[...~a].reverse()" (emit-expr (car args))) #f)]
    [(sort) (if (= n 1) (format "[...~a].sort()" (emit-expr (car args))) #f)]
    [(into) (if (= n 2) (format "[...~a, ...~a]" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(concat) (format "[].concat(~a)" (string-join (map emit-expr args) ", "))]
    [(apply) (if (= n 2) (format "~a(...~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(identity) (if (= n 1) (emit-expr (car args)) #f)]
    [(boolean) (if (= n 1) (format "Boolean(~a)" (emit-expr (car args))) #f)]
    [(string?) (if (= n 1) (format "(typeof ~a === 'string')" (emit-expr (car args))) #f)]
    [(number?) (if (= n 1) (format "(typeof ~a === 'number')" (emit-expr (car args))) #f)]
    [(keyword?) (if (= n 1) (format "(typeof ~a === 'string')" (emit-expr (car args))) #f)]
    [(fn?) (if (= n 1) (format "(typeof ~a === 'function')" (emit-expr (car args))) #f)]
    [(and) (if (>= n 1)
              (format "(~a)" (string-join (map emit-expr args) " && "))
              #f)]
    [(or) (if (>= n 1)
             (format "(~a)" (string-join (map emit-expr args) " || "))
             #f)]
    [(throw) (if (= n 1) (format "(() => { throw ~a; })()" (emit-expr (car args))) #f)]
    [(ex-info) (if (= n 2) (format "Object.assign(new Error(~a), {data: ~a})"
                                   (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(ex-message) (if (= n 1) (format "~a.message" (emit-expr (car args))) #f)]
    [(ex-data) (if (= n 1) (format "~a.data" (emit-expr (car args))) #f)]
    [(name) (if (= n 1) (format "String(~a)" (emit-expr (car args))) #f)]
    [(keyword) (if (= n 1) (emit-expr (car args)) #f)]
    [(integer?) (if (= n 1) (format "Number.isInteger(~a)" (emit-expr (car args))) #f)]
    [(subs) (cond
              [(= n 2) (format "~a.substring(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
              [(= n 3) (format "~a.substring(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
              [else #f])]
    [(re-find) (if (= n 2) (format "(~a.match(~a) || [])[0] || null"
                                   (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(atom) (if (= n 1) (format "({value: ~a, watches: {}})" (emit-expr (car args))) #f)]
    [(deref) (if (= n 1) (format "~a.value" (emit-expr (car args))) #f)]
    [(reset!) (if (= n 2)
                (format "(() => { const _a = ~a, _v = ~a; const _old = _a.value; _a.value = _v; for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _v); return _v; })()"
                        (emit-expr (car args)) (emit-expr (cadr args)))
                #f)]
    [(swap!) (if (>= n 2)
               (format "(() => { const _a = ~a; const _old = _a.value; _a.value = (~a)(_old~a); for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _a.value); return _a.value; })()"
                       (emit-expr (car args))
                       (emit-expr (cadr args))
                       (if (> n 2) (string-append ", " (string-join (map emit-expr (cddr args)) ", ")) ""))
               #f)]
    [(add-watch) (if (= n 3)
                   (format "(~a.watches[~a] = ~a, ~a)"
                           (emit-expr (car args))
                           (emit-expr (cadr args))
                           (emit-expr (caddr args))
                           (emit-expr (car args)))
                   #f)]
    [(remove-watch) (if (= n 2)
                      (format "(delete ~a.watches[~a], ~a)"
                              (emit-expr (car args))
                              (emit-expr (cadr args))
                              (emit-expr (car args)))
                      #f)]
    ;; --- collection / sequence -------------------------------------------------
    [(mapv) (if (= n 2) (format "~a.map(~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(filterv) (if (= n 2) (format "~a.filter(~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(get) (cond
             [(= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
             [(= n 3) (format "(~a[~a] != null ? ~a[~a] : ~a)"
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (caddr args)))]
             [else #f])]
    [(update) (if (= n 3)
               (format "({...~a, [~a]: ~a(~a[~a])})"
                       (emit-expr (car args))
                       (emit-expr (cadr args))
                       (emit-expr (caddr args))
                       (emit-expr (car args))
                       (emit-expr (cadr args)))
               #f)]
    [(merge) (if (>= n 1)
              (format "Object.assign({}, ~a)" (string-join (map emit-expr args) ", "))
              #f)]
    [(dissoc) (if (= n 2)
               (format "(() => { const _r = {...~a}; delete _r[~a]; return _r; })()"
                       (emit-expr (car args)) (emit-expr (cadr args)))
               #f)]
    [(subvec) (cond
                [(= n 2) (format "~a.slice(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
                [(= n 3) (format "~a.slice(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
                [else #f])]
    [(pop) (if (= n 1) (format "~a.slice(0, -1)" (emit-expr (car args))) #f)]
    [(peek) (if (= n 1) (format "~a[~a.length - 1]" (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(take) (if (= n 2) (format "~a.slice(0, ~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(drop) (if (= n 2) (format "~a.slice(~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(some) (if (= n 2)
             (format "~a.find(~a) ?? null" (emit-expr (cadr args)) (emit-expr (car args)))
             #f)]
    [(distinct) (if (= n 1) (format "[...new Set(~a)]" (emit-expr (car args))) #f)]
    [(flatten) (if (= n 1) (format "~a.flat(Infinity)" (emit-expr (car args))) #f)]
    [(not-empty) (if (= n 1) (format "(~a.length > 0 ? ~a : null)" (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(sort-by) (if (= n 2)
                (format "[...~a].sort((a, b) => { const ka = ~a(a), kb = ~a(b); return ka < kb ? -1 : ka > kb ? 1 : 0; })"
                        (emit-expr (cadr args)) (emit-expr (car args)) (emit-expr (car args)))
                #f)]
    [(partition) (if (= n 2)
                  (format "(() => { const _c = ~a, _n = ~a, _r = []; for (let i = 0; i < _c.length; i += _n) _r.push(_c.slice(i, i + _n)); return _r; })()"
                          (emit-expr (cadr args)) (emit-expr (car args)))
                  #f)]
    [(interleave) (if (= n 2)
                   (format "(() => { const _a = ~a, _b = ~a, _r = []; for (let i = 0; i < Math.min(_a.length, _b.length); i++) { _r.push(_a[i], _b[i]); } return _r; })()"
                           (emit-expr (car args)) (emit-expr (cadr args)))
                   #f)]
    [(frequencies) (if (= n 1)
                    (format "~a.reduce((m, x) => (m[x] = (m[x] || 0) + 1, m), {})"
                            (emit-expr (car args)))
                    #f)]
    [(group-by) (if (= n 2)
                 (format "~a.reduce((m, x) => { const k = ~a(x); (m[k] = m[k] || []).push(x); return m; }, {})"
                         (emit-expr (cadr args)) (emit-expr (car args)))
                 #f)]
    ;; --- function combinators --------------------------------------------------
    [(comp) (if (= n 2) (format "((x) => ~a(~a(x)))" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(partial) (if (>= n 2)
                (format "((..._rest) => ~a(~a, ..._rest))"
                        (emit-expr (car args))
                        (string-join (map emit-expr (cdr args)) ", "))
                #f)]
    [(constantly) (if (= n 1) (format "(() => ~a)" (emit-expr (car args))) #f)]
    [(complement) (if (= n 1) (format "((..._args) => !~a(..._args))" (emit-expr (car args))) #f)]
    [(juxt) (if (>= n 1)
             (format "((..._args) => [~a])"
                     (string-join (map (lambda (a) (format "~a(..._args)" (emit-expr a))) args) ", "))
             #f)]
    ;; --- type predicates -------------------------------------------------------
    [(vector?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(map?) (if (= n 1) (format "(typeof ~a === 'object' && ~a !== null && !Array.isArray(~a))"
                                (emit-expr (car args)) (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(set?) (if (= n 1) (format "(~a instanceof Set)" (emit-expr (car args))) #f)]
    [(sequential?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(seq?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(coll?) (if (= n 1) (format "(Array.isArray(~a) || (typeof ~a === 'object' && ~a !== null))"
                                 (emit-expr (car args)) (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(take-last) (if (= n 2) (format "~a.slice(-~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(drop-last) (cond
                   [(= n 1) (format "~a.slice(0, -1)" (emit-expr (car args)))]
                   [(= n 2) (format "~a.slice(0, -~a)" (emit-expr (cadr args)) (emit-expr (car args)))]
                   [else #f])]
    [(pr-str) (if (>= n 1)
                (format "[~a].map(x => JSON.stringify(x)).join(' ')"
                        (string-join (map emit-expr args) ", "))
                #f)]
    [(to-array) (if (= n 1) (format "Array.from(~a)" (emit-expr (car args))) #f)]
    [(aget) (if (= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(aset) (if (= n 3) (format "(~a[~a] = ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args))) #f)]
    [(array-seq) (if (= n 1) (format "Array.from(~a)" (emit-expr (car args))) #f)]
    [(clj->js) (if (= n 1) (emit-expr (car args)) #f)]
    [(js->clj) (if (= n 1) (emit-expr (car args)) #f)]
    [(not=) (if (= n 2) (format "(~a !== ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(seq) (if (= n 1) (format "(~a.length > 0 ? ~a : null)" (emit-expr (car args)) (emit-expr (car args))) #f)]
    ;; --- runtime helpers (beagle/core.js) -------------------------------------
    [(range) (begin (use-runtime!) (format "$$bc.range(~a)" (string-join (map emit-expr args) ", ")))]
    [(remove) (if (= n 2) (begin (use-runtime!) (format "$$bc.remove(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(mapcat) (if (= n 2) (begin (use-runtime!) (format "$$bc.mapcat(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(every?) (if (= n 2) (begin (use-runtime!) (format "$$bc.every_p(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(keep) (if (= n 2) (begin (use-runtime!) (format "$$bc.keep(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(map-indexed) (if (= n 2) (begin (use-runtime!) (format "$$bc.map_indexed(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(assoc-in) (if (= n 3) (begin (use-runtime!) (format "$$bc.assoc_in(~a, ~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))) #f)]
    [(update-in) (if (= n 3) (begin (use-runtime!) (format "$$bc.update_in(~a, ~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))) #f)]
    [(select-keys) (if (= n 2) (begin (use-runtime!) (format "$$bc.select_keys(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(merge-with) (if (>= n 2) (begin (use-runtime!) (format "$$bc.merge_with(~a)" (string-join (map emit-expr args) ", "))) #f)]
    [(take-while) (if (= n 2) (begin (use-runtime!) (format "$$bc.take_while(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [(drop-while) (if (= n 2) (begin (use-runtime!) (format "$$bc.drop_while(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))) #f)]
    [else #f]))

;; --- async detection -------------------------------------------------------

(define (contains-await? exprs)
  (for/or ([e (in-list exprs)])
    (expr-has-await? e)))

(define (expr-has-await? e)
  (cond
    [(await-form? e) #t]
    [(call-form? e) (contains-await? (call-form-args e))]
    [(if-form? e) (or (expr-has-await? (if-form-cond-expr e))
                      (expr-has-await? (if-form-then-expr e))
                      (expr-has-await? (if-form-else-expr e)))]
    [(let-form? e) (or (for/or ([b (let-form-bindings e)])
                         (expr-has-await? (let-binding-value b)))
                       (contains-await? (let-form-body e)))]
    [(letfn-form? e) (or (for/or ([f (letfn-form-fns e)])
                            (contains-await? (letfn-fn-body f)))
                         (contains-await? (letfn-form-body e)))]
    [(do-form? e) (contains-await? (do-form-body e))]
    [(cond-form? e) (for/or ([c (cond-form-clauses e)])
                      (or (and (not (symbol? (cond-clause-test c)))
                               (expr-has-await? (cond-clause-test c)))
                          (contains-await? (cond-clause-body c))))]
    [(try-form? e) (or (contains-await? (try-form-body e))
                       (for/or ([c (try-form-catches e)])
                         (contains-await? (catch-clause-body c))))]
    [(match-form? e) (or (expr-has-await? (match-form-target e))
                         (for/or ([c (match-form-clauses e)])
                           (contains-await? (match-clause-body c))))]
    [(when-form? e) (or (expr-has-await? (when-form-cond-expr e))
                        (contains-await? (when-form-body e)))]
    [(for-form? e) (contains-await? (for-form-body e))]
    [(with-form? e) (expr-has-await? (with-form-target e))]
    [(kw-access? e) (expr-has-await? (kw-access-target e))]
    [(set!-form? e) (or (expr-has-await? (set!-form-target e))
                        (expr-has-await? (set!-form-value e)))]
    [(check-expr? e) (expr-has-await? (check-expr-expr e))]
    [(rescue-form? e) (or (expr-has-await? (rescue-form-expr e))
                          (expr-has-await? (rescue-form-fallback e)))]
    [(target-case-form? e)
     (for/or ([(k v) (in-hash (target-case-form-cases e))])
       (expr-has-await? v))]
    [else #f]))

;; --- IIFE helper -----------------------------------------------------------

(define (iife body-str #:async? [async? #f])
  (if async?
    (format "(async () => { ~a })()" body-str)
    (format "(() => { ~a })()" body-str)))

;; --- context tracking ------------------------------------------------------

(define current-js-context (make-parameter 'stmt))
(define current-js-record-fields (make-parameter (hasheq)))
(define current-js-record-ns (make-parameter (hasheq)))
(define current-js-scalar-fns (make-parameter (set)))
(define current-js-symbol-ns (make-parameter (hasheq)))

;; --- runtime import tracking -----------------------------------------------

(define needs-runtime? (make-parameter #f))

(define (use-runtime!)
  (needs-runtime? #t))

;; --- binding environment (for value-position wrapper resolution) -----------

(define current-js-bound (make-parameter (set)))

(define (js-bound? sym)
  (set-member? (current-js-bound) sym))

(define (with-bindings syms thunk)
  (parameterize ([current-js-bound (set-union (current-js-bound) (list->set syms))])
    (thunk)))

(define (names-from-binding-target name)
  (cond
    [(symbol? name) (list name)]
    [(map-destructure? name)
     (append (map-destructure-keys name)
             (if (map-destructure-as-name name)
               (list (map-destructure-as-name name))
               '()))]
    [(seq-destructure? name)
     (append (seq-destructure-names name)
             (if (seq-destructure-rest-name name)
               (list (seq-destructure-rest-name name))
               '()))]
    [else '()]))

(define (binding-names-from-params params [rest-param #f])
  (append
   (apply append (map (lambda (p)
     (if (param? p) (list (param-name p)) (names-from-binding-target p)))
     params))
   (if rest-param (list (param-name rest-param)) '())))

;; --- entry point -----------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
      (cond
        [(record-form? f)
         (hash-set h (record-form-name f)
                     (map (lambda (p) (symbol->string (param-name p)))
                          (record-form-fields f)))]
        [(and (defunion-form? f) (defunion-form-member-fields f))
         (for/fold ([h2 h]) ([m (in-list (defunion-form-members f))])
           (define fields (hash-ref (defunion-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [(deferror-form? f)
         (for/fold ([h2 h]) ([m (in-list (deferror-form-members f))])
           (define fields (hash-ref (deferror-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [else h])))
  (for/fold ([h local]) ([(rec-name field-names) (in-hash (program-imported-record-field-order prog))])
    (hash-set h rec-name field-names)))

(define (build-scalar-fns prog)
  (define predicated
    (for/fold ([h (hash)]) ([f (in-list (program-forms prog))])
      (if (and (defscalar-form? f) (not (null? (defscalar-form-predicates f))))
          (hash-set h (defscalar-form-name f) #t)
          h)))
  (define local
    (for/fold ([s (set)]) ([f (in-list (program-forms prog))])
      (if (defscalar-form? f)
          (let* ([name (defscalar-form-name f)]
                 [name-str (symbol->string name)]
                 [name-lower (string-downcase name-str)]
                 [ctor (string->symbol (string-append "->" name-str))]
                 [accessor (string->symbol (string-append name-lower "-value"))])
            (if (hash-has-key? predicated name)
                (set-add s accessor)
                (set-add (set-add s ctor) accessor)))
          s)))
  (for/fold ([s local]) ([sym (in-list (program-imported-scalar-fns prog))])
    (set-add s sym)))

(define (validate-js-target! prog)
  (unless (null? (program-imports prog))
    (error 'beagle-js "Java imports are not supported for JS target: ~a"
           (program-imports prog))))

(define (collect-top-level-names prog)
  (define from-forms
    (for/fold ([s (set)]) ([f (in-list (program-forms prog))])
      (cond
        [(def-form? f)      (set-add s (def-form-name f))]
        [(defonce-form? f)  (set-add s (defonce-form-name f))]
        [(defn-form? f)     (set-add s (defn-form-name f))]
        [(defn-multi? f)    (set-add s (defn-multi-name f))]
        [(record-form? f)   (set-add s (record-form-name f))]
        [(defenum-form? f)  (set-add s (defenum-form-name f))]
        [(defunion-form? f) (set-add s (defunion-form-name f))]
        [(deferror-form? f) (set-add s (deferror-form-name f))]
        [(defscalar-form? f)(set-add s (defscalar-form-name f))]
        [else s])))
  (define from-externs (list->set (hash-keys (program-externs prog))))
  (define from-refers
    (for/fold ([s (set)]) ([r (in-list (program-requires prog))])
      (define refer (require-entry-refer r))
      (if refer (set-union s (list->set refer)) s)))
  (set-union from-forms from-externs from-refers))

(define (js-emit-program prog)
  (validate-js-target! prog)
  (parameterize ([current-js-context 'stmt]
                 [current-js-record-fields (build-record-field-table prog)]
                 [current-js-record-ns (program-imported-record-ns prog)]
                 [current-js-scalar-fns (build-scalar-fns prog)]
                 [current-js-symbol-ns (program-imported-symbol-ns prog)]
                 [needs-runtime? #f]
                 [current-js-bound (collect-top-level-names prog)])
    (define header (emit-module-header prog))
    (define body
      (string-join
       (for/list ([form (in-list (program-forms prog))])
         (emit-form form))
       "\n\n"))
    (define runtime-import
      (if (needs-runtime?)
        "import * as $$bc from 'beagle/core.js';\n"
        ""))
    (string-append header runtime-import "\n" body "\n")))

;; --- module header ---------------------------------------------------------

(define (emit-module-header prog)
  (define rs (program-requires prog))
  (if (null? rs)
    ""
    (string-append
     (string-join
      (for/list ([r (in-list rs)])
        (define ns-str (symbol->string (require-entry-ns r)))
        (define refer (require-entry-refer r))
        (define module-path
          (if (or (string-prefix? ns-str "@")
                  (not (string-contains? ns-str ".")))
            ns-str
            (string-append "./" (string-replace ns-str "." "/") ".js")))
        (if refer
          (format "import { ~a } from '~a';"
                  (string-join (map (lambda (s) (mangle-str (symbol->string s))) refer) ", ")
                  module-path)
          (let ([alias (or (require-entry-alias r)
                           (let ([parts (string-split ns-str ".")])
                             (string->symbol (last parts))))])
            (format "import * as ~a from '~a';"
                    (mangle-name alias)
                    module-path))))
      "\n")
     "\n")))

;; --- top-level forms -------------------------------------------------------

(define (emit-form f)
  (cond
    [(def-form? f)
     (format "const ~a = ~a;"
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "const ~a = ~a;"
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define params (emit-js-params (defn-form-params f) (defn-form-rest-param f)))
     (define async? (contains-await? (defn-form-body f)))
     (define bound (binding-names-from-params (defn-form-params f) (defn-form-rest-param f)))
     (format "~afunction ~a(~a) {\n  ~a\n}"
             (if async? "async " "")
             (mangle-name (defn-form-name f))
             params
             (with-bindings bound (lambda () (emit-body-return (defn-form-body f) "  "))))]

    [(defn-multi? f)
     (define name (mangle-name (defn-multi-name f)))
     (define arities (defn-multi-arities f))
     (define async? (for/or ([a (in-list arities)])
                      (contains-await? (arity-clause-body a))))
     (define branches
       (for/list ([a (in-list arities)])
         (define n (length (arity-clause-params a)))
         (define rest? (arity-clause-rest-param a))
         (define destructure-strs
           (for/list ([p (in-list (arity-clause-params a))]
                      [i (in-naturals)])
             (format "const ~a = _args[~a];" (emit-js-param p) i)))
         (define rest-str
           (if rest?
             (list (format "const ~a = _args.slice(~a);" (emit-js-param rest?) n))
             '()))
         (define all-bindings (append destructure-strs rest-str))
         (define arity-bound (binding-names-from-params (arity-clause-params a) (arity-clause-rest-param a)))
         (define body (with-bindings arity-bound (lambda () (emit-body-return (arity-clause-body a) "    "))))
         (define bindings-str (string-join all-bindings "\n    "))
         (define inner (if (null? all-bindings) body (format "~a\n    ~a" bindings-str body)))
         (if rest?
           (format "  if (arguments.length >= ~a) {\n    ~a\n  }" n inner)
           (format "  if (arguments.length === ~a) {\n    ~a\n  }" n inner))))
     (format "~afunction ~a(..._args) {\n~a\n  throw new Error('No matching arity: ' + _args.length);\n}"
             (if async? "async " "")
             name (string-join branches "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(defenum-form? f)
     (define name (mangle-name (defenum-form-name f)))
     (define vals (defenum-form-values f))
     (define val-strs (map (lambda (v) (format "~v" (symbol->string v))) vals))
     (format "const ~a_values = new Set([~a]);" name (string-join val-strs ", "))]

    [(defunion-form? f)
     (define comment
       (format "// ~a = ~a"
               (mangle-name (defunion-form-name f))
               (string-join (map (compose mangle-str symbol->string)
                                (defunion-form-members f)) " | ")))
     (define member-fields (defunion-form-member-fields f))
     (if (not member-fields)
       comment
       (string-append comment "\n"
         (string-join
           (for/list ([m (in-list (defunion-form-members f))])
             (define fields (hash-ref member-fields m))
             (define m-str (mangle-str (symbol->string m)))
             (define field-names (map (compose mangle-str symbol->string param-name) fields))
             (format "function ~a(~a) { return Object.freeze({ _tag: ~v~a }); }"
                     m-str
                     (string-join field-names ", ")
                     (symbol->string m)
                     (if (null? field-names) ""
                       (string-append ", "
                         (string-join
                           (map (lambda (n) (format "~a: ~a" n n)) field-names)
                           ", ")))))
           "\n")))]

    [(deferror-form? f)
     (define name (mangle-str (symbol->string (deferror-form-name f))))
     (define members (deferror-form-members f))
     (define mf (deferror-form-member-fields f))
     (define comment (format "// error ~a = ~a" name
                             (string-join (map (compose mangle-str symbol->string) members) " | ")))
     (string-append comment "\n"
       (string-join
         (for/list ([m (in-list members)])
           (define fields (hash-ref mf m '()))
           (define m-str (mangle-str (symbol->string m)))
           (define field-names (map (compose mangle-str symbol->string param-name) fields))
           (format "function ~a(~a) { return Object.freeze({ _tag: ~v~a }); }"
                   m-str
                   (string-join field-names ", ")
                   (symbol->string m)
                   (if (null? field-names) ""
                     (string-append ", "
                       (string-join
                         (map (lambda (n) (format "~a: ~a" n n)) field-names)
                         ", ")))))
         "\n"))]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [(protocol-form? f)
     (error 'beagle-js "protocol-form is not supported for JS target")]
    [(defmulti-form? f)
     (error 'beagle-js "defmulti is not supported for JS target")]
    [(defmethod-form? f)
     (error 'beagle-js "defmethod is not supported for JS target")]
    [(deftype-form? f)
     (error 'beagle-js "deftype is not supported for JS target")]
    [(extend-type-form? f)
     (error 'beagle-js "extend-type is not supported for JS target")]

    [(js-quote-form? f)
     (emit-js-ast-node (js-quote-form-body f) 0)]

    [else (emit-expr-stmt f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
  (parameterize ([current-js-context 'expr])
    (emit-expr-core e)))

(define (emit-expr-stmt e)
  (define s (emit-expr-core e))
  (if (string-suffix? s ";") s (string-append s ";")))

(define (emit-expr-core e)
  (cond
    [(block-string? e)  (emit-js-block-string (block-string-text e))]
    [(string? e)        (~v e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (number->string e)]
    [(symbol? e)
     (cond
       [(eq? e 'nil) "null"]
       [(char=? (string-ref (symbol->string e) 0) #\:)
        (~v (mangle-str (substring (symbol->string e) 1)))]
       [(js-bound? e) (mangle-name e)]
       [(hash-ref JS-VALUE-WRAPPERS e #f) => values]
       [else
        (let ([m (mangle-name e)])
          (cond
            [(and (string-contains? m "/")
                  (string-prefix? (symbol->string e) "js/"))
             (mangle-str (substring (symbol->string e) 3))]
            [(string-contains? m "/")
             (string-replace m "/" ".")]
            [else m]))])]
    [(quoted? e)        (emit-quoted (quoted-datum e))]
    [(regex-lit? e)
     (define pat (escape-js-regex-slash (regex-lit-pattern e)))
     (format "/~a/" pat)]

    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) ", "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p)
                     (define k (car p))
                     (define v (cdr p))
                     (define key-str
                       (cond
                         [(and (symbol? k) (char=? (string-ref (symbol->string k) 0) #\:))
                          (mangle-str (substring (symbol->string k) 1))]
                         [else (format "[~a]" (emit-expr k))]))
                     (format "~a: ~a" key-str (emit-expr v)))
                   (map-form-pairs e))
              ", "))]
    [(set-form? e)
     (format "new Set([~a])"
             (string-join (map emit-expr (set-form-items e)) ", "))]

    [(with-meta? e)     (emit-expr (with-meta-expr e))]
    [(unsafe-expr? e)   (emit-expr (unsafe-expr-inner e))]
    [(unsafe-clj? e)    (error 'beagle-js "unsafe Clojure strings are not supported for JS target")]

    [(js-quote-form? e)
     (emit-js-ast-node (js-quote-form-body e) 0)]

    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(~a ? ~a : ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(~a ? ~a : null)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]

    [(when-form? e)
     (define async? (or (expr-has-await? (when-form-cond-expr e))
                        (contains-await? (when-form-body e))))
     (iife (format "if (~a) { ~a }"
                    (emit-expr (when-form-cond-expr e))
                    (emit-body-return (when-form-body e) ""))
           #:async? async?)]

    [(when-let-form? e)
     (define val-str (emit-expr (when-let-form-expr e)))
     (define name (mangle-name (when-let-form-name e)))
     (define async? (or (expr-has-await? (when-let-form-expr e))
                        (contains-await? (when-let-form-body e))))
     (with-bindings (list (when-let-form-name e))
       (lambda ()
         (iife (format "const ~a = ~a; if (~a != null) { ~a }"
                        name val-str name
                        (emit-body-return (when-let-form-body e) ""))
               #:async? async?)))]

    [(if-let-form? e)
     (define val-str (emit-expr (if-let-form-expr e)))
     (define name (mangle-name (if-let-form-name e)))
     (define async? (or (expr-has-await? (if-let-form-expr e))
                        (expr-has-await? (if-let-form-then-body e))
                        (and (if-let-form-else-body e)
                             (expr-has-await? (if-let-form-else-body e)))))
     (with-bindings (list (if-let-form-name e))
       (lambda ()
         (define then-str (emit-expr (if-let-form-then-body e)))
         (define else-str (if (if-let-form-else-body e)
                             (emit-expr (if-let-form-else-body e))
                             "null"))
         (iife (format "const ~a = ~a; if (~a != null) { return ~a; } else { return ~a; }"
                        name val-str name then-str else-str)
               #:async? async?)))]

    [(when-some-form? e)
     (define val-str (emit-expr (when-some-form-expr e)))
     (define name (mangle-name (when-some-form-name e)))
     (define async? (or (expr-has-await? (when-some-form-expr e))
                        (contains-await? (when-some-form-body e))))
     (with-bindings (list (when-some-form-name e))
       (lambda ()
         (iife (format "const ~a = ~a; if (~a != null) { ~a }"
                        name val-str name
                        (emit-body-return (when-some-form-body e) ""))
               #:async? async?)))]

    [(if-some-form? e)
     (define val-str (emit-expr (if-some-form-expr e)))
     (define name (mangle-name (if-some-form-name e)))
     (define async? (or (expr-has-await? (if-some-form-expr e))
                        (expr-has-await? (if-some-form-then-body e))
                        (expr-has-await? (if-some-form-else-body e))))
     (with-bindings (list (if-some-form-name e))
       (lambda ()
         (define then-str (emit-expr (if-some-form-then-body e)))
         (define else-str (emit-expr (if-some-form-else-body e)))
         (iife (format "const ~a = ~a; if (~a != null) { return ~a; } else { return ~a; }"
                        name val-str name then-str else-str)
               #:async? async?)))]

    [(do-form? e)
     (iife (emit-body-return (do-form-body e) "")
           #:async? (contains-await? (do-form-body e)))]

    [(cond-form? e)
     (define clauses (cond-form-clauses e))
     (define parts
       (for/list ([c (in-list clauses)])
         (define test (cond-clause-test c))
         (define body (cond-clause-body c))
         (define body-str (if (= (length body) 1) (emit-expr (car body)) (emit-body-return body "")))
         (cond
           [(and (symbol? test) (eq? test ':else))
            (format "~a" body-str)]
           [else
            (format "(~a) ? ~a" (emit-expr test) body-str)])))
     (string-join parts " : ")]

    [(let-form? e)
     (define bindings (let-form-bindings e))
     (define body (let-form-body e))
     (define has-await (or (for/or ([b (in-list bindings)])
                             (expr-has-await? (let-binding-value b)))
                           (contains-await? body)))
     (define let-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define-values (bind-strs _ignored)
       (for/fold ([strs '()]
                  [bound (current-js-bound)])
                 ([b (in-list bindings)])
         (define s (parameterize ([current-js-bound bound])
                     (format "const ~a = ~a;"
                             (emit-binding-target (let-binding-name b))
                             (emit-expr (let-binding-value b)))))
         (define new-names (names-from-binding-target (let-binding-name b)))
         (values (append strs (list s))
                 (set-union bound (list->set new-names)))))
     (with-bindings let-names
       (lambda ()
         (iife (format "~a ~a" (string-join bind-strs " ") (emit-body-return body ""))
                #:async? has-await)))]

    [(loop-form? e)
     (define bindings (loop-form-bindings e))
     (define body (loop-form-body e))
     (define loop-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define bind-names
       (for/list ([b (in-list bindings)])
         (emit-binding-target (let-binding-name b))))
     (define bind-strs
       (for/list ([b (in-list bindings)])
         (format "let ~a = ~a;"
                 (emit-binding-target (let-binding-name b))
                 (emit-expr (let-binding-value b)))))
     (with-bindings loop-names
       (lambda ()
         (define body-str
           (string-join (map (lambda (e) (emit-loop-stmt e bind-names)) body) "\n    "))
         (format "(() => { ~a while (true) {\n    ~a\n  } })()"
                 (string-join bind-strs " ")
                 body-str)))]

    [(recur-form? e)
     (define assignments
       (for/list ([a (in-list (recur-form-args e))]
                  [i (in-naturals)])
         (format "_recur_~a = ~a" i (emit-expr a))))
     (string-append (string-join assignments "; ") "; continue")]

    [(for-form? e)
     (emit-for e)]

    [(fn-form? e)
     (define params (emit-js-params (fn-form-params e) (fn-form-rest-param e)))
     (define body (fn-form-body e))
     (define async? (contains-await? body))
     (define prefix (if async? "async " ""))
     (define bound (binding-names-from-params (fn-form-params e) (fn-form-rest-param e)))
     (with-bindings bound
       (lambda ()
         (if (= (length body) 1)
           (format "~a(~a) => ~a" prefix params (emit-expr (car body)))
           (format "~a(~a) => { ~a }" prefix params (emit-body-return body "")))))]

    [(letfn-form? e)
     (define fns (letfn-form-fns e))
     (define body (letfn-form-body e))
     (define fn-names (map letfn-fn-name fns))
     (define has-await (or (for/or ([f (in-list fns)])
                             (contains-await? (letfn-fn-body f)))
                           (contains-await? body)))
     (with-bindings fn-names
       (lambda ()
         (define fn-strs
           (for/list ([f (in-list fns)])
             (define name (mangle-name (letfn-fn-name f)))
             (define params (emit-js-params (letfn-fn-params f) (letfn-fn-rest-param f)))
             (define fn-body (letfn-fn-body f))
             (define fn-async? (contains-await? fn-body))
             (define prefix (if fn-async? "async " ""))
             (define fn-bound (binding-names-from-params (letfn-fn-params f) (letfn-fn-rest-param f)))
             (with-bindings fn-bound
               (lambda ()
                 (format "~afunction ~a(~a) { ~a }"
                         prefix name params (emit-body-return fn-body ""))))))
         (iife (format "~a ~a" (string-join fn-strs " ") (emit-body-return body ""))
                #:async? has-await)))]

    [(method-call? e)
     (define method-str (symbol->string (method-call-method-name e)))
     (if (and (> (string-length method-str) 2)
              (string=? (substring method-str 0 2) ".-"))
       (format "~a.~a"
               (emit-expr (method-call-target e))
               (mangle-prop (substring method-str 2)))
       (format "~a.~a(~a)"
               (emit-expr (method-call-target e))
               (mangle-prop (substring method-str 1))
               (string-join (map emit-expr (method-call-args e)) ", ")))]

    [(static-call? e)
     (define s (symbol->string (static-call-class+method e)))
     (define slash-pos (let loop ([i 0])
                         (cond [(= i (string-length s)) #f]
                               [(char=? (string-ref s i) #\/) i]
                               [else (loop (+ i 1))])))
     (define dotted
       (cond
         [(and slash-pos (string=? (substring s 0 slash-pos) "js"))
          (substring s (+ slash-pos 1))]
         [(and slash-pos
               (> (string-length s) (+ slash-pos 3))
               (string=? (substring s (+ slash-pos 1) (+ slash-pos 3)) "->"))
          (string-append (substring s 0 slash-pos) "." (substring s (+ slash-pos 3)))]
         [else (string-replace s "/" ".")]))
     (format "~a(~a)" (mangle-str dotted)
             (string-join (map emit-expr (static-call-args e)) ", "))]

    [(dynamic-var? e)
     (mangle-name (dynamic-var-name e))]

    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (iife (format "const r = ~a;\nif (r && r.__tag === \"Ok\") return r.value;\nthrow new Error(\"check failed: \" + JSON.stringify(r));"
                   inner))]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define fallback (emit-expr (rescue-form-fallback e)))
     (define err-name (if (rescue-form-err-name e)
                          (mangle-name (rescue-form-err-name e))
                          "_err"))
     (iife (format "const r = ~a;\nif (r && r.__tag === \"Ok\") return r.value;\nconst ~a = r;\nreturn ~a;"
                   inner err-name fallback))]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases 'js #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target js"))
     (emit-expr branch)]
    [(try-form? e)
     (define body-str (emit-body-return (try-form-body e) "  "))
     (define catch-strs
       (for/list ([c (try-form-catches e)])
         (with-bindings (list (catch-clause-name c))
           (lambda ()
             (format "catch (~a) {\n    ~a\n  }"
                     (mangle-name (catch-clause-name c))
                     (emit-body-return (catch-clause-body c) "    "))))))
     (define finally-str
       (if (try-form-finally-body e)
         (format " finally {\n    ~a\n  }"
                 (emit-body-stmts (try-form-finally-body e) "    "))
         ""))
     (define has-await (or (contains-await? (try-form-body e))
                            (for/or ([c (try-form-catches e)])
                              (contains-await? (catch-clause-body c)))))
     (iife (format "try {\n    ~a\n  } ~a~a" body-str (string-join catch-strs " ") finally-str)
           #:async? has-await)]

    [(doseq-form? e)
     (emit-doseq e)]

    [(dotimes-form? e)
     (define name (mangle-name (dotimes-form-name e)))
     (define count-str (emit-expr (dotimes-form-count-expr e)))
     (with-bindings (list (dotimes-form-name e))
       (lambda ()
         (define body-str (emit-body-stmts (dotimes-form-body e) "  "))
         (iife (format "for (let ~a = 0; ~a < ~a; ~a++) {\n  ~a\n}"
                       name name count-str name body-str))))]

    [(condp-form? e)
     (define pred (emit-expr (condp-form-pred-fn e)))
     (define test-val (emit-expr (condp-form-test-expr e)))
     (define clause-strs
       (for/list ([c (condp-form-clauses e)])
         (format "~a(~a, ~a) ? ~a"
                 pred (emit-expr (car c)) test-val (emit-expr (cdr c)))))
     (define default-str
       (if (condp-form-default e) (emit-expr (condp-form-default e)) "null"))
     (string-append (string-join clause-strs " : ") " : " default-str)]

    [(case-form? e)
     (define test-str (emit-expr (case-form-test e)))
     (define clauses (case-form-clauses e))
     (define parts
       (for/list ([c (in-list clauses)])
         (format "(~a === ~a) ? ~a"
                 test-str
                 (emit-expr (case-clause-value c))
                 (emit-expr (case-clause-body c)))))
     (define default-str
       (if (case-form-default e) (emit-expr (case-form-default e)) "null"))
     (string-append (string-join parts " : ") " : " default-str)]

    [(new-form? e)
     (define raw (symbol->string (new-form-class-name e)))
     (define cls (if (string-suffix? raw ".") (substring raw 0 (sub1 (string-length raw))) raw))
     (format "new ~a(~a)"
             (mangle-str cls)
             (string-join (map emit-expr (new-form-args e)) ", "))]

    [(kw-access? e)
     (define key (symbol->string (kw-access-kw e)))
     (define prop (mangle-str (substring key 1)))
     (if (kw-access-default e)
       (format "(~a.~a != null ? ~a.~a : ~a)"
               (emit-expr (kw-access-target e)) prop
               (emit-expr (kw-access-target e)) prop
               (emit-expr (kw-access-default e)))
       (format "~a.~a" (emit-expr (kw-access-target e)) prop))]

    [(match-form? e)
     (emit-match e)]

    [(with-form? e)
     (emit-with e)]

    [(await-form? e)
     (format "await ~a" (emit-expr (await-form-expr e)))]

    [(set!-form? e)
     (define target (set!-form-target e))
     (define val (emit-expr (set!-form-value e)))
     (cond
       [(method-call? target)
        (define method-str (symbol->string (method-call-method-name target)))
        (define prop
          (if (and (> (string-length method-str) 2)
                   (string=? (substring method-str 0 2) ".-"))
            (substring method-str 2)
            (mangle-str (substring method-str 1))))
        (format "(~a.~a = ~a)" (emit-expr (method-call-target target)) prop val)]
       [(symbol? target)
        (format "(~a = ~a)" (mangle-name target) val)]
       [else
        (format "(~a = ~a)" (emit-expr target) val)])]

    [(with-open-form? e)
     (error 'beagle-js "with-open is not supported for JS target")]
    [(doto-form? e)
     (error 'beagle-js "doto is not supported for JS target")]

    [(call-form? e)
     (define fn-sym (call-form-fn e))
     (define args (call-form-args e))
     (cond
       [(and (set-member? (current-js-scalar-fns) fn-sym)
             (= 1 (length args)))
        (emit-expr (car args))]
       [(and (js-infix? fn-sym) (>= (length args) 2))
        (define op (hash-ref JS-INFIX-OPS fn-sym))
        (format "(~a)" (string-join (map emit-expr args) (format " ~a " op)))]
       [(and (js-unary? fn-sym) (= 1 (length args)))
        (format "(~a~a)" (hash-ref JS-UNARY-OPS fn-sym) (emit-expr (car args)))]
       [(emit-core-call fn-sym args) => values]
       [else
        (define fn-str (symbol->string fn-sym))
        (define mangled
          (cond
            [(string-prefix? fn-str "->")
             (mangle-str (substring fn-str 2))]
            [(string-contains? fn-str "/->")
             (let ([parts (string-split fn-str "/->")])
               (string-append (mangle-name (string->symbol (car parts)))
                              "." (mangle-str (cadr parts))))]
            [else (mangle-name fn-sym)]))
        (define qualified
          (let ([mod-prefix (hash-ref (current-js-symbol-ns) fn-sym #f)])
            (cond
              [(and mod-prefix (not (string-contains? mangled "/")))
               (string-append (mangle-name mod-prefix) "." mangled)]
              [(string-contains? mangled "/")
               (string-replace mangled "/" ".")]
              [else mangled])))
        (format "~a(~a)"
                qualified
                (string-join (map emit-expr args) ", "))])]

    [else (error 'beagle-js "don't know how to emit: ~v" e)]))

;; --- records ---------------------------------------------------------------

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-mangled (mangle-str name-str))
  (define name-lower (string-downcase name-str))
  (define field-names (map (lambda (p) (symbol->string (param-name p))) fields))
  (define field-params (map mangle-str field-names))
  (define factory
    (format "function ~a(~a) {\n  return Object.freeze({_tag: ~v, ~a});\n}"
            name-mangled
            (string-join field-params ", ")
            name-str
            (string-join field-params ", ")))
  (define accessors
    (for/list ([fname (in-list field-names)])
      (define mangled-fname (mangle-str fname))
      (format "function ~a_~a(r) { return r.~a; }"
              (mangle-str name-lower) mangled-fname mangled-fname)))
  (string-join (cons factory accessors) "\n\n"))

;; --- with (record update) --------------------------------------------------

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (define key (symbol->string (with-update-field-kw u)))
      (define prop (mangle-str (substring key 1)))
      (format "~a: ~a" prop (emit-expr (with-update-value u)))))
  (format "Object.freeze({...~a, ~a})" target-str (string-join update-strs ", ")))

;; --- match -----------------------------------------------------------------

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define tmp (format "_match_~a" (random 99999)))
  (define clauses (match-form-clauses e))
  (define arms
    (for/list ([c (in-list clauses)])
      (emit-match-arm c tmp)))
  (define async? (or (expr-has-await? (match-form-target e))
                     (for/or ([c (match-form-clauses e)])
                       (contains-await? (match-clause-body c)))))
  (define arms-str (string-join arms " "))
  (define needs-fallback?
    (and (pair? clauses)
         (let ([last-pat (match-clause-pattern (last clauses))])
           (not (or (pat-wildcard? last-pat) (pat-var? last-pat))))))
  (define full
    (if needs-fallback?
      (format "const ~a = ~a; ~a { return null; }" tmp target-str arms-str)
      (format "const ~a = ~a; ~a" tmp target-str arms-str)))
  (iife full #:async? async?))

(define (emit-match-arm clause tmp)
  (define pat (match-clause-pattern clause))
  (define body (match-clause-body clause))
  (define (make-body-str [extra-bound '()])
    (with-bindings extra-bound
      (lambda ()
        (if (= (length body) 1)
          (format "return ~a;" (emit-expr (car body)))
          (emit-body-return body "")))))
  (cond
    [(pat-wildcard? pat)
     (format "{ ~a }" (make-body-str))]
    [(pat-var? pat)
     (format "{ const ~a = ~a; ~a }"
             (mangle-name (pat-var-name pat)) tmp (make-body-str (list (pat-var-name pat))))]
    [(pat-literal? pat)
     (define val (pat-literal-value pat))
     (define test
       (cond
         [(eq? val 'nil) (format "~a == null" tmp)]
         [(string? val)  (format "~a === ~v" tmp val)]
         [(boolean? val) (format "~a === ~a" tmp (if val "true" "false"))]
         [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
          (format "~a === ~v" tmp (mangle-str (substring (symbol->string val) 1)))]
         [else (format "~a === ~a" tmp val)]))
     (format "if (~a) { ~a } else" test (make-body-str))]
    [(pat-record? pat)
     (define rec-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define fields (hash-ref (current-js-record-fields) rec-name #f))
     (define test (format "~a._tag === ~v" tmp (symbol->string rec-name)))
     (cond
       [(or (null? bindings) (not fields))
        (format "if (~a) { ~a } else" test (make-body-str))]
       [else
        (define let-strs
          (for/list ([b (in-list bindings)]
                     [fname (in-list fields)])
            (format "const ~a = ~a.~a;"
                    (mangle-name b) tmp (mangle-str fname))))
        (format "if (~a) { ~a ~a } else"
                test (string-join let-strs " ") (make-body-str bindings))])]
    [(pat-map? pat)
     (define tests
       (for/list ([entry (in-list (pat-map-entries pat))])
         (define k (mangle-str (substring (symbol->string (car entry)) 1)))
         (define v (cdr entry))
         (cond
           [(pat-literal? v)
            (define val (pat-literal-value v))
            (cond
              [(string? val) (format "~a.~a === ~v" tmp k val)]
              [(eq? val 'nil) (format "~a.~a == null" tmp k)]
              [else (format "~a.~a === ~a" tmp k val)])]
           [(pat-wildcard? v) "true"]
           [else (format "~a.~a != null" tmp k)])))
     (define test
       (if (= (length tests) 1) (car tests)
           (format "(~a)" (string-join tests " && "))))
     (format "if (~a) { ~a } else" test (make-body-str))]))

;; --- for comprehension → .map / .filter ------------------------------------

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))
  (define for-names (apply append
    (for/list ([c (in-list clauses)])
      (if (for-binding? c) (names-from-binding-target (for-binding-name c)) '()))))
  (with-bindings for-names
    (lambda ()
      (define body-str
        (if (= (length body) 1)
          (emit-expr (car body))
          (format "(() => { ~a })()" (emit-body-return body ""))))
      (emit-for-clauses clauses body-str))))

(define (emit-for-clauses clauses body-str)
  (match clauses
    [(list (for-binding name expr))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             body-str)]
    [(list (for-binding name expr) (for-when test) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.filter((~a) => ~a).map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             (emit-expr test)
             (emit-binding-target name)
             inner)]
    [(list (for-binding name expr) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             inner)]
    [_ (error 'beagle-js "unsupported for clause combination")]))

;; --- doseq → forEach -------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (match clauses
    [(list (for-binding name expr))
     (define doseq-names (names-from-binding-target name))
     (with-bindings doseq-names
       (lambda ()
         (define body-str (emit-body-stmts body "  "))
         (format "~a.forEach((~a) => {\n  ~a\n});"
                 (emit-expr expr)
                 (emit-binding-target name)
                 body-str)))]
    [_ (error 'beagle-js "complex doseq clauses not yet supported for JS target")]))

;; --- defscalar -------------------------------------------------------------

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format "// ~a : scalar" (mangle-name name))
    (let ([ctor (mangle-str (string-append "->" (symbol->string name)))]
          [checks (string-join
                    (for/list ([p (in-list preds)])
                      (format "v ~a ~a"
                              (scalar-predicate-op p)
                              (scalar-predicate-value p)))
                    " && ")])
      (format "function ~a(v) {\n  if (!(~a)) throw new Error('scalar constraint violated');\n  return v;\n}"
              ctor checks))))

;; --- quoted values ---------------------------------------------------------

(define (emit-quoted d)
  (cond
    [(string? d) (~v d)]
    [(boolean? d) (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d) (number->string d)]
    [(symbol? d)
     (define s (symbol->string d))
     (if (char=? (string-ref s 0) #\:)
       (~v (mangle-str (substring s 1)))
       (~v s))]
    [(null? d) "[]"]
    [(pair? d) (format "[~a]" (string-join (map emit-quoted d) ", "))]
    [else (~v d)]))

;; --- helpers ---------------------------------------------------------------

(define (emit-js-params params rest-p)
  (define fixed (string-join (map emit-js-param params) ", "))
  (if rest-p
    (if (string=? fixed "")
      (format "...~a" (emit-js-param rest-p))
      (format "~a, ...~a" fixed (emit-js-param rest-p)))
    fixed))

(define (emit-js-param p)
  (cond
    [(map-destructure? p)
     (define keys (map-destructure-keys p))
     (format "{~a}" (string-join (map (compose mangle-str symbol->string) keys) ", "))]
    [(seq-destructure? p)
     (define names (seq-destructure-names p))
     (define mangled (map (compose mangle-str symbol->string) names))
     (if (seq-destructure-rest-name p)
       (format "[~a, ...~a]" (string-join mangled ", ")
               (mangle-str (symbol->string (seq-destructure-rest-name p))))
       (format "[~a]" (string-join mangled ", ")))]
    [else (mangle-name (param-name p))]))

(define (emit-binding-target name)
  (cond
    [(map-destructure? name)
     (define keys (map-destructure-keys name))
     (format "{~a}" (string-join (map (compose mangle-str symbol->string) keys) ", "))]
    [(seq-destructure? name)
     (define names (seq-destructure-names name))
     (define mangled (map (compose mangle-str symbol->string) names))
     (if (seq-destructure-rest-name name)
       (format "[~a, ...~a]" (string-join mangled ", ")
               (mangle-str (symbol->string (seq-destructure-rest-name name))))
       (format "[~a]" (string-join mangled ", ")))]
    [(symbol? name) (mangle-name name)]
    [else (error 'beagle-js "unsupported binding target: ~v" name)]))

(define (expr-contains-recur? e)
  (cond
    [(recur-form? e) #t]
    [(if-form? e)
     (or (expr-contains-recur? (if-form-then-expr e))
         (and (if-form-else-expr e) (expr-contains-recur? (if-form-else-expr e))))]
    [(let-form? e)
     (body-contains-recur? (let-form-body e))]
    [(cond-form? e)
     (for/or ([c (in-list (cond-form-clauses e))])
       (body-contains-recur? (cond-clause-body c)))]
    [(when-let-form? e)
     (body-contains-recur? (when-let-form-body e))]
    [(if-let-form? e)
     (or (expr-contains-recur? (if-let-form-then-body e))
         (and (if-let-form-else-body e)
              (expr-contains-recur? (if-let-form-else-body e))))]
    [else #f]))

(define (body-contains-recur? body)
  (for/or ([e (in-list body)])
    (expr-contains-recur? e)))

(define (emit-recur-stmts e bind-names)
  (define temps
    (for/list ([a (in-list (recur-form-args e))]
               [i (in-naturals)])
      (format "const _recur_~a = ~a;" i (emit-expr a))))
  (define assigns
    (for/list ([name (in-list bind-names)]
               [i (in-naturals)])
      (format "~a = _recur_~a;" name i)))
  (string-append (string-join (append temps assigns) " ") " continue;"))

(define (emit-loop-stmt e bind-names)
  (cond
    [(and (if-form? e) (expr-contains-recur? e))
     (define cond-str (emit-expr (if-form-cond-expr e)))
     (define then-str (emit-loop-stmt (if-form-then-expr e) bind-names))
     (if (if-form-else-expr e)
       (let ([else-str (emit-loop-stmt (if-form-else-expr e) bind-names)])
         (format "if (~a) { ~a } else { ~a }" cond-str then-str else-str))
       (format "if (~a) { ~a }" cond-str then-str))]
    [(and (let-form? e) (body-contains-recur? (let-form-body e)))
     (define let-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) (let-form-bindings e))))
     (define binding-strs
       (for/list ([b (in-list (let-form-bindings e))])
         (format "const ~a = ~a;"
                 (emit-binding-target (let-binding-name b))
                 (emit-expr (let-binding-value b)))))
     (with-bindings let-names
       (lambda ()
         (define body-str
           (string-join (map (lambda (x) (emit-loop-stmt x bind-names)) (let-form-body e)) " "))
         (string-append (string-join binding-strs " ") " " body-str)))]
    [(and (cond-form? e) (for/or ([c (in-list (cond-form-clauses e))]) (body-contains-recur? (cond-clause-body c))))
     (define parts
       (for/list ([c (in-list (cond-form-clauses e))])
         (define test (cond-clause-test c))
         (define body (cond-clause-body c))
         (define body-str
           (string-join (map (lambda (x) (emit-loop-stmt x bind-names)) body) " "))
         (cond
           [(and (symbol? test) (eq? test ':else))
            (format "{ ~a }" body-str)]
           [else
            (format "if (~a) { ~a }" (emit-expr test) body-str)])))
     (string-join parts " else ")]
    [(recur-form? e)
     (emit-recur-stmts e bind-names)]
    [else
     (format "return ~a;" (emit-expr e))]))

(define (emit-body-return exprs indent)
  (cond
    [(null? exprs) ""]
    [(= (length exprs) 1)
     (format "return ~a;" (emit-expr (car exprs)))]
    [else
     (define stmts (take exprs (- (length exprs) 1)))
     (define last-e (last exprs))
     (string-append
      (string-join (map (lambda (e) (emit-expr-stmt e)) stmts) (string-append "\n" indent))
      (string-append "\n" indent)
      (format "return ~a;" (emit-expr last-e)))]))

(define (emit-body-stmts exprs indent)
  (string-join (map (lambda (e) (emit-expr-stmt e)) exprs)
               (string-append "\n" indent)))

(define (take lst n)
  (if (or (<= n 0) (null? lst)) '()
      (cons (car lst) (take (cdr lst) (- n 1)))))

(define (last lst)
  (if (null? (cdr lst)) (car lst) (last (cdr lst))))

;; --- block string -----------------------------------------------------------

(define (emit-js-block-string text)
  (~v text))

;; --- js/quote AST rendering ------------------------------------------------

;; Map beagle binary op symbols → JS operator strings
(define JS-AST-BINARY-OPS
  (hasheq '+ "+" '- "-" '* "*" '/ "/" '% "%"
          '** "**" '=== "===" '!== "!==" '== "==" '!= "!="
          '< "<" '> ">" '<= "<=" '>= ">="
          'and "&&" 'or "||" 'nullish "??"
          'bit-and "&" 'bit-or "|" 'bit-xor "^"
          '<< "<<" '>> ">>" '>>> ">>>"
          'in "in" 'instanceof "instanceof"))

(define (indent-str depth)
  (make-string (* depth 2) #\space))

(define (emit-js-ast-node node depth)
  (cond
    ;; --- Statements ---
    [(js-ast-block? node)
     (define stmts (js-ast-block-stmts node))
     (string-join
      (for/list ([s (in-list stmts)])
        (emit-js-ast-stmt s depth))
      "\n")]

    ;; --- Declarations ---
    [(js-ast-function? node)
     (emit-js-ast-function-decl node depth)]
    [(js-ast-class? node)
     (emit-js-ast-class-decl node depth)]

    ;; --- Single statements ---
    [else (emit-js-ast-stmt node depth)]))

(define (emit-js-ast-stmt node depth)
  (define ind (indent-str depth))
  (cond
    [(js-ast-block? node)
     (define stmts (js-ast-block-stmts node))
     (string-join
      (for/list ([s (in-list stmts)])
        (emit-js-ast-stmt s depth))
      "\n")]

    [(js-ast-const? node)
     (format "~aconst ~a = ~a;"
             ind
             (emit-js-ast-ident-str (js-ast-const-name node))
             (emit-js-ast-expr-str (js-ast-const-value node)))]

    [(js-ast-let? node)
     (format "~alet ~a = ~a;"
             ind
             (emit-js-ast-ident-str (js-ast-let-name node))
             (emit-js-ast-expr-str (js-ast-let-value node)))]

    [(js-ast-assign? node)
     (format "~a~a = ~a;"
             ind
             (emit-js-ast-expr-str (js-ast-assign-target node))
             (emit-js-ast-expr-str (js-ast-assign-value node)))]

    [(js-ast-return? node)
     (if (js-ast-return-expr node)
       (format "~areturn ~a;" ind (emit-js-ast-expr-str (js-ast-return-expr node)))
       (format "~areturn;" ind))]

    [(js-ast-if? node)
     (define test-str (emit-js-ast-expr-str (js-ast-if-test node)))
     (define then-str (emit-js-ast-block-str (js-ast-if-then node) depth))
     (cond
       [(js-ast-if-else-branch node)
        (define else-str (emit-js-ast-block-str (js-ast-if-else-branch node) depth))
        (format "~aif (~a) ~a else ~a" ind test-str then-str else-str)]
       [else
        (format "~aif (~a) ~a" ind test-str then-str)])]
    [(js-ast-for-of? node)
     (format "~afor (const ~a of ~a) ~a"
             ind
             (emit-js-ast-ident-str (js-ast-for-of-binding node))
             (emit-js-ast-expr-str (js-ast-for-of-iterable node))
             (emit-js-ast-block-str (js-ast-for-of-body node) depth))]

    [(js-ast-while? node)
     (format "~awhile (~a) ~a"
             ind
             (emit-js-ast-expr-str (js-ast-while-test node))
             (emit-js-ast-block-str (js-ast-while-body node) depth))]

    [(js-ast-throw? node)
     (format "~athrow ~a;" ind (emit-js-ast-expr-str (js-ast-throw-expr node)))]

    [(js-ast-try? node)
     (define body-str (emit-js-ast-block-str (js-ast-try-body node) depth))
     (define catch-str
       (if (js-ast-try-catch-name node)
         (format " catch (~a) ~a"
                 (emit-js-ast-ident-str (js-ast-try-catch-name node))
                 (emit-js-ast-block-str (js-ast-try-catch-body node) depth))
         ""))
     (define finally-str
       (if (js-ast-try-finally-body node)
         (format " finally ~a"
                 (emit-js-ast-block-str (js-ast-try-finally-body node) depth))
         ""))
     (format "~atry ~a~a~a" ind body-str catch-str finally-str)]

    [(js-ast-expr-stmt? node)
     (format "~a~a;" ind (emit-js-ast-expr-str (js-ast-expr-stmt-expr node)))]

    [(js-ast-function? node)
     (emit-js-ast-function-decl node depth)]
    [(js-ast-class? node)
     (emit-js-ast-class-decl node depth)]

    ;; Splice statements
    [(js-ast-splice-stmts? node)
     (format "~a~a" ind (emit-expr (js-ast-splice-stmts-beagle-expr node)))]

    [else (format "~a~a;" ind (emit-js-ast-expr-str node))]))

(define (emit-js-ast-block-str node depth)
  ;; Render a node as a { ... } block
  (define inner-depth (+ depth 1))
  (define stmts
    (cond
      [(js-ast-block? node) (js-ast-block-stmts node)]
      [else (list node)]))
  (define body
    (string-join
     (for/list ([s (in-list stmts)])
       (emit-js-ast-stmt s inner-depth))
     "\n"))
  (define ind (indent-str depth))
  (format "{\n~a\n~a}" body ind))

(define (emit-js-ast-function-decl node depth)
  (define ind (indent-str depth))
  (define export-prefix (if (js-ast-function-export? node) "export " ""))
  (define async-prefix (if (js-ast-function-async? node) "async " ""))
  (define name-str (emit-js-ast-ident-str (js-ast-function-name node)))
  (define params-str (emit-js-ast-params (js-ast-function-params node)))
  (define body-str (emit-js-ast-block-str (js-ast-function-body node) depth))
  (format "~a~a~afunction ~a(~a) ~a"
          ind export-prefix async-prefix name-str params-str body-str))

(define (emit-js-ast-class-decl node depth)
  (define ind (indent-str depth))
  (define name-str (emit-js-ast-ident-str (js-ast-class-name node)))
  (define extends-str
    (if (js-ast-class-extends-expr node)
      (format " extends ~a" (emit-js-ast-expr-str (js-ast-class-extends-expr node)))
      ""))
  (define inner-depth (+ depth 1))
  (define methods-str
    (string-join
     (for/list ([m (in-list (js-ast-class-methods node))])
       (emit-js-ast-method-str m inner-depth))
     "\n\n"))
  (format "~aclass ~a~a {\n~a\n~a}"
          ind name-str extends-str methods-str ind))

(define (emit-js-ast-method-str node depth)
  (define ind (indent-str depth))
  (define static-prefix (if (js-ast-method-static? node) "static " ""))
  (define async-prefix (if (js-ast-method-async? node) "async " ""))
  (define kind (js-ast-method-kind node))
  (define kind-prefix
    (case kind
      [(get) "get "]
      [(set) "set "]
      [else ""]))
  (define name-str
    (if (eq? kind 'constructor)
      "constructor"
      (emit-js-ast-ident-str (js-ast-method-name node))))
  (define params-str (emit-js-ast-params (js-ast-method-params node)))
  (define body-str (emit-js-ast-block-str (js-ast-method-body node) depth))
  (format "~a~a~a~a~a(~a) ~a"
          ind static-prefix async-prefix kind-prefix name-str params-str body-str))

(define (emit-js-ast-params params)
  (string-join
   (for/list ([p (in-list params)])
     (cond
       [(symbol? p) (emit-js-ast-ident-str p)]
       [(and (list? p) (eq? (car p) 'spread) (= (length p) 2))
        (format "...~a" (emit-js-ast-ident-str (cadr p)))]
       [else (format "~a" p)]))
   ", "))

(define (emit-js-ast-ident-str sym)
  ;; Convert a symbol to a JS identifier string (mangle beagle-style names)
  (mangle-name sym))

(define (emit-js-ast-expr-str node)
  (cond
    ;; Literals
    [(js-ast-literal? node)
     (define v (js-ast-literal-value node))
     (cond
       [(string? v) (~v v)]
       [(number? v) (number->string v)]
       [(boolean? v) (if v "true" "false")]
       [(eq? v 'null) "null"]
       [(eq? v 'undefined) "undefined"]
       [else (format "~a" v)])]

    ;; Identifier
    [(js-ast-ident? node)
     (emit-js-ast-ident-str (js-ast-ident-name node))]

    ;; Splices — emit the beagle expression
    [(js-ast-splice-expr? node)
     (emit-expr (js-ast-splice-expr-beagle-expr node))]
    [(js-ast-splice-json? node)
     (format "JSON.parse(~a)" (emit-expr (js-ast-splice-json-beagle-expr node)))]

    ;; Call
    [(js-ast-call? node)
     (define callee-str (emit-js-ast-expr-str (js-ast-call-callee node)))
     (define args-str (string-join (map emit-js-ast-expr-str (js-ast-call-args node)) ", "))
     (format "~a(~a)" callee-str args-str)]

    ;; Member access
    [(js-ast-member? node)
     (define obj-str (emit-js-ast-expr-str (js-ast-member-object node)))
     (define prop (js-ast-member-property node))
     (if (js-ast-member-computed? node)
       (format "~a[~a]" obj-str (emit-js-ast-expr-str prop))
       (format "~a.~a" obj-str (emit-js-ast-ident-str prop)))]

    ;; Index access
    [(js-ast-index? node)
     (format "~a[~a]"
             (emit-js-ast-expr-str (js-ast-index-object node))
             (emit-js-ast-expr-str (js-ast-index-index-expr node)))]

    ;; Arrow function
    [(js-ast-arrow? node)
     (define params-str (emit-js-ast-params (js-ast-arrow-params node)))
     (define body (js-ast-arrow-body node))
     (cond
       ;; If body is a block or multiple stmts, use { }
       [(js-ast-block? body)
        (format "(~a) => ~a" params-str (emit-js-ast-block-str body 0))]
       ;; Single expression body
       [else
        (format "(~a) => ~a" params-str (emit-js-ast-expr-str body))])]

    ;; Ternary
    [(js-ast-ternary? node)
     (format "(~a ? ~a : ~a)"
             (emit-js-ast-expr-str (js-ast-ternary-test node))
             (emit-js-ast-expr-str (js-ast-ternary-then node))
             (emit-js-ast-expr-str (js-ast-ternary-else-expr node)))]

    ;; Binary
    [(js-ast-binary? node)
     (define op-str (hash-ref JS-AST-BINARY-OPS (js-ast-binary-op node)
                              (symbol->string (js-ast-binary-op node))))
     (format "(~a ~a ~a)"
             (emit-js-ast-expr-str (js-ast-binary-left node))
             op-str
             (emit-js-ast-expr-str (js-ast-binary-right node)))]

    ;; Unary
    [(js-ast-unary? node)
     (define op-str (symbol->string (js-ast-unary-op node)))
     (if (js-ast-unary-prefix? node)
       (format "~a~a" op-str (emit-js-ast-expr-str (js-ast-unary-expr node)))
       (format "~a~a" (emit-js-ast-expr-str (js-ast-unary-expr node)) op-str))]

    ;; Template literal
    [(js-ast-template? node)
     (define parts-str
       (string-join
        (for/list ([p (in-list (js-ast-template-parts node))])
          (if (string? p)
            (escape-js-template-string p)
            (format "${~a}" (emit-js-ast-expr-str p))))
        ""))
     (format "`~a`" parts-str)]

    ;; Array
    [(js-ast-array? node)
     (format "[~a]"
             (string-join (map emit-js-ast-expr-str (js-ast-array-items node)) ", "))]

    ;; Object
    [(js-ast-object? node)
     (define pairs-str
       (string-join
        (for/list ([p (in-list (js-ast-object-pairs node))])
          (define key (car p))
          (define val (cdr p))
          (define key-str
            (cond
              ;; If key is an identifier, use it directly (shorthand possible)
              [(js-ast-ident? key)
               (define k (emit-js-ast-ident-str (js-ast-ident-name key)))
               (define v (emit-js-ast-expr-str val))
               (if (and (js-ast-ident? val)
                        (string=? k (emit-js-ast-ident-str (js-ast-ident-name val))))
                 k  ;; shorthand: { name } when key === value
                 (format "~a: ~a" k v))]
              ;; String key
              [(js-ast-literal? key)
               (format "~a: ~a" (emit-js-ast-expr-str key) (emit-js-ast-expr-str val))]
              ;; Computed key
              [else
               (format "[~a]: ~a" (emit-js-ast-expr-str key) (emit-js-ast-expr-str val))]))
          key-str)
        ", "))
     (format "{~a}" pairs-str)]

    ;; Spread
    [(js-ast-spread? node)
     (format "...~a" (emit-js-ast-expr-str (js-ast-spread-expr node)))]

    ;; Await
    [(js-ast-await? node)
     (format "await ~a" (emit-js-ast-expr-str (js-ast-await-expr node)))]

    ;; New
    [(js-ast-new? node)
     (format "new ~a(~a)"
             (emit-js-ast-expr-str (js-ast-new-callee node))
             (string-join (map emit-js-ast-expr-str (js-ast-new-args node)) ", "))]

    ;; Typeof
    [(js-ast-typeof? node)
     (format "typeof ~a" (emit-js-ast-expr-str (js-ast-typeof-expr node)))]

    ;; Fall through for complex expression nodes used as expressions
    [(js-ast-function? node)
     ;; Function expression (anonymous or named)
     (define async-prefix (if (js-ast-function-async? node) "async " ""))
     (define name-str (emit-js-ast-ident-str (js-ast-function-name node)))
     (define params-str (emit-js-ast-params (js-ast-function-params node)))
     (define body-str (emit-js-ast-block-str (js-ast-function-body node) 0))
     (format "~afunction ~a(~a) ~a" async-prefix name-str params-str body-str)]

    [else (format "/* js/quote: unhandled node ~v */" node)]))

;; --- registration ----------------------------------------------------------

(define js-backend
  (emitter-backend 'js js-emit-program))

(register-backend! 'js js-backend)

(provide js-backend)
