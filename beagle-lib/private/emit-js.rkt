#lang racket/base

;; JavaScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/list
         racket/set
         "parse.rkt"
         "emit-dispatch.rkt"
         "js-capabilities.rkt"
         "js-emit-utils.rkt"
         "emit-jst.rkt"
         "emit-js-quote.rkt")

;; match temp counter — a PARAMETER holding a box, reset fresh per program (see
;; js-emit-program) so the same source emits byte-identical .js every build, exactly
;; as emit-clj does. A module-level box would leak across programs in one process.
(define match-counter (make-parameter (box 0)))
(define (next-match-id!)
  (define b (match-counter))
  (define n (unbox b))
  (set-box! b (add1 n))
  n)

;; --- special float values ---------------------------------------------------

(define (emit-js-number n)
  (cond
    [(eqv? n +inf.0) "Infinity"]
    [(eqv? n -inf.0) "-Infinity"]
    [(eqv? n +nan.0) "NaN"]
    [else (number->string n)]))

;; --- infix operators -------------------------------------------------------
;; JS-INFIX-OPS / JS-UNARY-OPS live in js-capabilities.rkt.

(define (js-infix? sym) (hash-has-key? JS-INFIX-OPS sym))
(define (js-unary? sym) (hash-has-key? JS-UNARY-OPS sym))

;; --- small string utilities ------------------------------------------------

;; A keyword symbol like ':x is rendered as a bare property name "x".
;; Accepts either the full string (":x") or a symbol whose first char is `:`.
(define (kw->prop kw)
  (define s (if (symbol? kw) (symbol->string kw) kw))
  (mangle-str (substring s 1)))

