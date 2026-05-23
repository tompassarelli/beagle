#lang racket/base

;; SQL-specific parse helpers — extracted from parse.rkt.

(require racket/match
         "ast.rkt"
         "types.rkt")

;; --- Small primitives ------------------------------------------------------

;; `foo.bar` → dotted column reference. The dot must be interior
;; (not at position 0 or final).
(define (sql-dot-ref? sym)
  (define s (symbol->string sym))
  (define len (string-length s))
  (define dot-pos (for/or ([i (in-range len)])
                    (and (char=? (string-ref s i) #\.) i)))
  (and dot-pos (> dot-pos 0) (< dot-pos (- len 1))))

(define (parse-sql-column-ref sym)
  (define s (symbol->string sym))
  (define dot-pos (for/or ([i (in-range (string-length s))])
                    (and (char=? (string-ref s i) #\.) i)))
  (sql-column-ref (string->symbol (substring s 0 dot-pos))
                  (string->symbol (substring s (+ dot-pos 1)))))

;; A column may be bare `foo` or qualified `t.foo`. Return either a
;; symbol or a sql-column-ref. Used by group-by/partition-by.
(define (parse-sql-bare-or-dot d)
  (if (and (symbol? d) (sql-dot-ref? d))
    (parse-sql-column-ref d)
    d))

;; Unwrap a `[...]` or `(...)` form into its element list. Errors with
;; `ctx` (a short string describing where this was used) on malformed input.
(define (unwrap-bracket-or-list form ctx)
  (define d (->datum form))
  (cond
    [(bracketed? d) (bracket-body d)]
    [(list? d) d]
    [else (error 'beagle "~a: expected a list, got ~v" ctx d)]))

;; Parse a single expression via the current parse-expr injection.
(define (parse-via-current-expr item)
  ((current-parse-expr) (if (syntax? item) item (datum->syntax #f item))))

;; --- Column / constraint parsing -------------------------------------------

(define (parse-sql-constraints items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (eq? (car rest) ':default) (pair? (cdr rest)))
       (loop (cddr rest) (cons (list ':default (parse-sql-expr (datum->syntax #f (cadr rest)))) acc))]
      [(and (eq? (car rest) ':references) (pair? (cdr rest)) (pair? (cddr rest)))
       (loop (cdddr rest) (cons (list ':references (cadr rest) (caddr rest)) acc))]
      [(and (eq? (car rest) ':check) (pair? (cdr rest)))
       (loop (cddr rest) (cons (list ':check (parse-sql-expr (datum->syntax #f (cadr rest)))) acc))]
      [else
       (loop (cdr rest) (cons (car rest) acc))])))

(define (parse-sql-columns fields-form)
  (define items (unwrap-items (->datum fields-form) "deftable column list"))
  (for/list ([item (in-list items)])
    (define d (if (syntax? item) (syntax->datum item) item))
    (define col-items (cond
                        [(bracketed? d) (bracket-body d)]
                        [(list? d) d]
                        [else (error 'beagle "deftable: column must be a list, got ~v" d)]))
    (when (< (length col-items) 3)
      (error 'beagle "deftable column requires at least (name : Type), got ~v" col-items))
    (define col-name (car col-items))
    (unless (eq? (cadr col-items) ':)
      (error 'beagle "deftable column ~a: expected : after name" col-name))
    (define col-type (parse-type (caddr col-items)))
    (define constraints (parse-sql-constraints (cdddr col-items)))
    (sql-column col-name col-type constraints)))

(define (parse-sql-column-names cols-form)
  (define items (unwrap-bracket-or-list cols-form "insert column names"))
  (for/list ([item (in-list items)])
    (define s (->datum item))
    (unless (symbol? s)
      (error 'beagle "insert: column name must be a symbol, got ~v" s))
    s))

(define (parse-sql-values-row row)
  (define items (unwrap-bracket-or-list row "insert values row"))
  (map parse-via-current-expr items))

(define (parse-sql-set-pairs set-form)
  (define d (->datum set-form))
  (define pairs-raw (cdr d))
  (for/list ([pair-raw (in-list pairs-raw)])
    (define items (unwrap-bracket-or-list pair-raw "update set pair"))
    (when (< (length items) 2)
      (error 'beagle "update set: need [column value], got ~v" items))
    (cons (car items)
          (parse-via-current-expr (cadr items)))))

(define (parse-sql-where-clause rest-forms)
  (for/or ([form (in-list rest-forms)])
    (define d (->datum form))
    (and (pair? d) (eq? (car d) 'where)
         (parse-sql-expr (datum->syntax #f (cadr d))))))

;; --- Expression parsing ----------------------------------------------------

;; Operators recognised by parse-sql-expr without falling through to the
;; generic call branch. Kept as a single source of truth.
(define SQL-OPERATOR-FORMS
  '(= <> > < >= <= + - * / and or not like between in
    is-null is-not-null ||))

(define SQL-KNOWN-FUNCTIONS
  '(count sum avg min max coalesce upper lower trim ltrim rtrim length
    char_length octet_length
    concat substring replace position left right lpad rpad reverse
    string_agg group_concat
    now current_date current_time current_timestamp date_trunc extract age
    abs ceil floor round mod power sqrt sign exp ln log
    nullif greatest least
    count-distinct
    row_number rank dense_rank ntile lag lead percent_rank cume_dist
    first_value last_value nth_value))

(define SQL-AGGREGATE-FUNCTIONS
  '(count sum avg min max count-distinct))

(define (parse-sql-expr stx)
  (define d (->datum stx))
  (cond
    [(and (symbol? d) (sql-dot-ref? d))
     (parse-sql-column-ref d)]
    [(eq? d '*) '*]
    [(symbol? d) d]
    [(string? d) d]
    [(number? d) d]
    [(boolean? d) d]
    [(eq? d 'nil) 'nil]
    [(and (pair? d) (memq (car d) SQL-OPERATOR-FORMS))
     (call-form (car d) (map parse-sql-subexpr (cdr d)))]
    [(and (pair? d) (eq? (car d) 'case))
     (parse-sql-case (cdr d))]
    [(and (pair? d) (eq? (car d) 'cast))
     (when (< (length d) 3)
       (error 'beagle "cast requires (cast expr Type)"))
     (sql-cast (parse-sql-subexpr (cadr d))
               (caddr d))]
    [(and (pair? d) (eq? (car d) 'exists))
     (sql-exists (parse-sql-subexpr (cadr d)))]
    [(and (pair? d) (eq? (car d) 'select))
     (parse-sql-select (cdr d) #f #f)]
    [(and (pair? d) (eq? (car d) 'select-distinct))
     (parse-sql-select (cdr d) #f #t)]
    [(and (pair? d) (memq (car d) SQL-KNOWN-FUNCTIONS))
     (parse-sql-function-call d)]
    [(pair? d)
     (call-form (car d) (map parse-sql-subexpr (cdr d)))]
    [else d]))

;; Helper: parse-sql-expr on a sub-datum that needs wrapping.
(define (parse-sql-subexpr d)
  (parse-sql-expr (datum->syntax #f d)))

(define (parse-sql-function-call d)
  (define fn-name (car d))
  (define rest-items (cdr d))
  (define-values (args alias over-clauses)
    (let loop ([items rest-items] [acc '()] [alias #f] [over #f])
      (cond
        [(null? items) (values (reverse acc) alias over)]
        [(eq? (->datum (car items)) ':as)
         (loop (cddr items) acc (->datum (cadr items)) over)]
        [(eq? (->datum (car items)) ':over)
         (values (reverse acc) alias (cdr items))]
        [else (loop (cdr items) (cons (car items) acc) alias over)])))
  (define parsed-args (map parse-sql-subexpr args))
  (cond
    [over-clauses
     (define-values (partition-by win-order-by)
       (parse-sql-over-clauses over-clauses))
     (sql-window fn-name parsed-args partition-by win-order-by alias)]
    [(memq fn-name SQL-AGGREGATE-FUNCTIONS)
     (sql-aggregate fn-name (if (null? parsed-args) #f (car parsed-args)) alias)]
    [(<= (length parsed-args) 1)
     (sql-aggregate fn-name (if (null? parsed-args) #f (car parsed-args)) alias)]
    [else
     (define cf (call-form fn-name parsed-args))
     (if alias (sql-alias cf alias) cf)]))

(define (parse-sql-over-clauses clauses)
  (define partition-by #f)
  (define order-by #f)
  (for ([c (in-list clauses)])
    (define cd (->datum c))
    (when (pair? cd)
      (case (car cd)
        [(partition-by)
         (set! partition-by (map (lambda (g) (parse-sql-bare-or-dot (->datum g)))
                                 (cdr cd)))]
        [(order-by)
         (set! order-by (parse-sql-order-by (cdr cd)))])))
  (values partition-by order-by))

(define (parse-sql-case items)
  (let loop ([rest items] [clauses '()] [else-expr #f])
    (cond
      [(null? rest)
       (sql-case (reverse clauses) else-expr)]
      [(and (pair? rest) (pair? (cdr rest)) (eq? (car rest) ':else))
       (loop '() clauses (parse-sql-subexpr (cadr rest)))]
      [(and (pair? rest) (pair? (car rest)) (eq? (caar rest) 'when))
       (define clause-d (car rest))
       (define cond-expr (parse-sql-subexpr (cadr clause-d)))
       (define result-expr (parse-sql-subexpr (caddr clause-d)))
       (loop (cdr rest) (cons (sql-case-clause cond-expr result-expr) clauses) else-expr)]
      [else
       (error 'beagle "case: expected (when cond result) clauses, got ~v" (car rest))])))

;; --- Top-level query forms (queryable from with/union) ---------------------

(define (parse-sql-top-form datum)
  (define d (->datum datum))
  (cond
    [(and (pair? d) (eq? (car d) 'select))
     (parse-sql-select (cdr d) #f #f)]
    [(and (pair? d) (eq? (car d) 'select-distinct))
     (parse-sql-select (cdr d) #f #t)]
    [(and (pair? d) (memq (car d) '(union union-all intersect except)))
     (sql-union (car d)
                (parse-sql-top-form (cadr d))
                (parse-sql-top-form (caddr d)))]
    [else (error 'beagle "expected SQL query form (select/union/etc), got ~v" d)]))

(define (parse-sql-with rest)
  (when (null? rest)
    (error 'beagle "with: requires at least one CTE and a body query"))
  (let loop ([items rest] [ctes '()])
    (if (null? (cdr items))
      (sql-with (reverse ctes) (parse-sql-top-form (car items)))
      (let ([d (->datum (car items))])
        (unless (and (pair? d) (symbol? (car d)) (pair? (cdr d)))
          (error 'beagle "with: CTE must be (name query), got ~v" d))
        (loop (cdr items)
              (cons (sql-cte (car d) (parse-sql-top-form (cadr d))) ctes))))))

;; --- SELECT and friends ----------------------------------------------------

(define (parse-sql-select-column col-datum)
  (define d (->datum col-datum))
  (cond
    [(eq? d '*) '*]
    [(and (symbol? d) (sql-dot-ref? d))
     (parse-sql-column-ref d)]
    [(symbol? d) d]
    [(and (pair? d) (memq (car d) SQL-KNOWN-FUNCTIONS))
     (parse-sql-function-call d)]
    [else (parse-sql-subexpr d)]))

(define (parse-sql-select rest subs distinct?)
  (when (null? rest) (error 'beagle "select requires at least a column list"))
  (define cols-form (car rest))
  (define col-items (unwrap-bracket-or-list cols-form "select column list"))
  (define columns
    (let loop ([items col-items] [acc '()])
      (cond
        [(null? items) (reverse acc)]
        [(and (pair? (cdr items)) (eq? (->datum (cadr items)) ':as) (pair? (cddr items)))
         (define col (parse-sql-select-column (car items)))
         (define alias (->datum (caddr items)))
         (loop (cdddr items) (cons (sql-alias col alias) acc))]
        [else
         (loop (cdr items) (cons (parse-sql-select-column (car items)) acc))])))

  (define clauses (cdr rest))
  (define from-clause #f)
  (define joins '())
  (define where-clause #f)
  (define group-by #f)
  (define having #f)
  (define order-by #f)
  (define limit-val #f)
  (define offset-val #f)

  (for ([clause (in-list clauses)])
    (define cd (->datum clause))
    (when (pair? cd)
      (case (car cd)
        [(from)
         (define table-name (cadr cd))
         (define alias (parse-sql-as-alias (cddr cd)))
         (set! from-clause (if alias (sql-alias table-name alias) table-name))]
        [(join inner-join) (set! joins (append joins (list (parse-sql-join-clause 'inner (cdr cd)))))]
        [(left-join)       (set! joins (append joins (list (parse-sql-join-clause 'left  (cdr cd)))))]
        [(right-join)      (set! joins (append joins (list (parse-sql-join-clause 'right (cdr cd)))))]
        [(full-join)       (set! joins (append joins (list (parse-sql-join-clause 'full  (cdr cd)))))]
        [(cross-join)      (set! joins (append joins (list (parse-sql-join-clause 'cross (cdr cd)))))]
        [(where)
         (set! where-clause (parse-sql-subexpr (cadr cd)))]
        [(group-by)
         (set! group-by (map (lambda (g) (parse-sql-bare-or-dot (->datum g))) (cdr cd)))]
        [(having)
         (set! having (parse-sql-subexpr (cadr cd)))]
        [(order-by)
         (set! order-by (parse-sql-order-by (cdr cd)))]
        [(limit)
         (set! limit-val (cadr cd))]
        [(offset)
         (set! offset-val (cadr cd))])))

  (sql-select columns from-clause joins where-clause group-by having order-by limit-val offset-val distinct?))

(define (parse-sql-as-alias rest)
  (let loop ([items rest])
    (cond
      [(null? items) #f]
      [(and (pair? (cdr items)) (eq? (->datum (car items)) ':as))
       (->datum (cadr items))]
      [else (loop (cdr items))])))

(define (parse-sql-join-clause type args)
  (define table (car args))
  (define rest-args (cdr args))
  (define alias (parse-sql-as-alias rest-args))
  (define condition
    (let loop ([items rest-args])
      (cond
        [(null? items) #f]
        [(eq? (->datum (car items)) ':as) (loop (cddr items))]
        [(pair? (->datum (car items)))
         (parse-sql-subexpr (->datum (car items)))]
        [else (loop (cdr items))])))
  (sql-join type table alias condition))

(define (parse-sql-order-by items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [else
       (define col-expr (parse-sql-bare-or-dot (->datum (car rest))))
       (define-values (dir remaining)
         (if (and (pair? (cdr rest))
                  (memq (->datum (cadr rest)) '(:asc :desc asc desc)))
           (values (let ([v (->datum (cadr rest))])
                     (if (memq v '(:asc asc)) 'asc 'desc))
                   (cddr rest))
           (values 'asc (cdr rest))))
       (loop remaining (cons (sql-order-spec col-expr dir) acc))])))

(provide
 sql-dot-ref? parse-sql-column-ref
 parse-sql-columns parse-sql-column-names parse-sql-values-row
 parse-sql-set-pairs parse-sql-where-clause parse-sql-expr
 parse-sql-top-form parse-sql-with parse-sql-select)
