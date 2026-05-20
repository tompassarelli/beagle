#lang racket/base

;; SQL emitter backend.
;; Maps Beagle AST -> SQL source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

;; --- Security helpers -------------------------------------------------------

(define (sql-escape-string s)
  (string-replace s "'" "''"))

(define (sql-quote-string s)
  (format "'~a'" (sql-escape-string s)))

(define (sql-quote-identifier sym)
  (define s (if (symbol? sym) (symbol->string sym) (format "~a" sym)))
  (format "\"~a\"" (string-replace s "\"" "\"\"")))

(define (sql-safe-number n)
  (cond
    [(eqv? n +inf.0) (error 'beagle "SQL: cannot emit +inf.0 as a numeric literal")]
    [(eqv? n -inf.0) (error 'beagle "SQL: cannot emit -inf.0 as a numeric literal")]
    [(eqv? n +nan.0) (error 'beagle "SQL: cannot emit +nan.0 as a numeric literal")]
    [else (format "~a" n)]))

;; --- SQL emission from Beagle AST -----------------------------------------

(define (sql-emit-program prog)
  (define forms (program-forms prog))
  (define statements
    (for/list ([f (in-list forms)]
               #:unless (with-meta? f))
      (emit-sql-form f)))
  (string-join (filter (lambda (s) (and s (not (string=? s "")))) statements)
               ";\n"))

(define (emit-sql-form f)
  (cond
    [(sql-table? f)  (emit-create-table f)]
    [(sql-select? f) (emit-select f)]
    [(sql-insert? f) (emit-insert f)]
    [(sql-update? f) (emit-update f)]
    [(sql-delete? f) (emit-delete f)]
    [(sql-with? f)           (emit-with f)]
    [(sql-union? f)          (emit-union f)]
    [(sql-insert-select? f)  (emit-insert-select f)]
    [(sql-returning? f)      (emit-returning f)]
    [(sql-create-index? f)   (emit-create-index f)]
    [(sql-drop-table? f)     (emit-drop-table f)]
    [(sql-alter-table? f)    (emit-alter-table f)]
    [(sql-truncate? f)       (emit-truncate f)]
    [else ""]))

;; --- CREATE TABLE ----------------------------------------------------------

(define (nullable-type? t)
  (and (type-union? t)
       (= (length (type-union-alts t)) 2)
       (ormap (lambda (a) (and (type-prim? a) (eq? (type-prim-name a) 'Nil))) (type-union-alts t))))

(define (nullable-inner t)
  (findf (lambda (a) (not (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))) (type-union-alts t)))

(define (beagle-type->sql-type t)
  (cond
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int)     "INTEGER"]
       [(Float)   "REAL"]
       [(String)  "TEXT"]
       [(Bool)    "BOOLEAN"]
       [(Keyword) "TEXT"]
       [(Symbol)  "TEXT"]
       [(Any)     "TEXT"]
       [else      "TEXT"])]
    [(nullable-type? t)
     (beagle-type->sql-type (nullable-inner t))]
    [else "TEXT"]))

(define (symbol->sql-type sym)
  (case sym
    [(Int)     "INTEGER"]
    [(Float)   "REAL"]
    [(String)  "TEXT"]
    [(Bool)    "BOOLEAN"]
    [else      "TEXT"]))

(define (emit-sql-constraint c)
  (cond
    [(eq? c ':primary-key) "PRIMARY KEY"]
    [(eq? c ':not-null)    "NOT NULL"]
    [(eq? c ':unique)      "UNIQUE"]
    [(eq? c ':autoincrement) "AUTOINCREMENT"]
    [(and (pair? c) (eq? (car c) ':default))
     (format "DEFAULT ~a" (emit-sql-expr (cadr c)))]
    [(and (pair? c) (eq? (car c) ':references))
     (if (= (length (cdr c)) 2)
       (format "REFERENCES ~a(~a)" (sql-quote-identifier (cadr c)) (sql-quote-identifier (caddr c)))
       (format "REFERENCES ~a" (sql-quote-identifier (cadr c))))]
    [(and (pair? c) (eq? (car c) ':check))
     (format "CHECK (~a)" (emit-sql-expr (cadr c)))]
    [else (string-upcase (string-replace (symbol->string c) ":" ""))]))

(define (emit-create-table tbl)
  (define name (sql-table-name tbl))
  (define columns (sql-table-columns tbl))
  (define col-strs
    (for/list ([col (in-list columns)])
      (define col-name (sql-quote-identifier (sql-column-name col)))
      (define col-type (beagle-type->sql-type (sql-column-type col)))
      (define constraint-strs
        (map emit-sql-constraint (sql-column-constraints col)))
      (define not-null?
        (and (not (nullable-type? (sql-column-type col)))
             (not (member ':not-null (sql-column-constraints col)))
             (not (member ':primary-key (sql-column-constraints col)))))
      (string-join
       (filter (lambda (s) (and s (not (string=? s ""))))
               (append (list col-name col-type)
                       (if not-null? '("NOT NULL") '())
                       constraint-strs))
       " ")))
  (format "CREATE TABLE ~a (\n  ~a\n)" (sql-quote-identifier name) (string-join col-strs ",\n  ")))

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
  (define distinct? (sql-select-distinct? sel))

  (define parts '())

  (define col-strs (map emit-sql-column cols))
  (define select-kw (if distinct? "SELECT DISTINCT" "SELECT"))
  (set! parts (list (format "~a ~a" select-kw (string-join col-strs ", "))))

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
        [(full)  "FULL JOIN"]
        [(cross) "CROSS JOIN"]
        [else "JOIN"]))
    (define table-str
      (if (sql-join-alias j)
        (format "~a AS ~a" (sql-quote-identifier (sql-join-table j)) (sql-quote-identifier (sql-join-alias j)))
        (sql-quote-identifier (sql-join-table j))))
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
                             [(symbol? g) (sql-quote-identifier g)]
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
                  (sql-quote-identifier (sql-order-spec-expr spec))]
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

  (define col-str (string-join (map sql-quote-identifier cols) ", "))
  (define row-strs
    (map (lambda (row)
           (define val-strs (map emit-sql-value row))
           (format "(~a)" (string-join val-strs ", ")))
         rows))

  (format "INSERT INTO ~a (~a) VALUES ~a"
          (sql-quote-identifier table) col-str (string-join row-strs ", ")))

;; --- UPDATE ----------------------------------------------------------------

(define (emit-update upd)
  (define table (sql-update-table upd))
  (define set-pairs (sql-update-set-pairs upd))
  (define where (sql-update-where-clause upd))

  (define set-strs
    (map (lambda (pair)
           (format "~a = ~a" (sql-quote-identifier (car pair)) (emit-sql-expr (cdr pair))))
         set-pairs))

  (define base (format "UPDATE ~a SET ~a" (sql-quote-identifier table) (string-join set-strs ", ")))
  (if where
    (format "~a WHERE ~a" base (emit-sql-expr where))
    base))

;; --- DELETE ----------------------------------------------------------------

(define (emit-delete del)
  (define table (sql-delete-table del))
  (define where (sql-delete-where-clause del))

  (define qt (sql-quote-identifier table))
  (if where
    (format "DELETE FROM ~a WHERE ~a" qt (emit-sql-expr where))
    (format "DELETE FROM ~a" qt)))

;; --- Expression emission ---------------------------------------------------

(define (emit-sql-expr e)
  (cond
    [(sql-column-ref? e) (emit-sql-column-ref e)]
    [(sql-aggregate? e)  (emit-sql-aggregate e)]
    [(sql-window? e)     (emit-sql-window e)]
    [(sql-case? e)       (emit-sql-case-expr e)]
    [(sql-cast? e)       (emit-sql-cast e)]
    [(sql-exists? e)     (format "EXISTS (~a)" (emit-sql-expr (sql-exists-subquery e)))]
    [(sql-in-subquery? e)
     (format "~a IN (~a)" (emit-sql-expr (sql-in-subquery-expr e))
             (emit-sql-expr (sql-in-subquery-subquery e)))]
    [(sql-select? e)     (emit-select e)]
    [(sql-raw? e)        (sql-raw-text e)]
    [(call-form? e)      (emit-sql-call e)]
    [(eq? e '*)          "*"]
    [(symbol? e) (sql-quote-identifier e)]
    [(string? e) (sql-quote-string e)]
    [(number? e) (sql-safe-number e)]
    [(boolean? e) (if e "TRUE" "FALSE")]
    [(eq? e 'nil) "NULL"]
    [else (format "~a" e)]))

(define (emit-sql-column-ref ref)
  (format "~a.~a" (sql-quote-identifier (sql-column-ref-table-or-alias ref))
          (sql-quote-identifier (sql-column-ref-column ref))))

(define (emit-sql-aggregate agg)
  (define fn-name (sql-aggregate-fn-name agg))
  (define base
    (cond
      [(eq? fn-name 'count-distinct)
       (format "COUNT(DISTINCT ~a)" (emit-sql-expr (sql-aggregate-expr agg)))]
      [else
       (define fn-str (string-upcase (symbol->string fn-name)))
       (define arg-str
         (if (sql-aggregate-expr agg)
           (emit-sql-expr (sql-aggregate-expr agg))
           "*"))
       (format "~a(~a)" fn-str arg-str)]))
  (if (sql-aggregate-alias agg)
    (format "~a AS ~a" base (sql-quote-identifier (sql-aggregate-alias agg)))
    base))

(define (emit-sql-case-expr c)
  (define parts '("CASE"))
  (for ([clause (in-list (sql-case-clauses c))])
    (set! parts (append parts
                        (list (format "WHEN ~a THEN ~a"
                                      (emit-sql-expr (sql-case-clause-condition clause))
                                      (emit-sql-expr (sql-case-clause-result clause)))))))
  (when (sql-case-else-expr c)
    (set! parts (append parts (list (format "ELSE ~a" (emit-sql-expr (sql-case-else-expr c)))))))
  (set! parts (append parts '("END")))
  (string-join parts " "))

(define (emit-sql-cast c)
  (define type-str
    (cond
      [(symbol? (sql-cast-type-name c))
       (string-upcase (symbol->string (sql-cast-type-name c)))]
      [else (format "~a" (sql-cast-type-name c))]))
  (format "CAST(~a AS ~a)" (emit-sql-expr (sql-cast-expr c)) type-str))

(define (emit-sql-window w)
  (define fn-str (string-upcase (symbol->string (sql-window-fn-name w))))
  (define args (sql-window-args w))
  (define arg-str
    (if (null? args) ""
      (string-join (map emit-sql-expr args) ", ")))
  (define over-parts '())
  (when (sql-window-partition-by w)
    (define pb-strs (map (lambda (g)
                           (cond
                             [(sql-column-ref? g) (emit-sql-column-ref g)]
                             [(symbol? g) (sql-quote-identifier g)]
                             [else (emit-sql-expr g)]))
                         (sql-window-partition-by w)))
    (set! over-parts (append over-parts (list (format "PARTITION BY ~a" (string-join pb-strs ", "))))))
  (when (sql-window-order-by w)
    (define ob-strs
      (map (lambda (spec)
             (define expr-str
               (cond
                 [(sql-column-ref? (sql-order-spec-expr spec))
                  (emit-sql-column-ref (sql-order-spec-expr spec))]
                 [(symbol? (sql-order-spec-expr spec))
                  (sql-quote-identifier (sql-order-spec-expr spec))]
                 [else (emit-sql-expr (sql-order-spec-expr spec))]))
             (format "~a ~a" expr-str (string-upcase (symbol->string (sql-order-spec-direction spec)))))
           (sql-window-order-by w)))
    (set! over-parts (append over-parts (list (format "ORDER BY ~a" (string-join ob-strs ", "))))))
  (define base (format "~a(~a) OVER (~a)" fn-str arg-str (string-join over-parts " ")))
  (if (sql-window-alias w)
    (format "~a AS ~a" base (sql-quote-identifier (sql-window-alias w)))
    base))

(define (emit-sql-call c)
  (define fn (call-form-fn c))
  (define args (call-form-args c))
  (cond
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
    [(eq? fn 'and)
     (format "(~a)"
             (string-join (map emit-sql-expr args) " AND "))]
    [(eq? fn 'or)
     (format "(~a)"
             (string-join (map emit-sql-expr args) " OR "))]
    [(eq? fn 'not)
     (format "NOT ~a" (emit-sql-expr (car args)))]
    [(eq? fn 'is-null)
     (format "~a IS NULL" (emit-sql-expr (car args)))]
    [(eq? fn 'is-not-null)
     (format "~a IS NOT NULL" (emit-sql-expr (car args)))]
    [(eq? fn '||)
     (string-join (map emit-sql-expr args) " || ")]
    [(eq? fn 'like)
     (format "~a LIKE ~a" (emit-sql-expr (car args)) (emit-sql-expr (cadr args)))]
    [(eq? fn 'between)
     (format "~a BETWEEN ~a AND ~a"
             (emit-sql-expr (car args))
             (emit-sql-expr (cadr args))
             (emit-sql-expr (caddr args)))]
    [(eq? fn 'in)
     (if (and (= (length (cdr args)) 1) (sql-select? (cadr args)))
       (format "~a IN (~a)" (emit-sql-expr (car args)) (emit-select (cadr args)))
       (format "~a IN (~a)"
               (emit-sql-expr (car args))
               (string-join (map emit-sql-expr (cdr args)) ", ")))]
    [else
     (define fn-str (if (symbol? fn) (string-upcase (symbol->string fn)) (format "~a" fn)))
     (format "~a(~a)" fn-str (string-join (map emit-sql-expr args) ", "))]))

(define (emit-sql-value v)
  (cond
    [(string? v) (sql-quote-string v)]
    [(number? v) (sql-safe-number v)]
    [(boolean? v) (if v "TRUE" "FALSE")]
    [(eq? v 'nil) "NULL"]
    [(symbol? v) (sql-quote-identifier v)]
    [(sql-column-ref? v) (emit-sql-column-ref v)]
    [(call-form? v) (emit-sql-call v)]
    [else (emit-sql-expr v)]))

(define (emit-sql-column col)
  (cond
    [(eq? col '*) "*"]
    [(sql-column-ref? col) (emit-sql-column-ref col)]
    [(sql-aggregate? col) (emit-sql-aggregate col)]
    [(sql-window? col) (emit-sql-window col)]
    [(sql-alias? col)
     (format "~a AS ~a" (emit-sql-expr (sql-alias-expr col)) (sql-quote-identifier (sql-alias-alias-name col)))]
    [(symbol? col) (sql-quote-identifier col)]
    [(string? col) (sql-quote-string col)]
    [else (emit-sql-expr col)]))

(define (emit-sql-table-ref ref)
  (cond
    [(sql-alias? ref)
     (format "~a AS ~a" (sql-quote-identifier (sql-alias-expr ref)) (sql-quote-identifier (sql-alias-alias-name ref)))]
    [(symbol? ref) (sql-quote-identifier ref)]
    [else (format "~a" ref)]))

;; --- INSERT...SELECT -------------------------------------------------------

(define (emit-insert-select ins)
  (define col-str (string-join (map sql-quote-identifier (sql-insert-select-columns ins)) ", "))
  (format "INSERT INTO ~a (~a)\n~a"
          (sql-quote-identifier (sql-insert-select-table ins)) col-str
          (emit-sql-form (sql-insert-select-query ins))))

;; --- RETURNING ------------------------------------------------------------

(define (emit-returning ret)
  (define base (emit-sql-form (sql-returning-stmt ret)))
  (define col-str (string-join (map sql-quote-identifier (sql-returning-columns ret)) ", "))
  (format "~a\nRETURNING ~a" base col-str))

;; --- CREATE INDEX ---------------------------------------------------------

(define (emit-create-index idx)
  (define kw (if (sql-create-index-unique? idx) "CREATE UNIQUE INDEX" "CREATE INDEX"))
  (define col-str (string-join (map sql-quote-identifier (sql-create-index-columns idx)) ", "))
  (format "~a ~a ON ~a (~a)" kw (sql-quote-identifier (sql-create-index-name idx))
          (sql-quote-identifier (sql-create-index-table idx)) col-str))

;; --- DROP TABLE -----------------------------------------------------------

(define (emit-drop-table dt)
  (define qt (sql-quote-identifier (sql-drop-table-name dt)))
  (if (sql-drop-table-if-exists? dt)
    (format "DROP TABLE IF EXISTS ~a" qt)
    (format "DROP TABLE ~a" qt)))

;; --- ALTER TABLE ----------------------------------------------------------

(define (emit-alter-table alt)
  (define table (sql-quote-identifier (sql-alter-table-table alt)))
  (define action (sql-alter-table-action alt))
  (cond
    [(and (pair? action) (eq? (car action) 'add-column))
     (define col-def (cdr action))
     (define col-name (sql-quote-identifier (car col-def)))
     (define col-type
       (if (and (pair? (cdr col-def)) (eq? (cadr col-def) ':))
         (symbol->sql-type (caddr col-def))
         "TEXT"))
     (format "ALTER TABLE ~a ADD COLUMN ~a ~a" table col-name col-type)]
    [(and (pair? action) (eq? (car action) 'drop-column))
     (format "ALTER TABLE ~a DROP COLUMN ~a" table (sql-quote-identifier (cadr action)))]
    [(and (pair? action) (eq? (car action) 'rename-column))
     (format "ALTER TABLE ~a RENAME COLUMN ~a TO ~a" table (sql-quote-identifier (cadr action)) (sql-quote-identifier (caddr action)))]
    [(and (pair? action) (eq? (car action) 'rename-to))
     (format "ALTER TABLE ~a RENAME TO ~a" table (sql-quote-identifier (cadr action)))]
    [else (format "ALTER TABLE ~a ~a" table action)]))

;; --- TRUNCATE -------------------------------------------------------------

(define (emit-truncate trunc)
  (format "TRUNCATE TABLE ~a" (sql-quote-identifier (sql-truncate-table trunc))))

;; --- WITH (CTEs) -----------------------------------------------------------

(define (emit-with w)
  (define cte-strs
    (for/list ([cte (in-list (sql-with-ctes w))])
      (format "~a AS (\n  ~a\n)" (sql-quote-identifier (sql-cte-name cte)) (emit-sql-form (sql-cte-query cte)))))
  (define body-str (emit-sql-form (sql-with-body w)))
  (format "WITH ~a\n~a" (string-join cte-strs ",\n") body-str))

;; --- UNION / INTERSECT / EXCEPT -------------------------------------------

(define (emit-union u)
  (define op-str
    (case (sql-union-op u)
      [(union)     "UNION"]
      [(union-all) "UNION ALL"]
      [(intersect) "INTERSECT"]
      [(except)    "EXCEPT"]
      [else        "UNION"]))
  (format "~a\n~a\n~a" (emit-sql-form (sql-union-left u)) op-str (emit-sql-form (sql-union-right u))))

;; --- registration ----------------------------------------------------------

(define sql-backend
  (emitter-backend 'sql sql-emit-program))

(register-backend! 'sql sql-backend)
