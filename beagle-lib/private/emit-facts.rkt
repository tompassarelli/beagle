#lang racket/base

;; In-tree beagle backend: emit a parsed program's AST as CNF claim triples.
;;
;; Backbone is a REFLECTIVE walk over the transparent AST structs (ast.rkt) — so
;; coverage is complete by construction: every current and future form is walked
;; via struct->vector, nothing is silently dropped (the out-of-tree bridge's
;; failure mode). Semantic OVERLAYS add the graph-meaningful edges (defn/def/
;; record nodes, call edges) for the forms worth querying with Datalog.
;;
;; Sibling to emit-js.rkt / emit-nix.rkt; lives in beagle-lib/private so it
;; versions in lockstep with ast.rkt instead of rotting against an external snapshot.
;;
;; Output: newline-separated EDN triples  [<subj> "<pred>" <obj>]  where subj is a
;; minted integer node-id, pred a string, obj an int node-id or an inline literal.

(require racket/string
         "parse.rkt"          ; re-exports ast.rkt structs + program accessors
         "emit-dispatch.rkt")

(provide claims-emit-program)

;; --- per-program state (fresh per emit) ---
(define cur-triples (make-parameter #f))   ; box of (listof (list subj pred obj))
(define cur-id      (make-parameter #f))   ; box of int

(define (fresh-id!)
  (define b (cur-id))
  (set-box! b (add1 (unbox b)))
  (unbox b))

(define (emit! s p o)
  (set-box! (cur-triples) (cons (list s p o) (unbox (cur-triples)))))

;; Emit a field edge AND, when the value is a MINTED node (a compound, not an
;; inlined literal), a uniform `child` edge. This makes structural containment a
;; SINGLE predicate to traverse transitively (so a defn reaches every nested call
;; via `child`+), and makes node-refs unambiguous vs literal integers downstream.
(define (field! parent pred x)
  (define o (val->obj x))
  (emit! parent pred o)
  (unless (lit? x) (emit! parent "child" o))
  o)

;; --- literals: inlined as triple objects, NOT minted as nodes (keep leaves compact) ---
(define (lit? x)
  (or (string? x) (number? x) (boolean? x) (symbol? x) (keyword? x) (char? x) (null? x)))

(define (lit->obj x)
  (cond
    [(keyword? x) (string-append ":" (keyword->string x))]
    [(symbol? x)  (symbol->string x)]
    [(char? x)    (string x)]
    [(null? x)    "()"]
    [else x]))                          ; string / number / boolean pass through

;; --- value -> triple-object (minting child nodes for compounds) ---
(define (val->obj x)
  (cond
    [(lit? x)     (lit->obj x)]
    [(struct? x)  (emit-struct! x)]
    [(list? x)    (seq->id x)]
    [(pair? x)    (emit-pair! x)]       ; dotted pair, e.g. a map entry (:k . v)
    [(vector? x)  (seq->id (vector->list x))]
    [else (error 'emit-claims "unrepresentable value: ~s" x)]))

(define (emit-pair! x)
  (define id (fresh-id!))
  (emit! id "form-kind" "pair")
  (field! id "key"   (car x))
  (field! id "value" (cdr x))
  id)

(define (seq->id xs)
  (define id (fresh-id!))
  (emit! id "form-kind" "seq")
  (for ([x (in-list xs)] [i (in-naturals)])
    (field! id (string-append "f" (number->string i)) x))
  id)

(define (strip-kind sym)
  (define s (regexp-replace #rx"^struct:" (symbol->string sym) ""))
  (regexp-replace #rx"-form$" s ""))

;; --- reflective backbone: any transparent struct -> node ---
(define (emit-generic! x)
  (define v (struct->vector x))         ; #(struct:<name> f0 f1 ...)
  (define id (fresh-id!))
  (emit! id "form-kind" (strip-kind (vector-ref v 0)))
  (for ([i (in-range 1 (vector-length v))])
    (field! id (string-append "f" (number->string (sub1 i)))
            (vector-ref v i)))
  id)

;; --- semantic overlays for graph-meaningful forms ---
(define (emit-struct! x)
  (cond
    [(with-meta? x)   (val->obj (with-meta-expr x))]   ; unwrap metadata noise
    [(defn-form? x)   (emit-defn! x)]
    [(def-form? x)    (emit-def! x)]
    [(call-form? x)   (emit-call! x)]
    [(record-form? x) (emit-record! x)]
    [else             (emit-generic! x)]))

(define (emit-defn! x)
  (define id (fresh-id!))
  (emit! id "form-kind" "defn")
  (emit! id "name" (symbol->string (defn-form-name x)))
  (when (defn-form-private? x) (emit! id "private" #t))
  (define b (seq->id (defn-form-body x)))
  (emit! id "body" b)
  (emit! id "child" b)
  id)

(define (emit-def! x)
  (define id (fresh-id!))
  (emit! id "form-kind" "def")
  (emit! id "name" (symbol->string (def-form-name x)))
  (field! id "value" (def-form-value x))
  id)

(define (emit-call! x)
  (define id (fresh-id!))
  (emit! id "form-kind" "call")
  (define fn (call-form-fn x))
  (if (symbol? fn)
      (emit! id "calls" (symbol->string fn))        ; the call-graph edge
      (field! id "calls-expr" fn))
  (define a (seq->id (call-form-args x)))
  (emit! id "args" a)
  (emit! id "child" a)
  id)

(define (emit-record! x)
  (define id (fresh-id!))
  (emit! id "form-kind" "record")
  (emit! id "name" (symbol->string (record-form-name x)))
  (field! id "fields" (record-form-fields x))
  id)

;; --- entry point (backend contract: prog -> String) ---
(define (claims-emit-program prog)
  (parameterize ([cur-triples (box '())] [cur-id (box 0)])
    (for ([form (in-list (program-forms prog))])
      (val->obj form))
    (define ts (reverse (unbox (cur-triples))))
    (string-join (map triple->string ts) "\n")))

(define (triple->string t)
  (format "[~a ~s ~a]" (car t) (cadr t) (obj->edn (caddr t))))

(define (obj->edn o)
  (cond
    [(string? o)  (format "~s" o)]
    [(boolean? o) (if o "true" "false")]
    [else o]))                           ; integers (node ids), numbers

(register-backend! 'claims (emitter-backend 'claims claims-emit-program))
