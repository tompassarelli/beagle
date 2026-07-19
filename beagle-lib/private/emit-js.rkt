#lang racket/base

;; JavaScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/list
         racket/set
         "types.rkt"          ; type-prim?/type-prim-name for scalar-=== dispatch
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
  ;; PROPERTY position: char-mangle only, never the reserved-word `$` suffix
  ;; (`:delete` -> `delete`, not `delete$`). Store + read both funnel here so
  ;; the map/record property spelling stays internally consistent.
  (mangle-chars (substring s 1)))

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
    [(count)
     (if (= n 1)
       (let ([coll (car args)])
         (case (classify-rep coll)
           [(hmap) (hamt-call "hamtMapCount" (emit-expr coll))]
           [(hset) (hamt-call "hamtSetCount" (emit-expr coll))]
           [(poly) (begin (mark-needs-v!) (use-runtime!) (format "$$bc$count(~a)" (emit-expr coll)))]
           [else
            (case (coll-kind coll)
              ;; native Set -> .size (NOT .length, which is undefined on a Set);
              ;; coll-kind sees through conj/into/disj to the underlying set.
              [(set) (format "~a.size" (emit-expr coll))]
              ;; native object (map) -> own-key count (NOT .length)
              [(map) (format "Object.keys(~a).length" (emit-expr coll))]
              ;; array/string/unknown -> .length
              [else (format "~a.length" (emit-expr coll))])]))
       #f)]
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
    [(conj) (cond
              [(< n 2) #f]
              ;; conj a NOT-provably-scalar element onto a set -> value-dedup HAMT
              ;; (coerce a native/empty/literal set target to hamtSet first).
              [(conj-hset? args)
               (tally-rep! 'hamt)
               (for/fold ([acc (emit-set-as-hamt (car args))]) ([x (in-list (cdr args))])
                 (use-hamt! "hamtSetAdd")
                 (format "hamtSetAdd(~a, ~a)" acc (emit-expr x)))]
              ;; conj scalars onto a NATIVE set -> a Set (NOT an array)
              [(eq? (coll-kind (car args)) 'set)
               (tally-rep! 'native)
               (format "new Set([...~a, ~a])"
                       (emit-expr (car args))
                       (string-join (map emit-expr (cdr args)) ", "))]
              [else (tally-rep! 'native)
                    (format "[...~a, ~a]"
                            (emit-expr (car args))
                            (string-join (map emit-expr (cdr args)) ", "))])]
    [(assoc) (cond
               [(not (and (>= n 3) (odd? n))) #f]
               ;; compound-keyed -> fold hamtMapAssoc (coerce a native coll input)
               [(assoc-hmap? args)
                (tally-rep! 'hamt)
                (let loop ([acc (emit-as-hamt-map (car args))] [kvs (cdr args)])
                  (if (< (length kvs) 2)
                      acc
                      (begin
                        (use-hamt! "hamtMapAssoc")
                        (loop (format "hamtMapAssoc(~a, ~a, ~a)"
                                      acc (emit-expr (car kvs)) (emit-expr (cadr kvs)))
                              (cddr kvs)))))]
               [else (tally-rep! 'native)
                     (format "({...~a, ~a})"
                             (emit-expr (car args))
                             (emit-kv-entries (cdr args)))])]
    [(inc) (if (= n 1) (format "(~a + 1)" (emit-expr (car args))) #f)]
    [(dec) (if (= n 1) (format "(~a - 1)" (emit-expr (car args))) #f)]
    [(abs) (if (= n 1) (format "Math.abs(~a)" (emit-expr (car args))) #f)]
    [(max) (format "Math.max(~a)" (string-join (map emit-expr args) ", "))]
    [(min) (format "Math.min(~a)" (string-join (map emit-expr args) ", "))]
    [(rand) (if (= n 0) "Math.random()" #f)]
    [(rand-int) (if (= n 1) (format "Math.floor(Math.random() * ~a)" (emit-expr (car args))) #f)]
    [(vec) (if (= n 1) (format "Array.from(~a)" (emit-expr (car args))) #f)]
    [(set) (cond
             [(not (= n 1)) #f]
             ;; compound elements -> value-keyed HAMT set (value dedup)
             [(set-hset? args) (tally-rep! 'hamt) (hamt-call "hamtSet" (emit-expr (car args)))]
             [else (tally-rep! 'native) (format "new Set(~a)" (emit-expr (car args)))])]
    ;; value-semantic membership: routes to runtime $$bc$contains, which
    ;; dispatches on coll type per Clojure contains? — Set: equiv-membership
    ;; (not reference Set.has); Array: valid-index; object/map: key present.
    ;; (Compound map keys by value are the P3 representation gap.)
    [(contains?)
     (if (= n 2)
       (case (classify-rep (car args))
         ;; known-HAMT -> monomorphic O(log n) op; native/poly -> $$bc$contains
         ;; (now polymorphic over native + HAMT).
         [(hmap) (hamt-call "hamtMapHas" (emit-expr (car args)) (emit-expr (cadr args)))]
         [(hset) (hamt-call "hamtSetHas" (emit-expr (car args)) (emit-expr (cadr args)))]
         [else (begin (mark-needs-v-if-hamtish! (car args)) (use-runtime!)
                      (format "$$bc$contains(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args))))])
       #f)]
    [(keys) (if (= n 1)
                (case (classify-rep (car args))
                  [(hmap) (hamt-call "hamtMapKeys" (emit-expr (car args)))]
                  [(poly) (begin (mark-needs-v!) (use-runtime!) (format "$$bc$keys(~a)" (emit-expr (car args))))]
                  [else (format "Object.keys(~a)" (emit-expr (car args)))])
                #f)]
    [(vals) (if (= n 1)
                (case (classify-rep (car args))
                  [(hmap) (hamt-call "hamtMapVals" (emit-expr (car args)))]
                  [(poly) (begin (mark-needs-v!) (use-runtime!) (format "$$bc$vals(~a)" (emit-expr (car args))))]
                  [else (format "Object.values(~a)" (emit-expr (car args)))])
                #f)]
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
    [(into) (cond
              [(not (= n 2)) #f]
              ;; into a SET whose ELEMENTS are not provably-scalar -> fold
              ;; hamtSetAdd over xs at runtime (value dedup); coerce the target.
              [(into-hset? args)
               (use-hamt! "hamtSetAdd")
               (format "~a.reduce((_s, _x) => hamtSetAdd(_s, _x), ~a)"
                       (emit-expr (cadr args)) (emit-set-as-hamt (car args)))]
              ;; into a NATIVE set of scalars -> a Set
              [(eq? (coll-kind (car args)) 'set)
               (format "new Set([...~a, ...~a])" (emit-expr (car args)) (emit-expr (cadr args)))]
              [else (format "[...~a, ...~a]" (emit-expr (car args)) (emit-expr (cadr args)))])]
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
    [(get) (let ([crep (and (>= n 2) (classify-rep (car args)))])
             (cond
               [(and (= n 2) (eq? crep 'hmap))
                (hamt-call "hamtMapGet" (emit-expr (car args)) (emit-expr (cadr args)))]
               [(and (= n 3) (eq? crep 'hmap))
                (hamt-call "hamtMapGet" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
               ;; poly (Any/union-typed) coll -> polymorphic $$bc$get (native + HAMT)
               [(and (= n 2) (eq? crep 'poly))
                (begin (mark-needs-v!) (use-runtime!) (format "$$bc$get(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args))))]
               [(and (= n 3) (eq? crep 'poly))
                (begin (mark-needs-v!) (use-runtime!) (format "$$bc$get(~a, ~a, ~a)"
                                              (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args))))]
               [(= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
               [(= n 3) (format "(() => { const _x = ~a, _k = ~a; return _x[_k] != null ? _x[_k] : ~a; })()"
                                (emit-expr (car args)) (emit-expr (cadr args))
                                (emit-expr (caddr args)))]
               [else #f]))]
    [(update) (if (= n 3)
                  (format "(() => { const _m = ~a, _k = ~a; return { ..._m, [_k]: ~a(_m[_k]) }; })()"
                          (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))
                  #f)]
    [(merge) (if (>= n 1)
              (format "Object.assign({}, ~a)" (string-join (map emit-expr args) ", "))
              #f)]
    [(dissoc) (cond
                [(not (= n 2)) #f]
                [(eq? (classify-rep (car args)) 'hmap)
                 (hamt-call "hamtMapDissoc" (emit-expr (car args)) (emit-expr (cadr args)))]
                [else (format "(() => { const _r = {...~a}; delete _r[~a]; return _r; })()"
                              (emit-expr (car args)) (emit-expr (cadr args)))])]
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
    [(distinct) (if (= n 1)
                    (begin
                      ;; distinct over elements that could be HAMTs needs distinct_equivV
                      (when (memq (type-read-rep (seq-elem-type (arg-type (car args)))) '(hmap hset poly))
                        (mark-needs-v!))
                      (use-runtime!) (format "$$bc$distinct_equiv(~a)" (emit-expr (car args))))
                    #f)]
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
    [(frequencies)
     (cond
       [(not (= n 1)) #f]
       ;; compound elements -> value-keyed hamtMap (native object keys collide).
       [(not (eq? (key-class (seq-elem-type (arg-type (car args)))) 'native))
        (use-hamt! "hamtMap") (use-hamt! "hamtMapAssoc") (use-hamt! "hamtMapGet")
        (format "~a.reduce((_m, _x) => hamtMapAssoc(_m, _x, hamtMapGet(_m, _x, 0) + 1), hamtMap())"
                (emit-expr (car args)))]
       [else (format "~a.reduce((m, x) => (m[x] = (m[x] || 0) + 1, m), {})"
                     (emit-expr (car args)))])]
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
    [(disj)        (cond
                     [(< n 2) #f]
                     [(eq? (classify-rep (car args)) 'hset)
                      (for/fold ([acc (emit-expr (car args))]) ([x (in-list (cdr args))])
                        (use-hamt! "hamtSetDisjoin")
                        (format "hamtSetDisjoin(~a, ~a)" acc (emit-expr x)))]
                     [else (runtime-call "disj" args)])]
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

;; --- type-based scalar equality optimization (P3) ---------------------------
;; A type is ===-safe iff its core.js value-equality (equiv) coincides with JS
;; ===.  ===-SAFE: Int + integer widths, String, Bool, Keyword (emits as a bare
;; string).  EXCLUDED by design:
;;   - Nil: equiv(null,undefined)=true but null===undefined=false; Beagle nil has
;;     two runtime reps (null AND undefined), so === would mis-compare.
;;   - Float/F32: NaN===NaN is false (equiv(NaN,NaN) too — they only coincide);
;;     excluded to avoid relying on coincidence (float = is rare).
;;   - Any / type vars / unions / functions / parametric (Vec/Map/Set/List): structural.
;; DEFAULT-TO-EQUIV: any type off this closed allowlist, and any operand with a
;; missing/#f type-table entry, falls back to $$bc$equiv. Nothing uncertain is ===.
(define SCALAR-EQ-SAFE-PRIMS
  '(Int U8 U16 U32 U64 I8 I16 I32 String Bool Keyword))
(define (scalar-eq-safe-type? ty)
  (and (type-prim? ty)
       (and (memq (unqualify-type-name (type-prim-name ty)) SCALAR-EQ-SAFE-PRIMS) #t)))
;; Both operands provably ===-safe scalar? Looks up each AST node in the per-node
;; type table (ast.rkt current-type-table, bound during emit to program-type-table).
;; #f when the table is #f (capture not requested) or either node is absent/non-
;; scalar — conservative default-to-equiv. Bare literals (5,"x",true) are NOT keyed
;; (store-type! excludes interned leaves), so (= 5 5) stays equiv; correct, just an
;; unoptimized micro-case (no unsound syntactic literal fast-path).
(define (both-scalar-eq-safe? node-a node-b)
  (define tbl (current-type-table))
  (and tbl
       (scalar-eq-safe-type? (hash-ref tbl node-a #f))
       (scalar-eq-safe-type? (hash-ref tbl node-b #f))))

;; --- P3 representation selection (native vs HAMT persistent) ----------------
;;
;; A map keyed by a COMPOUND value, or a set of compound values built by
;; dedup, has NO sound native-JS representation: object keys stringify to
;; "[object Object]" (distinct-but-equiv keys collide; an absent key "hits");
;; `new Set` dedups by reference (value-equal elements both survive). Such a
;; value must be a value-keyed HAMT (lib/beagle/hamt.js, $$bc-backed identity).
;;
;; CLASSIFIER (sound, PROVABLY-COMPOUND -> persistent):
;;   - HAMT iff the key (map) / element (set) type is a CONCRETE compound ctor
;;     (Map/Set/Vec/List). Scalar-eq-safe, Any, type-var, union, Float, Nil are
;;     NOT provably-compound -> native (today's emit, unchanged).
;;   - This is the dual of "unprovable -> persistent" applied to the
;;     CORRECTNESS driver: we promote ONLY what we can prove native cannot hold.
;;     Consequence: a HAMT value has no native equivalent of the SAME value, so
;;     a HAMT and a native collection never represent the same value -> $$bc
;;     equiv/hash need no HAMT-awareness for this ship (no cross-rep mismatch).
;;   - assoc/conj erase key/elem types to Any (stdlib sig), so an assoc-built
;;     map is classified from its KEY ARGUMENT's type (precise where the key is
;;     a literal) plus its coll input's rep (a hamt coll stays hamt). The
;;     unhelpful Any RESULT type is never consulted.
;;   - Bindings propagate: a let binding's rep is its value's rep (current-rep-env),
;;     so a read through a var (bare symbol, absent from the type table) resolves
;;     consistently — the soundness crux the per-node type table alone can't give.
;;
;; SCOPE (intraprocedural): a HAMT passed to a function arg typed non-compound
;; is read native inside the callee (documented boundary; not exercised by the
;; conformance gate, which is local). Polymorphic $$bc fallback + assoc key-type
;; preservation are the fraction-native follow-ups.

(define COMPOUND-CTORS '(Map Set Vec Vector List))

(define (provably-compound-type? ty)
  (and (type-app? ty) (and (memq (type-app-ctor ty) COMPOUND-CTORS) #t)))

(define (node-type node)
  (define tbl (current-type-table))
  (and tbl (hash-ref tbl node #f)))

(define (map-type? ty) (and (type-app? ty) (eq? (type-app-ctor ty) 'Map)))
(define (set-type? ty) (and (type-app? ty) (eq? (type-app-ctor ty) 'Set)))

;; (Map K V) -> K ; else #f
(define (map-key-type ty)
  (and (map-type? ty) (pair? (type-app-args ty)) (car (type-app-args ty))))

;; (Vec E)/(List E)/(Set E) -> E ; else #f
(define (seq-elem-type ty)
  (and (type-app? ty) (memq (type-app-ctor ty) '(Vec Vector List Set))
       (pair? (type-app-args ty)) (car (type-app-args ty))))

;; binding-name -> rep tag (set at let/param scopes); default 'native
(define current-rep-env (make-parameter (hasheq)))
(define (rep-of-binding sym) (hash-ref (current-rep-env) sym 'native))

;; binding-name -> declared/inferred TYPE (set at let/param scopes). Resolves the
;; var-ref type gap: a bare symbol is excluded from the per-node type table
;; (interned-leaf), so a var used as a key/elem arg has no node-type — this env
;; supplies it from the param `:-` annotation or the let value's inferred type.
(define current-type-env (make-parameter (hasheq)))
(define (type-of-binding sym) (hash-ref (current-type-env) sym #f))

;; Type of an argument NODE. Scalar LITERALS are interned leaves excluded from the
;; per-node type table, so resolve them by datum form (a keyword literal `:b` is a
;; keyword-SYMBOL — it must NOT be mistaken for a var-ref); a var-ref resolves
;; through the type-env; anything else through the per-node table.
(define (arg-type node)
  (cond
    [(keyword-symbol? node) (type-prim 'Keyword)]
    [(exact-integer? node)  (type-prim 'Int)]
    [(string? node)         (type-prim 'String)]
    [(boolean? node)        (type-prim 'Bool)]
    [(quoted? node)         (arg-type (quoted-datum node))] ; '(quote :b) keys by the datum
    [(symbol? node)         (type-of-binding node)]
    [else                   (node-type node)]))

;; A record TYPE (defrecord / defunion-member / deferror-member with fields)
;; emits as a JS object, so as a map key / set element it collides on
;; "[object Object]" — it needs the HAMT, exactly like a compound ctor.
(define (record-type? t)
  (and (type-prim? t)
       (let ([rf (current-js-record-fields)])
         (and rf (hash-has-key? rf (unqualify-type-name (type-prim-name t))) #t))))

;; REP CLASS of a key/element TYPE — the heart of rep-selection:
;;   'native : scalar-eq-safe (Int/widths/String/Bool/Keyword) -> sound native JS key.
;;   'hamt   : PROVABLY object-emitting compound (Map/Set/Vec/List ctor OR a record),
;;             with no scalar subtype -> a value of this type is ALWAYS a HAMT.
;;   'poly   : Any / type-var / union / Float / Nil / unknown -> the runtime value
;;             could be EITHER rep (Any is a BIDIRECTIONAL wildcard in the type
;;             system — a native scalar map <: (Map Any V)), so reads must go through
;;             the polymorphic $$bc$* primitives; production stores by value (HAMT).
(define (key-class t)
  (cond
    [(scalar-eq-safe-type? t) 'native]
    [(or (provably-compound-type? t) (record-type? t)) 'hamt]
    [else 'poly]))   ; Any, type-var, union, Float, Nil, #f

;; READ rep to assume for a value of collection TYPE t: 'native | 'hmap | 'hset | 'poly.
(define (type-read-rep t)
  (cond
    [(map-type? t) (case (key-class (map-key-type t)) [(native) 'native] [(hamt) 'hmap] [else 'poly])]
    [(set-type? t) (case (key-class (seq-elem-type t)) [(native) 'native] [(hamt) 'hset] [else 'poly])]
    [(and (type-app? t) (memq (type-app-ctor t) '(Vec Vector List))) 'native] ; vectors are native arrays
    [(or (any-type? t) (type-var? t) (type-union? t) (not t)) 'poly] ; unknown collection kind
    [else 'native]))                                                  ; scalar/string/non-collection

;; Classify a NODE's collection representation: 'hmap | 'hset | 'native | 'poly.
;; PRODUCTION sites (literals / set / assoc / conj) only ever see hmap/hset/native
;; (a producer has a concrete structure). READ sites (get/contains/count/...) may
;; also see 'poly (an Any/union-typed var or call) -> route to the polymorphic
;; $$bc$* read. Layers: (1) var-ref -> rep-env, else its declared type's read-rep;
;; (2) a producer's structural rep (scalar key -> native, else -> HAMT); (3) any
;; other typed expr -> its type's read-rep.
(define (classify-rep e)
  (cond
    [(symbol? e)
     (define re (rep-of-binding e))
     (if (eq? re 'native) (type-read-rep (type-of-binding e)) re)]
    [(and (map-form? e) (null? (map-form-pairs e))) 'native] ; empty map: assoc coerces if upgraded
    [(set-form? e) 'native]             ; set LITERAL: distinct by construction; $$bc handles it
    [(map-form? e)
     ;; Classify a LITERAL by its actual KEY DATA (per pair), NOT the node-type —
     ;; a nested literal (e.g. a map built inside a `.map` arrow) may have no
     ;; captured node-type; its keys are still right there. All keys scalar ->
     ;; native; any non-scalar key -> hmap (store by value).
     (if (for/and ([p (in-list (map-form-pairs e))])
           (eq? (key-class (arg-type (car p))) 'native))
         'native 'hmap)]
    [(call-form? e)
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (case fn
       [(assoc assoc!) (if (assoc-hmap? args) 'hmap 'native)]
       [(set) (if (set-hset? args) 'hset 'native)]
       [(conj) (if (conj-hset? args) 'hset 'native)]
       [(into) (if (into-hset? args) 'hset 'native)]
       [(disj dissoc update merge into-map) (classify-rep (and (pair? args) (car args)))]
       [else (type-read-rep (node-type e))])]  ; non-producer call -> its return type's read-rep
    [else (type-read-rep (node-type e))]))

;; An assoc yields a HAMT map iff its coll is already one OR any key arg is NOT
;; provably-scalar (compound / record / Any / union -> store by value). The coll
;; being 'poly does NOT force HAMT here (assoc on an Any-typed coll is the deeper
;; poly-PRODUCTION boundary — needs a $$bc COW producer; documented, rarer).
(define (assoc-hmap? args)
  (and (pair? args)
       (or (eq? (classify-rep (car args)) 'hmap)
           (any-key-arg-nonscalar? args))))

;; (set X) builds a value-deduped HAMT set iff X's element type is NOT provably-
;; scalar (compound / record / Any / union). Native `new Set` ref-dedups, so any
;; non-scalar element needs value-dedup; Any is included (safe — dedups by value
;; regardless of the runtime element). arg-type resolves a var X via the type-env.
(define (set-hset? args)
  (and (pair? args)
       (let ([et (seq-elem-type (arg-type (car args)))])
         (and et (not (eq? (key-class et) 'native)) #t))))

;; assoc key args sit at odd indices (coll k0 v0 k1 v1 ...): any NOT provably-scalar?
;; arg-type resolves a var key through the type-env (params/let).
(define (any-key-arg-nonscalar? args)
  (and (pair? args)
       (let loop ([rest (cdr args)])
         (cond
           [(null? rest) #f]
           [(not (eq? (key-class (arg-type (car rest))) 'native)) #t]
           [(or (null? (cdr rest)) (null? (cddr rest))) #f]
           [else (loop (cddr rest))]))))

;; Collection KIND of a node — for builder dispatch (conj/into pick set vs vec vs
;; map semantics, which classify-rep's rep tag alone doesn't distinguish: a native
;; Set and a native vector are both 'native). 'set | 'vec | 'map | 'unknown.
(define (coll-kind node)
  (cond
    [(set-form? node) 'set]
    [(vec-form? node) 'vec]
    [(map-form? node) 'map]
    [(and (call-form? node) (memq (call-form-fn node) '(set hash-set sorted-set))) 'set]
    [(and (call-form? node) (memq (call-form-fn node) '(vector vec list cons))) 'vec]
    [(and (call-form? node) (memq (call-form-fn node) '(hash-map sorted-map zipmap frequencies group-by))) 'map]
    ;; conj/into/disj preserve the KIND of their collection argument
    [(and (call-form? node) (memq (call-form-fn node) '(conj into disj))
          (pair? (call-form-args node)))
     (coll-kind (car (call-form-args node)))]
    [else (let ([t (arg-type node)])
            (cond [(set-type? t) 'set]
                  [(map-type? t) 'map]
                  [(and (type-app? t) (memq (type-app-ctor t) '(Vec Vector List))) 'vec]
                  [else 'unknown]))]))

;; conj/into onto a SET produce a value-deduped HAMT set iff the ELEMENT being
;; added is not provably-scalar (records/compound/Any) OR the target is already a
;; HAMT set. Routes on the ELEMENT TYPE, not the target's rep — an empty `#{}` or
;; a native/compound set LITERAL target classifies native, but `(into #{} compound)`
;; / `(conj #{} compound)` must still value-dedup. (Native `new Set` ref-dedups.)
(define (conj-hset? args)   ; (conj coll x ...)
  (and (pair? args)
       (eq? (coll-kind (car args)) 'set)
       (or (eq? (classify-rep (car args)) 'hset)
           (for/or ([x (in-list (cdr args))]) (not (eq? (key-class (arg-type x)) 'native))))))
(define (into-hset? args)   ; (into target xs)
  (and (>= (length args) 2)
       (eq? (coll-kind (car args)) 'set)
       (or (eq? (classify-rep (car args)) 'hset)
           (let ([et (seq-elem-type (arg-type (cadr args)))])
             (and et (not (eq? (key-class et) 'native)))))))

;; Emit a SET target as a hamtSet: pass through if it already is one, else coerce
;; its elements (a native Set / set literal is iterable -> hamtSet(<it>)).
(define (emit-set-as-hamt target)
  (if (eq? (classify-rep target) 'hset)
      (emit-expr target)
      (begin (use-hamt! "hamtSet") (format "hamtSet(~a)" (emit-expr target)))))

;; --- HAMT op import tracking (tree-shakeable named imports) -----------------
;; Mirrors needs-runtime?: a mutable set of hamt.js export names actually emitted,
;; so the module header imports ONLY those (esbuild drops the rest).
(define hamt-ops-used (make-parameter #f))
(define (use-hamt! name)
  (define t (hamt-ops-used))
  (when t (hash-set! t name #t))
  (mark-needs-v!)        ; an in-module HAMT value will reach equiv/hash/etc.
  name)

;; LITE/FULL $$bc selection (size leg): a box, true iff this module could feed a
;; HAMT value to a value-op (=/contains/distinct/get/...). When FALSE the module
;; imports the LITE equiv/hash/contains/distinct_equiv (no HAMT branch -> esbuild
;; drops the HAMT comparison helpers, recovering the native-only margin); when
;; TRUE it imports the HAMT-aware V-variants. Set at: any HAMT production
;; (use-hamt!), any POLY value-op (poly =/contains/distinct/get/keys/vals/count).
;; A pure-native program (scalar + concrete-native compound, e.g. values/change)
;; never trips it -> lite.
(define bc-needs-v? (make-parameter #f))   ; #f, or a box
(define (mark-needs-v!) (let ([b (bc-needs-v?)]) (when b (set-box! b #t))))
;; Mark needs-V if a node's collection rep could be a HAMT (hmap/hset) or is
;; polymorphic (Any/union -> a HAMT may flow in at runtime).
(define (mark-needs-v-if-hamtish! node)
  (when (memq (classify-rep node) '(hmap hset poly)) (mark-needs-v!)))

;; Emit a HAMT op call, recording the op for the import set.
(define (hamt-call op . arg-strs)
  (use-hamt! op)
  (format "~a(~a)" op (string-join arg-strs ", ")))

;; Emit a coll node already known to need HAMT-map rep: pass through if it is
;; one, else coerce a native object's entries (empty {} -> empty hamtMap).
(define (emit-as-hamt-map coll-node)
  (if (eq? (classify-rep coll-node) 'hmap)
      (emit-expr coll-node)
      ;; asHamtMap is idempotent: a value that is ALREADY a hamt at runtime (e.g.
      ;; a loop var seeded native {} but reassigned by assoc) passes through, so
      ;; we never run Object.entries() on a hamt (which would surface its struct
      ;; fields instead of its entries and silently drop all prior keys).
      (begin (use-hamt! "asHamtMap")
             (format "asHamtMap(~a)" (emit-expr coll-node)))))

;; --- PHASE D: static per-alloc-site rep metric (fraction-native) ------------
;; OPT-IN (BEAGLE_REP_METRIC=1): when set, js-emit-program threads a counter and
;; every collection ALLOCATION site (literal map/set/vec + set/assoc/conj
;; constructors) tallies native-vs-HAMT, emitting a `// collection-rep: N/M
;; native (P%)` header. Off by default so normal output is byte-unchanged.
(define rep-metric? (and (getenv "BEAGLE_REP_METRIC") #t))
(define rep-counts (make-parameter #f))  ; mutable hasheq 'native/'hamt -> count, or #f
(define (tally-rep! kind)
  (define t (rep-counts))
  (when t (hash-update! t kind add1 0)))

;; --- runtime import tracking -----------------------------------------------

(define needs-runtime? (make-parameter #f))

(define (use-runtime!)
  (needs-runtime? #t))

;; Convenience: mark runtime as needed and emit a call to one of the
;; functions exported by beagle/core.js.
;;   (runtime-call "range" args) => "$$bc$range(arg1, arg2, ...)"
(define (runtime-call js-name args)
  (use-runtime!)
  (format "$$bc$~a(~a)" js-name (string-join (map emit-expr args) ", ")))

;; --- binding environment (for value-position wrapper resolution) -----------

(define current-js-bound (make-parameter (set)))

(define (js-bound? sym)
  (set-member? (current-js-bound) sym))

(define (with-bindings syms thunk)
  (parameterize ([current-js-bound (set-union (current-js-bound) (list->set syms))])
    (thunk)))

;; Seed the rep-selection envs from a param list (typed `:-` params): a param's
;; declared type populates current-type-env (so var key/elem args resolve) and,
;; when the type is a compound-keyed map / compound-elem set, current-rep-env (so
;; reads through the param route to HAMT ops). Composes with with-bindings.
(define (with-param-envs params thunk)
  (define-values (te re)
    (for/fold ([te (current-type-env)] [re (current-rep-env)])
              ([p (in-list params)])
      (if (and (param? p) (param-type p))
          (let* ([nm (param-name p)] [ty (param-type p)] [rep (type-read-rep ty)])
            (values (hash-set te nm ty)
                    (if (eq? rep 'native) re (hash-set re nm rep))))
          (values te re))))
  (parameterize ([current-type-env te] [current-rep-env re])
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

;; Base path for beagle's JS runtime modules. The emit imports 'beagle/core.js'
;; (and 'beagle/hamt.js' once rep-selection lands); this prefix replaces the
;; 'beagle/' so the WHOLE namespace remaps with one setting. Default 'beagle/'
;; keeps the bare specifiers that node (node_modules/beagle) + esbuild --bundle
;; resolve and tree-shake. Hosts with no resolver — Firefox chrome .sys.mjs —
;; set BEAGLE_JS_RUNTIME_PREFIX to a resolvable base (a resource:// URL or a
;; relative dir) and vendor the runtime there; one prefix covers core.js today +
;; hamt.js later, so no future HAMT-using module dangles on a bare specifier.
;; Relative/resolvable prefix is tree-shake-neutral under esbuild (headline holds).
(define js-runtime-prefix
  (or (getenv "BEAGLE_JS_RUNTIME_PREFIX") "beagle/"))

(define (js-emit-program prog)
  (validate-js-target! prog)
  (parameterize ([current-js-context 'stmt]
                 [match-counter (box 0)]
                 [current-js-record-fields (build-record-field-table prog)]
                 [current-js-record-ns (program-imported-record-ns prog)]
                 [current-js-scalar-fns (build-scalar-fns prog)]
                 [current-js-symbol-ns (program-imported-symbol-ns prog)]
                 [current-type-table (program-type-table prog)]  ; P3: per-node arg types for scalar-=== dispatch (#f when capture off)
                 [needs-runtime? #f]
                 [hamt-ops-used (make-hash)]
                 [bc-needs-v? (box #f)]
                 [rep-counts (and rep-metric? (make-hasheq))]
                 [current-js-bound (collect-top-level-names prog)])
    (define header (emit-module-header prog))
    (define body
      (string-join
       (for/list ([form (in-list (program-forms prog))])
         (emit-form form))
       "\n\n"))
    ;; PHASE D: opt-in static per-alloc-site rep metric header.
    (define rep-comment
      (let ([t (rep-counts)])
        (if t
          (let* ([nat (hash-ref t 'native 0)]
                 [ham (hash-ref t 'hamt 0)]
                 [tot (+ nat ham)]
                 [pct (if (zero? tot) 100 (round (/ (* 100.0 nat) tot)))])
            (format "// collection-rep: ~a/~a native (~a%) — ~a HAMT site(s)\n"
                    nat tot (inexact->exact pct) ham))
          "")))
    ;; LITE/FULL $$bc import (size leg): named imports of EXACTLY the core.js
    ;; functions this module emitted (scanned from the body as `$$bc$<name>`),
    ;; each aliased local `<name> as $$bc$<name>`. When the module can't feed a
    ;; HAMT to a value-op (bc-needs-v? false: pure-native), the splittable four
    ;; bind the LITE exports (no HAMT branch -> esbuild drops the HAMT comparison
    ;; helpers, recovering the native-only margin); otherwise the HAMT-aware
    ;; V-variants. Named (not namespace) imports so esbuild reliably tree-shakes.
    (define SPLITTABLE-BC '("equiv" "hash" "contains" "distinct_equiv"))
    (define used-bc
      (sort (remove-duplicates
             (regexp-match* #px"[$][$]bc[$]([a-z_]+)" body #:match-select cadr))
            string<?))
    (define needs-v (unbox (bc-needs-v?)))
    (define runtime-import
      (if (null? used-bc)
        ""
        (format "import { ~a } from '~a';\n"
                (string-join
                 (for/list ([nm (in-list used-bc)])
                   (if (and needs-v (member nm SPLITTABLE-BC))
                       (format "~aV as $$bc$~a" nm nm)
                       (format "~a as $$bc$~a" nm nm)))
                 ", ")
                (string-append js-runtime-prefix "core.js"))))
    ;; Tree-shakeable named import of ONLY the HAMT ops this module emitted.
    (define hamt-import
      (let ([ops (sort (hash-keys (hamt-ops-used)) string<?)])
        (if (null? ops)
          ""
          (format "import { ~a } from '~a';\n"
                  (string-join ops ", ")
                  (string-append js-runtime-prefix "hamt.js")))))
    (string-append rep-comment header runtime-import hamt-import "\n" body "\n")))

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
             (with-param-envs (defn-form-params f)
               (lambda ()
                 (with-bindings bound (lambda () (emit-body-return (defn-form-body f) "  "))))))]

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
         (define body (with-param-envs (arity-clause-params a)
                        (lambda ()
                          (with-bindings arity-bound (lambda () (emit-body-return (arity-clause-body a) "    "))))))
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

    ;; Top-level effect-position forms: route ctrl-flow (if/cond/when/let/do)
    ;; through the statement lowering; emit-stmt-inline falls back to
    ;; emit-expr-stmt for plain expressions, so non-ctrl-flow output is unchanged.
    [else (emit-stmt-inline f "")]))

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
    ;; Char literals lower to single-character strings in JS (no char type).
    [(char? e)          (js-string-lit (string e))]
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
     (tally-rep! 'native)  ; vectors are always native (COW arrays)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) ", "))]
    [(map-form? e)
     (cond
       ;; Compound-keyed map literal -> value-keyed HAMT (native object keys would
       ;; stringify distinct-but-equiv keys to the same "[object Object]").
       [(eq? (classify-rep e) 'hmap)
        (tally-rep! 'hamt)
        (use-hamt! "hamtMap")
        (format "hamtMap([~a])"
                (string-join
                 (map (lambda (p)
                        (format "[~a, ~a]" (emit-expr (car p)) (emit-expr (cdr p))))
                      (map-form-pairs e))
                 ", "))]
       [else
        (tally-rep! 'native)
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
                 ", "))])]
    [(set-form? e)
     (tally-rep! 'native)  ; set literal (distinct elems by construction)
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
     ;; A binding reassigned via `set!` in the body must emit `let`, not `const`.
     (define mutated-syms (collect-set!-target-syms body))
     ;; Thread the rep-env (binding-name -> 'hmap|'hset) ALONGSIDE js-bound so a
     ;; later binding's value (and the body) can classify a var-ref read of an
     ;; earlier binding consistently with how that binding's value was emitted.
     (define-values (bind-strs _ignored rep-env-out type-env-out)
       (for/fold ([strs '()]
                  [bound (current-js-bound)]
                  [rep-env (current-rep-env)]
                  [type-env (current-type-env)])
                 ([b (in-list bindings)])
         (define val-str (await-async-iife
                           (parameterize ([current-js-bound bound]
                                          [current-rep-env rep-env]
                                          [current-type-env type-env])
                             (emit-expr (let-binding-value b)))))
         (define new-names (names-from-binding-target (let-binding-name b)))
         (define mutable? (for/or ([nm (in-list new-names)]) (and (memq nm mutated-syms) #t)))
         (define stmts (emit-let-binding-stmts (let-binding-name b) val-str mutable?))
         ;; Only a single-symbol binding names the collection itself; record its
         ;; rep (when non-native) AND its type (so a native-bound var resolves to
         ;; native, not poly via a missing type — the lite/full $$bc selection
         ;; depends on this).
         (define name (let-binding-name b))
         (define bty (and (symbol? name)
                          (or (let-binding-type b) (node-type (let-binding-value b)))))
         (define rep (if (symbol? name)
                         (parameterize ([current-rep-env rep-env] [current-type-env type-env])
                           (classify-rep (let-binding-value b)))
                         'native))
         (values (append strs stmts)
                 (set-union bound (list->set new-names))
                 (if (and (symbol? name) (not (eq? rep 'native)))
                     (hash-set rep-env name rep)
                     rep-env)
                 (if bty (hash-set type-env name bty) type-env))))
     (with-bindings let-names
       (lambda ()
         (parameterize ([current-rep-env rep-env-out] [current-type-env type-env-out])
           (iife (format "~a ~a" (string-join bind-strs " ") (emit-body-return body ""))
                  #:async? has-await))))]

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
     (with-param-envs (fn-form-params e)
      (lambda ()
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
           (format "~a(~a) => { ~a }" prefix params (emit-body-return body ""))))))) ]

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
     ;; emit-doseq yields a STATEMENT (forEach/for-of). In EXPRESSION position
     ;; (a cond/if arm in return position, a let-binding value) a bare statement
     ;; splices into a ternary and emits unparseable JS — so wrap it in an IIFE
     ;; there, exactly like loop/dotimes/try. In statement position keep it bare.
     (define s (emit-doseq e))
     (if (eq? (current-js-context) 'expr)
         (iife s #:async? (contains-await? (doseq-form-body e)))
         s)]

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
     ;; (:kw m) / (get m :kw) — REP-AWARE: a scalar keyword read still hits the
     ;; HAMT when the COLLECTION is HAMT-repped (the key being scalar is a red
     ;; herring — dispatch on the COLL's rep, not the key). Native dot-access on a
     ;; hamtMap object would read `undefined`.
     (define target (kw-access-target e))
     (define prop (kw->prop (kw-access-kw e)))
     (define keystr (~v prop))
     (define default (kw-access-default e))
     (case (classify-rep target)
       [(hmap)
        (if default
            (hamt-call "hamtMapGet" (emit-expr target) keystr (emit-expr default))
            (hamt-call "hamtMapGet" (emit-expr target) keystr))]
       [(poly)
        (mark-needs-v!)
        (use-runtime!)
        (if default
            (format "$$bc$get(~a, ~a, ~a)" (emit-expr target) keystr (emit-expr default))
            (format "$$bc$get(~a, ~a)" (emit-expr target) keystr))]
       [else
        (define target-str (emit-expr target))
        (if default
            (format "(~a.~a != null ? ~a.~a : ~a)"
                    target-str prop target-str prop (emit-expr default))
            (format "~a.~a" target-str prop))])]

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
    [(binding-form? e)
     (error 'beagle-js "binding (dynamic vars) is not supported for JS target")]
    [(doto-form? e)
     (error 'beagle-js "doto is not supported for JS target")]

    [(call-form? e)
     (define fn-sym (call-form-fn e))
     (define args (call-form-args e))
     (cond
       [(and (set-member? (current-js-scalar-fns) fn-sym)
             (= 1 (length args)))
        (emit-expr (car args))]
       ;; Value-equality family routes to the runtime $$bc$equiv (Clojure =
       ;; semantics: structural, recursive over vectors/sets/maps/records).
       ;; `identical?` deliberately does NOT come here — it is reference
       ;; identity by design and stays `===` via the generic js-infix? branch
       ;; below. Variadic = matches Clojure: all consecutive pairs equal,
       ;; short-circuiting with &&. not= is `(not (apply = args))`.
       ;; P3 scalar-=== optimization: per consecutive pair, emit bare === when
       ;; BOTH operands are statically ===-safe scalars, else $$bc$equiv.
       ;; use-runtime! fires ONLY on an equiv pair, so a fully-scalar = emits no
       ;; runtime import. Variadic = = all consecutive pairs equal, joined with &&.
       ;; identical? is NOT here (stays === via the generic js-infix branch below —
       ;; reference identity by design).
       [(and (memq fn-sym '(= ==)) (>= (length args) 2))
        (define strs (map emit-expr args))
        (define pairs
          (for/list ([an (in-list args)] [bn (in-list (cdr args))]
                     [as (in-list strs)] [bs (in-list (cdr strs))])
            (if (both-scalar-eq-safe? an bn)
                (format "~a === ~a" as bs)
                (begin (mark-needs-v-if-hamtish! an) (mark-needs-v-if-hamtish! bn)
                       (use-runtime!)
                       (format "$$bc$equiv(~a, ~a)" as bs)))))
        (format "(~a)" (string-join pairs " && "))]
       ;; not= = not(all consecutive pairs equal): keep inner pairs POSITIVE
       ;; (=== or equiv) and negate the whole conjunction. Do NOT switch the
       ;; scalar branch to !== per-pair — that would change variadic semantics.
       [(and (eq? fn-sym 'not=) (>= (length args) 2))
        (define strs (map emit-expr args))
        (define pairs
          (for/list ([an (in-list args)] [bn (in-list (cdr args))]
                     [as (in-list strs)] [bs (in-list (cdr strs))])
            (if (both-scalar-eq-safe? an bn)
                (format "~a === ~a" as bs)
                (begin (mark-needs-v-if-hamtish! an) (mark-needs-v-if-hamtish! bn)
                       (use-runtime!)
                       (format "$$bc$equiv(~a, ~a)" as bs)))))
        (format "(!(~a))" (string-join pairs " && "))]
       [(and (js-infix? fn-sym) (>= (length args) 2))
        (define op (hash-ref JS-INFIX-OPS fn-sym))
        (format "(~a)" (string-join (map emit-expr args) (format " ~a " op)))]
       [(and (js-unary? fn-sym) (= 1 (length args)))
        (format "(~a~a)" (hash-ref JS-UNARY-OPS fn-sym) (emit-expr (car args)))]
       [(emit-core-call fn-sym args) => values]
       [(not (symbol? fn-sym))
        ;; higher-order call: the callee is an arbitrary expression — e.g.
        ;; ((.-newSession client)) or ((get o :k) a) — which parse.rkt emits as a
        ;; call-form with a non-symbol head. Emit (callee)(args); never run the
        ;; symbol-only mangle path below, which would `symbol->string` and crash.
        (format "(~a)(~a)"
                (emit-expr fn-sym)
                (string-join (map emit-expr args) ", "))]
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
  ;; params are BINDINGS (reserved-word-suffixed); the object KEYS are
  ;; PROPERTIES (char-mangle only). Split them so `{ delete: delete$ }`.
  (define field-params (map (compose mangle-name param-name) fields))
  (define field-props (map (compose mangle-chars symbol->string param-name) fields))
  (format "function ~a(~a) { return Object.freeze({ _tag: ~v~a }); }"
          m-str
          (string-join field-params ", ")
          (symbol->string member-name)
          (if (null? field-params) ""
              (string-append ", "
                             (string-join
                              (map (lambda (prop param) (format "~a: ~a" prop param))
                                   field-props field-params)
                              ", ")))))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-mangled (mangle-name name))
  (define accessor-prefix (mangle-str (string-downcase name-str)))
  ;; field PARAMS/accessor-name-suffix are bindings; field PROPS are property
  ;; positions. The accessor name mirrors the `<lcname>-<field>` call site,
  ;; which mangles the whole (non-reserved) symbol -> char-mangle, no `$`.
  (define field-params (map (compose mangle-name param-name) fields))
  (define field-props (map (compose mangle-chars symbol->string param-name) fields))
  ;; Keep the object shorthand `{x}` when prop == param (the common,
  ;; non-reserved case, byte-identical to before); only reserved fields need
  ;; the explicit `delete: delete$` split.
  (define field-entries
    (map (lambda (prop param)
           (if (string=? prop param) param (format "~a: ~a" prop param)))
         field-props field-params))
  (define factory
    (format "function ~a(~a) {\n  return Object.freeze({_tag: ~v, ~a});\n}"
            name-mangled
            (string-join field-params ", ")
            name-str
            (string-join field-entries ", ")))
  (define accessors
    (for/list ([prop (in-list field-props)])
      (format "function ~a_~a(r) { return r.~a; }"
              accessor-prefix prop prop)))
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
            ;; `b` is a fresh BINDING (suffixed); the read reaches a record
            ;; PROPERTY (char-mangle only) -> must match factory storage.
            (format "const ~a = ~a.~a;"
                    (mangle-name b) tmp (mangle-chars fname))))
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
;; Every bare-symbol target of a `set!` anywhere in a subtree. Descends into nested
;; fn bodies — a closure can reassign an outer let-binding, which then MUST emit as
;; `let`, not `const` (JS const throws on any reassignment, even from a closure).
;; Mirrors check.rkt's collect-markers descent; keep the two in sync if forms change.
(define (collect-set!-target-syms node)
  (define syms '())
  (define (note! s) (set! syms (cons s syms)))
  (define (walk e)
    (cond
      [(set!-form? e)
       (when (symbol? (set!-form-target e)) (note! (set!-form-target e)))
       (walk (set!-form-value e))]
      [(call-form? e) (walk (call-form-fn e)) (for-each walk (call-form-args e))]
      [(if-form? e) (walk (if-form-cond-expr e)) (walk (if-form-then-expr e))
                    (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(let-form? e) (for ([b (in-list (let-form-bindings e))]) (walk (let-binding-value b)))
                     (for-each walk (let-form-body e))]
      [(when-form? e) (walk (when-form-cond-expr e)) (for-each walk (when-form-body e))]
      [(do-form? e) (for-each walk (do-form-body e))]
      [(fn-form? e) (for-each walk (fn-form-body e))]
      [(cond-form? e) (for ([c (in-list (cond-form-clauses e))])
                        (walk (cond-clause-test c)) (for-each walk (cond-clause-body c)))]
      [(for-form? e) (for ([c (in-list (for-form-clauses e))])
                       (when (for-binding? c) (walk (for-binding-expr c))))
                     (for-each walk (for-form-body e))]
      [(doseq-form? e) (for ([c (in-list (doseq-form-clauses e))])
                         (when (for-binding? c) (walk (for-binding-expr c))))
                       (for-each walk (doseq-form-body e))]
      [(case-form? e) (walk (case-form-test e))
                      (for ([c (in-list (case-form-clauses e))]) (walk (case-clause-body c)))
                      (when (case-form-default e) (walk (case-form-default e)))]
      [(loop-form? e) (for-each walk (loop-form-body e))]
      [(match-form? e) (walk (match-form-target e))
                       (for ([c (in-list (match-form-clauses e))]) (for-each walk (match-clause-body c)))]
      [(try-form? e) (for-each walk (try-form-body e))
                     (for ([c (in-list (try-form-catches e))]) (for-each walk (catch-clause-body c)))
                     (when (try-form-finally-body e) (for-each walk (try-form-finally-body e)))]
      [(with-form? e) (walk (with-form-target e))
                      (for ([u (in-list (with-form-updates e))]) (walk (with-update-value u)))]
      [(vec-form? e) (for-each walk (vec-form-items e))]
      [(map-form? e) (for ([p (in-list (map-form-pairs e))]) (walk (car p)) (walk (cdr p)))]
      [(defn-form? e) (void)]
      [(defn-multi? e) (void)]
      [(def-form? e) (void)]
      [(pair? e) (for-each walk e)]
      [else (void)]))
  (for-each walk (if (list? node) node (list node)))
  syms)

;; mutable? — emit `let` (the binding is reassigned via set! in its scope) instead
;; of the default `const`. Without this, `(set! <bare-local> v)` compiled to
;; `const x = …; x = …;` and threw "Assignment to constant variable" at runtime.
(define (emit-let-binding-stmts target val-str [mutable? #f])
  (define kw (if mutable? "let" "const"))
  (define as-name (and (map-destructure? target) (map-destructure-as-name target)))
  (cond
    [as-name
     (define as-js (mangle-name as-name))
     (list (format "const ~a = ~a;" as-js val-str)
           (format "~a ~a = ~a;" kw (emit-binding-target target) as-js))]
    [else
     (list (format "~a ~a = ~a;" kw (emit-binding-target target) val-str))]))

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
     (define mutated-syms (collect-set!-target-syms (let-form-body e)))
     (define binding-strs
       (apply append
         (for/list ([b (in-list (let-form-bindings e))])
           (define new-names (names-from-binding-target (let-binding-name b)))
           (define mutable? (for/or ([nm (in-list new-names)]) (and (memq nm mutated-syms) #t)))
           (emit-let-binding-stmts (let-binding-name b) (await-async-iife (emit-expr (let-binding-value b))) mutable?))))
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
         (define mutated-syms (collect-set!-target-syms body))
         (define-values (bind-strs _ rep-env-out type-env-out)
           (for/fold ([strs '()] [bound (current-js-bound)]
                      [rep-env (current-rep-env)] [type-env (current-type-env)])
                     ([b (in-list bindings)])
             (define val-str (await-async-iife
                               (parameterize ([current-js-bound bound]
                                              [current-rep-env rep-env]
                                              [current-type-env type-env])
                                 (emit-expr (let-binding-value b)))))
             (define new-names (names-from-binding-target (let-binding-name b)))
             (define mutable? (for/or ([nm (in-list new-names)]) (and (memq nm mutated-syms) #t)))
             (define stmts (emit-let-binding-stmts (let-binding-name b) val-str mutable?))
             (define name (let-binding-name b))
             (define bty (and (symbol? name)
                              (or (let-binding-type b) (node-type (let-binding-value b)))))
             (define rep (if (symbol? name)
                             (parameterize ([current-rep-env rep-env] [current-type-env type-env])
                               (classify-rep (let-binding-value b)))
                             'native))
             (values (append strs stmts)
                     (set-union bound (list->set new-names))
                     (if (and (symbol? name) (not (eq? rep 'native)))
                         (hash-set rep-env name rep)
                         rep-env)
                     (if bty (hash-set type-env name bty) type-env))))
         (with-bindings let-names
           (lambda ()
             (parameterize ([current-js-inline-scope
                             (set-union (current-js-inline-scope) (list->set let-names))]
                            [current-rep-env rep-env-out]
                            [current-type-env type-env-out])
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
         (define mutated-syms (collect-set!-target-syms body))
         (define-values (bind-strs _)
           (for/fold ([strs '()] [bound (current-js-bound)])
                     ([b (in-list bindings)])
             (define val-str (await-async-iife
                               (parameterize ([current-js-bound bound])
                                 (emit-expr (let-binding-value b)))))
             (define new-names (names-from-binding-target (let-binding-name b)))
             (define mutable? (for/or ([nm (in-list new-names)]) (and (memq nm mutated-syms) #t)))
             (define stmts (emit-let-binding-stmts (let-binding-name b) val-str mutable?))
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
    ;; EFFECT position: if-WITH-else lowers to `if(c){...}else{...}`. Value/tail
    ;; positions keep the ternary (emit-expr-core / emit-return-position). Both
    ;; branches recurse through emit-body-stmts-inline so nested ctrl-flow lowers.
    [(if-form? e)
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a} else {\n~a~a\n~a}"
             (emit-expr (if-form-cond-expr e))
             inner (emit-body-stmts-inline (list (if-form-then-expr e)) inner) indent
             inner (emit-body-stmts-inline (list (if-form-else-expr e)) inner) indent)]
    ;; EFFECT position: cond lowers to an if / else-if / else chain. No trailing
    ;; `else { return null; }` — a statement context needs no value fallthrough.
    [(cond-form? e)
     (define inner (string-append indent "  "))
     (define (else-clause? c)
       (let ([t (cond-clause-test c)]) (and (symbol? t) (or (eq? t ':else) (eq? t 'else)))))
     (define parts
       (for/list ([c (in-list (cond-form-clauses e))])
         (define body-str (emit-body-stmts-inline (cond-clause-body c) inner))
         (if (else-clause? c)
           (format "{\n~a~a\n~a}" inner body-str indent)
           (format "if (~a) {\n~a~a\n~a}"
                   (emit-expr (cond-clause-test c)) inner body-str indent))))
     (string-join parts " else ")]
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

;; Statement-context body: each form routes through emit-stmt-inline so
;; effect-position ctrl-flow (if/cond/when/let/do) lowers to idiomatic
;; statements recursively, instead of value-position ternary/IIFE.
(define (emit-body-stmts exprs indent)
  (string-join (map (lambda (e) (emit-stmt-inline e indent)) exprs)
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
