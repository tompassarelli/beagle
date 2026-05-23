#lang racket/base

;; .bsql fixture coverage. Each fixture exercises a different surface
;; corner of the SQL target. We compile the source and assert structural
;; properties of the emitted SQL.

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/runtime-path
         beagle/private/parse
         beagle/private/emit
         beagle/lang/reader-impl)

(define-runtime-path fixtures-dir "fixtures")

(define (compile-bsql-file path)
  (define src (file->string path))
  (define lines (string-split src "\n"))
  (define body-lines
    (filter (lambda (l) (not (string-prefix? l "#lang"))) lines))
  (define body (string-append "(define-target sql)\n"
                              (string-join body-lines "\n")))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-read-syntax (path->string path) (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (string-trim (emit-program prog)))

(define (sql-fixture name)
  (compile-bsql-file (build-path fixtures-dir name)))

;; --- simple SELECT ----------------------------------------------------------

(test-case "sql-simple-select fixture"
  (define out (sql-fixture "sql-simple-select.bsql"))
  (check-true (string-contains? out "SELECT \"name\", \"price\""))
  (check-true (string-contains? out "FROM \"products\""))
  (check-true (string-contains? out "WHERE \"price\" > 10")))

;; --- CREATE TABLE -----------------------------------------------------------

(test-case "sql-deftable fixture — primary-key, NOT NULL, nullable, default, references"
  (define out (sql-fixture "sql-deftable.bsql"))
  (check-true (string-contains? out "CREATE TABLE \"customers\""))
  (check-true (string-contains? out "\"id\" INTEGER PRIMARY KEY"))
  (check-true (string-contains? out "\"name\" TEXT NOT NULL"))
  (check-true (string-contains? out "\"email\" TEXT NOT NULL UNIQUE"))
  ;; nullable column should NOT get the implicit NOT NULL
  (check-false (string-contains? out "\"city\" TEXT NOT NULL"))
  (check-true (string-contains? out "DEFAULT 0"))
  (check-true (string-contains? out "REFERENCES \"customers\"(\"id\")")))

;; --- JOINs ------------------------------------------------------------------

(test-case "sql-joins fixture — inner + left with alias"
  (define out (sql-fixture "sql-joins.bsql"))
  (check-true (string-contains? out "FROM \"customers\" AS \"c\""))
  (check-true (string-contains? out "LEFT JOIN \"orders\" AS \"o\""))
  (check-true (string-contains? out "JOIN \"order_items\" AS \"oi\""))
  (check-true (string-contains? out "JOIN \"products\" AS \"p\""))
  (check-true (string-contains? out "GROUP BY \"c\".\"name\", \"p\".\"name\"")))

;; --- GROUP BY + HAVING ------------------------------------------------------

(test-case "sql-group-having fixture — aggregates + HAVING + LIMIT"
  (define out (sql-fixture "sql-group-having.bsql"))
  (check-true (string-contains? out "COUNT(\"id\") AS \"item_count\""))
  (check-true (string-contains? out "AVG(\"price\") AS \"avg_price\""))
  (check-true (string-contains? out "GROUP BY \"category\""))
  (check-true (string-contains? out "HAVING COUNT(\"id\") > 5"))
  (check-true (string-contains? out "ORDER BY \"avg_price\" DESC"))
  (check-true (string-contains? out "LIMIT 10")))

;; --- CTE (WITH) -------------------------------------------------------------

(test-case "sql-cte fixture — WITH then SELECT"
  (define out (sql-fixture "sql-cte.bsql"))
  (check-true (string-contains? out "WITH \"top_customers\" AS"))
  (check-true (string-contains? out "SUM(\"total\") AS \"revenue\""))
  (check-true (string-contains? out "HAVING SUM(\"total\") > 1000"))
  (check-true (string-contains? out "JOIN \"top_customers\" AS \"tc\"")))

;; --- subquery ---------------------------------------------------------------

(test-case "sql-subquery fixture — EXISTS + IN subqueries"
  (define out (sql-fixture "sql-subquery.bsql"))
  (check-true (string-contains? out "EXISTS"))
  (check-true (string-contains? out "FROM \"orders\" AS \"o\""))
  (check-true (string-contains? out "\"c\".\"id\" IN ("))
  (check-true (string-contains? out "FROM \"premium_members\"")))

;; --- INSERT -----------------------------------------------------------------

(test-case "sql-insert fixture — CREATE TABLE + multi-row INSERT"
  (define out (sql-fixture "sql-insert.bsql"))
  (check-true (string-contains? out "CREATE TABLE \"products\""))
  (check-true (string-contains? out "INSERT INTO \"products\" (\"name\", \"price\", \"stock\")"))
  (check-true (string-contains? out "('Widget', 9.99, 100)"))
  (check-true (string-contains? out "('Gadget', 19.99, 50)"))
  (check-true (string-contains? out "('Gizmo', 29.99, 25)")))

;; --- UPDATE -----------------------------------------------------------------

(test-case "sql-update fixture — multi-pair SET + WHERE"
  (define out (sql-fixture "sql-update.bsql"))
  (check-true (string-contains? out "UPDATE \"products\" SET"))
  (check-true (string-contains? out "\"price\" = \"price\" * 0.9"))
  (check-true (string-contains? out "\"stock\" = \"stock\" + 10"))
  (check-true (string-contains? out "WHERE \"category\" = 'clearance'")))

;; --- DELETE -----------------------------------------------------------------

(test-case "sql-delete fixture — DELETE with OR predicate"
  (define out (sql-fixture "sql-delete.bsql"))
  (check-true (string-contains? out "DELETE FROM \"sessions\""))
  (check-true (string-contains? out "(\"expires_at\" < '2024-01-01' OR \"revoked\" = TRUE)")))

;; --- window functions -------------------------------------------------------

(test-case "sql-window fixture — RANK + SUM OVER (PARTITION BY ...)"
  (define out (sql-fixture "sql-window.bsql"))
  (check-true (string-contains? out "RANK() OVER (PARTITION BY \"department\" ORDER BY \"salary\" DESC) AS \"salary_rank\""))
  (check-true (string-contains? out "SUM(\"salary\") OVER (PARTITION BY \"department\") AS \"dept_total\""))
  (check-true (string-contains? out "ORDER BY \"department\" ASC, \"salary\" DESC")))

;; --- CASE + UNION -----------------------------------------------------------

(test-case "sql-case-union fixture — CASE expr with else, UNION of selects"
  (define out (sql-fixture "sql-case-union.bsql"))
  (check-true (string-contains? out "CASE"))
  (check-true (string-contains? out "WHEN \"price\" > 100 THEN 'premium'"))
  (check-true (string-contains? out "WHEN \"price\" > 50 THEN 'mid-range'"))
  (check-true (string-contains? out "ELSE 'budget'"))
  (check-true (string-contains? out "END AS \"tier\""))
  (check-true (string-contains? out "UNION"))
  (check-true (string-contains? out "'discontinued' AS \"tier\"")))

;; --- stdlib funcs (LTRIM, SIGN, ROUND, CURRENT_TIMESTAMP) -------------------

(test-case "sql-stdlib-funcs fixture — newly-added scalar/math/time functions"
  (define out (sql-fixture "sql-stdlib-funcs.bsql"))
  (check-true (string-contains? out "LTRIM(\"raw_name\") AS \"cleaned\""))
  (check-true (string-contains? out "SIGN(\"balance\") AS \"bal_sign\""))
  (check-true (string-contains? out "ROUND(\"qty\" * \"unit_price\", 2) AS \"line_total\""))
  ;; niladic keywords emit without parens — portable across PostgreSQL, MySQL, SQLite
  (check-true (string-contains? out "CURRENT_TIMESTAMP AS \"fetched_at\""))
  (check-false (string-contains? out "CURRENT_TIMESTAMP()")))
