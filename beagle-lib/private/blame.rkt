#lang racket/base

;; Semantic property inference and blame analysis.
;;
;; This module provides "soft diagnostics" — suspicions about likely bugs
;; based on function/variable names and arithmetic patterns. These are
;; hints, not proofs. Each diagnostic carries a confidence level (0.0–1.0).
;;
;; The rules are deliberately simple string patterns. No ML, no LLM.

(require racket/match
         racket/string
         racket/list
         racket/format
         json
         "parse.rkt")

;; --- Semantic rules ----------------------------------------------------------
;;
;; Each rule: (name-pattern expected-ops unexpected-ops confidence reason)
;; When a function/binding name matches the pattern AND uses an unexpected op,
;; emit a suspicion.

(struct semantic-rule (name-pattern expected-ops suspicious-ops confidence reason)
  #:transparent)

(define RULES
  (list
   ;; "total", "sum" → should aggregate (+ or reduce +, *)
   ;; suspicious: - as the main operation
   (semantic-rule
    #rx"total|sum-of|aggregate"
    '(+ * reduce)
    '(-)
    0.7
    "name implies aggregation/accumulation — subtraction is suspicious")

   ;; "discount" → should subtract from something
   ;; suspicious: + (adding a discount increases the value)
   (semantic-rule
    #rx"discount|rebate|deduct"
    '(-)
    '(+)
    0.75
    "name implies reduction — addition of a 'discount' value is suspicious")

   ;; "margin", "profit" → price - cost (not cost - price)
   ;; This is trickier — we check operand order
   (semantic-rule
    #rx"margin|profit|markup"
    '(-)
    '()
    0.6
    "name implies price minus cost — check operand order")

   ;; "commission", "fee", "surcharge", "tax" on a base → multiplication
   ;; suspicious: + or - as the rate application
   (semantic-rule
    #rx"commission|surcharge|fee-amount|tax-amount|interest-amount"
    '(*)
    '(+)
    0.7
    "name implies rate × base — addition instead of multiplication is suspicious")

   ;; "pct", "percent", "percentage" → division by 100
   ;; suspicious: division by 10 or 1000
   (semantic-rule
    #rx"pct|percent|percentage"
    '()
    '()
    0.65
    "name implies percentage — check divisor is 100")

   ;; "count", "num-" → result should be non-negative
   (semantic-rule
    #rx"^count-|^num-|-count$"
    '()
    '(-)
    0.5
    "name implies count — negative results are suspicious")

   ;; "needed", "required", "threshold" with comparison → check direction
   (semantic-rule
    #rx"needed|required|below|under"
    '(<)
    '(>)
    0.6
    "name implies 'less than threshold' — > comparison may be inverted")

   ;; "in-period", "in-range", "between" → needs both <= and >=
   (semantic-rule
    #rx"in-period|in-range|between"
    '(<= >=)
    '()
    0.6
    "name implies range check — verify both bounds use correct direction")

   ;; "line-total", "line-cost", "line-amount" → unit × quantity (multiplication)
   (semantic-rule
    #rx"line-total|line-cost|line-amount|poline-total"
    '(*)
    '(+ -)
    0.75
    "name implies unit × quantity — addition/subtraction is suspicious")))

;; --- AST walking: extract operations from a function body --------------------
;;
;; We track whether an operation is in an "aggregation context" (inside for,
;; reduce, map, etc.) vs a "computation context" (let binding, direct return).
;; Only computation-context ops are candidates for semantic suspicion.

(struct op-usage (op args src-info context aggregation?) #:transparent)

(define (extract-ops expr #:context [ctx ""])
  (define results '())

  (define (go e ctx agg?)
    (match e
      [(call-form fn args)
       (when (symbol? fn)
         (set! results (cons (op-usage fn args #f ctx agg?) results)))
       (for ([a (in-list args)]) (go a ctx agg?))]
      [(let-form bindings body)
       (for ([b (in-list bindings)])
         ;; Binding name may be a destructure pattern, not a bare symbol
         ;; (crashed on {:keys [...]} let bindings before 2026-06-12).
         (define bname
           (cond
             [(and (let-binding? b) (symbol? (let-binding-name b)))
              (symbol->string (let-binding-name b))]
             [(let-binding? b)
              (string-join (map symbol->string
                                (destructure-bound-names (let-binding-name b)))
                           "+")]
             [else "?"]))
         (define bval (if (let-binding? b) (let-binding-value b) b))
         (go bval (format "~a/~a" ctx bname) agg?))
       (for ([b (in-list body)]) (go b ctx agg?))]
      [(if-form c t e)
       (go c ctx agg?) (go t ctx agg?) (go e ctx agg?)]
      [(cond-form clauses)
       (for ([cl (in-list clauses)])
         (go (cond-clause-test cl) ctx agg?)
         (go (cond-clause-body cl) ctx agg?))]
      [(when-form c body)
       (go c ctx agg?)
       (for ([b (in-list body)]) (go b ctx agg?))]
      [(do-form body)
       (for ([b (in-list body)]) (go b ctx agg?))]
      [(for-form clauses body)
       ;; Inside a for comprehension = aggregation context
       (for ([b (in-list body)]) (go b ctx #t))]
      [(fn-form _ _ _ body)
       ;; Lambda passed to reduce/map = likely aggregation
       (for ([b (in-list body)]) (go b ctx #t))]
      [(vec-form items)
       (for ([i (in-list items)]) (go i ctx agg?))]
      [_ (void)]))

  (go expr ctx #f)
  (reverse results))

;; --- Rule matching -----------------------------------------------------------

(struct suspicion (function-name rule op-found location confidence message) #:transparent)

(define (check-function-semantics fn-name body)
  (define name-str (symbol->string fn-name))
  (define ops (extract-ops body #:context name-str))
  (define op-syms (map op-usage-op ops))

  (define suspicions '())

  ;; Check each rule against function name
  (for ([rule (in-list RULES)])
    (when (regexp-match (semantic-rule-name-pattern rule) name-str)
      (for ([op (in-list (semantic-rule-suspicious-ops rule))])
        (when (memq op op-syms)
          ;; Only flag ops in computation context, not aggregation
          (define matching-ops
            (filter (lambda (u)
                      (and (eq? (op-usage-op u) op)
                           (not (op-usage-aggregation? u))))
                    ops))
          (for ([m (in-list matching-ops)])
            (set! suspicions
                  (cons (suspicion fn-name rule op
                                  (op-usage-context m)
                                  (semantic-rule-confidence rule)
                                  (format "~a: `~a` in `~a` — ~a"
                                          name-str op
                                          (op-usage-context m)
                                          (semantic-rule-reason rule)))
                        suspicions)))))))

  ;; Special case: percentage divisor check
  (when (and (regexp-match #rx"pct|percent|percentage|discount-amount" name-str)
             (memq '/ op-syms))
    (define div-ops (filter (lambda (u) (eq? (op-usage-op u) '/)) ops))
    (for ([d (in-list div-ops)])
      (define args (op-usage-args d))
      (when (and (>= (length args) 2)
                 (number? (last args))
                 (not (= (last args) 100)))
        (set! suspicions
              (cons (suspicion fn-name #f '/
                              (op-usage-context d)
                              0.8
                              (format "~a: divides by ~a — percentages typically divide by 100"
                                      name-str (last args)))
                    suspicions)))))

  (reverse suspicions))

;; --- Program-level analysis --------------------------------------------------

(define (analyze-program-semantics prog)
  (define all-suspicions '())

  (for ([form (in-list (program-forms prog))])
    (cond
      [(defn-form? form)
       (define fn-name (defn-form-name form))
       (define body (defn-form-body form))
       (for ([expr (in-list body)])
         (define s (check-function-semantics fn-name expr))
         (set! all-suspicions (append all-suspicions s)))]
      [(defn-multi? form)
       (define fn-name (defn-multi-name form))
       (for ([arity (in-list (defn-multi-arities form))])
         (for ([expr (in-list (arity-clause-body arity))])
           (define s (check-function-semantics fn-name expr))
           (set! all-suspicions (append all-suspicions s))))]))

  all-suspicions)

;; --- Output formatting -------------------------------------------------------

(define (format-suspicion s)
  (format "  SUSPECT [~a]: ~a"
          (real->decimal-string (suspicion-confidence s) 2)
          (suspicion-message s)))

(define (real->decimal-string n digits)
  (define factor (expt 10 digits))
  (define rounded (/ (round (* n factor)) factor))
  (~a (exact->inexact rounded)))

;; Structured emission. format-suspicion is LOSSY — it collapses six fields to
;; "[conf]: message", so a consumer must regex the function name back out of the
;; message prefix (and dies on names with chars outside its class, e.g. `total=`).
;; This carries every field verbatim as one JSON object per line, prefixed so a
;; consumer can find it amid other build output. The reason is the message with
;; the redundant "<fn>: " prefix stripped (it's already in the `function` field).
(define (suspicion->jsexpr s file)
  (define name (symbol->string (suspicion-function-name s)))
  (define msg  (suspicion-message s))
  (define pfx  (string-append name ": "))
  (define reason (if (string-prefix? msg pfx) (substring msg (string-length pfx)) msg))
  (define op   (suspicion-op-found s))
  (hasheq 'kind       "semantic-suspicion"
          'function   name
          'op         (if (symbol? op) (symbol->string op) (format "~a" op))
          'context    (format "~a" (suspicion-location s))
          'confidence (exact->inexact (suspicion-confidence s))
          'reason     reason
          'file       file))

(define (run-semantic-analysis! prog #:file [file ""])
  (define suspicions (analyze-program-semantics prog))
  (cond
    [(null? suspicions) (void)]
    ;; Structured path (opt-in): consumers like beagle-repair set this so they
    ;; get the suspicion as data, not a prose line they have to scrape back.
    [(getenv "BEAGLE_SEMANTIC_JSON")
     (for ([s (in-list suspicions)])
       (eprintf "beagle-semantic-json: ~a\n" (jsexpr->string (suspicion->jsexpr s file))))]
    ;; Human path (default): the readable warning, unchanged.
    [else
     (eprintf "beagle [semantic]: ~a suspicion(s) in ~a\n" (length suspicions) file)
     (for ([s (in-list suspicions)])
       (eprintf "~a\n" (format-suspicion s)))])
  suspicions)

(provide analyze-program-semantics
         run-semantic-analysis!
         suspicion? suspicion-function-name suspicion-confidence
         suspicion-message suspicion-op-found suspicion-location)
