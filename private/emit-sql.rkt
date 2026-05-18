#lang racket/base

;; SQL emitter backend.
;; Maps Beagle AST -> SQL source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "emit-dispatch.rkt")

;; --- SQL emission from Beagle AST -----------------------------------------

(define (sql-emit-program prog)
  (define forms (program-forms prog))
  (define statements
    (for/list ([f (in-list forms)]
               #:unless (or (sql-table? f)    ; deftable = type-env only, no output
                            (with-meta? f)))  ; metadata wrappers
      (emit-sql-form f)))
  (string-join (filter (lambda (s) (and s (not (string=? s "")))) statements)
               ";\n"))

(define (emit-sql-form f)
  (cond
    [(sql-select? f) (emit-select f)]
    [(sql-insert? f) (emit-insert f)]
    [(sql-update? f) (emit-update f)]
    [(sql-delete? f) (emit-delete f)]
    [(sql-table? f) ""]  ; no output
    [else ""]))

;; --- SELECT ----------------------------------------------------------------

(define (emit-select sel)
  (define cols (sql-select-columns sel))
  (define from (sql-select-from-clause sel))
  (define joins (sql-select-joins sel))
  (define where (sql-select-where-clause sel))
  (define group-by (sql-select-group-by sel))
  (define having (sql-select-having sel))
  (define order-by (sql-select-order-by sel))
  (define limit (sql-select-limit sel))
  (define offset (sql-select-offset sel))

  (define parts '())

  ;; SELECT columns
  (define col-strs (map emit-sql-column cols))
  (set! parts (list (format "SELECT ~a" (string-join col-strs ", "))))

  ;; FROM
  (when from
    (set! parts (append parts (list (format "FROM ~a" (emit-sql-table-ref from))))))

  ;; JOINs
  (for ([j (in-list joins)])
    (define join-type
      (case (sql-join-type j)
        [(inner) "JOIN"]
        [(left)  "LEFT JOIN"]
        [(right) "RIGHT JOIN"]
        [else "JOIN"]))
    (define table-str
      (if (sql-join-alias j)
        (format "~a AS ~a" (sql-join-table j) (sql-join-alias j))
        (format "~a" (sql-join-table j))))
    (define on-str
      (if (sql-join-condition j)
        (format " ON ~a" (emit-sql-expr (sql-join-condition j)))
        ""))
    (set! parts (append parts (list (format "~a ~a~a" join-type table-str on-str)))))

  ;; WHERE
  (when where
    (set! parts (append parts (list (format "WHERE ~a" (emit-sql-expr where))))))

  ;; GROUP BY
  (when (and group-by (not (null? group-by)))
    (define gb-strs (map (lambda (g)
                           (cond
                             [(sql-column-ref? g) (emit-sql-column-ref g)]
                             [(symbol? g) (symbol->string g)]
                             [else (format "~a" g)]))
                         group-by))
    (set! parts (append parts (list (format "GROUP BY ~a" (string-join gb-strs ", "))))))

  ;; HAVING
  (when having
    (set! parts (append parts (list (format "HAVING ~a" (emit-sql-expr having))))))

  ;; ORDER BY
  (when (and order-by (not (null? order-by)))
    (define ob-strs
      (map (lambda (spec)
             (define expr-str
               (cond
                 [(sql-column-ref? (sql-order-spec-expr spec))
                  (emit-sql-column-ref (sql-order-spec-expr spec))]
                 [(symbol? (sql-order-spec-expr spec))
                  (symbol->string (sql-order-spec-expr spec))]
                 [else (emit-sql-expr (sql-order-spec-expr spec))]))
             (format "~a ~a" expr-str (string-upcase (symbol->string (sql-order-spec-direction spec)))))
           order-by))
    (set! parts (append parts (list (format "ORDER BY ~a" (string-join ob-strs ", "))))))

  ;; LIMIT
  (when limit
    (set! parts (append parts (list (format "LIMIT ~a" limit)))))

  ;; OFFSET
  (when offset
    (set! parts (append parts (list (format "OFFSET ~a" offset)))))

  (string-join parts "\n"))

;; --- INSERT ----------------------------------------------------------------

(define (emit-insert ins)
  (define table (sql-insert-table ins))
  (define cols (sql-insert-columns ins))
  (define rows (sql-insert-values ins))

  (define col-str (string-join (map symbol->string cols) ", "))
  (define row-strs
    (map (lambda (row)
           (define val-strs (map emit-sql-value row))
           (format "(~a)" (string-join val-strs ", ")))
         rows))

  (format "INSERT INTO ~a (~a) VALUES ~a"
          table col-str (string-join row-strs ", ")))

;; --- UPDATE ----------------------------------------------------------------

(define (emit-update upd)
  (define table (sql-update-table upd))
  (define set-pairs (sql-update-set-pairs upd))
  (define where (sql-update-where-clause upd))

  (define set-strs
    (map (lambda (pair)
           (format "~a = ~a" (car pair) (emit-sql-expr (cdr pair))))
         set-pairs))

  (define base (format "UPDATE ~a SET ~a" table (string-join set-strs ", ")))
  (if where
    (format "~a WHERE ~a" base (emit-sql-expr where))
    base))

;; --- DELETE ----------------------------------------------------------------

(define (emit-delete del)
  (define table (sql-delete-table del))
  (define where (sql-delete-where-clause del))

  (if where
    (format "DELETE FROM ~a WHERE ~a" table (emit-sql-expr where))
    (format "DELETE FROM ~a" table)))

;; --- Expression emission ---------------------------------------------------

(define (emit-sql-expr e)
  (cond
    [(sql-column-ref? e) (emit-sql-column-ref e)]
    [(sql-aggregate? e) (emit-sql-aggregate e)]
    [(call-form? e) (emit-sql-call e)]
    [(symbol? e) (symbol->string e)]
    [(string? e) (format "'~a'" e)]
    [(number? e) (format "~a" e)]
    [(boolean? e) (if e "TRUE" "FALSE")]
    [(eq? e 'nil) "NULL"]
    [else (format "~a" e)]))

(define (emit-sql-column-ref ref)
  (format "~a.~a" (sql-column-ref-table-or-alias ref) (sql-column-ref-column ref)))

(define (emit-sql-aggregate agg)
  (define fn-str (string-upcase (symbol->string (sql-aggregate-fn-name agg))))
  (define arg-str
    (if (sql-aggregate-expr agg)
      (emit-sql-expr (sql-aggregate-expr agg))
      "*"))
  (define base (format "~a(~a)" fn-str arg-str))
  (if (sql-aggregate-alias agg)
    (format "~a AS ~a" base (sql-aggregate-alias agg))
    base))

(define (emit-sql-call c)
  (define fn (call-form-fn c))
  (define args (call-form-args c))
  (cond
    ;; Comparison and arithmetic operators — infix
    [(and (symbol? fn) (memq fn '(= <> > < >= <= + - * /)))
     (cond
       [(= (length args) 2)
        (format "~a ~a ~a"
                (emit-sql-expr (car args))
                (symbol->string fn)
                (emit-sql-expr (cadr args)))]
       [(and (= (length args) 1) (eq? fn '-))
        (format "-~a" (emit-sql-expr (car args)))]
       [else
        (string-join (map emit-sql-expr args) (format " ~a " (symbol->string fn)))])]
    ;; Boolean operators
    [(eq? fn 'and)
     (format "(~a)"
             (string-join (map emit-sql-expr args) " AND "))]
    [(eq? fn 'or)
     (format "(~a)"
             (string-join (map emit-sql-expr args) " OR "))]
    [(eq? fn 'not)
     (format "NOT ~a" (emit-sql-expr (car args)))]
    ;; LIKE
    [(eq? fn 'like)
     (format "~a LIKE ~a" (emit-sql-expr (car args)) (emit-sql-expr (cadr args)))]
    ;; BETWEEN
    [(eq? fn 'between)
     (format "~a BETWEEN ~a AND ~a"
             (emit-sql-expr (car args))
             (emit-sql-expr (cadr args))
             (emit-sql-expr (caddr args)))]
    ;; IN
    [(eq? fn 'in)
     (format "~a IN (~a)"
             (emit-sql-expr (car args))
             (string-join (map emit-sql-expr (cdr args)) ", "))]
    ;; SQL aggregate/functions
    [(memq fn '(count sum avg min max coalesce upper lower trim length))
     (define fn-str (string-upcase (symbol->string fn)))
     (format "~a(~a)" fn-str (string-join (map emit-sql-expr args) ", "))]
    ;; Generic function call
    [else
     (define fn-str (if (symbol? fn) (string-upcase (symbol->string fn)) (format "~a" fn)))
     (format "~a(~a)" fn-str (string-join (map emit-sql-expr args) ", "))]))

(define (emit-sql-value v)
  (cond
    [(string? v) (format "'~a'" v)]
    [(number? v) (format "~a" v)]
    [(boolean? v) (if v "TRUE" "FALSE")]
    [(eq? v 'nil) "NULL"]
    [(symbol? v) (symbol->string v)]
    [(sql-column-ref? v) (emit-sql-column-ref v)]
    [(call-form? v) (emit-sql-call v)]
    [else (emit-sql-expr v)]))

(define (emit-sql-column col)
  (cond
    [(sql-column-ref? col) (emit-sql-column-ref col)]
    [(sql-aggregate? col) (emit-sql-aggregate col)]
    [(sql-alias? col)
     (format "~a AS ~a" (emit-sql-expr (sql-alias-expr col)) (sql-alias-alias-name col))]
    [(symbol? col) (symbol->string col)]
    [(string? col) (format "'~a'" col)]
    [else (emit-sql-expr col)]))

(define (emit-sql-table-ref ref)
  (cond
    [(sql-alias? ref)
     (format "~a AS ~a" (sql-alias-expr ref) (sql-alias-alias-name ref))]
    [(symbol? ref) (symbol->string ref)]
    [else (format "~a" ref)]))

;; --- registration ----------------------------------------------------------

(define sql-backend
  (emitter-backend 'sql sql-emit-program))

(register-backend! 'sql sql-backend)
