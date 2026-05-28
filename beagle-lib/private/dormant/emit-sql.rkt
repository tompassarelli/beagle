#lang racket/base

;; SQL emitter backend.
;; Maps Beagle AST -> SQL source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         "../parse.rkt"
         "../types.rkt"
         "../emit-dispatch.rkt")

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

;; --- Small emission helpers -------------------------------------------------

;; Group-by, partition-by, and order-by all accept the same shape:
;; bare symbol → quoted identifier; sql-column-ref → "t"."col";
;; otherwise → fall back to general expression emission.
(define (emit-sql-column-or-symbol x)
  (cond
    [(sql-column-ref? x) (emit-sql-column-ref x)]
    [(symbol? x)         (sql-quote-identifier x)]
    [else                (emit-sql-expr x)]))

;; Emit a single ORDER BY spec: `<expr> ASC|DESC`.
(define (emit-sql-order-spec spec)
  (define expr-str (emit-sql-column-or-symbol (sql-order-spec-expr spec)))
  (format "~a ~a" expr-str
          (string-upcase (symbol->string (sql-order-spec-direction spec)))))

(define (emit-sql-order-by-list specs)
  (string-join (map emit-sql-order-spec specs) ", "))

(define (emit-sql-column-list cols)
  (string-join (map emit-sql-column-or-symbol cols) ", "))

;; Join non-empty string parts with newlines. Filters falsy/empty entries.
(define (join-non-empty parts sep)
  (string-join (filter (lambda (s) (and s (not (string=? s "")))) parts) sep))

;; --- SQL emission from Beagle AST -----------------------------------------

