#lang racket/base

;; JavaScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/list
         racket/set
         "types.rkt"          ; type-prim?/type-prim-name for scalar-=== dispatch
         "parse.rkt"
         "module-interface.rkt"
         "emit-dispatch.rkt"
         "js-capabilities.rkt"
         "js-emit-utils.rkt"
         "emit-jst.rkt"
         "emit-js-quote.rkt")

(define current-js-semantic-contracts (make-parameter #f))

(define (binding-constraint-proof binding)
  (and (current-js-semantic-contracts)
       (hash-ref (current-js-semantic-contracts) binding #f)))

(define (error-payload-keyword field)
  (define contract
    (and (current-js-semantic-contracts)
         (hash-ref (current-js-semantic-contracts) field #f)))
  (if (error-payload-key-contract? contract)
      (error-payload-key-contract-keyword contract)
      (string->symbol (format ":~a" (param-name field)))))

(define (emit-error-data-access field)
  (define prop (kw->prop (error-payload-keyword field)))
  (if (string-contains? prop "/")
      (format "err__exception.data[~v]" prop)
      (format "err__exception.data.~a" prop)))

(define current-js-export-names (make-parameter #f))
;; Set while emitting a js/export-marked definition. Multi-binding forms use it
;; to export every binding; single-binding forms use it to suppress a second
;; export prefix from the batch demand plan.
(define current-js-export-marked? (make-parameter #f))

(define (js-defn-signature form #:async? async? #:name name #:params params)
  (format "~afunction ~a(~a)" (if async? "async " "") name params))

;; match temp counter — a PARAMETER holding a box, reset fresh per program (see
;; js-emit-program) so the same source emits byte-identical .js every build, exactly
;; as emit-clj does. A module-level box would leak across programs in one process.
(define match-counter (make-parameter (box 0)))
(define (next-match-id!)
  (define b (match-counter))
  (define n (unbox b))
  (set-box! b (add1 n))
  n)

(define logical-counter (make-parameter (box 0)))
(define (next-logical-id!)
  (define b (logical-counter))
  (define n (unbox b))
  (set-box! b (add1 n))
  n)

(define constrained-binding-counter (make-parameter (box 0)))
(define (next-constrained-binding-id!)
  (define b (constrained-binding-counter))
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
  (mangle-prop (substring s 1)))

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
               (cons (format "[~a]: ~a"
                             (emit-property-key (car rest))
                             (emit-expr (cadr rest)))
                     acc))))
   ", "))

(define (emit-property-key key)
  (runtime-call "property_key" (list key)))

(define (emit-apply-call args)
  (define call-args (cdr args))
  (define fixed-args (drop-right call-args 1))
  (define fixed-names
    (for/list ([arg (in-list fixed-args)] [i (in-naturals)])
      (format "$beagle$apply$arg$~a" i)))
  (define parameters
    (append (list "$beagle$apply$fn")
            fixed-names
            (list "$beagle$apply$tail")))
  (define forwarded
    (append fixed-names
            (list "...($beagle$apply$tail ?? [])")))
  (format "((~a) => $beagle$apply$fn.call($beagle$apply$fn, ~a))(~a)"
          (string-join parameters ", ")
          (string-join forwarded ", ")
          (string-join (map emit-expr args) ", ")))

(define (emit-core-call fn-sym args)
  (define n (length args))
  (case fn-sym
    [(str) (runtime-call "str" args)]
    [(println) (format "console.log(~a)" (runtime-call "print_str" args))]
    [(print) (format "process.stdout.write(~a)" (runtime-call "print_str" args))]
    [(pr) (format "process.stdout.write(~a)" (runtime-call "pr_str" args))]
    [(prn) (format "console.log(~a)" (runtime-call "pr_str" args))]
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
                  [else (begin
                          (mark-needs-v-if-hamtish! (car args))
                          (runtime-call "keys" args))])
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
    [(apply) (if (>= n 2) (emit-apply-call args) #f)]
    [(identity) (if (= n 1) (emit-expr (car args)) #f)]
    [(boolean) (if (= n 1) (emit-truthy-expr (car args)) #f)]
    [(string?) (if (= n 1) (format "(typeof ~a === 'string')" (emit-expr (car args))) #f)]
    [(number?) (if (= n 1) (format "(typeof ~a === 'number')" (emit-expr (car args))) #f)]
    [(keyword?) (if (= n 1) (runtime-call "keyword_p" args) #f)]
    [(fn?) (if (= n 1) (format "(typeof ~a === 'function')" (emit-expr (car args))) #f)]
    [(and) (emit-logical-expr 'and args)]
    [(or) (emit-logical-expr 'or args)]
    [(throw) (if (= n 1) (format "(() => { throw ~a; })()" (emit-expr (car args))) #f)]
    [(ex-info) (if (= n 2) (format "Object.assign(new Error(~a), {data: ~a})"
                                   (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(ex-message) (if (= n 1) (format "~a.message" (emit-expr (car args))) #f)]
    [(ex-data) (if (= n 1) (format "~a.data" (emit-expr (car args))) #f)]
    [(name) (if (= n 1) (runtime-call "name" args) #f)]
    [(keyword) (if (= n 1) (runtime-call "keyword" args) #f)]
    [(symbol) (if (= n 1) (runtime-call "symbol" args) #f)]
    [(integer?) (if (= n 1) (format "Number.isInteger(~a)" (emit-expr (car args))) #f)]
    [(subs) (cond
              [(= n 2) (format "~a.substring(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
              [(= n 3) (format "~a.substring(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
              [else #f])]
    [(re-find)
     (if (= n 2)
         (format
          "(() => { const _r = ~a, _f = _r.flags.replace(/[gy]/g, \"\") + (_r.flags.includes(\"u\") ? \"\" : \"u\"), _m = ~a.match(new RegExp(_r.source, _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })()"
          (emit-expr (car args)) (emit-expr (cadr args)))
         #f)]
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
               [(or (= n 2) (= n 3)) (runtime-call "get" args)]
               [else #f]))]
    [(update) (if (= n 3)
                  (begin
                    (use-runtime!)
                    (format "(() => { const _m = ~a, _k = $$bc$property_key(~a); return { ..._m, [_k]: ~a(_m[_k]) }; })()"
                            (emit-expr (car args))
                            (emit-expr (cadr args))
                            (emit-expr (caddr args))))
                  #f)]
    [(merge) (if (>= n 1)
              (format "Object.assign({}, ~a)" (string-join (map emit-expr args) ", "))
              #f)]
    [(dissoc) (cond
                [(not (= n 2)) #f]
                [(eq? (classify-rep (car args)) 'hmap)
                 (hamt-call "hamtMapDissoc" (emit-expr (car args)) (emit-expr (cadr args)))]
                [else (format "(() => { const _r = {...~a}; delete _r[~a]; return _r; })()"
                              (emit-expr (car args))
                              (emit-property-key (cadr args)))])]
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
             (format "((_pred, _coll) => { if (_coll == null) return null; for (const _item of _coll) { const _value = _pred(_item); if (_value !== false && _value != null) return _value; } return null; })(~a, ~a)"
                     (emit-expr (car args)) (emit-expr (cadr args)))
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
    [(pr-str) (if (>= n 1) (runtime-call "pr_str" args) #f)]
    [(to-array) (if (= n 1) (host-call "to_array" args) #f)]
    [(aget) (if (>= n 2) (host-call "aget" args) #f)]
    [(aset) (if (>= n 3) (host-call "aset" args) #f)]
    [(alength) (if (= n 1) (host-call "alength" args) #f)]
    [(array) (host-call "array" args)]
    [(js-obj) (host-call "js_obj" args)]
    [(into-array) (if (or (= n 1) (= n 2)) (host-call "into_array" args) #f)]
    [(object-array) (if (= n 1) (host-call "object_array" args) #f)]
    [(js-keys) (if (= n 1) (host-call "js_keys" args) #f)]
    [(js-delete) (if (= n 2) (host-call "js_delete" args) #f)]
    [(js-in) (if (= n 2) (host-call "js_in" args) #f)]
    [(array-seq) (if (= n 1) (host-call "iterable_array" args) #f)]
    [(clj->js) (if (= n 1) (host-call "clj_to_js" args) #f)]
    [(js->clj) (if (= n 1) (host-call "js_to_clj" args) #f)]
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
    [(symbol?) (if (= n 1) (runtime-call "symbol_p" args) #f)]
    [(undefined?) (if (= n 1) (runtime-call "undefined_p" args) #f)]
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
    [(distinct?) (if (>= n 2) (runtime-call "distinct_p" args) #f)]
    ;; --- string / regex --------------------------------------------------------
    [(re-pattern) (if (= n 1) (format "new RegExp(~a)" (emit-expr (car args))) #f)]
    [(re-matches)
     (if (= n 2)
         (format
          "(() => { const _r = ~a, _f = _r.flags.replace(/[gy]/g, \"\") + (_r.flags.includes(\"u\") ? \"\" : \"u\"), _m = ~a.match(new RegExp(\"^(?:\" + _r.source + \")$\", _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })()"
          (emit-expr (car args)) (emit-expr (cadr args)))
         #f)]
    [(re-seq) (if (= n 2) (format "[...~a.matchAll(~a)].map(m => m[0])"
                                  (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(re-groups) (if (= n 1) (format "~a" (emit-expr (car args))) #f)]
    [(format)     (if (>= n 1) (runtime-call "format" args) #f)]
    ;; --- type coercion ----------------------------------------------------------
    [(int)        (if (= n 1) (format "(~a | 0)" (emit-expr (car args))) #f)]
    [(double)     (if (= n 1) (format "Number(~a)" (emit-expr (car args))) #f)]
    [(char)       (if (= n 1) (runtime-call "char" args) #f)]
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
    [(gensym) (runtime-call "gensym" args)]
    [(hash) (if (= n 1) (runtime-call "hash" args) #f)]
    [(random-uuid) (if (= n 0) "crypto.randomUUID()" #f)]
    [(parse-long) (if (= n 1) (format "parseInt(~a, 10)" (emit-expr (car args))) #f)]
    [(parse-double) (if (= n 1) (format "parseFloat(~a)" (emit-expr (car args))) #f)]
    [(parse-boolean) (if (= n 1) (format "(~a === 'true')" (emit-expr (car args))) #f)]
    [else #f]))

;; --- binding constraints ---------------------------------------------------

(define (binding-target binding)
  (cond
    [(param? binding) (param-name binding)]
    [(let-binding? binding) (let-binding-name binding)]
    [(for-binding? binding) (for-binding-name binding)]
    [else (param-binding-target binding)]))

(define (binding-constraint binding)
  (cond
    [(param? binding) (param-constraint binding)]
    [(let-binding? binding) (let-binding-constraint binding)]
    [(for-binding? binding) (for-binding-constraint binding)]
    [else #f]))

(define (binding-target-label binding)
  (define target (binding-target binding))
  (define (label item)
    (cond
      [(symbol? item) (symbol->string item)]
      [(seq-destructure? item)
       (define fixed
         (map label (seq-destructure-names item)))
       (define parts
         (if (seq-destructure-rest-name item)
             (append fixed
                     (list "&"
                           (symbol->string
                            (seq-destructure-rest-name item))))
             fixed))
       (format "[~a]" (string-join parts " "))]
      [(map-destructure? item)
       (define keys
         (format ":keys [~a]"
                 (string-join
                  (map symbol->string (map-destructure-keys item))
                  " ")))
       (define as
         (and (map-destructure-as-name item)
              (format ":as ~a"
                      (symbol->string (map-destructure-as-name item)))))
       (format "{~a}" (string-join (filter values (list keys as)) " "))]
      [else (format "~v" item)]))
  (label target))

;; Constraints are synchronous unary predicates. Generic structural descent is
;; deliberate: an await hidden inside a nested fn/js-quote must not escape the
;; normal async walker merely because constraint metadata is not executable as
;; the surrounding body.
(define (constraint-contains-async? node)
  (cond
    [(or (await-form? node)
         (js-ast-await? node)
         (and (js-ast-function? node) (js-ast-function-async? node))
         (and (js-ast-method? node) (js-ast-method-async? node))
         (and (jst-method? node) (jst-method-async? node)))
     #t]
    [(pair? node)
     (or (constraint-contains-async? (car node))
         (constraint-contains-async? (cdr node)))]
    [(vector? node)
     (for/or ([item (in-vector node)])
       (constraint-contains-async? item))]
    [(hash? node)
     (for/or ([(key value) (in-hash node)])
       (or (constraint-contains-async? key)
           (constraint-contains-async? value)))]
    [(struct? node)
     (define fields (struct->vector node))
     (for/or ([i (in-range 1 (vector-length fields))])
       (constraint-contains-async? (vector-ref fields i)))]
    [else #f]))

(define (binding-constraint-has-await? binding)
  (define constraint (binding-constraint binding))
  (and constraint (constraint-contains-async? constraint)))

(define (params-have-constraint-await? params [rest-param #f])
  (for/or ([binding (in-list
                     (if rest-param
                         (append params (list rest-param))
                         params))])
    (binding-constraint-has-await? binding)))

(define (emit-binding-constraint-statement binding source)
  (define constraint (binding-constraint binding))
  (cond
    [(not constraint) #f]
    [(constraint-contains-async? constraint)
     (error 'beagle-js
            (string-append
             "binding constraint for ~a must be a synchronous unary predicate; "
             "js/await and async functions are not allowed")
            (binding-target-label binding))]
    [(let ([proof (binding-constraint-proof binding)])
       (not (and (binding-constraint-contract? proof)
                 (binding-constraint-contract-synchronous? proof))))
     (error 'beagle-js
            (string-append
             "binding constraint for ~a lacks the compiler's positive "
             "synchronization proof; checked emission refuses to call it")
            (binding-target-label binding))]
    [else
     (format "if (!(~a)(~a)) throw new Error(~a);"
             (emit-expr constraint)
             source
             (js-string-lit
              (format "Binding constraint failed: ~a"
                      (binding-target-label binding))))]))

;; --- async detection -------------------------------------------------------

(define (contains-await? exprs)
  (for/or ([e (in-list exprs)])
    (expr-has-await? e)))

(define (expr-has-await? e)
  (cond
    [(or (await-form? e) (js-ast-await? e)) #t]
    ;; A nested callable owns its own async status. Creating one must not make
    ;; the enclosing function or IIFE async merely because its body awaits.
    [(or (fn-form? e)
         (fn-multi? e)
         (letfn-fn? e)
         (defn-form? e)
         (defn-multi? e)
         (js-ast-function? e)
         (js-ast-method? e)
         (jst-method? e))
     #f]
    ;; letfn's declarations are callable boundaries, but its executable body
    ;; still belongs to the enclosing function.
    [(letfn-form? e) (contains-await? (letfn-form-body e))]
    ;; Await may sit beneath any expression container, including typed-JS
    ;; forms such as js/call and js/set!. Structural descent keeps new forms
    ;; from silently emitting await into a synchronous function.
    [(pair? e)
     (or (expr-has-await? (car e))
         (expr-has-await? (cdr e)))]
    [(vector? e)
     (for/or ([item (in-vector e)])
       (expr-has-await? item))]
    [(hash? e)
     (for/or ([(key value) (in-hash e)])
       (or (expr-has-await? key)
           (expr-has-await? value)))]
    [(struct? e)
     (define fields (struct->vector e))
     (for/or ([i (in-range 1 (vector-length fields))])
       (expr-has-await? (vector-ref fields i)))]
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
(define current-js-record-field-bindings (make-parameter (hasheq)))
(define current-js-record-ns (make-parameter (hasheq)))
(define current-js-record-validator-refs (make-parameter (hasheq)))
(define current-js-record-constructors (make-parameter (set)))
(define current-js-scalar-fns (make-parameter (set)))
(define current-js-symbol-ns (make-parameter (hasheq)))
(define current-js-module-bindings (make-parameter (hasheq)))
(define current-js-public-esm-members (make-parameter (hasheq)))

(define (qualified-ref-same-binding? left right)
  (and (qualified-ref? left)
       (qualified-ref? right)
       (eq? (qualified-ref-qualifier left)
            (qualified-ref-qualifier right))
       (eq? (qualified-ref-name left) (qualified-ref-name right))
       (or (not (qualified-ref-provider-id left))
           (not (qualified-ref-provider-id right))
           (eq? (qualified-ref-provider-id left)
                (qualified-ref-provider-id right)))))

(define (qualified-member-constructor? ref)
  (string-prefix? (symbol->string (qualified-ref-name ref)) "->"))

(define (qualified-runtime-member ref constructor?)
  (define member (symbol->string (qualified-ref-name ref)))
  (if (and constructor? (string-prefix? member "->"))
      (substring member 2)
      member))

(define (qualified-module-binding ref)
  (define bindings (current-js-module-bindings))
  (or (and (qualified-ref-provider-id ref)
           (hash-ref bindings (qualified-ref-provider-id ref) #f))
      (hash-ref bindings (qualified-ref-qualifier ref) #f)))

(define (qualified-public-esm-name ref)
  (define names (current-js-public-esm-members))
  (or (and (qualified-ref-provider-id ref)
           (hash-ref names
                     (cons (qualified-ref-provider-id ref)
                           (qualified-ref-name ref))
                     #f))
      (hash-ref names
                (cons (qualified-ref-qualifier ref) (qualified-ref-name ref))
                #f)))

(define (emit-qualified-reference ref #:constructor? [constructor? #f])
  (define member
    (mangle-str (qualified-runtime-member ref constructor?)))
  (cond
    [(eq? (qualified-ref-qualifier ref) 'js) member]
    [(qualified-module-binding ref)
     => (lambda (binding)
          (define public-name (qualified-public-esm-name ref))
          (if public-name
              (format "~a[~v]" binding public-name)
              (string-append binding "." member)))]
    [else
     (string-append
      (mangle-name (qualified-ref-qualifier ref)) "." member)]))

(define (qualified-set-member? values value)
  (or (set-member? values value)
      (and (qualified-ref? value)
           (for/or ([candidate (in-set values)])
             (qualified-ref-same-binding? candidate value)))))
;; The active loop's source bindings paired with their mutable aggregate slots.
;; `recur` is a fresh binding operation, so constraints validate its temporary
;; values before any loop slot is reassigned.
(define current-loop-binding-slots (make-parameter #f))

;; --- type-based scalar equality optimization (P3) ---------------------------
;; A type is ===-safe iff its core.js value-equality (equiv) coincides with JS
;; ===.  ===-SAFE: Int + integer widths, String, Bool, and interned Keyword.
;; EXCLUDED by design:
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
(define (binding-env-ref env name fallback)
  (if (resolved-ref? name)
      (hash-ref
       env
       (resolved-ref-binding-id name)
       (lambda ()
         (hash-ref env
                   (structural-name->symbol (resolved-ref-name name))
                   fallback)))
      (hash-ref env name fallback)))
(define (rep-of-binding name)
  (binding-env-ref (current-rep-env) name 'native))

;; binding-name -> declared/inferred TYPE (set at let/param scopes). Resolves the
;; var-ref type gap: a bare symbol is excluded from the per-node type table
;; (interned-leaf), so a var used as a key/elem arg has no node-type — this env
;; supplies it from the param `:-` annotation or the let value's inferred type.
(define current-type-env (make-parameter (hasheq)))
(define (type-of-binding name)
  (binding-env-ref (current-type-env) name #f))

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
    [(or (symbol? e) (resolved-ref? e))
     (define re (rep-of-binding e))
     (if (eq? re 'native) (type-read-rep (type-of-binding e)) re)]
    [(and (map-form? e) (null? (map-form-pairs e))) 'native] ; empty map: assoc coerces if upgraded
    [(set-form? e)
     (if (for/or ([item (in-list (set-form-items e))])
           (or (vec-form? item) (map-form? item) (set-form? item)))
         'hset
         'native)]
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
       (or
        (let ([et (seq-elem-type (arg-type (car args)))])
          (and et (not (eq? (key-class et) 'native)) #t))
        ;; A freshly parsed nested literal may not yet have a type-table entry.
        ;; Its element syntax is still decisive: collection elements require
        ;; value-dedup and therefore the HAMT path.
        (and (vec-form? (car args))
             (for/or ([item (in-list (vec-form-items (car args)))])
               (or (vec-form? item) (map-form? item) (set-form? item)))))))

(define (keyword-string-mixed? left right)
  (or (and (keyword-symbol? left) (string? right))
      (and (string? left) (keyword-symbol? right))))

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

;; Explicit JavaScript host values live in a separate runtime module from
;; persistent Beagle values. The import set is derived from emitted calls, so a
;; module pays for only the host operations it uses.
(define (host-call js-name args)
  (format "$$bh$~a(~a)" js-name (string-join (map emit-expr args) ", ")))

;; --- binding environment (for value-position wrapper resolution) -----------

(define current-js-bound (make-parameter (set)))

(define (js-bound? sym)
  (set-member? (current-js-bound) sym))

;; A `let`/return-position-let with a repeated (shadowed) binding name — legal,
;; idiomatic Clojure (`(let [x 1 x (+ x 1)] x)`) — lowers each binding to a flat
;; `const`/`let` statement in ONE JS block; declaring the same identifier twice
;; in one block is a JS SyntaxError even though the source type-checks clean.
;; `current-rename-env` maps a shadowed source symbol to the freshened JS
;; identifier actually declared for its latest binding (see
;; `emit-let-bindings`), and every var-ref / binding-target site resolves a
;; name through it before falling back to the ordinary `mangle-name`. Mirrors
;; `loop`'s `_recur_N` freshening for the same reason: distinct JS identifiers
;; per rebinding, one flat block.
(define current-rename-env (make-parameter (hash)))
(define current-binder-types (make-parameter #f))

(define (resolved-name name)
  (cond
    [(qualified-ref? name) (emit-qualified-reference name)]
    [(resolved-ref? name)
     (hash-ref
      (current-rename-env)
      (resolved-ref-binding-id name)
      (lambda () (mangle-name (resolved-ref-output-symbol name))))]
    [else
     (hash-ref (current-rename-env) name
               (lambda () (mangle-name name)))]))

(define (rename-env-set-binder env binding name rendered)
  (define with-name (hash-set env name rendered))
  (define id (binder-binding-id binding name #f))
  (if id (hash-set with-name id rendered) with-name))

(define (resolved-binder-name binding name)
  (define id (binder-binding-id binding name #f))
  (or (and id (hash-ref (current-rename-env) id #f))
      (hash-ref (current-rename-env) name #f)
      (mangle-name (binder-output-symbol binding name))))

;; Typed-JS operators live in emit-jst.rkt, but their operands share this
;; emitter's lexical rename environment with every ordinary expression.
(current-jst-resolve-name resolved-name)

(define (with-bindings syms thunk)
  (parameterize ([current-js-bound (set-union (current-js-bound) (list->set syms))])
    (thunk)))

;; Typed-JS class methods are emitted in a separate module, but their bodies
;; may contain ordinary Beagle AST that routes back through `emit-expr`. Bridge
;; the method's hidden constrained-parameter names into this emitter too.
(current-jst-with-binding-env
 (lambda (names rename-additions thunk)
   (define merged-rename-env
     (for/fold ([env (current-rename-env)])
               ([(name js-name) (in-hash rename-additions)])
       (hash-set env name js-name)))
   (parameterize
       ([current-js-bound
         (set-union (current-js-bound) (list->set names))]
        [current-rename-env merged-rename-env])
     (thunk))))

;; Seed the rep-selection envs from a param list (typed `:-` params): a param's
;; declared type populates current-type-env (so var key/elem args resolve) and,
;; when the type is a compound-keyed map / compound-elem set, current-rep-env (so
;; reads through the param route to HAMT ops). Composes with with-bindings.
(define (with-param-envs params thunk [rest-param #f])
  (define-values (te re)
    (extend-binding-type-envs
     (if rest-param (append params (list rest-param)) params)
     (current-type-env)
     (current-rep-env)))
  (parameterize ([current-type-env te] [current-rep-env re])
    (thunk)))

(define (binding-type-pairs binding)
  (define target (param-binding-target binding))
  (define direct-type (and (param? binding) (param-type binding)))
  (define projected
    (and (current-binder-types)
         (hash-ref (current-binder-types) binding #f)))
  (cond
    [projected (hash->list projected)]
    [(and (symbol? target) direct-type) (list (cons target direct-type))]
    [else '()]))

(define (extend-binding-type-envs bindings type-env rep-env)
  (for*/fold ([te type-env] [re rep-env])
             ([binding (in-list bindings)]
              [entry (in-list (binding-type-pairs binding))])
    (define name (car entry))
    (define ty (cdr entry))
    (define rep (type-read-rep ty))
    (values (hash-set te name ty)
            (if (eq? rep 'native) re (hash-set re name rep)))))

(define (names-from-binding-target name)
  (binding-target-bound-names (binding-target name)))

(define (binding-names-from-params params [rest-param #f])
  (append
   (apply append (map (lambda (p)
     (names-from-binding-target p))
     params))
   (if rest-param (names-from-binding-target rest-param) '())))

(define (param-bindings params rest-param)
  (if rest-param (append params (list rest-param)) params))

(define (bindings-have-constraints? bindings)
  (for/or ([binding (in-list bindings)])
    (binding-constraint binding)))

(define (hidden-binding-rename-env bindings prefix [base (current-rename-env)])
  (for/fold ([env base]) ([binding (in-list bindings)]
                          [index (in-naturals)])
    (for/fold ([inner env])
              ([name (in-list (names-from-binding-target binding))])
      (rename-env-set-binder
       inner binding name
       (format "$beagle$~a$~a$~a"
               prefix index (mangle-name name))))))

(define (binding-indexed-rename-env
         bindings prefix index [base (current-rename-env)])
  (for/fold ([env base])
            ([name (in-list
                    (names-from-binding-target
                     (list-ref bindings index)))])
    (rename-env-set-binder
     env (list-ref bindings index) name
     (format "$beagle$~a$~a$~a"
             prefix index (mangle-name name)))))

(define (callable-param-rename-env params rest-param)
  (define bindings (param-bindings params rest-param))
  (if (bindings-have-constraints? bindings)
      (hidden-binding-rename-env bindings "param")
      (current-rename-env)))

;; --- entry point -----------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hasheq)]) ([raw (in-list (program-forms prog))])
      (define f (unwrap-definition-form raw))
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
  (define with-legacy-type-names
    (for/fold ([h local])
              ([(rec-name field-names)
                (in-hash (program-imported-record-field-order prog))])
      (hash-set h rec-name field-names)))
  (for*/fold ([table with-legacy-type-names])
             ([import (in-list (program-imported-module-interfaces prog))]
              [entry
               (in-value
                (let ([interface (module-import-interface import)])
                  (list interface
                        (module-import-prefix import)
                        (module-interface-namespace interface)
                        (module-import-refer import))))]
              [(record-name contract)
               (in-hash
                (module-interface-record-contracts (car entry)))])
    (define fields
      (for/list ([field (in-list
                         (interface-record-contract-fields contract))])
        (symbol->string (param-name field))))
    (define prefix-ref
      (qualified-ref (cadr entry) record-name (caddr entry)))
    (define namespace-ref
      (qualified-ref (caddr entry) record-name (caddr entry)))
    (define next
      (hash-set (hash-set table prefix-ref fields) namespace-ref fields))
    (if (and (cadddr entry) (memq record-name (cadddr entry)))
        (hash-set next record-name fields)
        next)))

(define (record-fields-ref table name [fallback #f])
  (or (hash-ref table name #f)
      (and (qualified-ref? name)
           (for/first ([(candidate fields) (in-hash table)]
                       #:when
                       (qualified-ref-same-binding? candidate name))
             fields))
      fallback))

(define (build-record-field-binding-table prog)
  (for/fold ([table (hasheq)]) ([raw (in-list (program-forms prog))])
    (define form (unwrap-definition-form raw))
    (cond
      [(record-form? form)
       (hash-set table (record-form-name form) (record-form-fields form))]
      [(and (defunion-form? form) (defunion-form-member-fields form))
       (for/fold ([next table])
                 ([member (in-list (defunion-form-members form))])
         (hash-set next member
                   (hash-ref (defunion-form-member-fields form) member '())))]
      [(deferror-form? form)
       (for/fold ([next table])
                 ([member (in-list (deferror-form-members form))])
         (hash-set next member
                   (hash-ref (deferror-form-member-fields form) member '())))]
      [else table])))

;; A checked record-update contract names the declaration by its canonical
;; provider identity. JavaScript, however, must call that provider through the
;; consumer's actual require spelling: `p.$validator` for `:as p`, or the
;; hidden named import for `:refer`. Keep that projection explicit and derived
;; from the authoritative module interface; never turn a namespace string into
;; an identifier and hope it matches the runtime import.
(define (build-record-validator-reference-table prog)
  (for/fold ([table (hasheq)])
            ([contract (in-hash-values (program-semantic-contracts prog))]
             #:when
             (and (record-update-contract? contract)
                  (record-update-contract-validator-symbol contract)))
    (define record-name (record-update-contract-record-name contract))
    (define resolved-contract
      (program-record-contract-ref prog record-name #f))
    (define validator
      (and resolved-contract
           (interface-record-contract-validator-symbol resolved-contract)))
    (define namespace
      (hash-ref (program-imported-record-ns prog) record-name #f))
    (define import
      (and namespace
           (for/first
               ([candidate
                 (in-list (program-imported-module-interfaces prog))]
                #:when
                (eq? (module-interface-namespace
                      (module-import-interface candidate))
                     namespace))
             candidate)))
    (define interface (and import (module-import-interface import)))
    (define imported-record-name
      (and interface
           (for/first
               ([(candidate-name candidate-contract)
                 (in-hash (module-interface-record-contracts interface))]
                #:when
                (equal? candidate-contract resolved-contract))
             candidate-name)))
    (cond
      [(not imported-record-name) table]
      [else
       (define refer (module-import-refer import))
       (define referred?
         (and refer
              (or (memq imported-record-name refer)
                  (memq
                   (string->symbol (format "->~a" imported-record-name))
                   refer))))
       (hash-set
        table
        record-name
        (if referred?
            validator
            (qualified-ref
             (module-import-prefix import) validator namespace)))])))

(define (record-update-runtime-validator contract)
  (define validator (record-update-contract-validator-symbol contract))
  (cond
    [(not validator) #f]
    [(hash-ref
      (current-js-record-validator-refs)
      (record-update-contract-record-name contract)
      #f)
     => values]
    [(not
      (hash-has-key?
       (current-js-record-ns)
       (record-update-contract-record-name contract)))
     validator]
    [else
     (error
      'beagle-js
      "record update for ~a lacks an authoritative runtime validator import"
      (record-update-contract-record-name contract))]))

(define RECORD-CONSTRUCTOR-KINDS
  '(record-constructor union-constructor error-constructor))

(define (record-constructor-kind? kind)
  (and (memq kind RECORD-CONSTRUCTOR-KINDS) #t))

(define (require-prefix entry)
  (or (require-entry-alias entry)
      (string->symbol
       (last (string-split (symbol->string (require-entry-ns entry)) ".")))))

(define (require-module-import prog entry)
  (for/first ([import (in-list (program-imported-module-interfaces prog))]
              #:when (eq? (module-interface-namespace
                            (module-import-interface import))
                           (require-entry-ns entry)))
    import))

(define (require-interface-binding prog entry name)
  (define import (require-module-import prog entry))
  (and import
       (module-interface-binding-ref
        (module-import-interface import) name #f)))

(define (interface-scalar-predicated? interface scalar-name)
  (define declaration
    (hash-ref (module-interface-type-declarations interface) scalar-name #f))
  (and declaration
       (match (interface-type-declaration-details declaration)
         [`(backing ,_ predicates ,predicates) (pair? predicates)]
         [_ #f])))

(define (record-constructor-import? prog entry name)
  (define binding (require-interface-binding prog entry name))
  (and (string-prefix? (symbol->string name) "->")
       binding
       (record-constructor-kind? (interface-binding-kind binding))))

(define (build-record-constructor-set prog)
  (define local
    (for/fold ([constructors (set)]) ([raw (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw))
      (define names
        (cond
          [(record-form? form) (list (record-form-name form))]
          [(and (defunion-form? form) (defunion-form-member-fields form))
           (defunion-form-members form)]
          [(deferror-form? form) (deferror-form-members form)]
          [else '()]))
      (for/fold ([next constructors]) ([name (in-list names)])
        (set-add next
                 (string->symbol (string-append "->" (symbol->string name)))))))
  (for/fold ([constructors local]) ([entry (in-list (program-requires prog))])
    (for/fold ([next constructors])
              ([name (in-list (or (require-entry-refer entry) '()))]
               #:when (record-constructor-import? prog entry name))
      (set-add next name))))

(define (build-scalar-fns prog)
  (define predicated
    (for/fold ([h (hash)]) ([raw (in-list (program-forms prog))])
      (define f (unwrap-definition-form raw))
      (if (and (defscalar-form? f) (not (null? (defscalar-form-predicates f))))
          (hash-set h (defscalar-form-name f) #t)
          h)))
  (define local
    (for/fold ([s (set)]) ([raw (in-list (program-forms prog))])
      (define f (unwrap-definition-form raw))
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
  (for*/fold ([values local])
             ([import (in-list (program-imported-module-interfaces prog))]
              [(type-name declaration)
               (in-hash
                (module-interface-type-declarations
                 (module-import-interface import)))]
              [runtime-name
               (in-list
                (match (interface-type-declaration-details declaration)
                  [`(backing ,_ predicates ,predicates)
                   (define name-string (symbol->string type-name))
                   (define accessor
                     (string->symbol
                      (string-append
                       (string-downcase name-string) "-value")))
                   (if (null? predicates)
                       (list
                        (string->symbol
                         (string-append "->" name-string))
                        accessor)
                       (list accessor))]
                  [_ '()]))])
    (define namespace
      (module-interface-namespace (module-import-interface import)))
    (define with-qualified
      (set-add
       (set-add
        values
        (qualified-ref (module-import-prefix import) runtime-name namespace))
       (qualified-ref namespace runtime-name namespace)))
    (if (and (module-import-refer import)
             (memq runtime-name (module-import-refer import)))
        (set-add with-qualified runtime-name)
        with-qualified)))

(define (validate-js-target! prog)
  (unless (null? (program-imports prog))
    (error 'beagle-js "Java imports are not supported for JS target: ~a"
           (program-imports prog))))

(define (collect-top-level-names prog)
  (define from-forms
    (for/fold ([s (set)]) ([raw (in-list (program-forms prog))])
      (define f (unwrap-definition-form raw))
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

;; A namespace alias and a lexical binding occupy distinct source roles even
;; when they share a spelling: `(state/f x)` still names the imported module
;; inside `(defn g [state] ...)`. JavaScript puts both in one lexical namespace,
;; so bind only colliding imports to an emitter-owned identifier and route every
;; qualified reference through that table. Searching program forms for the
;; exact alias symbol is deliberately conservative: binders necessarily occur
;; there, while the qualified `state/f` symbol does not equal `state`.
(define (tree-contains-symbol? node target)
  (cond
    [(qualified-ref? node) #f]
    [(symbol? node) (eq? node target)]
    [(pair? node)
     (or (tree-contains-symbol? (car node) target)
         (tree-contains-symbol? (cdr node) target))]
    [(vector? node)
     (for/or ([item (in-vector node)])
       (tree-contains-symbol? item target))]
    [(hash? node)
     (for/or ([(key value) (in-hash node)])
       (or (tree-contains-symbol? key target)
           (tree-contains-symbol? value target)))]
    [(struct? node)
     (define fields (struct->vector node))
     (for/or ([index (in-range 1 (vector-length fields))])
       (tree-contains-symbol? (vector-ref fields index) target))]
    [else #f]))

(define (build-js-module-binding-table prog)
  (for/fold ([table (hasheq)])
            ([entry (in-list (program-requires prog))]
             #:unless (require-entry-refer entry))
    (define prefix (require-prefix entry))
    (define namespace (require-entry-ns entry))
    (define collides?
      (for/or ([form (in-list (program-forms prog))])
        (tree-contains-symbol? form prefix)))
    (define binding
      (if collides?
          (format "$beagle$import$~a" (mangle-name prefix))
          (mangle-name prefix)))
    (hash-set (hash-set table prefix binding) namespace binding)))

(define (build-js-public-esm-member-table prog)
  (for/fold ([table (hasheq)])
            ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define namespace (module-interface-namespace interface))
    (for/fold ([next table])
              ([name (in-list
                      (sort (hash-keys (module-interface-public-esm-exports
                                        interface))
                            symbol<?))])
      (define public-name
        (module-interface-public-esm-name interface name))
      (hash-set
       (hash-set next (cons prefix name) public-name)
       (cons namespace name) public-name))))

(define (js-module-binding-name prefix)
  (hash-ref (current-js-module-bindings) prefix
            (lambda () (mangle-name prefix))))

(define (exported-binding? _name [_private? #f]) #f)

(define (public-esm-runtime-name interface name)
  (define binding (module-interface-binding-ref interface name #f))
  (if (and binding
           (record-constructor-kind? (interface-binding-kind binding))
           (string-prefix? (symbol->string name) "->"))
      (string->symbol (substring (symbol->string name) 2))
      name))

(define (emit-public-esm-exports interface public-esm-exports)
  (string-join
   (for/list ([name (in-list (sort (hash-keys public-esm-exports) symbol<?))])
     (format "export { ~a as ~v };"
             (mangle-name (public-esm-runtime-name interface name))
             (hash-ref public-esm-exports name)))
   "\n"))

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

;; Forms that emit more than one top-level binding: one "export " prefix on the
;; emitted string would reach only the first.
(define (multi-binding-form? f0)
  (define f (unwrap-definition-form f0))
  (or (record-form? f) (defunion-form? f) (deferror-form? f) (defscalar-form? f)))

(define (js-emit-program prog)
  (validate-js-target! prog)
  (define local-interface
    (program->module-interface prog #:provisional? #t))
  (define public-esm-exports
    (module-interface-public-esm-exports local-interface))
  (parameterize ([current-js-export-names (list->set (hash-keys public-esm-exports))]
                 [current-js-context 'stmt]
                 [match-counter (box 0)]
                 [logical-counter (box 0)]
                 [constrained-binding-counter (box 0)]
                 [current-js-record-fields (build-record-field-table prog)]
                 [current-js-record-field-bindings
                  (build-record-field-binding-table prog)]
                 [current-js-record-ns (program-imported-record-ns prog)]
                 [current-js-record-validator-refs
                  (build-record-validator-reference-table prog)]
                 [current-js-record-constructors
                  (build-record-constructor-set prog)]
                 [current-js-scalar-fns (build-scalar-fns prog)]
                 [current-js-symbol-ns (program-imported-symbol-ns prog)]
                 [current-js-module-bindings
                  (build-js-module-binding-table prog)]
                 [current-js-public-esm-members
                  (build-js-public-esm-member-table prog)]
                 [current-js-semantic-contracts (program-semantic-contracts prog)]
                 [current-jst-semantic-contracts
                  (program-semantic-contracts prog)]
                 [current-type-table (program-type-table prog)]  ; P3: per-node arg types for scalar-=== dispatch (#f when capture off)
                 [current-binder-types (program-binder-type-table prog)]
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
    (define public-exports
      (emit-public-esm-exports local-interface public-esm-exports))
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
    (define used-host
      (sort (remove-duplicates
             (regexp-match* #px"[$][$]bh[$]([a-z_]+)" body #:match-select cadr))
            string<?))
    (define host-import
      (if (null? used-host)
          ""
          (format "import { ~a } from '~a';\n"
                  (string-join
                   (for/list ([name (in-list used-host)])
                     (format "~a as $$bh$~a" name name))
                   ", ")
                  (string-append js-runtime-prefix "host.js"))))
    ;; Tree-shakeable named import of ONLY the HAMT ops this module emitted.
    (define hamt-import
      (let ([ops (sort (hash-keys (hamt-ops-used)) string<?)])
        (if (null? ops)
          ""
          (format "import { ~a } from '~a';\n"
                  (string-join ops ", ")
                  (string-append js-runtime-prefix "hamt.js")))))
    (string-append rep-comment header runtime-import host-import hamt-import
                   "\n" body
                   (if (string=? public-exports "") "\n"
                       (string-append "\n\n" public-exports "\n")))))

;; --- module header ---------------------------------------------------------

;; Relative ES-module specifier from the importing module to an imported one,
;; both given as dotted namespaces (e.g. gjoa.tools.prep.cli importing
;; gjoa.tools.prep.log → "./log.js"; importing gjoa.tools.security.check →
;; "../security/check.js". A
;; `./`-prefixed full-ns path only resolves when the importer sits at the module
;; root, which is false for any nested module run un-bundled — so emit a path
;; relative to the importer's own directory.
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

;; Beagle namespaces are dotted. A slash instead marks a bare npm package
;; subpath, whose filename and extension are already the exact ESM specifier.
(define (bare-js-module-specifier? ns-str)
  (or (string-prefix? ns-str "@")
      (string-contains? ns-str "/")
      (not (string-contains? ns-str "."))))

(define (emit-module-header prog)
  (define importer-ns (symbol->string (program-namespace prog)))
  (define rs (program-requires prog))
  (define used-unqualified-record-validators
    (for/set ([(node contract)
               (in-hash (program-semantic-contracts prog))]
              #:when
              (and (record-update-contract? contract)
                   (record-update-runtime-validator contract)
                   (symbol?
                    (record-update-runtime-validator contract))))
      (record-update-runtime-validator contract)))
  (define (referred-record-validators entry refer)
    (define import (require-module-import prog entry))
    (define interface (and import (module-import-interface import)))
    (if (not interface)
        '()
        (for/list
            ([(record-name contract)
              (in-hash (module-interface-record-contracts interface))]
             #:when
             (let ([validator
                    (interface-record-contract-validator-symbol contract)])
               (and validator
                    (set-member?
                     used-unqualified-record-validators validator)
                    (or (memq record-name refer)
                        (memq
                         (string->symbol (format "->~a" record-name))
                         refer)))))
          (interface-record-contract-validator-symbol contract))))
  (define (runtime-import-name entry name)
    (define import (require-module-import prog entry))
    (define interface (and import (module-import-interface import)))
    (define binding
      (and interface (module-interface-binding-ref interface name #f)))
    (define kind (and binding (interface-binding-kind binding)))
    (cond
      [(and interface
            (module-interface-type-export? interface name)
            (not binding))
       #f]
      [(record-constructor-import? prog entry name)
       (string->symbol (substring (symbol->string name) 2))]
      [(eq? kind 'scalar-accessor)
       #f]
      [(eq? kind 'scalar-constructor)
       (and (interface-scalar-predicated?
             interface
             (string->symbol (substring (symbol->string name) 2)))
            name)]
      [(eq? kind 'extern) #f]
      [else name]))
  (define (runtime-import-spec entry source-name local-name)
    (define import (require-module-import prog entry))
    (define interface (and import (module-import-interface import)))
    (define public-name
      (and interface
           (module-interface-public-esm-name interface source-name #f)))
    (if public-name
        (format "~v as ~a" public-name (mangle-name local-name))
        (mangle-name local-name)))
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
         (if (bare-js-module-specifier? ns-str)
             ns-str
             (relative-js-module-path importer-ns ns-str)))
       (if refer
         (let ([runtime-refer
                (remove-duplicates
                 (append
                  (filter-map
                   (lambda (name)
                     (define local-name
                       (and (not (hash-ref macros name #f))
                            (runtime-import-name r name)))
                     (and local-name (cons name local-name)))
                   refer)
                  (for/list ([name (in-list (referred-record-validators r refer))])
                    (cons name name))))])
           (if (null? runtime-refer)
             ""
             (format "import { ~a } from '~a';"
                     (string-join
                      (for/list ([entry (in-list runtime-refer)])
                        (runtime-import-spec r (car entry) (cdr entry)))
                      ", ")
                     module-path)))
         (let ([alias (or (require-entry-alias r)
                          (let ([parts (string-split ns-str ".")])
                            (string->symbol (last parts))))])
           (format "import * as ~a from '~a';"
                   (js-module-binding-name alias)
                   module-path))))))
  (if (null? lines)
    ""
    (string-append (string-join lines "\n") "\n")))

;; --- top-level forms -------------------------------------------------------

(define (emit-js-multi-arity-function arities [name #f])
  (define async? (for/or ([a (in-list arities)])
                   (or (params-have-constraint-await?
                        (arity-clause-params a)
                        (arity-clause-rest-param a))
                       (contains-await? (arity-clause-body a)))))
  (define branches
    (for/list ([a (in-list arities)])
      (define n (length (arity-clause-params a)))
      (define rest? (arity-clause-rest-param a))
      (define arity-bindings
        (param-bindings (arity-clause-params a) rest?))
      (define arity-rename-env
        (if (bindings-have-constraints? arity-bindings)
            (hidden-binding-rename-env arity-bindings "arity")
            (current-rename-env)))
      (define param-binding-strs
        (apply append
               (for/list ([p (in-list (arity-clause-params a))]
                          [i (in-naturals)])
                 (emit-js-argument-binding-setup
                  p
                  (format "$beagle$args[~a]" i)
                  (format "$beagle$arg$~a" i)
                  #:install-rename-env arity-rename-env))))
      (define rest-str
        (if rest?
          (emit-js-argument-binding-setup
           rest?
           (format "$beagle$args.slice(~a)" n)
           "$beagle$arg$rest"
           #:install-rename-env arity-rename-env)
          '()))
      (define all-bindings (append param-binding-strs rest-str))
      (define arity-bound
        (binding-names-from-params
         (arity-clause-params a) (arity-clause-rest-param a)))
      (define body
        (with-param-envs
         (arity-clause-params a)
         (lambda ()
           (parameterize ([current-rename-env arity-rename-env])
             (with-bindings arity-bound
               (lambda ()
                 (emit-body-return (arity-clause-body a) "    ")))))
         (arity-clause-rest-param a)))
      (define bindings-str (string-join all-bindings "\n    "))
      (define inner
        (if (null? all-bindings)
          body
          (format "~a\n    ~a" bindings-str body)))
      (if rest?
        (format "  if (arguments.length >= ~a) {\n    ~a\n  }" n inner)
        (format "  if (arguments.length === ~a) {\n    ~a\n  }" n inner))))
  (format "~afunction~a(...$beagle$args) {\n~a\n  throw new Error('No matching arity: ' + $beagle$args.length);\n}"
          (if async? "async " "")
          (if name (format " ~a" name) "")
          (string-join branches "\n")))

(define (emit-form f)
  (cond
    [(def-form? f)
     (format "~aconst ~a = ~a;"
             (if (exported-binding? (def-form-name f)) "export " "")
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "~aconst ~a = ~a;"
             (if (exported-binding? (defonce-form-name f)) "export " "")
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define params (emit-js-params (defn-form-params f) (defn-form-rest-param f)))
     (define param-rename-env
       (callable-param-rename-env
        (defn-form-params f) (defn-form-rest-param f)))
     (define setup
       (emit-js-param-setup
        (defn-form-params f) (defn-form-rest-param f)
        param-rename-env))
     (define async?
       (or (params-have-constraint-await?
            (defn-form-params f) (defn-form-rest-param f))
           (contains-await? (defn-form-body f))))
     (define bound (binding-names-from-params (defn-form-params f) (defn-form-rest-param f)))
     (define emitted-body
       (with-param-envs (defn-form-params f)
         (lambda ()
           (parameterize ([current-rename-env param-rename-env])
             (with-bindings bound
               (lambda () (emit-body-return (defn-form-body f) "  ")))))
         (defn-form-rest-param f)))
     (define inner
       (string-join (append setup (list emitted-body)) "\n  "))
     (format "~a~a {\n  ~a\n}"
             (if (exported-binding? (defn-form-name f) (defn-form-private? f))
                 "export "
                 "")
             (js-defn-signature f
                                #:async? async?
                                #:name (mangle-name (defn-form-name f))
                                #:params params)
             inner)]

    [(defn-multi? f)
     (format "~a~a"
             (if (exported-binding? (defn-multi-name f) (defn-multi-private? f))
                 "export "
                 "")
             (emit-js-multi-arity-function
              (defn-multi-arities f)
              (mangle-name (defn-multi-name f))))]

    [(record-form? f)
     (emit-record f)]

    [(defenum-form? f)
     (define values-name
       (string->symbol
        (string-append (symbol->string (defenum-form-name f)) "-values")))
     (define vals (defenum-form-values f))
     (define val-strs (map (lambda (v) (format "~v" (symbol->string v))) vals))
     (format "~aconst ~a = new Set([~a]);"
             (if (exported-binding? values-name) "export " "")
             (mangle-name values-name)
             (string-join val-strs ", "))]

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
    [(jst-export? f)
     (emit-form (jst-export-form f))]
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
    [(resolved-ref? e) (resolved-name e)]
    [(qualified-ref? e) (emit-qualified-reference e)]
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
       [(keyword-symbol? e) (runtime-call "keyword" (list (kw->prop e)))]
       [(js-bound? e) (resolved-name e)]
       [(hash-ref JS-VALUE-WRAPPERS e #f) => values]
       [else (mangle-name e)])]
    [(quoted? e)        (emit-quoted (quoted-datum e))]
    [(regex-lit? e)
     (define pat (escape-js-regex-slash (regex-lit-pattern e)))
     (format "/~a/" pat)]

    [(vec-form? e)
     (tally-rep! 'native)  ; vectors are always native (COW arrays)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) ", "))]
    [(js-host-array? e)
     (host-call "host_array" (js-host-array-items e))]
    [(js-host-object? e)
     (host-call
      "host_object"
      (append-map (lambda (pair) (list (car pair) (cdr pair)))
                  (js-host-object-pairs e)))]
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
                            [else (format "[~a]" (emit-property-key k))]))
                        (format "~a: ~a" key-str (emit-expr v)))
                      (map-form-pairs e))
                 ", "))])]
    [(set-form? e)
     (define items
       (string-join (map emit-expr (set-form-items e)) ", "))
     (if (eq? (classify-rep e) 'hset)
         (begin
           (tally-rep! 'hamt)
           (hamt-call "hamtSet" (format "[~a]" items)))
         (begin
           (tally-rep! 'native)
           (format "new Set([~a])" items)))]

    [(with-meta? e)     (emit-expr (with-meta-expr e))]

    [(threading-marker? e)
     (emit-expr (threading-marker-desugared e))]

    [(js-quote-form? e)
     (emit-js-ast-node (js-quote-form-body e) 0)]

    ;; --- Typed JS target expression forms (jst-*) -----------------------------
    [(jst-dot? e)      (emit-jst-dot e)]
    [(jst-get? e)      (emit-jst-get e)]
    [(jst-call? e)     (emit-jst-call e)]
    [(jst-set? e)      (emit-jst-set e)]
    [(jst-new? e)      (emit-jst-new e)]
    [(jst-delete? e)   (emit-jst-delete e)]
    [(jst-in? e)       (emit-jst-in e)]
    [(jst-spread? e)   (format "...~a" (emit-jst-expr (jst-spread-expr e)))]
    [(jst-import-meta? e) "import.meta"]
    [(jst-typeof? e)   (emit-jst-typeof e)]
    [(jst-template? e) (emit-jst-template e)]
    [(jst-binary? e)   (emit-jst-binary e)]
    [(jst-unary? e)    (emit-jst-unary e)]
    [(jst-class? e)    (emit-jst-class e)]
    [(jst-return? e)   (emit-jst-return e)]
    [(jst-export? e)
     (emit-form (jst-export-form e))]
    [(jst-export-default? e) (string-append "export default " (emit-form (jst-export-default-form e)))]

    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(~a ? ~a : ~a)"
                (emit-truthy-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(~a ? ~a : null)"
                (emit-truthy-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]

    [(when-form? e)
     (define async? (or (expr-has-await? (when-form-cond-expr e))
                        (contains-await? (when-form-body e))))
     (iife (format "if (~a) { ~a }"
                    (emit-truthy-expr (when-form-cond-expr e))
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
           (format "(~a) ? ~a" (emit-truthy-expr test) body-str))))
     ;; Clojure cond with no matching clause yields nil — without a trailing
     ;; :else the ternary chain would dangle (`a ? x : b ? y` with no final
     ;; `: …`), so supply the implicit null branch.
     (define complete-parts
       (if (and (pair? clauses) (else-clause? (last clauses)))
         parts
         (append parts (list "null"))))
     (format "(~a)" (string-join complete-parts " : "))]

    [(let-form? e)
     (define bindings (let-form-bindings e))
     (define body (let-form-body e))
     (define has-await (or (for/or ([b (in-list bindings)])
                             (expr-has-await? (let-binding-value b)))
                           (contains-await? body)))
     (define let-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     ;; Earlier bindings are visible to later initializers, so scan the whole let.
     (define mutated-syms (collect-let-set!-target-syms bindings body))
     ;; Thread the rep-env (binding-name -> 'hmap|'hset) ALONGSIDE js-bound so a
     ;; later binding's value (and the body) can classify a var-ref read of an
     ;; earlier binding consistently with how that binding's value was emitted.
     ;; emit-let-bindings also freshens any repeated (shadowed) binding name so
     ;; the flat const/let sequence below never redeclares one JS identifier.
     (define-values (bind-strs rep-env-out type-env-out rename-env-out)
       (emit-let-bindings bindings mutated-syms))
     (with-bindings let-names
       (lambda ()
         (parameterize ([current-rep-env rep-env-out] [current-type-env type-env-out]
                        [current-rename-env rename-env-out])
           (iife (format "~a ~a" (string-join bind-strs " ") (emit-body-return body ""))
                  #:async? has-await))))]

    [(loop-form? e)
     (define bindings (loop-form-bindings e))
     (define body (loop-form-body e))
     (define constrained-loop? (bindings-have-constraints? bindings))
     (define has-await (or (for/or ([b (in-list bindings)])
                             (expr-has-await? (let-binding-value b)))
                           (contains-await? body)))
     (define loop-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) bindings)))
     (define outer-bound (current-js-bound))
     (define outer-rename-env (current-rename-env))
     (define outer-type-env (current-type-env))
     (define outer-rep-env (current-rep-env))
     ;; Recur has one value per SOURCE binding. A destructuring pattern must
     ;; therefore own one stable aggregate slot; projecting leaves into recur
     ;; slots would change arity and lose the aggregate on the next iteration.
     (define bind-names
       (for/list ([b (in-list bindings)] [i (in-naturals)])
         (define target (let-binding-name b))
         (if (or constrained-loop?
                 (map-destructure? target)
                 (seq-destructure? target))
             (format "$beagle$loop$~a" i)
             (emit-binding-target target))))
     ;; The body projects stable aggregate slots into authored bindings once per
     ;; iteration. Default expressions use the progressive pre-binding scope.
     (define-values
       (iteration-pre-bounds iteration-pre-rename-envs
        loop-bound loop-rename-env)
       (for/fold ([rename-envs '()]
                  [bound-envs '()]
                  [bound outer-bound]
                  [rename-env outer-rename-env]
                  #:result (values bound-envs rename-envs bound rename-env))
                 ([binding (in-list bindings)] [i (in-naturals)])
         (define names (names-from-binding-target binding))
         (define rename-env*
           (if constrained-loop?
               (for/fold ([next rename-env]) ([name (in-list names)])
                 (rename-env-set-binder
                  next binding name
                  (format "$beagle$loop$~a$~a"
                          i (mangle-name name))))
               rename-env))
         (values (append rename-envs (list rename-env))
                 (append bound-envs (list bound))
                 (set-union bound (list->set names))
                 rename-env*)))
     ;; In a constrained loop, initialize sequentially: RHS, predicate, authored
     ;; install, then the next declaration. This matches the checker's scope and
     ;; prevents later effects from running after an earlier failed constraint.
     (define bind-strs
       (if constrained-loop?
           (let-values
               ([(strs _bound _rename-env _type-env _rep-env)
                 (for/fold ([strs '()]
                            [bound outer-bound]
                            [rename-env outer-rename-env]
                            [type-env outer-type-env]
                            [rep-env outer-rep-env])
                           ([binding (in-list bindings)]
                            [slot (in-list bind-names)]
                            [i (in-naturals)])
                   (define rhs
                     (parameterize ([current-js-bound bound]
                                    [current-rename-env rename-env]
                                    [current-type-env type-env]
                                    [current-rep-env rep-env])
                       (await-async-iife
                        (emit-expr (let-binding-value binding)))))
                   (define check
                     (parameterize ([current-js-bound bound]
                                    [current-rename-env rename-env]
                                    [current-type-env type-env]
                                    [current-rep-env rep-env])
                       (emit-binding-constraint-statement binding slot)))
                   (define names (names-from-binding-target binding))
                   (define bound*
                     (set-union bound (list->set names)))
                   (define rename-env*
                     (for/fold ([next rename-env]) ([name (in-list names)])
                       (rename-env-set-binder
                        next binding name
                        (format "$beagle$loop$init$~a$~a"
                                i (mangle-name name)))))
                   (define target (let-binding-name binding))
                   (define installs
                     (parameterize ([current-js-bound bound*]
                                    [current-rename-env rename-env*])
                       (if (or (map-destructure? target)
                               (seq-destructure? target))
                           (emit-pattern-binding-statements
                            target slot binding
                            #:default-bound bound
                            #:default-rename-env rename-env)
                           (list (format "const ~a = ~a;"
                                         (emit-binding-target binding) slot)))))
                   (define-values (type-env* rep-env*)
                     (extend-binding-type-envs
                      (list target) type-env rep-env))
                   (values
                    (append strs
                            (list (format "let ~a = ~a;" slot rhs))
                            (if check (list check) '())
                            installs)
                    bound* rename-env* type-env* rep-env*))])
             strs)
           (for/list ([binding (in-list bindings)]
                      [slot (in-list bind-names)])
             (format "let ~a = ~a;"
                     slot
                     (await-async-iife
                      (emit-expr (let-binding-value binding)))))))
     (define iteration-setup-strs
       (apply append
              (for/list ([b (in-list bindings)]
                         [slot (in-list bind-names)]
                         [default-bound (in-list iteration-pre-bounds)]
                         [default-rename-env
                          (in-list iteration-pre-rename-envs)])
                (define target (let-binding-name b))
                (define installs
                  (parameterize ([current-rename-env loop-rename-env]
                                 [current-js-bound loop-bound])
                    (cond
                      [(or (map-destructure? target) (seq-destructure? target))
                       (emit-pattern-binding-statements
                        target slot b
                        #:default-bound default-bound
                        #:default-rename-env default-rename-env)]
                      [constrained-loop?
                       (list (format "let ~a = ~a;"
                                     (emit-binding-target b) slot))]
                      [else '()])))
                installs)))
     (define-values (loop-type-env loop-rep-env)
       (extend-binding-type-envs
        (map let-binding-name bindings)
        (current-type-env)
        (current-rep-env)))
     ;; Recur validates every candidate exactly once before committing any slot.
     ;; Later predicates see earlier candidate bindings, never stale loop values.
     (define recur-binding-contexts
       (and constrained-loop?
            (let-values
                ([(entries _bound _rename-env _type-env _rep-env)
                  (for/fold ([entries '()]
                             [bound outer-bound]
                             [rename-env outer-rename-env]
                             [type-env outer-type-env]
                             [rep-env outer-rep-env])
                            ([binding (in-list bindings)]
                             [slot (in-list bind-names)]
                             [i (in-naturals)])
                    (define names (names-from-binding-target binding))
                    (define bound*
                      (set-union bound (list->set names)))
                    (define rename-env*
                      (for/fold ([next rename-env]) ([name (in-list names)])
                        (rename-env-set-binder
                         next binding name
                         (format "$beagle$recur$~a$~a"
                                 i (mangle-name name)))))
                    (define-values (type-env* rep-env*)
                      (extend-binding-type-envs
                       (list (let-binding-name binding)) type-env rep-env))
                    (values
                     (append entries
                             (list (list binding slot
                                         bound rename-env type-env rep-env
                                         bound* rename-env*)))
                     bound* rename-env* type-env* rep-env*))])
              entries)))
     (with-bindings loop-names
       (lambda ()
         (parameterize ([current-type-env loop-type-env]
                        [current-rep-env loop-rep-env]
                        [current-rename-env loop-rename-env]
                        [current-loop-binding-slots recur-binding-contexts])
           (define body-str
             (string-join (map (lambda (e) (emit-loop-stmt e bind-names)) body) "\n    "))
           (define prefix (if has-await "async " ""))
           (format "(~a() => { ~a while (true) {\n    ~a~a~a\n  } })()"
                   prefix
                   (string-join bind-strs " ")
                   (string-join iteration-setup-strs " ")
                   (if (null? iteration-setup-strs) "" "\n    ")
                   body-str))))]

    [(recur-form? e)
     (error 'beagle-js
            "recur reached ordinary expression emission; loop tail lowering is required")]

    [(for-form? e)
     (emit-for e)]

    [(fn-form? e)
     (define params (emit-js-params (fn-form-params e) (fn-form-rest-param e)))
     (define param-rename-env
       (callable-param-rename-env
        (fn-form-params e) (fn-form-rest-param e)))
     (define setup
       (emit-js-param-setup
        (fn-form-params e) (fn-form-rest-param e) param-rename-env))
     (define body (fn-form-body e))
     (define async?
       (or (params-have-constraint-await?
            (fn-form-params e) (fn-form-rest-param e))
           (contains-await? body)))
     (define prefix (if async? "async " ""))
     (define bound (binding-names-from-params (fn-form-params e) (fn-form-rest-param e)))
     (with-param-envs
      (fn-form-params e)
      (lambda ()
       (parameterize ([current-rename-env param-rename-env])
         (with-bindings bound
           (lambda ()
             (if (and (null? setup)
                      (= (length body) 1) (not (stmt-inline? (car body))))
               (let ([body-str (emit-expr (car body))])
                 ;; An expression-body arrow whose body emits an OBJECT LITERAL must be
                 ;; parenthesized: `=> {…}` is a JS block (a labeled-statement parse),
                 ;; whereas `=> ({…})` returns the object. Any expression that emits
                 ;; starting with `{` is an object literal in this position, so wrap it.
                 (if (regexp-match? #rx"^[ \t\r\n]*[{]" body-str)
                   (format "~a(~a) => (~a)" prefix params body-str)
                   (format "~a(~a) => ~a" prefix params body-str)))
               (format "~a(~a) => { ~a }"
                       prefix params
                       (string-join
                        (append setup (list (emit-body-return body "")))
                        " ")))))))
      (fn-form-rest-param e))]

    [(fn-multi? e)
     (emit-js-multi-arity-function (fn-multi-arities e))]

    [(letfn-form? e)
     (define fns (letfn-form-fns e))
     (define body (letfn-form-body e))
     (define fn-names (map letfn-fn-name fns))
     (define letfn-rename-env
       (for/fold ([env (current-rename-env)])
                 ([fn (in-list fns)] [fn-name (in-list fn-names)])
         (rename-env-set-binder
          env fn fn-name (mangle-name (binder-output-symbol fn fn-name)))))
     ;; Nested functions own their async status. Their bodies must not make
     ;; the surrounding letfn IIFE async: declaring an async local while the
     ;; letfn body returns a plain value must still return that value directly.
     (define has-await (contains-await? body))
     (parameterize ([current-rename-env letfn-rename-env])
       (with-bindings fn-names
        (lambda ()
         (define fn-strs
           (for/list ([f (in-list fns)])
             (define name (resolved-binder-name f (letfn-fn-name f)))
             (define params
               (emit-js-params
                (letfn-fn-params f) (letfn-fn-rest-param f)))
             (define param-rename-env
               (callable-param-rename-env
                (letfn-fn-params f) (letfn-fn-rest-param f)))
             (define setup
               (emit-js-param-setup
                (letfn-fn-params f)
                (letfn-fn-rest-param f)
                param-rename-env))
             (define fn-body (letfn-fn-body f))
             (define fn-async?
               (or (params-have-constraint-await?
                    (letfn-fn-params f) (letfn-fn-rest-param f))
                   (contains-await? fn-body)))
             (define prefix (if fn-async? "async " ""))
             (define fn-bound (binding-names-from-params (letfn-fn-params f) (letfn-fn-rest-param f)))
             (with-param-envs
              (letfn-fn-params f)
              (lambda ()
                (parameterize ([current-rename-env param-rename-env])
                  (with-bindings fn-bound
                    (lambda ()
                      (format "~afunction ~a(~a) { ~a }"
                              prefix name params
                              (string-join
                               (append setup
                                       (list (emit-body-return fn-body "")))
                               " "))))))
              (letfn-fn-rest-param f))))
         (iife (format "~a ~a" (string-join fn-strs " ") (emit-body-return body ""))
                #:async? has-await))))]

    [(static-call? e)
     (define ref (static-call-class+method e))
     (format "~a(~a)"
             (emit-qualified-reference
              ref #:constructor? (qualified-member-constructor? ref))
             (string-join (map emit-expr (static-call-args e)) ", "))]

    [(dynamic-var? e)
     (mangle-name (dynamic-var-name e))]

    [(ascription? e) (emit-expr (ascription-expr e))]
    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (define contract
       (and (current-js-semantic-contracts)
            (hash-ref (current-js-semantic-contracts) e #f)))
     (if (error-contract? contract)
         inner
         (iife
          (format "const r = ~a;\nif (r && r.__tag === \"Ok\") return r.value;\nthrow new Error(\"check failed: \" + JSON.stringify(r));"
                  inner)))]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define err-name (if (rescue-form-err-name e)
                          (mangle-name (rescue-form-err-name e))
                          "_err"))
     (define contract
       (and (current-js-semantic-contracts)
            (hash-ref (current-js-semantic-contracts) e #f)))
     (if (error-contract? contract)
         (let* ([variant (car (error-contract-payload-layout contract))]
                [member (car variant)]
                [fields (cdr variant)]
                [fallback
                 (parameterize
                     ([current-type-env
                       (hash-set
                        (current-type-env)
                        (or (rescue-form-err-name e) '_err)
                        (type-prim member))])
                   (emit-expr (rescue-form-fallback e)))]
                [payload
                 (format
                  "~a(~a)"
                  (mangle-name member)
                  (string-join
                   (for/list ([field (in-list fields)])
                     (if (eq? (param-name field) 'message)
                         "err__exception.message"
                         (emit-error-data-access field)))
                   ", "))])
           (iife
            (format
             "try { return ~a; } catch (err__exception) {\nconst ~a = ~a;\nreturn ~a;\n}"
             inner err-name payload fallback)))
         (let ([fallback (emit-expr (rescue-form-fallback e))])
           (iife (format "const r = ~a;\nif (r && r.__tag === \"Ok\") return r.value;\nconst ~a = r;\nreturn ~a;"
                         inner err-name fallback))))]
    [(target-case-form? e)
     (define target 'js)
     (define cases (target-case-form-cases e))
     (define branch (hash-ref cases target #f))
     (unless branch
       (error 'beagle "target-case: no branch for target ~a" target))
     (emit-expr branch)]
    [(try-form? e)
     (define body-str (emit-body-return (try-form-body e) "  "))
     (define catch-strs
       (for/list ([c (try-form-catches e)])
         (with-bindings (list (catch-clause-name c))
           (lambda ()
             (define authored-name (catch-clause-name c))
             (define name
               (mangle-name (binder-output-symbol c authored-name)))
             (parameterize
                 ([current-rename-env
                   (rename-env-set-binder
                    (current-rename-env) c authored-name name)])
               (format "catch (~a) {\n    ~a\n  }"
                       name
                       (emit-body-return (catch-clause-body c) "    ")))))))
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

    [(kw-access? e)
     ;; (:kw m) / (get m :kw) — REP-AWARE: a scalar keyword read still hits the
     ;; HAMT when the COLLECTION is HAMT-repped (the key being scalar is a red
     ;; herring — dispatch on the COLL's rep, not the key). Native dot-access on a
     ;; hamtMap object would read `undefined`.
     (define target (kw-access-target e))
     (define prop (kw->prop (kw-access-kw e)))
     (define keystr (emit-expr (kw-access-kw e)))
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
     (unless (or (symbol? target) (resolved-ref? target))
       (error 'beagle-js "set! emission requires a lexical binding target"))
     (format "(~a = ~a)" (resolved-name target) val)]

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
       [(and (qualified-set-member? (current-js-scalar-fns) fn-sym)
             (= 1 (length args)))
        (emit-expr (car args))]
       ;; `bgl/promote` copies a value into an older epoch's arena. JS has one
       ;; GC-owned heap and no epochs, so the value already outlives every
       ;; scope that could name it: the form erases.
       [(and (qualified-ref? fn-sym)
             (eq? (qualified-ref-qualifier fn-sym) 'bgl)
             (eq? (qualified-ref-name fn-sym) 'promote)
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
            (cond
              [(keyword-string-mixed? an bn) "false"]
              [(both-scalar-eq-safe? an bn) (format "~a === ~a" as bs)]
              [else
               (mark-needs-v-if-hamtish! an)
               (mark-needs-v-if-hamtish! bn)
               (use-runtime!)
               (format "$$bc$equiv(~a, ~a)" as bs)])))
        (format "(~a)" (string-join pairs " && "))]
       ;; not= = not(all consecutive pairs equal): keep inner pairs POSITIVE
       ;; (=== or equiv) and negate the whole conjunction. Do NOT switch the
       ;; scalar branch to !== per-pair — that would change variadic semantics.
       [(and (eq? fn-sym 'not=) (>= (length args) 2))
        (define strs (map emit-expr args))
        (define pairs
          (for/list ([an (in-list args)] [bn (in-list (cdr args))]
                     [as (in-list strs)] [bs (in-list (cdr strs))])
            (cond
              [(keyword-string-mixed? an bn) "false"]
              [(both-scalar-eq-safe? an bn) (format "~a === ~a" as bs)]
              [else
               (mark-needs-v-if-hamtish! an)
               (mark-needs-v-if-hamtish! bn)
               (use-runtime!)
               (format "$$bc$equiv(~a, ~a)" as bs)])))
        (format "(!(~a))" (string-join pairs " && "))]
       [(and (js-infix? fn-sym) (>= (length args) 2))
        (define op (hash-ref JS-INFIX-OPS fn-sym))
        (format "(~a)" (string-join (map emit-expr args) (format " ~a " op)))]
       [(and (js-unary? fn-sym) (= 1 (length args)))
        (if (eq? fn-sym 'not)
            (format "(!~a)" (emit-truthy-expr (car args)))
            (format "(~a~a)" (hash-ref JS-UNARY-OPS fn-sym)
                    (emit-expr (car args))))]
       [(and (current-js-semantic-contracts)
             (hash-ref (current-js-semantic-contracts) e #f)
             (= (length args) 3)
             (qualified-ref? fn-sym)
             (eq? (qualified-ref-name fn-sym) 'replace))
        (format
         "(() => { const _r = ~a, _f = _r.flags.replace(/[gy]/g, \"\") + (_r.flags.includes(\"u\") ? \"g\" : \"gu\"); return ~a.replace(new RegExp(_r.source, _f), ~a); })()"
         (emit-expr (cadr args))
         (emit-expr (car args))
         (emit-expr (caddr args)))]
       [(and (current-js-semantic-contracts)
             (hash-ref (current-js-semantic-contracts) e #f)
             (= (length args) 2)
             (qualified-ref? fn-sym)
             (eq? (qualified-ref-name fn-sym) 'split))
        (format
         "(() => { const _s = ~a, _r = ~a, _f = _r.flags.replace(/[gy]/g, \"\") + (_r.flags.includes(\"u\") ? \"g\" : \"gu\"), _out = []; let _last = 0; for (const _m of _s.matchAll(new RegExp(_r.source, _f))) { _out.push(_s.slice(_last, _m.index)); _last = _m.index + _m[0].length; if (_m[0].length === 0 && _last < _s.length) _last += Array.from(_s.slice(_last))[0].length; } _out.push(_s.slice(_last)); while (_out.length > 0 && _out[_out.length - 1] === \"\") _out.pop(); return _out; })()"
         (emit-expr (car args))
         (emit-expr (cadr args)))]
       [(and (symbol? fn-sym)
             (not (js-bound? fn-sym))
             (emit-core-call fn-sym args))
        => values]
       [(qualified-ref? fn-sym)
        (format "~a(~a)"
                (emit-qualified-reference
                 fn-sym
                 #:constructor? (qualified-member-constructor? fn-sym))
                (string-join (map emit-expr args) ", "))]
       [(resolved-ref? fn-sym)
        (format "~a(~a)"
                (resolved-name fn-sym)
                (string-join (map emit-expr args) ", "))]
       [(not (symbol? fn-sym))
        ;; higher-order call: the callee is an arbitrary expression — e.g.
        ;; ((get o :k) a) — which parse.rkt emits as a call-form with a
        ;; non-symbol head. Emit (callee)(args); never run the symbol-only
        ;; mangle path below, which would `symbol->string` and crash.
       (format "(~a)(~a)"
                (emit-expr fn-sym)
                (string-join (map emit-expr args) ", "))]
       [else
        (define fn-str (symbol->string fn-sym))
        (define mangled
          (cond
            [(and (string-prefix? fn-str "->")
                  (set-member? (current-js-record-constructors) fn-sym))
             (mangle-str (substring fn-str 2))]
            [else (mangle-name fn-sym)]))
        (define qualified
          (let ([mod-prefix (hash-ref (current-js-symbol-ns) fn-sym #f)])
            (cond
              [(js-bound? fn-sym) mangled]
              [mod-prefix
               (string-append (js-module-binding-name mod-prefix) "." mangled)]
              [else mangled])))
        (format "~a(~a)"
                qualified
                (string-join (map emit-expr args) ", "))])]

    ;; A definition cannot be emitted from expression position. Procedural
    ;; macros return top-level definitions inside one generated `(do ...)`.
    [(defn-form? e)
     (error 'beagle-js
            (string-append
             "a definition cannot appear where an expression is expected: ~a\n"
             "  to generate definitions, return a top-level `(do ...)` from `defmacro`")
            (defn-form-name e))]
    [else (error 'beagle-js "don't know how to emit: ~v" e)]))

;; --- records ---------------------------------------------------------------

;; Emit a tagged variant constructor plus its field accessors.  check.rkt
;; registers `circle-radius` for every inline member field, so the constructor
;; alone would leave an emitted call undefined.
;; Shared by defunion and deferror members (both produce tagged variant ctors).
(define (emit-tagged-factory member-name fields)
  (define m-str (mangle-name member-name))
  (define constructor-name
    (string->symbol
     (string-append "->" (symbol->string member-name))))
  ;; params are BINDINGS (reserved-word-suffixed); the object KEYS are
  ;; PROPERTIES (char-mangle only). Split them so `{ delete: delete$ }`.
  (define constrained? (bindings-have-constraints? fields))
  (define field-raw-params
    (for/list ([field (in-list fields)] [i (in-naturals)])
      (if constrained?
          (format "$beagle$field$~a" i)
          (mangle-name (param-name field)))))
  ;; Keep installed field locals hidden too. A predicate may legitimately have
  ;; the same authored name as its field; a later `const field = ...` would
  ;; otherwise capture that predicate through JavaScript's TDZ.
  (define field-params
    (for/list ([field (in-list fields)] [i (in-naturals)])
      (if constrained?
          (format "$beagle$field$~a$~a"
                  i (mangle-name (param-name field)))
          (mangle-name (param-name field)))))
  (define field-props (map (compose mangle-prop symbol->string param-name) fields))
  (define field-installs
    (if constrained?
        (for/list ([name (in-list field-params)]
                   [raw (in-list field-raw-params)])
          (format "const ~a = ~a;" name raw))
        '()))
  (define field-checks
    (filter
     values
     (for/list ([field (in-list fields)]
                [raw (in-list field-raw-params)])
       (emit-binding-constraint-statement field raw))))
  (define validator (emit-record-validator member-name fields))
  (define factory
    (format "~afunction ~a(~a) { ~a~areturn Object.freeze({ _tag: ~v~a }); }"
            (if (or (current-js-export-marked?) (exported-binding? constructor-name))
                "export "
                "")
            m-str
            (string-join field-raw-params ", ")
            (if (null? field-checks)
                ""
                (string-append
                 (string-join field-checks " ")
                 " "))
            (if (null? field-installs)
                ""
                (string-append
                 (string-join field-installs " ")
                 " "))
            (symbol->string member-name)
            (if (null? field-params) ""
                (string-append ", "
                               (string-join
                                (map (lambda (prop param) (format "~a: ~a" prop param))
                                     field-props field-params)
                                ", ")))))
  (define accessors
    (for/list ([field-name (in-list (map (compose symbol->string param-name) fields))]
               [prop (in-list field-props)])
      (define accessor-name
        (string->symbol
         (format "~a-~a"
                 (string-downcase (symbol->string member-name))
                 field-name)))
      (format "~afunction ~a(r) { return r.~a; }"
              (if (or (current-js-export-marked?) (exported-binding? accessor-name)) "export " "")
              (mangle-name accessor-name)
              prop)))
  (string-join
   (append (if validator (list validator) '())
           (cons factory accessors))
   "\n\n"))

(define (record-validator-name name)
  (format "$beagle$record$~a$validate" (mangle-name name)))

(define (emit-record-validator name fields)
  (define checks
    (filter values
            (for/list ([field (in-list fields)])
              (define source
                (format "$beagle$record.~a"
                        (mangle-prop
                         (symbol->string (param-name field)))))
              (emit-binding-constraint-statement field source))))
  (and (pair? checks)
       (format "export function ~a($beagle$record) {\n  ~a\n  return $beagle$record;\n}"
               (record-validator-name name)
               (string-join checks "\n  "))))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-mangled (mangle-name name))
  ;; field PARAMS/accessor-name-suffix are bindings; field PROPS are property
  ;; positions. The accessor name mirrors the `<lcname>-<field>` call site,
  ;; so mangle that whole authored binding independently of the property.
  (define field-source-names (map (compose symbol->string param-name) fields))
  (define constrained? (bindings-have-constraints? fields))
  (define field-raw-params
    (for/list ([field (in-list fields)] [i (in-naturals)])
      (if constrained?
          (format "$beagle$field$~a" i)
          (mangle-name (param-name field)))))
  ;; Constrained constructors keep their installed locals hidden as well as
  ;; their raw parameters. A field may have the same authored name as its
  ;; predicate; spelling that local `const value` would capture a top-level
  ;; predicate named `value` through JavaScript's whole-block TDZ even though
  ;; the guard text appears before the declaration.
  (define field-params
    (for/list ([field (in-list fields)] [i (in-naturals)])
      (if constrained?
          (format "$beagle$field$~a$~a"
                  i (mangle-name (param-name field)))
          (mangle-name (param-name field)))))
  (define field-props (map mangle-prop field-source-names))
  (define field-installs
    (if constrained?
        (for/list ([name (in-list field-params)]
                   [raw (in-list field-raw-params)])
          (format "const ~a = ~a;" name raw))
        '()))
  (define field-checks
    (filter
     values
     (for/list ([field (in-list fields)]
                [raw (in-list field-raw-params)])
       (emit-binding-constraint-statement field raw))))
  (define validator (emit-record-validator name fields))
  ;; Keep the object shorthand `{x}` when prop == param (the common,
  ;; non-reserved case, byte-identical to before); only reserved fields need
  ;; the explicit `delete: delete$` split.
  (define field-entries
    (map (lambda (prop param)
           (if (string=? prop param) param (format "~a: ~a" prop param)))
         field-props field-params))
  (define constructor-name
    (string->symbol (string-append "->" name-str)))
  (define factory
    (format "~afunction ~a(~a) {\n  ~a~areturn Object.freeze({_tag: ~v, ~a});\n}"
            (if (or (current-js-export-marked?) (exported-binding? constructor-name))
                "export "
                "")
            name-mangled
            (string-join field-raw-params ", ")
            (if (null? field-checks)
                ""
                (string-append
                 (string-join field-checks "\n  ")
                 "\n  "))
            (if (null? field-installs)
                ""
                (string-append
                 (string-join field-installs "\n  ")
                 "\n  "))
            name-str
            (string-join field-entries ", ")))
  (define accessors
    (for/list ([field-name (in-list field-source-names)]
               [prop (in-list field-props)])
      (define accessor-name
        (string->symbol (format "~a-~a" (string-downcase name-str) field-name)))
      (format "~afunction ~a(r) { return r.~a; }"
              (if (or (current-js-export-marked?) (exported-binding? accessor-name)) "export " "")
              (mangle-name accessor-name)
              prop)))
  (string-join
   (append (if validator (list validator) '())
           (cons factory accessors))
   "\n\n"))

;; --- with (record update) --------------------------------------------------

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define record-type
    (or (node-type (with-form-target e))
        (and (symbol? (with-form-target e))
             (type-of-binding (with-form-target e)))))
  (define record-name
    (cond
      [(type-prim? record-type) (type-prim-name record-type)]
      [(type-app? record-type) (type-app-ctor record-type)]
      [else #f]))
  (define contract
    (and (current-js-semantic-contracts)
         (hash-ref (current-js-semantic-contracts) e #f)))
  (define statically-record?
    (and record-name
         (hash-has-key? (current-js-record-fields) record-name)))
  (when (and statically-record? (not (record-update-contract? contract)))
    (error 'beagle-js
           "with ~a: checked record update contract is missing"
           record-name))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (format "~a: ~a"
              (kw->prop (with-update-field-kw u))
              (emit-expr (with-update-value u)))))
  (define value
    (format "{...~a, ~a}"
            target-str (string-join update-strs ", ")))
  (define validator
    (and (record-update-contract? contract)
         (record-update-runtime-validator contract)))
  (if validator
      ;; The checker resolves this conceptual symbol to the provider-owned
      ;; helper. Qualified imports route through their namespace object;
      ;; referred helpers are synthesized into the named ESM import list.
      (format "Object.freeze(~a(~a))" (emit-expr validator) value)
      (format "Object.freeze(~a)" value)))

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
             (mangle-name (binder-output-symbol pat (pat-var-name pat)))
             tmp (make-body-str (list (pat-var-name pat))))]
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
     (define fields
       (record-fields-ref (current-js-record-fields) rec-name))
     (define tag-name
       (if (qualified-ref? rec-name)
           (qualified-ref-name rec-name)
           rec-name))
     (define test (format "~a._tag === ~v" tmp (symbol->string tag-name)))
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
                    (mangle-name (binder-output-symbol pat b))
                    tmp (mangle-prop fname))))
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
         (format "const ~a = ~a.~a;"
                 (mangle-name
                  (binder-output-symbol pat (pat-var-name (cdr en))))
                 tmp (kw->prop (car en)))))
     (if (null? let-strs)
         (format "if (~a) { ~a } else" test (make-body-str))
         (format "if (~a) { ~a ~a } else" test (string-join let-strs " ")
                 (make-body-str vnames)))]))

;; --- for comprehension → .map / .filter ------------------------------------

(define (extend-js-binding-context binding prefix index bound rename-env)
  (define names (names-from-binding-target binding))
  (define rename-env*
    (for/fold ([next rename-env]) ([name (in-list names)])
      (rename-env-set-binder
       next binding name
       (if (binding-constraint binding)
           (format "$beagle$~a$~a$~a" prefix index (mangle-name name))
           (mangle-name name)))))
  (values (set-union bound (list->set names)) rename-env*))

(define (build-for-binding-contexts clauses)
  (define contexts (make-hasheq))
  (define bound (current-js-bound))
  (define rename-env (current-rename-env))
  (define index 0)
  (for ([clause (in-list clauses)])
    (cond
      [(for-binding? clause)
       (define pre-bound bound)
       (define pre-rename-env rename-env)
       (define-values (bound* rename-env*)
         (extend-js-binding-context
          clause "for" index bound rename-env))
       (hash-set! contexts clause
                  (list pre-bound pre-rename-env bound* rename-env* index))
       (set! bound bound*)
       (set! rename-env rename-env*)
       (set! index (add1 index))]
      [(for-let? clause)
       (define binding-contexts
         (for/list ([binding (in-list (for-let-bindings clause))])
           (define pre-bound bound)
           (define pre-rename-env rename-env)
           (define-values (bound* rename-env*)
             (extend-js-binding-context
              binding "for_let" index bound rename-env))
           (define context
             (list pre-bound pre-rename-env bound* rename-env* index))
           (set! bound bound*)
           (set! rename-env rename-env*)
           (set! index (add1 index))
           context))
       (hash-set! contexts clause binding-contexts)]
      [else (hash-set! contexts clause (list bound rename-env))]))
  (values contexts bound rename-env))

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))
  (define-values (contexts final-bound final-rename-env)
    (build-for-binding-contexts clauses))
  (define body-str
    (parameterize ([current-js-bound final-bound]
                   [current-rename-env final-rename-env])
      (if (= (length body) 1)
          (emit-expr (car body))
          (format "(() => { ~a })()" (emit-body-return body "")))))
  (emit-for-clauses clauses body-str contexts))

(define (emit-for-clauses clauses body-str contexts)
  (match clauses
    [(list (and binding (for-binding name expr _ _)))
     (match-define
       (list pre-bound pre-rename-env post-bound post-rename-env _)
       (hash-ref contexts binding))
     (define-values (arg setup)
       (emit-js-binding-parameter
        binding "$beagle$item"
        #:constraint-bound pre-bound
        #:constraint-rename-env pre-rename-env
        #:install-bound post-bound
        #:install-rename-env post-rename-env))
     (define collection-str
       (parameterize ([current-js-bound pre-bound]
                      [current-rename-env pre-rename-env])
         (emit-expr expr)))
     (format "~a.map((~a) => ~a)"
             collection-str
             arg
             (if (null? setup)
                 body-str
                 (format "{ ~a return ~a; }" (string-join setup " ") body-str)))]
    [(list (and binding (for-binding name expr _ _))
           (for-when test)
           rest ...)
     (match-define
       (list pre-bound pre-rename-env post-bound post-rename-env _)
       (hash-ref contexts binding))
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str contexts)))
     (define-values (arg setup)
       (emit-js-binding-parameter
        binding "$beagle$item"
        #:constraint-bound pre-bound
        #:constraint-rename-env pre-rename-env
        #:install-bound post-bound
        #:install-rename-env post-rename-env))
     (define test-str
       (parameterize ([current-js-bound post-bound]
                      [current-rename-env post-rename-env])
         (emit-expr test)))
     (define collection-str
       (parameterize ([current-js-bound pre-bound]
                      [current-rename-env pre-rename-env])
         (emit-expr expr)))
     ;; A binding with setup (destructuring/defaults/constraint) must perform
     ;; that binding operation exactly once per source item, so the established
     ;; filter-before-body ordering is preserved by carrying a delayed producer
     ;; through the filter. Without setup there is nothing to share, and plain
     ;; filter-then-map is the same evaluation in the idiomatic shape.
     (define entry "$beagle$filtered$entry")
     (if (null? setup)
         (format "~a.filter((~a) => ~a).map((~a) => ~a)"
                 collection-str arg test-str arg inner)
         (format
          "~a.map((~a) => { ~a return [~a, () => ~a]; }).filter((~a) => ~a[0]).map((~a) => ~a[1]())"
          collection-str arg (string-join setup " ")
          test-str inner entry entry entry entry))]
    [(list (and binding (for-binding name expr _ _)) rest ...)
     (match-define
       (list pre-bound pre-rename-env post-bound post-rename-env _)
       (hash-ref contexts binding))
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str contexts)))
     (define-values (arg setup)
       (emit-js-binding-parameter
        binding "$beagle$item"
        #:constraint-bound pre-bound
        #:constraint-rename-env pre-rename-env
        #:install-bound post-bound
        #:install-rename-env post-rename-env))
     (define collection-str
       (parameterize ([current-js-bound pre-bound]
                      [current-rename-env pre-rename-env])
         (emit-expr expr)))
     (format "~a.map((~a) => ~a)"
             collection-str
             arg
             (if (null? setup)
                 inner
                 (format "{ ~a return ~a; }" (string-join setup " ") inner)))]
    [(list (? for-let? fl) rest ...)
     (define binds (for-let-bindings fl))
     (define binding-contexts (hash-ref contexts fl))
     (define let-strs
       (apply append
              (for/list ([b (in-list binds)]
                         [context (in-list binding-contexts)])
                (match-define
                  (list pre-bound pre-rename-env
                        post-bound post-rename-env index)
                  context)
                (define target (let-binding-name b))
                (define value
                  (parameterize ([current-js-bound pre-bound]
                                 [current-rename-env pre-rename-env])
                    (await-async-iife
                     (emit-expr (let-binding-value b)))))
                (if (binding-constraint b)
                    (parameterize ([current-js-bound post-bound]
                                   [current-rename-env post-rename-env])
                      (emit-let-binding-stmts
                       b value #f
                       (format "$beagle$for$let$~a" index)
                       #:constraint-bound pre-bound
                       #:constraint-rename-env pre-rename-env))
                    ;; Preserve the established unconstrained rendering.
                    (if (or (map-destructure? target)
                            (seq-destructure? target))
                        (let ([slot (format "$beagle$let$~a" index)])
                          (parameterize ([current-js-bound post-bound]
                                         [current-rename-env post-rename-env])
                            (append
                             (list (format "const ~a = ~a" slot value))
                             (emit-pattern-binding-statements
                              target slot b
                              #:default-bound pre-bound
                              #:default-rename-env pre-rename-env))))
                        (parameterize ([current-js-bound post-bound]
                                       [current-rename-env post-rename-env])
                          (list
                           (format "const ~a = ~a"
                                   (emit-binding-target b) value))))))))
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str contexts)))
     (format "(() => { ~a; return ~a; })()"
             (string-join let-strs "; ")
             inner)]
    [_ (error 'beagle-js "unsupported for clause combination")]))

;; --- doseq → forEach -------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (match clauses
    [(list (and binding (for-binding name expr _ _)))
     (define pre-bound (current-js-bound))
     (define pre-rename-env (current-rename-env))
     (define-values (post-bound post-rename-env)
       (extend-js-binding-context
        binding "doseq" 0 pre-bound pre-rename-env))
     (define body-str
       (parameterize ([current-js-bound post-bound]
                      [current-rename-env post-rename-env])
         (emit-body-stmts body "  ")))
     (define-values (arg setup)
       (emit-js-binding-parameter
        binding "$beagle$item"
        #:constraint-bound pre-bound
        #:constraint-rename-env pre-rename-env
        #:install-bound post-bound
        #:install-rename-env post-rename-env))
     (define collection-str
       (parameterize ([current-js-bound pre-bound]
                      [current-rename-env pre-rename-env])
         (emit-expr expr)))
     (define setup-str (string-join setup "\n  "))
     (define inner-body
       (if (null? setup)
           body-str
           (string-append setup-str "\n  " body-str)))
     (if (contains-await? body)
         ;; A forEach callback can't `await` sequentially (and the arrow
         ;; isn't async), so when the body awaits, emit a for-of loop —
         ;; which sequences awaits correctly inside the enclosing async fn.
         (format "for (const ~a of ~a) {\n  ~a\n}"
                 arg collection-str inner-body)
         (format "~a.forEach((~a) => {\n  ~a\n});"
                 collection-str arg inner-body))]
    [_ (error 'beagle-js "complex doseq clauses not yet supported for JS target")]))

;; --- defscalar -------------------------------------------------------------

(define (emit-scalar-predicate p)
  (define op
    (case (scalar-predicate-op p)
      [(>) ">"]
      [(>=) ">="]
      [(<) "<"]
      [(<=) "<="]
      ;; A Beagle equality predicate is a comparison. Rendering its source
      ;; spelling directly would turn `=` into JS assignment and `not=` into
      ;; an invalid token.
      [(=) "==="]
      [(not=) "!=="]
      [else
       (error 'beagle-js "defscalar: unsupported predicate operator: ~a"
              (scalar-predicate-op p))]))
  (format "v ~a ~a" op (emit-js-number (scalar-predicate-value p))))

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format "// ~a : scalar" (mangle-name name))
    (let* ([constructor-name
            (string->symbol (string-append "->" (symbol->string name)))]
           [ctor (mangle-name constructor-name)]
           [checks (string-join
                    (for/list ([p (in-list preds)])
                      (emit-scalar-predicate p))
                    " && ")])
      (format "~afunction ~a(v) {\n  if (!(~a)) throw new Error('scalar constraint violated');\n  return v;\n}"
              (if (or (current-js-export-marked?)
                      (exported-binding? constructor-name))
                  "export "
                  "")
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
         (runtime-call "keyword" (list (kw->prop d)))
         (runtime-call "symbol" (list (symbol->string d))))]
    [(null? d) "[]"]
    [(pair? d) (format "[~a]" (string-join (map emit-quoted d) ", "))]
    [else (~v d)]))

;; --- helpers ---------------------------------------------------------------

(define (emit-js-params params rest-p)
  (define hide-all?
    (bindings-have-constraints? (param-bindings params rest-p)))
  (define fixed
    (string-join
     (for/list ([p (in-list params)] [i (in-naturals)])
       (if (or hide-all? (pattern-param? p))
           (format "$beagle$param$~a" i)
           (emit-js-param p)))
     ", "))
  (if rest-p
    (let ([rest-name
           (if hide-all? "$beagle$param$rest" (emit-js-param rest-p))])
      (if (string=? fixed "")
          (format "...~a" rest-name)
          (format "~a, ...~a" fixed rest-name)))
    fixed))

(define (emit-pattern-binding-statements
         target source [owner target]
         #:default-bound [default-bound (current-js-bound)]
         #:default-rename-env
         [default-rename-env (current-rename-env)])
  (cond
    [(symbol? target)
     ;; `set!` may target any lexical binding. Pattern leaves therefore use
     ;; `let`; the hidden aggregate slot remains single-evaluation `const`.
     (list (format "let ~a = ~a;" (resolved-binder-name owner target) source))]
    [(seq-destructure? target)
     (append
      (apply append
             (for/list ([item (in-list (seq-destructure-names target))]
                        [i (in-naturals)])
               (emit-pattern-binding-statements
                item (format "~a[~a]" source i) owner
                #:default-bound default-bound
                #:default-rename-env default-rename-env)))
      (if (seq-destructure-rest-name target)
          (list
           (format "let ~a = ~a.slice(~a);"
                   (resolved-binder-name owner (seq-destructure-rest-name target))
                   source
                   (length (seq-destructure-names target))))
          '()))]
    [(map-destructure? target)
     (define defaults (map-destructure-or-defaults target))
     (append
      (if (map-destructure-as-name target)
          (list (format "let ~a = ~a;"
                        (resolved-binder-name owner (map-destructure-as-name target)) source))
          '())
      (for/list ([name (in-list (map-destructure-keys target))])
        (define property
          (kw->prop (string->symbol
                     (string-append ":" (symbol->string name)))))
        (define value (format "~a[~a]" source (js-string-lit property)))
        (define default (assq name defaults))
        (format "let ~a = ~a;"
                (resolved-binder-name owner name)
                (if default
                    (parameterize ([current-js-bound default-bound]
                                   [current-rename-env default-rename-env])
                      (format "(~a ?? ~a)"
                              value (emit-expr (cdr default))))
                    value))))]
    [else (error 'beagle-js "unsupported destructuring target: ~v" target)]))

(define (pattern-param? binding)
  (define target (binding-target binding))
  (or (map-destructure? target) (seq-destructure? target)))

(define (emit-js-binding-parameter
         binding source
         #:constraint? [constraint? #t]
         #:constraint-bound [constraint-bound (current-js-bound)]
         #:constraint-rename-env
         [constraint-rename-env (current-rename-env)]
         #:install-bound [install-bound (current-js-bound)]
         #:install-rename-env [install-rename-env (current-rename-env)])
  (define target (binding-target binding))
  (define constrained? (and (binding-constraint binding) #t))
  (define argument
    (parameterize ([current-js-bound install-bound]
                   [current-rename-env install-rename-env])
      (if (or (pattern-param? binding) constrained?)
          "$beagle$item"
          (emit-binding-target target))))
  (define incoming
    (if (or (pattern-param? binding) constrained?) source argument))
  (define check
    (and constraint?
         (parameterize ([current-js-bound constraint-bound]
                        [current-rename-env constraint-rename-env])
           (emit-binding-constraint-statement binding incoming))))
  (values
   argument
   (append
    (if check (list check) '())
    (parameterize ([current-js-bound install-bound]
                   [current-rename-env install-rename-env])
      (cond
        [(pattern-param? binding)
         (emit-pattern-binding-statements
          target source binding
          #:default-bound constraint-bound
          #:default-rename-env constraint-rename-env)]
        [constrained?
         (list (format "let ~a = ~a;"
                       (emit-binding-target target) source))]
        [else '()])))))

;; Multi-arity dispatch has one `$beagle$args` array instead of lexical
;; parameters. Materialize one source item, validate it, then project/bind it.
(define (emit-js-argument-binding-setup
         binding source [aggregate-slot "$beagle$arg"]
         #:constraint-bound [constraint-bound (current-js-bound)]
         #:constraint-rename-env
         [constraint-rename-env (current-rename-env)]
         #:install-bound [install-bound (current-js-bound)]
         #:install-rename-env [install-rename-env (current-rename-env)])
  (define target (param-binding-target binding))
  (define slot
    (and (or (pattern-param? binding) (binding-constraint binding))
         aggregate-slot))
  (define declaration
    (if slot
        (list (format "const ~a = ~a;" slot source))
        '()))
  (define value (or slot source))
  (define check
    (parameterize ([current-js-bound constraint-bound]
                   [current-rename-env constraint-rename-env])
      (emit-binding-constraint-statement binding value)))
  (append declaration
          (if check (list check) '())
          (parameterize ([current-js-bound install-bound]
                         [current-rename-env install-rename-env])
            (if (pattern-param? binding)
                (emit-pattern-binding-statements
                 target value binding
                #:default-bound constraint-bound
                 #:default-rename-env constraint-rename-env)
                (list (format "~a ~a = ~a;"
                              (if (binding-constraint binding) "let" "const")
                              (emit-binding-target target) value))))))

(define (emit-js-param-setup
         params [rest-param #f]
         [rename-env (current-rename-env)])
  (define bindings (param-bindings params rest-param))
  (define hide-all? (bindings-have-constraints? bindings))
  (define default-bound (current-js-bound))
  (define default-rename-env (current-rename-env))
  (define sources
    (for/list ([p (in-list bindings)] [i (in-naturals)])
      (cond
        [(and rest-param (= i (length params)))
         (if hide-all? "$beagle$param$rest" (emit-js-param rest-param))]
        [(or hide-all? (pattern-param? p))
         (format "$beagle$param$~a" i)]
        [else (emit-js-param p)])))
  ;; Emit predicates in the declaration environment. Authored parameter names
  ;; are deliberately absent here, matching the checker.
  (define checks
    (filter values
            (map emit-binding-constraint-statement bindings sources)))
  (define projections
    (parameterize ([current-rename-env rename-env])
      (apply append
             (for/list ([p (in-list bindings)]
                        [source (in-list sources)])
               (define target (param-binding-target p))
               (cond
                 [(pattern-param? p)
                  (emit-pattern-binding-statements
                   target source
                   #:default-bound default-bound
                   #:default-rename-env default-rename-env)]
                 [hide-all?
                  (list (format "let ~a = ~a;"
                                (emit-binding-target target) source))]
                 [else '()])))))
  (append checks projections))

;; Render a destructuring pattern to its JS form. Returns #f for non-destructure
;; inputs so callers can fall through to their own handling.
(define (emit-destructure p [owner p])
  (define target (binding-target p))
  (cond
    [(map-destructure? target)
     (define or-alist (map-destructure-or-defaults target))
     (define key-strs
       (for/list ([k (in-list (map-destructure-keys target))])
         (define default-pair (assq k or-alist))
         (if default-pair
             (format "~a = ~a" (resolved-binder-name owner k) (emit-expr (cdr default-pair)))
             (resolved-binder-name owner k))))
     (format "{~a}" (string-join key-strs ", "))]
    [(seq-destructure? target)
     (define mangled
       (for/list ([name (in-list (seq-destructure-names target))])
         (if (symbol? name)
             (resolved-binder-name owner name)
             (emit-destructure name owner))))
     (cond
       [(seq-destructure-rest-name target)
        (format "[~a, ...~a]" (string-join mangled ", ")
                (resolved-binder-name owner (seq-destructure-rest-name target)))]
       [else
        (format "[~a]" (string-join mangled ", "))])]
    [else #f]))

(define (emit-js-param p)
  (or (emit-destructure p p)
      (resolved-binder-name p (param-binding-target p))))

(define (emit-binding-target name [owner name])
  (define target (binding-target name))
  (cond
    [(emit-destructure target owner) => values]
    [(symbol? target)
     (resolved-binder-name owner target)]
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
       (define target (set!-form-target e))
       (cond
         [(resolved-ref? target)
          (note! (structural-name-leaf (resolved-ref-name target)))]
         [(symbol? target) (note! target)])
       (walk (set!-form-value e))]
      [(call-form? e) (walk (call-form-fn e)) (for-each walk (call-form-args e))]
      [(if-form? e) (walk (if-form-cond-expr e)) (walk (if-form-then-expr e))
                    (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(let-form? e) (for ([b (in-list (let-form-bindings e))]) (walk (let-binding-value b)))
                     (for ([b (in-list (let-form-bindings e))]
                           #:when (let-binding-constraint b))
                       (walk (let-binding-constraint b)))
                     (for-each walk (let-form-body e))]
      [(when-form? e) (walk (when-form-cond-expr e)) (for-each walk (when-form-body e))]
      [(do-form? e) (for-each walk (do-form-body e))]
      [(fn-form? e)
       (for ([p (in-list
                 (param-bindings (fn-form-params e) (fn-form-rest-param e)))]
             #:when (param-constraint p))
         (walk (param-constraint p)))
       (for-each walk (fn-form-body e))]
      [(fn-multi? e)
       (for ([a (in-list (fn-multi-arities e))])
         (for ([p (in-list
                   (param-bindings
                    (arity-clause-params a) (arity-clause-rest-param a)))]
               #:when (param-constraint p))
           (walk (param-constraint p)))
         (for-each walk (arity-clause-body a)))]
      [(cond-form? e) (for ([c (in-list (cond-form-clauses e))])
                        (walk (cond-clause-test c)) (for-each walk (cond-clause-body c)))]
      [(for-form? e) (for ([c (in-list (for-form-clauses e))])
                       (cond
                         [(for-binding? c)
                          (walk (for-binding-expr c))
                          (when (for-binding-constraint c)
                            (walk (for-binding-constraint c)))]
                         [(for-let? c)
                          (for ([b (in-list (for-let-bindings c))])
                            (walk (let-binding-value b))
                            (when (let-binding-constraint b)
                              (walk (let-binding-constraint b))))]
                         [(for-when? c) (walk (for-when-test c))]))
                     (for-each walk (for-form-body e))]
      [(doseq-form? e) (for ([c (in-list (doseq-form-clauses e))])
                         (when (for-binding? c)
                           (walk (for-binding-expr c))
                           (when (for-binding-constraint c)
                             (walk (for-binding-constraint c)))))
                       (for-each walk (doseq-form-body e))]
      [(case-form? e) (walk (case-form-test e))
                      (for ([c (in-list (case-form-clauses e))]) (walk (case-clause-body c)))
                      (when (case-form-default e) (walk (case-form-default e)))]
      [(loop-form? e)
       (for ([b (in-list (loop-form-bindings e))])
         (walk (let-binding-value b))
         (when (let-binding-constraint b)
           (walk (let-binding-constraint b))))
       (for-each walk (loop-form-body e))]
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

(define (collect-let-set!-target-syms bindings body)
  (collect-set!-target-syms
   (append
    (apply append
           (for/list ([binding (in-list bindings)])
             (filter values
                     (list (let-binding-value binding)
                           (let-binding-constraint binding)))))
    body)))

;; mutable? — emit `let` (the binding is reassigned via set! in its scope) instead
;; of the default `const`. Without this, `(set! <bare-local> v)` compiled to
;; `const x = …; x = …;` and threw "Assignment to constant variable" at runtime.
(define (emit-let-binding-stmts binding val-str [mutable? #f]
                                [aggregate-slot "$beagle$binding"]
                                #:constraint-bound
                                [constraint-bound (current-js-bound)]
                                #:constraint-rename-env
                                [constraint-rename-env (current-rename-env)]
                                #:constraint-type-env
                                [constraint-type-env (current-type-env)]
                                #:constraint-rep-env
                                [constraint-rep-env (current-rep-env)])
  (define target (let-binding-name binding))
  (define kw (if mutable? "let" "const"))
  (define (constraint-check source)
    (parameterize ([current-js-bound constraint-bound]
                   [current-rename-env constraint-rename-env]
                   [current-type-env constraint-type-env]
                   [current-rep-env constraint-rep-env])
      (emit-binding-constraint-statement binding source)))
  (cond
    [(or (map-destructure? target)
         (seq-destructure? target)
         (binding-constraint binding))
     (define check (constraint-check aggregate-slot))
     (append
      (list (format "const ~a = ~a;" aggregate-slot val-str))
      (if check (list check) '())
      (if (or (map-destructure? target) (seq-destructure? target))
          (emit-pattern-binding-statements
           target aggregate-slot binding
           #:default-bound constraint-bound
           #:default-rename-env constraint-rename-env)
          (list (format "~a ~a = ~a;"
                        kw (emit-binding-target binding) aggregate-slot))))]
    [else
     (define name (emit-binding-target binding))
     (define check (constraint-check name))
     (append
      (list (format "~a ~a = ~a;" kw name val-str))
      (if check (list check) '()))]))

;; Shared binding-sequence emitter for BOTH `let`-as-IIFE (emit-expr-core) and
;; the return-position inline `let` (emit-return-position) — same flat
;; const/let statement sequence in one JS block either way, so both need the
;; same shadow-freshening for a repeated (same-name) binding. See
;; `current-rename-env` above for why: without it, `(let [x 1 x (+ x 1)] x)`
;; emits two `const x = …;` in one block -> JS SyntaxError at runtime despite
;; passing `beagle check`. Returns (values bind-strs rep-env-out type-env-out
;; rename-env-out); callers still compute `let-names` themselves for
;; `with-bindings`/inline-scope tracking.
(define (emit-let-bindings bindings mutated-syms)
  ;; Constraints and RHS expressions resolve in the progressively extended
  ;; environment *before* the binding they belong to is installed. When any
  ;; declaration is constrained, hidden authored slots prevent a same-named
  ;; outer predicate from being captured by the new JS local's TDZ.
  (define constrained-sequence? (bindings-have-constraints? bindings))
  (define-values (strs _bound rep-env type-env rename-env _seen)
    (for/fold ([strs '()]
               [bound (current-js-bound)]
               [rep-env (current-rep-env)]
               [type-env (current-type-env)]
               [rename-env (current-rename-env)]
               [seen (hash)])
              ([b (in-list bindings)]
               [i (in-naturals)])
      (define val-str (await-async-iife
                        (parameterize ([current-js-bound bound]
                                       [current-rep-env rep-env]
                                       [current-type-env type-env]
                                       [current-rename-env rename-env])
                          (emit-expr (let-binding-value b)))))
      (define constrained-id
        (and constrained-sequence? (next-constrained-binding-id!)))
      (define new-names (names-from-binding-target (let-binding-name b)))
      ;; Freshen any name this SAME let-sequence already declared: 1st
      ;; occurrence keeps its plain mangled name (also overrides any stale
      ;; mapping inherited from an outer scope's rename-env — a fresh nested
      ;; `let` binding the same source name is a fresh JS scope, not a clash),
      ;; every later occurrence gets a `_shadowN` suffix so the block declares
      ;; distinct identifiers.
      (define-values (rename-env* seen*)
        (for/fold ([re rename-env] [sn seen]) ([nm (in-list new-names)])
          (define n (hash-ref sn nm 0))
          (define js-name
            (cond
              [constrained-sequence?
               (format "$beagle$constrained$binding$~a$~a"
                       constrained-id (mangle-name nm))]
              [(zero? n)
               (mangle-name (binder-output-symbol b nm))]
              [else
               (format "~a_shadow~a"
                       (mangle-name (binder-output-symbol b nm)) n)]))
          (values (rename-env-set-binder re b nm js-name)
                  (hash-set sn nm (add1 n)))))
      (define mutable? (for/or ([nm (in-list new-names)]) (and (memq nm mutated-syms) #t)))
      (define stmts (parameterize ([current-rename-env rename-env*])
                      (emit-let-binding-stmts
                       b val-str mutable?
                       (if constrained-sequence?
                           (format "$beagle$constrained$binding$~a"
                                   constrained-id)
                           (format "$beagle$binding$~a" i))
                       #:constraint-bound bound
                       #:constraint-rename-env rename-env
                       #:constraint-type-env type-env
                       #:constraint-rep-env rep-env)))
      (define name (let-binding-name b))
      (define bty (and (symbol? name)
                       (or (let-binding-type b) (node-type (let-binding-value b)))))
      (define rep (if (symbol? name)
                      (parameterize ([current-rep-env rep-env] [current-type-env type-env])
                        (classify-rep (let-binding-value b)))
                      'native))
      (define-values (projected-type-env projected-rep-env)
        (extend-binding-type-envs (list name) type-env rep-env))
      (values (append strs stmts)
              (set-union bound (list->set new-names))
              (if (and (symbol? name) (not (eq? rep 'native)))
                  (hash-set projected-rep-env name rep)
                  projected-rep-env)
              (if bty (hash-set projected-type-env name bty) projected-type-env)
              rename-env*
              seen*)))
  (values strs rep-env type-env rename-env))

(define (expr-contains-recur? e)
  (cond
    [(recur-form? e) #t]
    [(logical-call? e)
     (for/or ([a (in-list (call-form-args e))])
       (expr-contains-recur? a))]
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
    [(when-form? e)
     (body-contains-recur? (when-form-body e))]
    [(when-some-form? e)
     (body-contains-recur? (when-some-form-body e))]
    [(if-let-form? e)
     (or (expr-contains-recur? (if-let-form-then-body e))
         (and (if-let-form-else-body e)
              (expr-contains-recur? (if-let-form-else-body e))))]
    [(if-some-form? e)
     (or (expr-contains-recur? (if-some-form-then-body e))
         (expr-contains-recur? (if-some-form-else-body e)))]
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
  (define contexts (current-loop-binding-slots))
  (if (not contexts)
      (string-append
       (string-join (append temps assigns) " ")
       " continue;")
      (let ([candidate-setups
             (apply append
                    (for/list ([entry (in-list contexts)]
                               [i (in-naturals)])
                      (match-define
                        (list binding _slot
                              constraint-bound constraint-rename-env
                              constraint-type-env constraint-rep-env
                              install-bound install-rename-env)
                        entry)
                      (define source (format "_recur_~a" i))
                      (define check
                        (parameterize
                            ([current-js-bound constraint-bound]
                             [current-rename-env constraint-rename-env]
                             [current-type-env constraint-type-env]
                             [current-rep-env constraint-rep-env])
                          (emit-binding-constraint-statement binding source)))
                      (define target (let-binding-name binding))
                      (define install
                        (parameterize
                            ([current-js-bound install-bound]
                             [current-rename-env install-rename-env])
                          (if (or (map-destructure? target)
                                  (seq-destructure? target))
                              (emit-pattern-binding-statements
                               target source binding
                               #:default-bound constraint-bound
                               #:default-rename-env constraint-rename-env)
                              (list
                               (format "const ~a = ~a;"
                                       (emit-binding-target binding) source)))))
                      (append (if check (list check) '()) install)))])
        (format "{ ~a continue; }"
                (string-join
                 (append temps candidate-setups assigns)
                 " ")))))

(define (logical-call? e)
  (and (call-form? e)
       (symbol? (call-form-fn e))
       (memq (call-form-fn e) '(and or))))

(define (clj-truthy-test value-str)
  (format "~a !== false && ~a != null" value-str value-str))

(define (clj-truthy-expr value-str)
  (format "((_truthy) => _truthy !== false && _truthy != null)(~a)"
          value-str))

(define (statically-bool? e)
  (define type (arg-type e))
  (and (type-prim? type)
       (eq? (unqualify-type-name (type-prim-name type)) 'Bool)))

(define (emit-truthy-expr e)
  (define value-str (emit-expr e))
  (if (statically-bool? e) value-str (clj-truthy-expr value-str)))

(define (emit-logical-expr op args)
  (define identity-value (if (eq? op 'and) "true" "null"))
  (cond
    [(null? args) identity-value]
    [(null? (cdr args)) (emit-expr (car args))]
    [else
     (define next (emit-logical-expr op (cdr args)))
     (define first (car args))
     (define first-str (emit-expr first))
     (if (statically-bool? first)
         (format "(~a ~a ~a)" first-str (if (eq? op 'and) "&&" "||") next)
         (let ([truthy (clj-truthy-test "_logical")])
           (format "((_logical) => (~a ? ~a : ~a))(~a)"
                   truthy
                   (if (eq? op 'and) next "_logical")
                   (if (eq? op 'and) "_logical" next)
                   first-str)))]))

;; Logical loop tails lower as statements because recur never has a JS value.
(define (emit-logical-loop-stmt e bind-names emit-value)
  (define op (call-form-fn e))
  (define identity-value (if (eq? op 'and) "true" "null"))
  (define (walk args)
    (cond
      [(null? args) (emit-value identity-value)]
      [(null? (cdr args))
       (emit-loop-stmt (car args) bind-names emit-value)]
      [else
       (emit-loop-stmt
        (car args)
        bind-names
        (lambda (value-str)
          (define temp (format "_logical_~a" (next-logical-id!)))
          (define truthy (clj-truthy-test temp))
          (define next-str (walk (cdr args)))
          (define short-str (emit-value temp))
          (if (eq? op 'and)
              (format "const ~a = ~a; if (~a) { ~a } else { ~a }"
                      temp value-str truthy next-str short-str)
              (format "const ~a = ~a; if (~a) { ~a } else { ~a }"
                      temp value-str truthy short-str next-str))))]))
  (walk (call-form-args e)))

(define (emit-loop-stmt e bind-names
                        [emit-value (lambda (value-str)
                                      (format "return ~a;" value-str))])
  (define (emit-loop-body-seq forms)
    (string-append
     (string-join (map emit-expr-stmt (drop-right forms 1)) " ")
     (if (> (length forms) 1) " " "")
     (emit-loop-stmt (last forms) bind-names emit-value)))
  (cond
    [(logical-call? e)
     (emit-logical-loop-stmt e bind-names emit-value)]
    [(and (if-form? e) (expr-contains-recur? e))
     (define cond-str
       (emit-truthy-expr (if-form-cond-expr e)))
     (define then-str (emit-loop-stmt (if-form-then-expr e) bind-names emit-value))
     (if (if-form-else-expr e)
       (let ([else-str (emit-loop-stmt (if-form-else-expr e) bind-names emit-value)])
         (format "if (~a) { ~a } else { ~a }" cond-str then-str else-str))
       ;; No else (e.g. from `when`): falling through the condition means no
       ;; recur fired, so the loop is done — return nil. Without this the
       ;; enclosing `while (true)` spins forever when the condition goes false.
       (format "if (~a) { ~a } else { ~a }" cond-str then-str
               (emit-value "null")))]
    [(and (when-form? e) (body-contains-recur? (when-form-body e)))
     (format "if (~a) { ~a } else { ~a }"
             (emit-truthy-expr (when-form-cond-expr e))
             (emit-loop-body-seq (when-form-body e))
             (emit-value "null"))]
    [(and (or (when-let-form? e) (when-some-form? e))
          (body-contains-recur?
           (if (when-let-form? e)
               (when-let-form-body e)
               (when-some-form-body e))))
     (define name
       (if (when-let-form? e)
           (when-let-form-name e)
           (when-some-form-name e)))
     (define value
       (if (when-let-form? e)
           (when-let-form-expr e)
           (when-some-form-expr e)))
     (define forms
       (if (when-let-form? e)
           (when-let-form-body e)
           (when-some-form-body e)))
     (define js-name (mangle-name name))
     (parameterize ([current-rename-env
                     (hash-set (current-rename-env) name js-name)])
       (with-bindings (list name)
         (lambda ()
           (format "{ const ~a = ~a; if (~a != null) { ~a } else { ~a } }"
                   js-name (emit-expr value) js-name
                   (emit-loop-body-seq forms)
                   (emit-value "null")))))]
    [(and (or (if-let-form? e) (if-some-form? e))
          (expr-contains-recur? e))
     (define name
       (if (if-let-form? e) (if-let-form-name e) (if-some-form-name e)))
     (define value
       (if (if-let-form? e) (if-let-form-expr e) (if-some-form-expr e)))
     (define then-expr
       (if (if-let-form? e)
           (if-let-form-then-body e)
           (if-some-form-then-body e)))
     (define else-expr
       (if (if-let-form? e)
           (if-let-form-else-body e)
           (if-some-form-else-body e)))
     (define js-name (mangle-name name))
     (parameterize ([current-rename-env
                     (hash-set (current-rename-env) name js-name)])
       (with-bindings (list name)
         (lambda ()
           (format "{ const ~a = ~a; if (~a != null) { ~a } else { ~a } }"
                   js-name (emit-expr value) js-name
                   (emit-loop-stmt then-expr bind-names emit-value)
                   (if else-expr
                       (emit-loop-stmt else-expr bind-names emit-value)
                       (emit-value "null"))))))]
    [(and (let-form? e) (body-contains-recur? (let-form-body e)))
     (define let-names (apply append (map (lambda (b) (names-from-binding-target (let-binding-name b))) (let-form-bindings e))))
     (define mutated-syms
       (collect-let-set!-target-syms (let-form-bindings e) (let-form-body e)))
     (define-values (binding-strs rep-env-out type-env-out rename-env-out)
       (emit-let-bindings (let-form-bindings e) mutated-syms))
     (with-bindings let-names
       (lambda ()
         (parameterize ([current-rep-env rep-env-out]
                        [current-type-env type-env-out]
                        [current-rename-env rename-env-out])
           ;; Only the tail form drives the loop (recur/return); earlier forms are
           ;; side-effecting statements. Running emit-loop-stmt over all of them
           ;; would `return` a non-tail expression and make the recur unreachable.
           (define forms (let-form-body e))
           (define body-str (emit-loop-body-seq forms))
           (string-append (string-join binding-strs " ") " " body-str))))]
    [(and (cond-form? e) (for/or ([c (in-list (cond-form-clauses e))]) (body-contains-recur? (cond-clause-body c))))
     (define (else-clause? c)
       (let ([t (cond-clause-test c)]) (and (symbol? t) (or (eq? t ':else) (eq? t 'else)))))
     (define parts
       (for/list ([c (in-list (cond-form-clauses e))])
         (define test (cond-clause-test c))
         (define body-str (emit-loop-body-seq (cond-clause-body c)))
         (if (else-clause? c)
           (format "{ ~a }" body-str)
           (format "if (~a) { ~a }"
                   (emit-truthy-expr test) body-str))))
     ;; No :else means no clause may match — terminate the loop with nil rather
     ;; than spinning the enclosing while(true).
     (define has-else? (for/or ([c (in-list (cond-form-clauses e))]) (else-clause? c)))
     (string-append (string-join parts " else ")
                    (if has-else? ""
                        (format " else { ~a }" (emit-value "null"))))]
    [(and (do-form? e) (body-contains-recur? (do-form-body e)))
     (define exprs (do-form-body e))
     (define stmts (drop-right exprs 1))
     (define last-e (last exprs))
     (define side-strs (map emit-expr-stmt stmts))
     (format "~a ~a" (string-join side-strs " ")
             (emit-loop-stmt last-e bind-names emit-value))]
    [(recur-form? e)
     (emit-recur-stmts e bind-names)]
    [else
     (emit-value (emit-expr e))]))

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
         (define mutated-syms (collect-let-set!-target-syms bindings body))
         (define-values (bind-strs rep-env-out type-env-out rename-env-out)
           (emit-let-bindings bindings mutated-syms))
         (with-bindings let-names
           (lambda ()
             (parameterize ([current-js-inline-scope
                             (set-union (current-js-inline-scope) (list->set let-names))]
                            [current-rep-env rep-env-out]
                            [current-type-env type-env-out]
                            [current-rename-env rename-env-out])
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
             (emit-truthy-expr (when-form-cond-expr e))
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
             (emit-truthy-expr (if-form-cond-expr e))
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
             (emit-truthy-expr (if-form-cond-expr e))
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
         (define mutated-syms (collect-let-set!-target-syms bindings body))
         (define-values (bind-strs rep-env-out type-env-out rename-env-out)
           (emit-let-bindings bindings mutated-syms))
         (with-bindings let-names
           (lambda ()
             (parameterize ([current-js-inline-scope
                             (set-union (current-js-inline-scope) (list->set let-names))]
                            [current-rep-env rep-env-out]
                            [current-type-env type-env-out]
                            [current-rename-env rename-env-out])
               (string-append
                (string-join bind-strs (string-append "\n" indent))
                "\n" indent
                (emit-body-stmts body indent)))))))]
    [(do-form? e)
     (emit-body-stmts (do-form-body e) indent)]
    [(when-form? e)
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a}"
             (emit-truthy-expr (when-form-cond-expr e))
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
             (emit-truthy-expr (if-form-cond-expr e))
             inner
             (emit-body-stmts-inline (list (if-form-then-expr e)) inner)
             indent)]
    ;; EFFECT position: if-WITH-else lowers to `if(c){...}else{...}`. Value/tail
    ;; positions keep the ternary (emit-expr-core / emit-return-position). Both
    ;; branches recurse through emit-body-stmts-inline so nested ctrl-flow lowers.
    [(if-form? e)
     (define inner (string-append indent "  "))
     (format "if (~a) {\n~a~a\n~a} else {\n~a~a\n~a}"
             (emit-truthy-expr (if-form-cond-expr e))
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
                   (emit-truthy-expr (cond-clause-test c))
                   inner body-str indent))))
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

(provide js-backend
         current-js-export-names)
