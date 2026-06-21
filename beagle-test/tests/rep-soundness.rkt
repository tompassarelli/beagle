#lang racket/base

;; ============================================================================
;; P3 REPRESENTATION-SELECTION SOUNDNESS GATE  (the "trust spine" audit)
;; ============================================================================
;;
;; Asserts the two soundness invariants of rep-selection (compound-key map /
;; value-dedup set -> $$bc-backed HAMT; everything else native) on a corpus of
;; representative snippets:
;;
;;   (a) NO FALSE PROMOTION (size): a program with no provably-compound key/elem
;;       allocation emits ZERO hamt refs. A scalar-keyed map, a vector, a set
;;       LITERAL, and a scalar assoc all stay native.
;;
;;   (b) NO CORRECTNESS HOLE: a program that allocates a compound-keyed map or a
;;       value-deduped set over compound elements DOES route to the HAMT — native
;;       JS object keys collide ("[object Object]") and `new Set` ref-dedups, so
;;       leaving these native would silently corrupt value semantics.
;;
;; PLUS an INDEPENDENT ORACLE: it re-derives the provably-compound predicate from
;; the captured per-node type table (NOT the emitter's classify-rep) and asserts
;; the count of HAMT-predicted alloc sites matches the HAMT ops the emitter
;; actually produced. Two implementations agreeing is the real check — a drift in
;; either side fails the gate.
;;
;; This is a STRUCTURAL test (emits + inspects JS strings; no node/bb needed), so
;; it stays in the active tier as a permanent regression lock.
;; ============================================================================

(require rackunit
         rackunit/text-ui
         racket/string
         racket/list
         (file "../../beagle-lib/private/parse.rkt")
         (file "../../beagle-lib/private/check.rkt")
         (file "../../beagle-lib/private/emit.rkt")
         (file "../../beagle-lib/private/ast.rkt")
         (file "../../beagle-lib/private/types.rkt"))

(define (br . xs) (cons BRACKET-TAG xs))
(define (mt . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

;; Emit a strict JS module from body forms, with per-node type capture on (the
;; real emit path). Returns (values emitted-js type-table prog).
(define (emit+types body-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f))
          (append (list '(ns test.rep) '(define-mode strict) '(define-target js))
                  body-forms))
     #:source-path "rep-soundness.rkt"))
  (define tbl (make-hasheq))
  (parameterize ([current-type-table tbl]) (type-check! prog))
  (register-program-type-table! prog tbl)
  (values (parameterize ([current-type-table tbl]) (emit-program prog)) tbl prog))

(define (hamt-refs js) (regexp-match* #rx"hamt(Map|Set)[A-Za-z]*" js))

;; --- independent oracle: provably-compound, re-derived from the type table ---
(define (compound-type? ty)
  (and (type-app? ty) (and (memq (type-app-ctor ty) '(Map Set Vec Vector List)) #t)))
(define (map-key-of ty)
  (and (type-app? ty) (eq? (type-app-ctor ty) 'Map) (pair? (type-app-args ty)) (car (type-app-args ty))))
(define (seq-elem-of ty)
  (and (type-app? ty) (memq (type-app-ctor ty) '(Vec Vector List Set)) (pair? (type-app-args ty)) (car (type-app-args ty))))

;; Count alloc sites the ORACLE predicts must be HAMT, walking the type table:
;;   - a non-empty map literal whose key type is compound
;;   - a `set` call whose argument's element type is compound
;;   - an `assoc` call with any compound key argument
;; (set LITERALS are never HAMT — distinct by construction, $$bc handles them.)
(define (oracle-hamt-site-count tbl)
  (for/sum ([(n t) (in-hash tbl)])
    (cond
      [(and (map-form? n) (pair? (map-form-pairs n)) (compound-type? (map-key-of t))) 1]
      [(and (call-form? n) (eq? (call-form-fn n) 'set))
       (define arg (and (pair? (call-form-args n)) (car (call-form-args n))))
       (if (compound-type? (seq-elem-of (and arg (hash-ref tbl arg #f)))) 1 0)]
      [(and (call-form? n) (eq? (call-form-fn n) 'assoc))
       (if (let loop ([r (and (pair? (call-form-args n)) (cdr (call-form-args n)))])
             (cond [(or (not r) (null? r)) #f]
                   [(compound-type? (hash-ref tbl (car r) #f)) #t]
                   [(or (null? (cdr r)) (null? (cddr r))) #f]
                   [else (loop (cddr r))]))
           1 0)]
      [else 0])))

(define (assert-native name . body)
  (test-case (string-append "NO FALSE PROMOTION: " name)
    (define-values (js tbl prog) (emit+types body))
    (check-equal? (hamt-refs js) '()
                  (format "~a must emit ZERO hamt refs (all-native), got ~a in:\n~a"
                          name (hamt-refs js) js))
    (check-equal? (oracle-hamt-site-count tbl) 0
                  (format "oracle predicts no HAMT sites for ~a" name))))

(define (assert-hamt name expect-op . body)
  (test-case (string-append "NO CORRECTNESS HOLE: " name)
    (define-values (js tbl prog) (emit+types body))
    (check-true (string-contains? js expect-op)
                (format "~a must route to ~a, got refs ~a in:\n~a"
                        name expect-op (hamt-refs js) js))
    (check-true (> (oracle-hamt-site-count tbl) 0)
                (format "oracle must predict >=1 HAMT site for ~a" name))))

(run-tests
 (test-suite "P3 rep-selection soundness gate"

   ;; ---- (a) NO FALSE PROMOTION — these stay 100% native ----
   (assert-native "scalar-key map literal"
     `(def m :- Any ,(mt ':a 1)))
   (assert-native "nested-VALUE scalar-key map (compound values, scalar keys)"
     `(def m :- Any ,(mt ':a (br 1 2) ':b (mt ':c 3))))
   (assert-native "vector literal (always native COW array)"
     `(def v :- Any ,(br 1 2 3)))
   (assert-native "set literal with compound elems (distinct by construction)"
     `(defn f () :- Bool (contains? ,(st (br 1 2) (br 3 4)) ,(br 1 2))))
   (assert-native "scalar assoc (key arg scalar)"
     `(defn f () :- Any (assoc ,(mt ':a 1) ':b 2)))
   (assert-native "count of scalar set literal -> .size, no HAMT"
     `(defn f () :- Int (count ,(st 1 2 3))))
   (assert-native "distinct over compound values (array via $$bc, no HAMT)"
     `(defn f () :- Int (count (distinct ,(br (mt ':a 1) (mt ':a 1))))))

   ;; ---- (b) NO CORRECTNESS HOLE — these MUST route to HAMT ----
   (assert-hamt "compound-key map literal" "hamtMap("
     `(def m :- Any ,(mt (mt ':a 1) ':found)))
   (assert-hamt "vector-key map literal" "hamtMap("
     `(def m :- Any ,(mt (br 1 2) ':x)))
   (assert-hamt "assoc with compound key" "hamtMapAssoc("
     `(defn f () :- Any (assoc ,(mt) ,(mt ':k 1) "a")))
   (assert-hamt "value-dedup set over compound elems" "hamtSet("
     `(defn f () :- Int (count (set ,(br (br 1 2) (br 1 2))))))
   (assert-hamt "count of value-set -> hamtSetCount" "hamtSetCount("
     `(defn f () :- Int (count (set ,(br (br 1 2))))))

   ;; ---- (b') the FLIP: not-provably-scalar key/elem -> HAMT (records / Any /
   ;;      union / heterogeneous), with polymorphic $$bc reads for Any-typed colls ----
   (test-case "record-key map literal -> hamtMap (record emits as object -> collides native)"
     (define-values (js tbl prog)
       (emit+types (list `(defrecord K ((x :- Int)))
                         `(def m :- Any ,(mt `(->K 1) ':a)))))
     (check-true (string-contains? js "hamtMap(")
                 (format "record-key map must route to HAMT, got:\n~a" js)))
   (test-case "Any-typed key assoc -> hamtMapAssoc (Any not provably scalar)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f ((k :- Any) (v :- Any)) :- Any (assoc ,(mt) k v)))))
     (check-true (string-contains? js "hamtMapAssoc(")
                 (format "Any-typed key assoc must route to HAMT, got:\n~a" js)))
   (test-case "heterogeneous-key literal (scalar + compound) -> hamtMap"
     (define-values (js tbl prog)
       (emit+types (list `(def m :- Any ,(mt ':a 1 (mt ':b 2) 5)))))
     (check-true (string-contains? js "hamtMap(")
                 (format "heterogeneous-key literal must route to HAMT, got:\n~a" js)))
   (test-case "read through an Any-typed param routes to polymorphic $$bc$get"
     (define-values (js tbl prog)
       (emit+types (list `(defn f ((m :- Any)) :- Any (get m ,(mt ':k 1))))))
     (check-true (string-contains? js "$$bc$get(")
                 (format "Any-typed coll read must be polymorphic $$bc$get (a native scalar map can flow into an Any read), got:\n~a" js)))

   ;; ---- (b''') #4 runtime dedup: set-builders produce SETS (not arrays);
   ;;      compound -> hamtSet; count sees through to .size/hamtSetCount ----
   (test-case "conj onto a native set -> a Set, count -> .size (not array/.length)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (conj ,(st 1 2) 3))))))
     (check-true (string-contains? js "new Set(") (format "conj-set must build a Set:\n~a" js))
     (check-true (string-contains? js ".size")    (format "count of a conj-set must be .size:\n~a" js)))
   (test-case "conj onto a value-set -> hamtSetAdd"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (conj (set ,(br (br 1 2))) ,(br 1 2)))))))
     (check-true (string-contains? js "hamtSetAdd(") (format "conj onto a value-set must be hamtSetAdd:\n~a" js)))
   (test-case "into a value-set -> runtime hamtSetAdd fold"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (into (set ,(br (br 1 2))) ,(br (br 1 2) (br 3 4))))))))
     (check-true (string-contains? js "hamtSetAdd(") (format "into a value-set must fold hamtSetAdd:\n~a" js)))
   (test-case "frequencies over compound elems -> hamtMap (value-keyed)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (frequencies ,(br (br 1 2) (br 1 2))))))))
     (check-true (string-contains? js "hamtMapAssoc(") (format "frequencies over compound must be hamtMap:\n~a" js)))
   ;; ELEMENT-driven (not target-rep): an EMPTY or native/literal set target with
   ;; compound elements must STILL value-dedup. (Residual caught by beagle-2 —
   ;; routing on the target's rep alone left these native.)
   (test-case "into an EMPTY set over compound elems -> hamtSetAdd (element-driven)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (into ,(st) ,(br (br 1 2) (br 1 2) (br 3 4))))))))
     (check-true (string-contains? js "hamtSetAdd(") (format "into #{} over compound must value-dedup:\n~a" js)))
   (test-case "into a compound set LITERAL target -> hamtSetAdd (coerce target)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (into ,(st (br 1 2)) ,(br (br 1 2) (br 3 4))))))))
     (check-true (string-contains? js "hamtSetAdd(") (format "into a compound set literal must value-dedup:\n~a" js)))
   (test-case "conj compound onto an empty set -> hamtSetAdd (element-driven)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (conj ,(st) ,(mt ':a 1)))))))
     (check-true (string-contains? js "hamtSetAdd(") (format "conj compound onto #{} must value-dedup:\n~a" js)))
   (test-case "into a VECTOR stays a native array (not over-promoted)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int (count (into ,(br 1) ,(br 2 3)))))))
     (check-false (string-contains? js "hamtSet") (format "into a vector must stay native:\n~a" js)))

   ;; (b'') a SCALAR keyword read on a HAMT-repped map must still hit the HAMT —
   ;; (get m :a) / (:a m) canonicalize to kw-access (native dot `m.a`); on a
   ;; hamtMap object that reads `undefined`. Dispatch on the COLL's rep, not the
   ;; (scalar) key. (Regression caught by beagle-2's adversarial corpus.)
   (test-case "scalar keyword read on a HAMT-repped map -> hamtMapGet (not native dot)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Int
                            (let (m ,(mt ':a 1 (mt ':b 2) 5)) (get m :a))))))
     (check-true (string-contains? js "hamtMapGet(m,")
                 (format "scalar-key read on a HAMT map must be hamtMapGet, got:\n~a" js))
     (check-false (regexp-match? #rx"m\\.a" js)
                  (format "must NOT emit native dot-access m.a on a HAMT:\n~a" js)))
   (test-case "scalar keyword read on an Any-typed param -> polymorphic $$bc$get"
     (define-values (js tbl prog)
       (emit+types (list `(defn f ((m :- (Map Any Int))) :- Int (get m :a)))))
     (check-true (string-contains? js "$$bc$get(m,")
                 (format "scalar-key read on an Any-typed map must be $$bc$get, got:\n~a" js)))

   ;; ---- (c) read-through-var consistency (the corruption crux) ----
   (test-case "read through let-bound compound map routes to hamtMapGet (not native index)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Keyword
                            (let (m ,(mt (mt ':a 1) ':x)) (get m ,(mt ':a 1)))))))
     (check-true (string-contains? js "hamtMapGet(m,")
                 (format "let-bound compound map read must be hamtMapGet, got:\n~a" js))
     (check-false (regexp-match? #rx"m\\[" js)
                  (format "must NOT emit a native index m[...] on a HAMT:\n~a" js)))

   ;; ---- (d) independent oracle <-> emit cross-check on a mixed program ----
   (test-case "oracle HAMT-site count matches emit (mixed native + compound)"
     (define-values (js tbl prog)
       (emit+types (list `(defn f () :- Any
                            (let (s ,(mt ':a 1)            ; native
                                  c ,(mt (mt ':k 1) ':v)   ; HAMT
                                  v ,(br 1 2 3))           ; native
                              (assoc c ,(mt ':k 2) ':w)))))) ; HAMT (compound key)
     (define oracle (oracle-hamt-site-count tbl))
     (check-true (>= oracle 2) (format "oracle should see >=2 HAMT sites, saw ~a" oracle))
     (check-true (> (length (hamt-refs js)) 0)
                 (format "emit should contain hamt refs, got none in:\n~a" js))
     (check-true (string-contains? js "{a: 1}")
                 (format "the scalar map must stay native in:\n~a" js)))
 ))