(define (keyword-symbol? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (positive? (string-length s))
              (char=? (string-ref s 0) #\:)))))

;; --- core function translations --------------------------------------------

;; Render a flat (k v k v ...) list as ", "-separated [k]: v JS entries.
;; Caller is responsible for confirming even arity. Returns "" when empty.
(define (emit-kv-entries kvs)
  (string-join
   (let loop ([rest kvs] [acc '()])
     (if (< (length rest) 2)
         (reverse acc)
         (loop (cddr rest)
               (cons (format "[~a]: ~a" (emit-expr (car rest)) (emit-expr (cadr rest)))
                     acc))))
   ", "))

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
    [(last) (if (= n 1)
                (format "(() => { const _x = ~a; return _x[_x.length - 1]; })()" (emit-expr (car args)))
                #f)]
    [(rest) (if (= n 1) (format "~a.slice(1)" (emit-expr (car args))) #f)]
    [(nth) (cond
             [(= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
             [(= n 3) (format "(() => { const _x = ~a, _i = ~a; return _x[_i] != null ? _x[_i] : ~a; })()"
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (caddr args)))]
             [else #f])]
    [(conj) (if (>= n 2)
              (format "[...~a, ~a]"
                      (emit-expr (car args))
                      (string-join (map emit-expr (cdr args)) ", "))
              #f)]
    [(assoc) (if (and (>= n 3) (odd? n))
                 (format "({...~a, ~a})"
                         (emit-expr (car args))
                         (emit-kv-entries (cdr args)))
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
             [(= n 3) (format "(() => { const _x = ~a, _k = ~a; return _x[_k] != null ? _x[_k] : ~a; })()"
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (caddr args)))]
             [else #f])]
    [(update) (if (= n 3)
                  (format "(() => { const _m = ~a, _k = ~a; return { ..._m, [_k]: ~a(_m[_k]) }; })()"
                          (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))
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
    [(peek) (if (= n 1)
                (format "(() => { const _x = ~a; return _x[_x.length - 1]; })()" (emit-expr (car args)))
                #f)]
    [(take) (if (= n 2) (format "~a.slice(0, ~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(drop) (if (= n 2) (format "~a.slice(~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(some) (if (= n 2)
             (format "~a.find(~a) ?? null" (emit-expr (cadr args)) (emit-expr (car args)))
             #f)]
    [(distinct) (if (= n 1) (format "[...new Set(~a)]" (emit-expr (car args))) #f)]
    [(flatten) (if (= n 1) (format "~a.flat(Infinity)" (emit-expr (car args))) #f)]
    [(not-empty) (if (= n 1)
                     (format "(() => { const _x = ~a; return _x.length > 0 ? _x : null; })()" (emit-expr (car args)))
                     #f)]
    [(sort-by) (if (= n 2)
                   (format "(() => { const _k = ~a; return [...~a].sort((a, b) => { const ka = _k(a), kb = _k(b); return ka < kb ? -1 : ka > kb ? 1 : 0; }); })()"
                           (emit-expr (car args)) (emit-expr (cadr args)))
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
    [(map?) (if (= n 1)
                (format "(() => { const _x = ~a; return typeof _x === 'object' && _x !== null && !Array.isArray(_x); })()"
                        (emit-expr (car args)))
                #f)]
    [(set?) (if (= n 1) (format "(~a instanceof Set)" (emit-expr (car args))) #f)]
    [(sequential?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(seq?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(coll?) (if (= n 1)
                 (format "(() => { const _x = ~a; return Array.isArray(_x) || (typeof _x === 'object' && _x !== null); })()"
                         (emit-expr (car args)))
                 #f)]
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
    [(seq) (if (= n 1)
               (format "(() => { const _x = ~a; return _x.length > 0 ? _x : null; })()" (emit-expr (car args)))
               #f)]
    ;; --- runtime helpers (beagle/core.js) -------------------------------------
    [(range)       (runtime-call "range" args)]
    [(remove)      (if (= n 2) (runtime-call "remove" args) #f)]
    [(mapcat)      (if (= n 2) (runtime-call "mapcat" args) #f)]
    [(every?)      (if (= n 2) (runtime-call "every_p" args) #f)]
    [(keep)        (if (= n 2) (runtime-call "keep" args) #f)]
    [(map-indexed) (if (= n 2) (runtime-call "map_indexed" args) #f)]
    [(assoc-in)    (if (= n 3) (runtime-call "assoc_in" args) #f)]
    [(update-in)   (if (= n 3) (runtime-call "update_in" args) #f)]
    [(select-keys) (if (= n 2) (runtime-call "select_keys" args) #f)]
    [(merge-with)  (if (>= n 2) (runtime-call "merge_with" args) #f)]
    [(take-while)  (if (= n 2) (runtime-call "take_while" args) #f)]
    [(drop-while)  (if (= n 2) (runtime-call "drop_while" args) #f)]
    ;; --- batch 2: collection ops -----------------------------------------------
    [(cons) (if (= n 2) (format "[~a, ...~a]" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(butlast) (if (= n 1) (format "~a.slice(0, -1)" (emit-expr (car args))) #f)]
    [(nfirst) (if (= n 1) (format "~a[0]?.slice(1) ?? null" (emit-expr (car args))) #f)]
    [(nnext) (if (= n 1) (format "(() => { const _s = ~a.slice(1); return _s.length > 1 ? _s.slice(1) : null; })()" (emit-expr (car args))) #f)]
    [(fnext) (if (= n 1) (format "~a.slice(1)[0]" (emit-expr (car args))) #f)]
    [(ffirst) (if (= n 1) (format "~a[0]?.[0]" (emit-expr (car args))) #f)]
    [(nthrest) (if (= n 2) (format "~a.slice(~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(nthnext) (if (= n 2) (format "(() => { const _s = ~a.slice(~a); return _s.length > 0 ? _s : null; })()" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(rand-nth) (if (= n 1)
                    (format "(() => { const _x = ~a; return _x[Math.floor(Math.random() * _x.length)]; })()" (emit-expr (car args)))
                    #f)]
    [(shuffle) (if (= n 1) (format "[...~a].sort(() => Math.random() - 0.5)" (emit-expr (car args))) #f)]
    [(list?) (if (= n 1) (format "Array.isArray(~a)" (emit-expr (car args))) #f)]
    [(boolean?) (if (= n 1) (format "(typeof ~a === 'boolean')" (emit-expr (car args))) #f)]
    [(any?) (if (= n 1) "true" #f)]
    [(symbol?) (if (= n 1) (format "(typeof ~a === 'symbol')" (emit-expr (car args))) #f)]
    ;; --- math / numeric --------------------------------------------------------
    [(quot) (if (= n 2) (format "Math.trunc(~a / ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(rem) (if (= n 2) (format "(~a % ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(compare) (if (= n 2) (format "(~a < ~a ? -1 : ~a > ~a ? 1 : 0)"
                                   (emit-expr (car args)) (emit-expr (cadr args))
                                   (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(infinite?) (if (= n 1) (format "(!Number.isFinite(~a))" (emit-expr (car args))) #f)]
    ;; --- predicates ------------------------------------------------------------
    [(not-any?) (if (= n 2) (format "(!~a.some(~a))" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(not-every?) (if (= n 2) (format "(!~a.every(~a))" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(distinct?) (if (>= n 2) (format "(new Set([~a]).size === ~a)"
                                      (string-join (map emit-expr args) ", ") (number->string n)) #f)]
    ;; --- string / regex --------------------------------------------------------
    [(re-pattern) (if (= n 1) (format "new RegExp(~a)" (emit-expr (car args))) #f)]
    [(re-matches) (if (= n 2) (format "~a.match(~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(re-seq) (if (= n 2) (format "[...~a.matchAll(~a)].map(m => m[0])"
                                  (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(re-groups) (if (= n 1) (format "~a" (emit-expr (car args))) #f)]
    [(format)     (if (>= n 1) (runtime-call "format" args) #f)]
    ;; --- type coercion (int/double/char omitted — shadow user names too easily)
    ;; --- higher-order ----------------------------------------------------------
    [(memoize)    (if (= n 1) (runtime-call "memoize" args) #f)]
    [(fnil)       (if (>= n 2) (runtime-call "fnil" args) #f)]
    [(some-fn)    (if (>= n 1) (runtime-call "some_fn" args) #f)]
    [(every-pred) (if (>= n 1) (runtime-call "every_pred" args) #f)]
    [(run!) (if (= n 2) (format "(~a.forEach(~a), null)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    ;; --- map / set ops ---------------------------------------------------------
    [(rename-keys) (if (= n 2) (runtime-call "rename_keys" args) #f)]
    [(map-keys)    (if (= n 2) (runtime-call "map_keys" args) #f)]
    [(map-vals)    (if (= n 2) (runtime-call "map_vals" args) #f)]
    [(update-keys) (if (= n 2) (runtime-call "map_keys" args) #f)]
    [(update-vals) (if (= n 2) (runtime-call "map_vals" args) #f)]
    [(disj)        (if (>= n 2) (runtime-call "disj" args) #f)]
    [(find) (if (= n 2) (format "(() => { const _m = ~a, _k = ~a; return _k in _m ? [_k, _m[_k]] : null; })()"
                                (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(key) (if (= n 1) (format "~a[0]" (emit-expr (car args))) #f)]
    [(val) (if (= n 1) (format "~a[1]" (emit-expr (car args))) #f)]
    [(reduce-kv)  (if (= n 3) (runtime-call "reduce_kv" args) #f)]
    ;; --- sequence generation ---------------------------------------------------
    [(repeat) (cond
                [(= n 2) (format "Array.from({length: ~a}, () => ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
                [else #f])]
    [(repeatedly) (if (= n 2) (format "Array.from({length: ~a}, ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(dedupe)        (if (= n 1) (runtime-call "dedupe" args) #f)]
    [(interpose)     (if (= n 2) (runtime-call "interpose" args) #f)]
    [(partition-all) (if (= n 2) (runtime-call "partition_all" args) #f)]
    [(partition-by)  (if (= n 2) (runtime-call "partition_by" args) #f)]
    [(split-at) (if (= n 2)
                    (format "(() => { const _n = ~a, _c = ~a; return [_c.slice(0, _n), _c.slice(_n)]; })()"
                            (emit-expr (car args)) (emit-expr (cadr args)))
                    #f)]
    [(split-with) (if (= n 2) (runtime-call "split_with" args) #f)]
    [(zipmap)     (if (= n 2) (runtime-call "zipmap" args) #f)]
    ;; --- bitwise ---------------------------------------------------------------
    [(bit-and) (if (= n 2) (format "(~a & ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-or) (if (= n 2) (format "(~a | ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-xor) (if (= n 2) (format "(~a ^ ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-not) (if (= n 1) (format "(~~~a)" (emit-expr (car args))) #f)]
    [(bit-shift-left) (if (= n 2) (format "(~a << ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-shift-right) (if (= n 2) (format "(~a >> ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(unsigned-bit-shift-right) (if (= n 2) (format "(~a >>> ~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-test) (if (= n 2) (format "((~a & (1 << ~a)) !== 0)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-set) (if (= n 2) (format "(~a | (1 << ~a))" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-clear) (if (= n 2) (format "(~a & ~~(1 << ~a))" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-flip) (if (= n 2) (format "(~a ^ (1 << ~a))" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(bit-and-not) (if (= n 2) (format "(~a & ~~~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    ;; --- more collection ops ---------------------------------------------------
    [(get-in)     (if (= n 2) (runtime-call "get_in" args) #f)]
    [(vector) (format "[~a]" (string-join (map emit-expr args) ", "))]
    [(list) (format "[~a]" (string-join (map emit-expr args) ", "))]
    [(hash-map) (if (even? n)
                    (format "{~a}" (emit-kv-entries args))
                    #f)]
    [(hash-set) (format "new Set([~a])" (string-join (map emit-expr args) ", "))]
    [(take-nth)     (if (= n 2) (runtime-call "take_nth" args) #f)]
    [(keep-indexed) (if (= n 2) (runtime-call "keep_indexed" args) #f)]
    [(reductions)   (if (>= n 2) (runtime-call "reductions" args) #f)]
    [(replace)      (if (= n 2) (runtime-call "replace" args) #f)]
    [(max-key)      (if (>= n 2) (runtime-call "max_key" args) #f)]
    [(min-key)      (if (>= n 2) (runtime-call "min_key" args) #f)]
    [(next) (if (= n 1) (format "(() => { const _s = ~a.slice(1); return _s.length > 0 ? _s : null; })()" (emit-expr (car args))) #f)]
    [(empty) (if (= n 1) (format "(Array.isArray(~a) ? [] : {})" (emit-expr (car args))) #f)]
    ;; --- IO / formatting -------------------------------------------------------
    [(newline) (if (= n 0) "console.log()" #f)]
    [(printf) (if (>= n 1)
                  (format "process.stdout.write(~a)" (runtime-call "format" args))
                  #f)]
    [(compare-and-set!) (if (= n 3)
                          (format "(() => { const _a = ~a; if (_a.value === ~a) { _a.value = ~a; return true; } return false; })()"
                                  (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))
                          #f)]
    [(gensym) (format "Symbol(~a)" (if (= n 0) "" (emit-expr (car args))))]
    [(hash) (if (= n 1) (runtime-call "hash" args) #f)]
    [(random-uuid) (if (= n 0) "crypto.randomUUID()" #f)]
    [(parse-long) (if (= n 1) (format "parseInt(~a, 10)" (emit-expr (car args))) #f)]
    [(parse-double) (if (= n 1) (format "parseFloat(~a)" (emit-expr (car args))) #f)]
    [(parse-boolean) (if (= n 1) (format "(~a === 'true')" (emit-expr (car args))) #f)]
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
    [(doseq-form? e) (contains-await? (doseq-form-body e))]
    [(loop-form? e) (or (for/or ([b (in-list (loop-form-bindings e))])
                          (expr-has-await? (let-binding-value b)))
                        (contains-await? (loop-form-body e)))]
    [(recur-form? e) (contains-await? (recur-form-args e))]
    [(with-form? e) (expr-has-await? (with-form-target e))]
    [(kw-access? e) (expr-has-await? (kw-access-target e))]
    [(set!-form? e) (or (expr-has-await? (set!-form-target e))
                        (expr-has-await? (set!-form-value e)))]
    [(threading-marker? e) (expr-has-await? (threading-marker-desugared e))]
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

;; A control-flow form (try/do/let/loop/when/match…) containing js/await compiles
;; to an async IIFE `(async () => {...})()`, which RETURNS A PROMISE. In value or
;; statement position that promise must be awaited — otherwise the binding holds a
;; pending promise and code after it runs before it settles (the recurring
;; "fire-and-forget" emit bug). The enclosing fn is necessarily async (its body
;; contains await), so `await` is valid here. The matched prefix is exactly the
;; `iife`/loop output, so this never over-awaits an inline-await call like
;; `f(await g())` (which does not start with `(async () => `).
(define (await-async-iife s)
  (if (string-prefix? s "(async () => ")
    (string-append "await " s)
    s))

;; --- context tracking ------------------------------------------------------

(define current-js-context (make-parameter 'stmt))
(define current-js-inline-scope (make-parameter (set)))
(define current-js-record-fields (make-parameter (hasheq)))
(define current-js-record-ns (make-parameter (hasheq)))
(define current-js-scalar-fns (make-parameter (set)))
(define current-js-symbol-ns (make-parameter (hasheq)))

;; --- runtime import tracking -----------------------------------------------

(define needs-runtime? (make-parameter #f))

(define (use-runtime!)
  (needs-runtime? #t))

;; Convenience: mark runtime as needed and emit a call to one of the
;; functions exported by beagle/core.js.
;;   (runtime-call "range" args) => "$$bc.range(arg1, arg2, ...)"
(define (runtime-call js-name args)
  (use-runtime!)
  (format "$$bc.~a(~a)" js-name (string-join (map emit-expr args) ", ")))

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
                 [match-counter (box 0)]
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

;; Relative ES-module specifier from the importing module to an imported one,
;; both given as dotted namespaces (e.g. gjoa.tools.prep.cli importing
;; gjoa.tools.prep.log → "./log.js"; importing gjoa.tools.security.check →
;; "../security/check.js"). A `./`-prefixed full-ns path only resolves when the
;; importer sits at the module root, which is false for any nested module run
;; un-bundled — so emit a path relative to the importer's own directory.
(define (relative-js-module-path importer-ns imported-ns)
  (define imp-parts (string-split importer-ns "."))
  (define imp-dir (if (null? imp-parts) '() (reverse (cdr (reverse imp-parts)))))
  (define tgt (string-split imported-ns "."))
  (let loop ([d imp-dir] [t tgt])
    (if (and (pair? d) (pair? t) (string=? (car d) (car t)))
      (loop (cdr d) (cdr t))
      (let* ([ups (map (lambda (_) "..") d)]
             [parts (append ups t)]
             [path (string-append (string-join parts "/") ".js")])
        (if (string-prefix? path "..") path (string-append "./" path))))))

(define (emit-module-header prog)
  (define importer-ns (symbol->string (program-namespace prog)))
  (define rs (program-requires prog))
  ;; A `:refer`'d name that resolved to a macro is compile-time only — it's
  ;; expanded away and never referenced at runtime, and the target module emits
  ;; no runtime export for it. Emitting it in `import { … }` produces an ESM that
  ;; throws "does not provide an export named X" in any consumer that ISN'T
  ;; bundled (e.g. tests loaded via dynamic import). Drop macro refers; if a
  ;; require's refers are ALL macros, emit no import line at all.
  (define macros (program-macros prog))
  (define lines
    (filter
     (lambda (s) (not (string=? s "")))
     (for/list ([r (in-list rs)])
       (define ns-str (symbol->string (require-entry-ns r)))
       (define refer (require-entry-refer r))
       (define module-path
         (cond
           [(string-prefix? ns-str "@") ns-str]
           [(not (string-contains? ns-str ".")) ns-str]
           [else (relative-js-module-path importer-ns ns-str)]))
       (if refer
         (let ([runtime-refer
                (filter (lambda (n) (not (hash-ref macros n #f))) refer)])
           (if (null? runtime-refer)
             ""
             (format "import { ~a } from '~a';"
                     (string-join (map mangle-name runtime-refer) ", ")
                     module-path)))
         (let ([alias (or (require-entry-alias r)
                          (let ([parts (string-split ns-str ".")])
                            (string->symbol (last parts))))])
           (format "import * as ~a from '~a';"
                   (mangle-name alias)
                   module-path))))))
  (if (null? lines)
    ""
    (string-append (string-join lines "\n") "\n")))

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
               (string-join (map mangle-name (defunion-form-members f)) " | ")))
     (define member-fields (defunion-form-member-fields f))
     (if (not member-fields)
       comment
       (string-append comment "\n"
         (string-join
           (for/list ([m (in-list (defunion-form-members f))])
             (define fields (hash-ref member-fields m))
             (emit-tagged-factory m fields))
           "\n")))]

    [(deferror-form? f)
     (define name (mangle-name (deferror-form-name f)))
     (define members (deferror-form-members f))
     (define mf (deferror-form-member-fields f))
     (define comment (format "// error ~a = ~a" name
                             (string-join (map mangle-name members) " | ")))
     (string-append comment "\n"
       (string-join
         (for/list ([m (in-list members)])
           (define fields (hash-ref mf m '()))
           (emit-tagged-factory m fields))
         "\n"))]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [(protocol-form? f)
     (error 'beagle-js "protocol-form is not supported for JS target")]
    [(defmulti-form? f)
     (error 'beagle-js "defmulti is not supported for JS target")]
    [(defmethod-form? f)
     (error 'beagle-js "defmethod is not supported for JS target")]
    [(extend-type-form? f)
     (error 'beagle-js "extend-type is not supported for JS target")]

    [(js-quote-form? f)
     (emit-js-ast-node (js-quote-form-body f) 0)]

    ;; --- Typed JS target forms (jst-*) ----------------------------------------
    [(jst-class? f)    (emit-jst-class f)]
    [(jst-export? f)   (string-append "export " (emit-form (jst-export-form f)))]
    [(jst-export-default? f) (string-append "export default " (emit-form (jst-export-default-form f)))]
    [(jst-return? f)   (emit-jst-return f)]

    [else (emit-expr-stmt f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
  (parameterize ([current-js-context 'expr])
    (emit-expr-core e)))

(define (emit-expr-stmt e)
  (define s (await-async-iife (emit-expr-core e)))
  (if (string-suffix? s ";") s (string-append s ";")))

(define (emit-expr-core e)
  (cond
    [(block-string? e)  (emit-js-block-string (block-string-text e))]
    [(string? e)        (js-string-lit e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (emit-js-number e)]
    [(symbol? e)
     (cond
       [(eq? e 'nil) "null"]
       [(keyword-symbol? e) (~v (kw->prop e))]
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
                         [(keyword-symbol? k) (kw->prop k)]
                         [else (format "[~a]" (emit-expr k))]))
                     (format "~a: ~a" key-str (emit-expr v)))
                   (map-form-pairs e))
              ", "))]
    [(set-form? e)
     (format "new Set([~a])"
             (string-join (map emit-expr (set-form-items e)) ", "))]

    [(with-meta? e)     (emit-expr (with-meta-expr e))]

    [(threading-marker? e)
     (emit-expr (threading-marker-desugared e))]

    [(js-quote-form? e)
     (emit-js-ast-node (js-quote-form-body e) 0)]

    ;; --- Typed JS target expression forms (jst-*) -----------------------------
    [(jst-dot? e)      (emit-jst-dot e)]
    [(jst-spread? e)   (format "...~a" (emit-jst-expr (jst-spread-expr e)))]
    [(jst-import-meta? e) "import.meta"]
    [(jst-typeof? e)   (format "typeof ~a" (emit-jst-expr (jst-typeof-expr e)))]
    [(jst-template? e) (emit-jst-template e)]
    [(jst-binary? e)   (emit-jst-binary e)]
    [(jst-unary? e)    (emit-jst-unary e)]
    [(jst-class? e)    (emit-jst-class e)]
    [(jst-return? e)   (emit-jst-return e)]
    [(jst-export? e)   (string-append "export " (emit-form (jst-export-form e)))]
    [(jst-export-default? e) (string-append "export default " (emit-form (jst-export-default-form e)))]

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
     (define (else-clause? c)
       (let ([t (cond-clause-test c)])
         (and (symbol? t) (or (eq? t ':else) (eq? t 'else)))))
     (define parts
       (for/list ([c (in-list clauses)])
         (define test (cond-clause-test c))
         (define body (cond-clause-body c))
         (define body-str (if (= (length body) 1) (emit-expr (car body)) (emit-body-return body "")))
         (if (else-clause? c)
           (format "~a" body-str)
           (format "(~a) ? ~a" (emit-expr test) body-str))))
     ;; Clojure cond with no matching clause yields nil — without a trailing
     ;; :else the ternary chain would dangle (`a ? x : b ? y` with no final
     ;; `: …`), so supply the implicit null branch.
     (define complete-parts
       (if (and (pair? clauses) (else-clause? (last clauses)))
         parts
         (append parts (list "null"))))
     (string-join complete-parts " : ")]

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
         (define val-str (await-async-iife
                           (parameterize ([current-js-bound bound])
                             (emit-expr (let-binding-value b)))))
         (define stmts (emit-let-binding-stmts (let-binding-name b) val-str))
         (define new-names (names-from-binding-target (let-binding-name b)))
         (values (append strs stmts)
                 (set-union bound (list->set new-names)))))
     (with-bindings let-names
       (lambda ()
         (iife (format "~a ~a" (string-join bind-strs " ") (emit-body-return body ""))
                #:async? has-await)))]

    [(loop-form? e)
     (define bindings (loop-form-bindings e))
     (define body (loop-form-body e))
     (define has-await (or (for/or ([b (in-list bindings)])
                             (expr-has-await? (let-binding-value b)))
                           (contains-await? body)))
     (define loop-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define bind-names
       (for/list ([b (in-list bindings)])
         (emit-binding-target (let-binding-name b))))
     (define bind-strs
       (for/list ([b (in-list bindings)])
         (format "let ~a = ~a;"
                 (emit-binding-target (let-binding-name b))
                 (await-async-iife (emit-expr (let-binding-value b))))))
     (with-bindings loop-names
       (lambda ()
         (define body-str
           (string-join (map (lambda (e) (emit-loop-stmt e bind-names)) body) "\n    "))
         (define prefix (if has-await "async " ""))
         (format "(~a() => { ~a while (true) {\n    ~a\n  } })()"
                 prefix
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
         (if (and (= (length body) 1) (not (stmt-inline? (car body))))
           (let ([body-str (emit-expr (car body))])
             ;; An expression-body arrow whose body emits an OBJECT LITERAL must be
             ;; parenthesized: `=> {…}` is a JS block (a labeled-statement parse),
             ;; whereas `=> ({…})` returns the object. Any expression that emits
             ;; starting with `{` is an object literal in this position, so wrap it.
             (if (regexp-match? #rx"^[ \t\r\n]*[{]" body-str)
               (format "~a(~a) => (~a)" prefix params body-str)
               (format "~a(~a) => ~a" prefix params body-str)))
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
     (define prop (kw->prop (kw-access-kw e)))
     (define target-str (emit-expr (kw-access-target e)))
     (cond
       [(kw-access-default e)
        (format "(~a.~a != null ? ~a.~a : ~a)"
                target-str prop target-str prop
                (emit-expr (kw-access-default e)))]
       [else (format "~a.~a" target-str prop)])]

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
            (mangle-prop (substring method-str 2))
            (mangle-prop (substring method-str 1))))
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

;; Emit `function Tag(...fields) { return Object.freeze({ _tag: "Tag", ... }); }`
;; Shared by defunion and deferror members (both produce tagged variant ctors).
(define (emit-tagged-factory member-name fields)
  (define m-str (mangle-name member-name))
  (define field-names (map (compose mangle-name param-name) fields))
  (format "function ~a(~a) { return Object.freeze({ _tag: ~v~a }); }"
          m-str
          (string-join field-names ", ")
          (symbol->string member-name)
          (if (null? field-names) ""
              (string-append ", "
                             (string-join
                              (map (lambda (n) (format "~a: ~a" n n)) field-names)
                              ", ")))))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-mangled (mangle-name name))
  (define accessor-prefix (mangle-str (string-downcase name-str)))
  (define field-params (map (compose mangle-name param-name) fields))
  (define factory
    (format "function ~a(~a) {\n  return Object.freeze({_tag: ~v, ~a});\n}"
            name-mangled
            (string-join field-params ", ")
            name-str
            (string-join field-params ", ")))
  (define accessors
    (for/list ([fp (in-list field-params)])
      (format "function ~a_~a(r) { return r.~a; }"
              accessor-prefix fp fp)))
  (string-join (cons factory accessors) "\n\n"))

;; --- with (record update) --------------------------------------------------

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (format "~a: ~a"
              (kw->prop (with-update-field-kw u))
              (emit-expr (with-update-value u)))))
  (format "Object.freeze({...~a, ~a})" target-str (string-join update-strs ", ")))

;; --- match -----------------------------------------------------------------

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define tmp (format "_match_~a" (next-match-id!)))
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

;; Pattern test expression for a literal pattern. Extracted so or-pattern
;; can compose tests across alternatives.
(define (emit-pat-literal-test-js pat tmp)
  (define val (pat-literal-value pat))
  (cond
    [(eq? val 'nil) (format "~a == null" tmp)]
    [(string? val)  (format "~a === ~a" tmp (js-string-lit val))]
    [(boolean? val) (format "~a === ~a" tmp (if val "true" "false"))]
    [(keyword-symbol? val)
     (format "~a === ~v" tmp (kw->prop val))]
    [else (format "~a === ~a" tmp val)]))

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
     (format "if (~a) { ~a } else" (emit-pat-literal-test-js pat tmp) (make-body-str))]
    ;; or-pattern (v1: literal-only alternatives). Combines per-alternative
    ;; tests with `||`. Future operators slot in as sibling cases here.
    [(pat-or? pat)
     (define tests
       (for/list ([alt (in-list (pat-or-alternatives pat))])
         (cond
           [(pat-literal? alt) (emit-pat-literal-test-js alt tmp)]
           [(pat-wildcard? alt) "true"]
           [else (error 'emit-js
                        "or-pattern (v1) supports literal alternatives only; got: ~v"
                        alt)])))
     (format "if (~a) { ~a } else"
             (string-join tests " || ")
             (make-body-str))]
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
         (define k (kw->prop (car entry)))
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
     ;; G4-emit: bind each VAR entry (const x = tmp.k) + scope it in the body.
     ;; Previously the var was emitted FREE (ReferenceError at runtime) — a latent bug.
     (define var-entries (filter (lambda (en) (pat-var? (cdr en))) (pat-map-entries pat)))
     (define vnames (map (lambda (en) (pat-var-name (cdr en))) var-entries))
     (define let-strs
       (for/list ([en (in-list var-entries)])
         (format "const ~a = ~a.~a;" (mangle-name (pat-var-name (cdr en)))
                 tmp (kw->prop (car en)))))
     (if (null? let-strs)
         (format "if (~a) { ~a } else" test (make-body-str))
         (format "if (~a) { ~a ~a } else" test (string-join let-strs " ")
                 (make-body-str vnames)))]))

;; --- for comprehension → .map / .filter ------------------------------------

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))
  (define for-names (apply append
    (for/list ([c (in-list clauses)])
      (cond
        [(for-binding? c) (names-from-binding-target (for-binding-name c))]
        [(for-let? c) (map let-binding-name (for-let-bindings c))]
        [else '()]))))
  (with-bindings for-names
    (lambda ()
      (define body-str
        (if (= (length body) 1)
          (emit-expr (car body))
          (format "(() => { ~a })()" (emit-body-return body ""))))
      (emit-for-clauses clauses body-str))))

(define (emit-for-clauses clauses body-str)
  (match clauses
    [(list (for-binding name expr _))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             body-str)]
    [(list (for-binding name expr _) (for-when test) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.filter((~a) => ~a).map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             (emit-expr test)
             (emit-binding-target name)
             inner)]
    [(list (for-binding name expr _) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             inner)]
    [(list (? for-let? fl) rest ...)
     (define binds (for-let-bindings fl))
     (define let-strs
       (for/list ([b (in-list binds)])
         (format "const ~a = ~a"
                 (mangle-name (let-binding-name b))
                 (await-async-iife (emit-expr (let-binding-value b))))))
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "(() => { ~a; return ~a; })()"
             (string-join let-strs "; ")
             inner)]
    [_ (error 'beagle-js "unsupported for clause combination")]))

;; --- doseq → forEach -------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (match clauses
    [(list (for-binding name expr _))
     (define doseq-names (names-from-binding-target name))
     (with-bindings doseq-names
       (lambda ()
         (define body-str (emit-body-stmts body "  "))
         (if (contains-await? body)
           ;; A forEach callback can't `await` sequentially (and the arrow
           ;; isn't async), so when the body awaits, emit a for-of loop —
           ;; which sequences awaits correctly inside the enclosing async fn.
           (format "for (const ~a of ~a) {\n  ~a\n}"
                   (emit-binding-target name)
                   (emit-expr expr)
                   body-str)
           (format "~a.forEach((~a) => {\n  ~a\n});"
                   (emit-expr expr)
                   (emit-binding-target name)
                   body-str))))]
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
    [(real? d) (emit-js-number d)]
    [(symbol? d)
     (if (keyword-symbol? d)
         (~v (kw->prop d))
         (~v (symbol->string d)))]
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

;; Render a destructuring pattern to its JS form. Returns #f for non-destructure
;; inputs so callers can fall through to their own handling.
(define (emit-destructure p)
  (cond
    [(map-destructure? p)
     (define or-alist (map-destructure-or-defaults p))
     (define key-strs
       (for/list ([k (in-list (map-destructure-keys p))])
         (define default-pair (assq k or-alist))
         (if default-pair
             (format "~a = ~a" (mangle-name k) (emit-expr (cdr default-pair)))
             (mangle-name k))))
     (format "{~a}" (string-join key-strs ", "))]
    [(seq-destructure? p)
     (define mangled (map mangle-name (seq-destructure-names p)))
     (cond
       [(seq-destructure-rest-name p)
        (format "[~a, ...~a]" (string-join mangled ", ")
                (mangle-name (seq-destructure-rest-name p)))]
       [else
        (format "[~a]" (string-join mangled ", "))])]
    [else #f]))

(define (emit-js-param p)
  (or (emit-destructure p)
      (mangle-name (param-name p))))

(define (emit-binding-target name)
  (cond
    [(emit-destructure name) => values]
    [(symbol? name) (mangle-name name)]
    [else (error 'beagle-js "unsupported binding target: ~v" name)]))

;; Emit the JS const-binding statement(s) for one let-binding target, given
;; the already-emitted value string. Returns a LIST of statement strings.
;; A map-destructure with an :as name binds the value to the :as name first,
;; then destructures FROM that name — so the value is evaluated exactly once
;; (matching Clojure single-eval) and the whole-map :as binding is always
;; available. Every let-emission site routes through here so the :as handling
;; can never drift between the IIFE, return-position, and statement paths.
(define (emit-let-binding-stmts target val-str)
  (define as-name (and (map-destructure? target) (map-destructure-as-name target)))
  (cond
    [as-name
     (define as-js (mangle-name as-name))
     (list (format "const ~a = ~a;" as-js val-str)
           (format "const ~a = ~a;" (emit-binding-target target) as-js))]
    [else
     (list (format "const ~a = ~a;" (emit-binding-target target) val-str))]))

(define (expr-contains-recur? e)
  (cond
    [(recur-form? e) #t]
    [(if-form? e)
     (or (expr-contains-recur? (if-form-then-expr e))
         (and (if-form-else-expr e) (expr-contains-recur? (if-form-else-expr e))))]
    [(let-form? e)
     (body-contains-recur? (let-form-body e))]
    [(do-form? e)
     (body-contains-recur? (do-form-body e))]
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
       ;; No else (e.g. from `when`): falling through the condition means no
       ;; recur fired, so the loop is done — return nil. Without this the
       ;; enclosing `while (true)` spins forever when the condition goes false.
       (format "if (~a) { ~a } else { return null; }" cond-str then-str))]
    [(and (let-form? e) (body-contains-recur? (let-form-body e)))
     (define let-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) (let-form-bindings e))))
     (define binding-strs
       (apply append
         (for/list ([b (in-list (let-form-bindings e))])
           (emit-let-binding-stmts (let-binding-name b) (await-async-iife (emit-expr (let-binding-value b)))))))
     (with-bindings let-names
       (lambda ()
         ;; Only the tail form drives the loop (recur/return); earlier forms are
         ;; side-effecting statements. Running emit-loop-stmt over all of them
         ;; would `return` a non-tail expression and make the recur unreachable.
         (define forms (let-form-body e))
         (define body-str
           (string-append
             (string-join (map emit-expr-stmt (drop-right forms 1)) " ")
             (if (> (length forms) 1) " " "")
             (emit-loop-stmt (last forms) bind-names)))
         (string-append (string-join binding-strs " ") " " body-str)))]
    [(and (cond-form? e) (for/or ([c (in-list (cond-form-clauses e))]) (body-contains-recur? (cond-clause-body c))))
     (define (else-clause? c)
       (let ([t (cond-clause-test c)]) (and (symbol? t) (or (eq? t ':else) (eq? t 'else)))))
     (define (loop-body-seq forms)
       (string-append
         (string-join (map emit-expr-stmt (drop-right forms 1)) " ")
         (if (> (length forms) 1) " " "")
         (emit-loop-stmt (last forms) bind-names)))
     (define parts
       (for/list ([c (in-list (cond-form-clauses e))])
         (define test (cond-clause-test c))
         (define body-str (loop-body-seq (cond-clause-body c)))
         (if (else-clause? c)
           (format "{ ~a }" body-str)
           (format "if (~a) { ~a }" (emit-expr test) body-str))))
     ;; No :else means no clause may match — terminate the loop with nil rather
     ;; than spinning the enclosing while(true).
     (define has-else? (for/or ([c (in-list (cond-form-clauses e))]) (else-clause? c)))
     (string-append (string-join parts " else ")
                    (if has-else? "" " else { return null; }"))]
    [(and (do-form? e) (body-contains-recur? (do-form-body e)))
     (define exprs (do-form-body e))
     (define stmts (drop-right exprs 1))
     (define last-e (last exprs))
     (define side-strs (map emit-expr-stmt stmts))
     (format "~a ~a" (string-join side-strs " ") (emit-loop-stmt last-e bind-names))]
    [(recur-form? e)
     (emit-recur-stmts e bind-names)]
    [else
     (format "return ~a;" (emit-expr e))]))

;; Emit a single expression as the last (returned) thing in a function body.
;; Inlines let/do/when/when-let/if-let/if to avoid unnecessary IIFEs.
(define (emit-return-position e indent)
  (cond
    [(let-form? e)
     (define bindings (let-form-bindings e))
     (define body (let-form-body e))
     (define let-names (apply append
       (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define shadows? (for/or ([n (in-list let-names)])
                        (set-member? (current-js-inline-scope) n)))
     (if shadows?
       (format "return ~a;" (emit-expr e))
       (let ()
         (define-values (bind-strs _)
           (for/fold ([strs '()] [bound (current-js-bound)])
                     ([b (in-list bindings)])
             (define val-str (await-async-iife
                               (parameterize ([current-js-bound bound])
                                 (emit-expr (let-binding-value b)))))
             (define stmts (emit-let-binding-stmts (let-binding-name b) val-str))
             (define new-names (names-from-binding-target (let-binding-name b)))
             (values (append strs stmts)
                     (set-union bound (list->set new-names)))))
         (with-bindings let-names
           (lambda ()
             (parameterize ([current-js-inline-scope
                             (set-union (current-js-inline-scope) (list->set let-names))])
               (string-append
                (string-join bind-strs (string-append "\n" indent))
                "\n" indent
                (emit-body-return body indent)))))))]
    [(do-form? e)
     (emit-body-return (do-form-body e) indent)]
    [(doseq-form? e)
     ;; doseq is a side-effecting statement (value is nil). Emit it as a
     ;; statement, not `return <doseq>` — the for-of variant is a statement
     ;; and can't be returned, and the forEach variant's value is undefined
     ;; anyway, so the function falls through to an implicit undefined return.
     (emit-doseq e)]
    [(when-form? e)
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a}"
             (emit-expr (when-form-cond-expr e))
             inner
             (emit-body-return (when-form-body e) inner)
             indent)]
    [(when-let-form? e)
     (define val-str (emit-expr (when-let-form-expr e)))
     (define name (mangle-name (when-let-form-name e)))
     (define inner (string-append indent "  "))
     (with-bindings (list (when-let-form-name e))
       (lambda ()
         (format "const ~a = ~a;\n~aif (~a != null) {\n~a~a\n~a}"
                 name val-str
                 indent name
                 inner
                 (emit-body-return (when-let-form-body e) inner)
                 indent)))]
    [(when-some-form? e)
     (define val-str (emit-expr (when-some-form-expr e)))
     (define name (mangle-name (when-some-form-name e)))
     (define inner (string-append indent "  "))
     (with-bindings (list (when-some-form-name e))
       (lambda ()
         (format "const ~a = ~a;\n~aif (~a != null) {\n~a~a\n~a}"
                 name val-str
                 indent name
                 inner
                 (emit-body-return (when-some-form-body e) inner)
                 indent)))]
    [(if-let-form? e)
     (define val-str (emit-expr (if-let-form-expr e)))
     (define name (mangle-name (if-let-form-name e)))
     (define inner (string-append indent "  "))
     (with-bindings (list (if-let-form-name e))
       (lambda ()
         (define then-str (emit-return-position (if-let-form-then-body e) inner))
         (define else-str (if (if-let-form-else-body e)
                            (emit-return-position (if-let-form-else-body e) inner)
                            (format "return null;")))
         (format "const ~a = ~a;\n~aif (~a != null) {\n~a~a\n~a} else {\n~a~a\n~a}"
                 name val-str
                 indent name
                 inner then-str
                 indent
                 inner else-str
                 indent)))]
    [(if-some-form? e)
     (define val-str (emit-expr (if-some-form-expr e)))
     (define name (mangle-name (if-some-form-name e)))
     (define inner (string-append indent "  "))
     (with-bindings (list (if-some-form-name e))
       (lambda ()
         (define then-str (emit-return-position (if-some-form-then-body e) inner))
         (define else-str (emit-return-position (if-some-form-else-body e) inner))
         (format "const ~a = ~a;\n~aif (~a != null) {\n~a~a\n~a} else {\n~a~a\n~a}"
                 name val-str
                 indent name
                 inner then-str
                 indent
                 inner else-str
                 indent)))]
    [(and (if-form? e) (not (if-form-else-expr e)))
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a}"
             (emit-expr (if-form-cond-expr e))
             inner (emit-return-position (if-form-then-expr e) inner)
             indent)]
    [(and (if-form? e) (if-form-else-expr e)
          (or (stmt-inline? (if-form-then-expr e))
              (stmt-inline? (if-form-else-expr e))
              (and (if-form? (if-form-then-expr e))
                   (not (if-form-else-expr (if-form-then-expr e))))
              (and (if-form? (if-form-else-expr e))
                   (not (if-form-else-expr (if-form-else-expr e))))))
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a} else {\n~a~a\n~a}"
             (emit-expr (if-form-cond-expr e))
             inner (emit-return-position (if-form-then-expr e) inner)
             indent
             inner (emit-return-position (if-form-else-expr e) inner)
             indent)]
    [else
     (format "return ~a;" (emit-expr e))]))

;; Does this expression benefit from statement-position inlining?
(define (stmt-inline? e)
  (or (let-form? e) (do-form? e) (when-form? e) (when-let-form? e)
      (doseq-form? e)
      (when-some-form? e) (if-let-form? e) (if-some-form? e)
      (and (if-form? e) (not (if-form-else-expr e)))
      (and (if-form? e) (if-form-else-expr e)
           (or (stmt-inline? (if-form-then-expr e))
               (stmt-inline? (if-form-else-expr e))))))

;; Emit a non-final expression as a statement (no return), inlining where possible.
(define (emit-stmt-inline e indent)
  (cond
    [(let-form? e)
     (define bindings (let-form-bindings e))
     (define body (let-form-body e))
     (define let-names (apply append
       (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define shadows? (for/or ([n (in-list let-names)])
                        (set-member? (current-js-inline-scope) n)))
     (if shadows?
       (emit-expr-stmt e)
       (let ()
         (define-values (bind-strs _)
           (for/fold ([strs '()] [bound (current-js-bound)])
                     ([b (in-list bindings)])
             (define val-str (await-async-iife
                               (parameterize ([current-js-bound bound])
                                 (emit-expr (let-binding-value b)))))
             (define stmts (emit-let-binding-stmts (let-binding-name b) val-str))
             (define new-names (names-from-binding-target (let-binding-name b)))
             (values (append strs stmts)
                     (set-union bound (list->set new-names)))))
         (with-bindings let-names
           (lambda ()
             (parameterize ([current-js-inline-scope
                             (set-union (current-js-inline-scope) (list->set let-names))])
               (string-append
                (string-join bind-strs (string-append "\n" indent))
                "\n" indent
                (emit-body-stmts body indent)))))))]
    [(do-form? e)
     (emit-body-stmts (do-form-body e) indent)]
    [(when-form? e)
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a}"
             (emit-expr (when-form-cond-expr e))
             inner
             (emit-body-stmts (when-form-body e) inner)
             indent)]
    [(when-let-form? e)
     (define val-str (emit-expr (when-let-form-expr e)))
     (define name (mangle-name (when-let-form-name e)))
     (define inner (string-append indent "  "))
     (with-bindings (list (when-let-form-name e))
       (lambda ()
         (format "const ~a = ~a;\n~aif (~a != null) {\n~a~a\n~a}"
                 name val-str
                 indent name
                 inner
                 (emit-body-stmts (when-let-form-body e) inner)
                 indent)))]
    [(and (if-form? e) (not (if-form-else-expr e)))
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a}"
             (emit-expr (if-form-cond-expr e))
             inner
             (emit-body-stmts-inline (list (if-form-then-expr e)) inner)
             indent)]
    [else
     (emit-expr-stmt e)]))

(define (emit-body-stmts-inline exprs indent)
  (string-join (map (lambda (e) (emit-stmt-inline e indent)) exprs)
               (string-append "\n" indent)))

(define (emit-body-return exprs indent)
  (cond
    [(null? exprs) ""]
    [(= (length exprs) 1)
     (emit-return-position (car exprs) indent)]
    [else
     (define stmts (take exprs (- (length exprs) 1)))
     (define last-e (last exprs))
     (string-append
      (string-join (map (lambda (e) (emit-stmt-inline e indent)) stmts) (string-append "\n" indent))
      (string-append "\n" indent)
      (emit-return-position last-e indent))]))

(define (emit-body-stmts exprs indent)
  (string-join (map (lambda (e) (emit-expr-stmt e)) exprs)
               (string-append "\n" indent)))

;; --- block string -----------------------------------------------------------

(define (emit-js-block-string text)
  (~v text))


;; Wire up emit-expr parameter for extracted modules
(current-emit-expr emit-expr)

;; --- registration ----------------------------------------------------------

(define js-backend
  (emitter-backend 'js js-emit-program))

(register-backend! 'js js-backend)

(provide js-backend)