(define (sql-emit-program prog)
  (define forms (program-forms prog))
  (define statements
    (for/list ([f (in-list forms)]
               #:unless (with-meta? f))
      (emit-sql-form f)))
  (join-non-empty statements ";\n"))

(define (emit-sql-form f)
  (cond
    [(sql-table? f)          (emit-create-table f)]
    [(sql-select? f)         (emit-select f)]
    [(sql-insert? f)         (emit-insert f)]
    [(sql-update? f)         (emit-update f)]
    [(sql-delete? f)         (emit-delete f)]
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

;; A nullable type is `(U T Nil)` exactly — two alts, one being Nil.
(define (nullable-type? t)
  (and (type-union? t)
       (= (length (type-union-alts t)) 2)
       (ormap nil-type? (type-union-alts t))))

(define (nullable-inner t)
  (findf (lambda (a) (not (nil-type? a))) (type-union-alts t)))

(define (nil-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Nil)))

(define (beagle-type->sql-type t)
  (cond
    [(type-prim? t) (sql-prim-type-name (type-prim-name t))]
    [(nullable-type? t) (beagle-type->sql-type (nullable-inner t))]
    [else "TEXT"]))

(define (symbol->sql-type sym)
  (sql-prim-type-name sym))

(define (sql-prim-type-name name)
  (case name
    [(Int)     "INTEGER"]
    [(Float)   "REAL"]
    [(String)  "TEXT"]
    [(Bool)    "BOOLEAN"]
    [(Keyword) "TEXT"]
    [(Symbol)  "TEXT"]
    [else      "TEXT"]))

(define (emit-sql-constraint c)
  (cond
    [(eq? c ':primary-key)   "PRIMARY KEY"]
    [(eq? c ':not-null)      "NOT NULL"]
    [(eq? c ':unique)        "UNIQUE"]
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
      (emit-create-table-column col)))
  (format "CREATE TABLE ~a (\n  ~a\n)" (sql-quote-identifier name) (string-join col-strs ",\n  ")))

(define (emit-create-table-column col)
  (define col-name (sql-quote-identifier (sql-column-name col)))
  (define col-type (beagle-type->sql-type (sql-column-type col)))
  (define raw-constraints (sql-column-constraints col))
  (define constraint-strs (map emit-sql-constraint raw-constraints))
  ;; NOT NULL is implied for non-nullable types unless already constrained.
  ;; Skip NOT NULL when :not-null or :primary-key is already declared.
  (define implicit-not-null?
    (and (not (nullable-type? (sql-column-type col)))
         (not (member ':not-null raw-constraints))
         (not (member ':primary-key raw-constraints))))
  (join-non-empty
    (append (list col-name col-type)
            (if implicit-not-null? '("NOT NULL") '())
            constraint-strs)
    " "))

;; --- SELECT ----------------------------------------------------------------

(define (emit-select sel)
  (define cols      (sql-select-columns sel))
  (define from      (sql-select-from-clause sel))
  (define joins     (sql-select-joins sel))
  (define where     (sql-select-where-clause sel))
  (define group-by  (sql-select-group-by sel))
  (define having    (sql-select-having sel))
  (define order-by  (sql-select-order-by sel))
  (define limit     (sql-select-limit sel))
  (define offset    (sql-select-offset sel))
  (define distinct? (sql-select-distinct? sel))

  (define select-kw (if distinct? "SELECT DISTINCT" "SELECT"))
  (define select-line
    (format "~a ~a" select-kw (string-join (map emit-sql-column cols) ", ")))

  (define lines
    (append
      (list select-line)
      (if from (list (format "FROM ~a" (emit-sql-table-ref from))) '())
      (map emit-sql-join joins)
      (if where (list (format "WHERE ~a" (emit-sql-expr where))) '())
      (if (pair? group-by)
        (list (format "GROUP BY ~a" (emit-sql-column-list group-by)))
        '())
      (if having (list (format "HAVING ~a" (emit-sql-expr having))) '())
      (if (pair? order-by)
        (list (format "ORDER BY ~a" (emit-sql-order-by-list order-by)))
        '())
      (if limit  (list (format "LIMIT ~a" limit))   '())
      (if offset (list (format "OFFSET ~a" offset)) '())))

  (string-join lines "\n"))

(define (emit-sql-join j)
  (define join-type
    (case (sql-join-type j)
      [(inner) "JOIN"]
      [(left)  "LEFT JOIN"]
      [(right) "RIGHT JOIN"]
      [(full)  "FULL JOIN"]
      [(cross) "CROSS JOIN"]
      [else    "JOIN"]))
  (define table-str
    (if (sql-join-alias j)
      (format "~a AS ~a" (sql-quote-identifier (sql-join-table j))
              (sql-quote-identifier (sql-join-alias j)))
      (sql-quote-identifier (sql-join-table j))))
  (define on-str
    (if (sql-join-condition j)
      (format " ON ~a" (emit-sql-expr (sql-join-condition j)))
      ""))
  (format "~a ~a~a" join-type table-str on-str))

;; --- INSERT ----------------------------------------------------------------

(define (emit-insert ins)
  (define table (sql-insert-table ins))
  (define cols  (sql-insert-columns ins))
  (define rows  (sql-insert-values ins))
  (define col-str (string-join (map sql-quote-identifier cols) ", "))
  (define row-strs
    (for/list ([row (in-list rows)])
      (format "(~a)" (string-join (map emit-sql-value row) ", "))))
  (format "INSERT INTO ~a (~a) VALUES ~a"
          (sql-quote-identifier table) col-str (string-join row-strs ", ")))

;; --- UPDATE ----------------------------------------------------------------

(define (emit-update upd)
  (define table (sql-update-table upd))
  (define set-pairs (sql-update-set-pairs upd))
  (define where (sql-update-where-clause upd))

  (define set-strs
    (for/list ([pair (in-list set-pairs)])
      (format "~a = ~a" (sql-quote-identifier (car pair)) (emit-sql-expr (cdr pair)))))

  (define base (format "UPDATE ~a SET ~a" (sql-quote-identifier table) (string-join set-strs ", ")))
  (if where
    (format "~a WHERE ~a" base (emit-sql-expr where))
    base))

;; --- DELETE ----------------------------------------------------------------

(define (emit-delete del)
  (define qt (sql-quote-identifier (sql-delete-table del)))
  (define where (sql-delete-where-clause del))
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
    [(symbol? e)  (sql-quote-identifier e)]
    [(string? e)  (sql-quote-string e)]
    [(number? e)  (sql-safe-number e)]
    [(boolean? e) (if e "TRUE" "FALSE")]
    [(eq? e 'nil) "NULL"]
    [else (format "~a" e)]))

(define (emit-sql-column-ref ref)
  (format "~a.~a" (sql-quote-identifier (sql-column-ref-table-or-alias ref))
          (sql-quote-identifier (sql-column-ref-column ref))))

;; CURRENT_TIMESTAMP / CURRENT_DATE / CURRENT_TIME are SQL keywords, not
;; functions — most engines (notably SQLite) reject the trailing `()`.
(define SQL-NILADIC-KEYWORDS
  '(current_date current_time current_timestamp))

(define (emit-sql-aggregate agg)
  (define fn-name (sql-aggregate-fn-name agg))
  (define arg-expr (sql-aggregate-expr agg))
  (define base
    (cond
      [(eq? fn-name 'count-distinct)
       (format "COUNT(DISTINCT ~a)" (emit-sql-expr arg-expr))]
      [(and (not arg-expr) (memq fn-name SQL-NILADIC-KEYWORDS))
       (string-upcase (symbol->string fn-name))]
      [else
       (define fn-str (string-upcase (symbol->string fn-name)))
       ;; `COUNT()` with no arg means `COUNT(*)`. Other zero-arg functions
       ;; (`NOW()` etc.) keep empty parens.
       (define arg-str
         (cond
           [arg-expr             (emit-sql-expr arg-expr)]
           [(eq? fn-name 'count) "*"]
           [else                 ""]))
       (format "~a(~a)" fn-str arg-str)]))
  (maybe-alias base (sql-aggregate-alias agg)))

(define (emit-sql-case-expr c)
  (define clause-strs
    (for/list ([clause (in-list (sql-case-clauses c))])
      (format "WHEN ~a THEN ~a"
              (emit-sql-expr (sql-case-clause-condition clause))
              (emit-sql-expr (sql-case-clause-result clause)))))
  (define else-strs
    (if (sql-case-else-expr c)
      (list (format "ELSE ~a" (emit-sql-expr (sql-case-else-expr c))))
      '()))
  (string-join (append (list "CASE") clause-strs else-strs (list "END")) " "))

(define (emit-sql-cast c)
  (define type-name (sql-cast-type-name c))
  (define type-str
    (if (symbol? type-name)
      (string-upcase (symbol->string type-name))
      (format "~a" type-name)))
  (format "CAST(~a AS ~a)" (emit-sql-expr (sql-cast-expr c)) type-str))

(define (emit-sql-window w)
  (define fn-str   (string-upcase (symbol->string (sql-window-fn-name w))))
  (define args     (sql-window-args w))
  (define arg-str  (if (null? args) "" (string-join (map emit-sql-expr args) ", ")))
  (define part-by  (sql-window-partition-by w))
  (define ord-by   (sql-window-order-by w))
  (define over-parts
    (append
      (if part-by  (list (format "PARTITION BY ~a" (emit-sql-column-list part-by))) '())
      (if ord-by   (list (format "ORDER BY ~a"     (emit-sql-order-by-list ord-by))) '())))
  (define base (format "~a(~a) OVER (~a)" fn-str arg-str (string-join over-parts " ")))
  (maybe-alias base (sql-window-alias w)))

;; Append `AS "alias"` to base if alias is set, else return base as-is.
(define (maybe-alias base alias)
  (if alias
    (format "~a AS ~a" base (sql-quote-identifier alias))
    base))

(define (emit-sql-call c)
  (define fn (call-form-fn c))
  (define args (call-form-args c))
  (cond
    [(and (symbol? fn) (memq fn '(= <> > < >= <= + - * /)))
     (emit-sql-binop fn args)]
    [(eq? fn 'and) (format "(~a)" (string-join (map emit-sql-expr args) " AND "))]
    [(eq? fn 'or)  (format "(~a)" (string-join (map emit-sql-expr args) " OR "))]
    [(eq? fn 'not) (format "NOT ~a" (emit-sql-expr (car args)))]
    [(eq? fn 'is-null)     (format "~a IS NULL"     (emit-sql-expr (car args)))]
    [(eq? fn 'is-not-null) (format "~a IS NOT NULL" (emit-sql-expr (car args)))]
    [(eq? fn '||)  (string-join (map emit-sql-expr args) " || ")]
    [(eq? fn 'like)
     (format "~a LIKE ~a" (emit-sql-expr (car args)) (emit-sql-expr (cadr args)))]
    [(eq? fn 'between)
     (format "~a BETWEEN ~a AND ~a"
             (emit-sql-expr (car args))
             (emit-sql-expr (cadr args))
             (emit-sql-expr (caddr args)))]
    [(eq? fn 'in) (emit-sql-in args)]
    [else
     (define fn-str (if (symbol? fn) (string-upcase (symbol->string fn)) (format "~a" fn)))
     (format "~a(~a)" fn-str (string-join (map emit-sql-expr args) ", "))]))

(define (emit-sql-binop op args)
  (cond
    [(= (length args) 2)
     (format "~a ~a ~a"
             (emit-sql-expr (car args))
             (symbol->string op)
             (emit-sql-expr (cadr args)))]
    [(and (= (length args) 1) (eq? op '-))
     (format "-~a" (emit-sql-expr (car args)))]
    [else
     (string-join (map emit-sql-expr args) (format " ~a " (symbol->string op)))]))

;; emit `x IN (...)`. Subquery operand → `IN (subselect)`; otherwise
;; emit a comma-separated value list.
(define (emit-sql-in args)
  (define lhs (emit-sql-expr (car args)))
  (define rhs (cdr args))
  (define inner
    (if (and (= (length rhs) 1) (sql-select? (car rhs)))
      (emit-select (car rhs))
      (string-join (map emit-sql-expr rhs) ", ")))
  (format "~a IN (~a)" lhs inner))

(define (emit-sql-value v)
  (cond
    [(string? v)         (sql-quote-string v)]
    [(number? v)         (sql-safe-number v)]
    [(boolean? v)        (if v "TRUE" "FALSE")]
    [(eq? v 'nil)        "NULL"]
    [(symbol? v)         (sql-quote-identifier v)]
    [(sql-column-ref? v) (emit-sql-column-ref v)]
    [(call-form? v)      (emit-sql-call v)]
    [else                (emit-sql-expr v)]))

(define (emit-sql-column col)
  (cond
    [(eq? col '*)          "*"]
    [(sql-column-ref? col) (emit-sql-column-ref col)]
    [(sql-aggregate? col)  (emit-sql-aggregate col)]
    [(sql-window? col)     (emit-sql-window col)]
    [(sql-alias? col)
     (format "~a AS ~a"
             (emit-sql-expr (sql-alias-expr col))
             (sql-quote-identifier (sql-alias-alias-name col)))]
    [(symbol? col) (sql-quote-identifier col)]
    [(string? col) (sql-quote-string col)]
    [else (emit-sql-expr col)]))

(define (emit-sql-table-ref ref)
  (cond
    [(sql-alias? ref)
     (format "~a AS ~a"
             (sql-quote-identifier (sql-alias-expr ref))
             (sql-quote-identifier (sql-alias-alias-name ref)))]
    [(symbol? ref) (sql-quote-identifier ref)]
    [else (format "~a" ref)]))

;; --- INSERT...SELECT -------------------------------------------------------

(define (emit-insert-select ins)
  (define col-str
    (string-join (map sql-quote-identifier (sql-insert-select-columns ins)) ", "))
  (format "INSERT INTO ~a (~a)\n~a"
          (sql-quote-identifier (sql-insert-select-table ins)) col-str
          (emit-sql-form (sql-insert-select-query ins))))

;; --- RETURNING ------------------------------------------------------------

(define (emit-returning ret)
  (define base    (emit-sql-form (sql-returning-stmt ret)))
  (define col-str (string-join (map sql-quote-identifier (sql-returning-columns ret)) ", "))
  (format "~a\nRETURNING ~a" base col-str))

;; --- CREATE INDEX ---------------------------------------------------------

(define (emit-create-index idx)
  (define kw (if (sql-create-index-unique? idx) "CREATE UNIQUE INDEX" "CREATE INDEX"))
  (define col-str
    (string-join (map sql-quote-identifier (sql-create-index-columns idx)) ", "))
  (format "~a ~a ON ~a (~a)"
          kw
          (sql-quote-identifier (sql-create-index-name idx))
          (sql-quote-identifier (sql-create-index-table idx))
          col-str))

;; --- DROP TABLE -----------------------------------------------------------

(define (emit-drop-table dt)
  (define qt (sql-quote-identifier (sql-drop-table-name dt)))
  (if (sql-drop-table-if-exists? dt)
    (format "DROP TABLE IF EXISTS ~a" qt)
    (format "DROP TABLE ~a" qt)))

;; --- ALTER TABLE ----------------------------------------------------------

(define (emit-alter-table alt)
  (define table  (sql-quote-identifier (sql-alter-table-table alt)))
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
     (format "ALTER TABLE ~a RENAME COLUMN ~a TO ~a"
             table
             (sql-quote-identifier (cadr action))
             (sql-quote-identifier (caddr action)))]
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
      (format "~a AS (\n  ~a\n)"
              (sql-quote-identifier (sql-cte-name cte))
              (emit-sql-form (sql-cte-query cte)))))
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
  (format "~a\n~a\n~a"
          (emit-sql-form (sql-union-left u))
          op-str
          (emit-sql-form (sql-union-right u))))

;; --- registration ----------------------------------------------------------

(define sql-backend
  (emitter-backend 'sql sql-emit-program))

(register-backend! 'sql sql-backend)
