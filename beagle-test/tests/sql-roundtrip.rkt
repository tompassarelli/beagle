#lang racket/base

;; SQLite round-trip tests: emit SQL from beagle source, execute against
;; sqlite3 :memory:, verify the SQL is syntactically and semantically valid.

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/system
         beagle/private/parse
         beagle/private/emit
         beagle/private/check
         beagle/private/types)

(define SQLITE-PATH (find-executable-path "sqlite3"))

(unless SQLITE-PATH
  (displayln "SKIP: sqlite3 not found, skipping SQL round-trip tests")
  (exit 0))

(define (sql-emit src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog (parse-program stxs))
  (type-check! prog)
  (string-trim (emit-program prog)))

(define (se . parts) (sql-emit (apply string-append parts)))

;; Emit a query-only program (no deftable, avoids duplicate CREATE TABLE)
(define (sq . parts) (sql-emit (string-append "(define-target sql) " (apply string-append parts))))

(define (run-sqlite sql)
  (define tmp (make-temporary-file "beagle-sql-~a.sql"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out) (display sql out) (newline out)))
      (define-values (proc stdout stdin stderr)
        (subprocess #f #f #f SQLITE-PATH ":memory:"
                    (string-append ".read " (path->string tmp))))
      (close-output-port stdin)
      (define out-str (port->string stdout))
      (define err-str (port->string stderr))
      (subprocess-wait proc)
      (define code (subprocess-status proc))
      (close-input-port stdout)
      (close-input-port stderr)
      (values code out-str err-str))
    (lambda () (delete-file tmp))))

(define (check-sqlite-ok sql [label ""])
  (define-values (code out err) (run-sqlite sql))
  (unless (= code 0)
    (fail (format "SQLite error~a:\n~a\nSQL:\n~a" (if (string=? label "") "" (format " [~a]" label)) err sql))))

;; Raw SQL setup for populating test databases (avoids duplicate CREATE TABLE from beagle emit)
(define products-ddl
  "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL, category TEXT NOT NULL, stock INTEGER NOT NULL);")

(define products-data
  (string-append
    products-ddl "\n"
    "INSERT INTO products VALUES (1, 'Widget', 9.99, 'tools', 50);\n"
    "INSERT INTO products VALUES (2, 'Gadget', 19.99, 'electronics', 30);\n"
    "INSERT INTO products VALUES (3, 'Bolt', 0.50, 'tools', 1000);\n"))

(define ecommerce-data
  (string-append
    "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE);\n"
    "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL, category TEXT);\n"
    "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, status TEXT);\n"
    "CREATE TABLE order_items (id INTEGER PRIMARY KEY, order_id INTEGER, product_id INTEGER, quantity INTEGER, unit_price REAL);\n"
    "INSERT INTO customers VALUES (1, 'Alice', 'alice@test.com');\n"
    "INSERT INTO customers VALUES (2, 'Bob', 'bob@test.com');\n"
    "INSERT INTO products VALUES (1, 'Widget', 9.99, 'tools');\n"
    "INSERT INTO products VALUES (2, 'Gadget', 19.99, 'electronics');\n"
    "INSERT INTO products VALUES (3, 'Bolt', 0.50, 'tools');\n"
    "INSERT INTO orders VALUES (1, 1, 'shipped');\n"
    "INSERT INTO orders VALUES (2, 1, 'delivered');\n"
    "INSERT INTO orders VALUES (3, 2, 'pending');\n"
    "INSERT INTO order_items VALUES (1, 1, 1, 5, 9.99);\n"
    "INSERT INTO order_items VALUES (2, 1, 2, 1, 19.99);\n"
    "INSERT INTO order_items VALUES (3, 2, 3, 100, 0.50);\n"
    "INSERT INTO order_items VALUES (4, 3, 1, 2, 9.99);\n"))

;; =====================================================================
;; DDL round-trip — beagle-emitted CREATE TABLE
;; =====================================================================

(test-case "sqlite: CREATE TABLE executes"
  (define sql (se "(define-target sql) " "(deftable users [(id : Int :primary-key) (name : String :not-null) (email : String :unique)])"))
  (check-sqlite-ok sql "CREATE TABLE"))

(test-case "sqlite: CREATE TABLE with nullable column"
  (define sql (se "(define-target sql) " "(deftable items [(id : Int :primary-key) (note : (U String Nil))])"))
  (check-sqlite-ok sql "nullable column"))

(test-case "sqlite: CREATE TABLE with Bool and Float"
  (define sql (se "(define-target sql) " "(deftable t [(price : Float) (active : Bool)])"))
  (check-sqlite-ok sql "Bool/Float types"))

;; =====================================================================
;; DML round-trip — INSERT/UPDATE/DELETE emitted as single programs
;; =====================================================================

(test-case "sqlite: INSERT + SELECT"
  (define sql (se "(define-target sql) " "(deftable products [(id : Int :primary-key) (name : String :not-null) (price : Float)]) " "(insert products [id name price] (values [1 \"Widget\" 9.99]))"))
  (define full-sql (string-append sql ";\nSELECT * FROM products;"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Widget")))

(test-case "sqlite: UPDATE executes"
  (define full-sql (string-append products-data "UPDATE products SET price = price * 0.9 WHERE id = 1;\n" "SELECT price FROM products WHERE id = 1;"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "8.991")))

(test-case "sqlite: UPDATE emitter output"
  (define sql (se "(define-target sql) " "(deftable products [(id : Int) (price : Float)]) " "(update products (set [price (* price 0.9)]) (where (= id 1)))"))
  (check-true (string-contains? sql "UPDATE \"products\" SET"))
  (check-true (string-contains? sql "\"price\" = \"price\" * 0.9")))

(test-case "sqlite: DELETE executes"
  (define full-sql (string-append products-data "DELETE FROM products WHERE id = 1;\n" "SELECT count(*) FROM products;"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "2")))

;; =====================================================================
;; SELECT round-trip
;; =====================================================================

(test-case "sqlite: simple SELECT"
  (define full-sql (string-append products-data (sq "(select [name price] (from products) (where (= category \"tools\")))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Widget")))

(test-case "sqlite: SELECT DISTINCT"
  (define full-sql (string-append products-data (sq "(select-distinct [category] (from products))") ";"))
  (check-sqlite-ok full-sql "SELECT DISTINCT"))

(test-case "sqlite: ORDER BY and LIMIT"
  (define full-sql (string-append products-data (sq "(select [name price] (from products) (order-by price :desc) (limit 2))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Gadget")))

(test-case "sqlite: OFFSET"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (order-by id :asc) (limit 1) (offset 1))") ";"))
  (check-sqlite-ok full-sql "OFFSET"))

(test-case "sqlite: SELECT star"
  (define full-sql (string-append products-data (sq "(select [*] (from products))") ";"))
  (check-sqlite-ok full-sql "SELECT *"))

;; =====================================================================
;; Expressions round-trip
;; =====================================================================

(test-case "sqlite: AND/OR"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (and (> price 1) (< stock 100))))") ";"))
  (check-sqlite-ok full-sql "AND/OR"))

(test-case "sqlite: BETWEEN"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (between price 1 15)))") ";"))
  (check-sqlite-ok full-sql "BETWEEN"))

(test-case "sqlite: IN with values"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (in category \"tools\" \"electronics\")))") ";"))
  (check-sqlite-ok full-sql "IN"))

(test-case "sqlite: IS NULL"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (is-null category)))") ";"))
  (check-sqlite-ok full-sql "IS NULL"))

(test-case "sqlite: LIKE"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (like name \"%idget\")))") ";"))
  (check-sqlite-ok full-sql "LIKE"))

(test-case "sqlite: NOT"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (not (= category \"tools\"))))") ";"))
  (check-sqlite-ok full-sql "NOT"))

(test-case "sqlite: CASE"
  (define full-sql (string-append products-data (sq "(select [(case (when (> price 10) \"expensive\") :else \"cheap\") :as tier] (from products))") ";"))
  (check-sqlite-ok full-sql "CASE"))

(test-case "sqlite: CAST"
  (define full-sql (string-append products-data (sq "(select [(cast price integer)] (from products))") ";"))
  (check-sqlite-ok full-sql "CAST"))

(test-case "sqlite: string concat ||"
  (define full-sql (string-append products-data (sq "(select [(|| name \" - \" category)] (from products))") ";"))
  (check-sqlite-ok full-sql "||"))

;; =====================================================================
;; Aggregates round-trip
;; =====================================================================

(test-case "sqlite: COUNT"
  (define full-sql (string-append products-data (sq "(select [(count id)] (from products))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "3")))

(test-case "sqlite: COUNT DISTINCT"
  (define full-sql (string-append products-data (sq "(select [(count-distinct category)] (from products))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "2")))

(test-case "sqlite: SUM/AVG/MIN/MAX"
  (define full-sql (string-append products-data (sq "(select [(sum price) (avg price) (min price) (max price)] (from products))") ";"))
  (check-sqlite-ok full-sql "SUM/AVG/MIN/MAX"))

(test-case "sqlite: GROUP BY"
  (define full-sql (string-append products-data (sq "(select [category (count id :as cnt)] (from products) (group-by category))") ";"))
  (check-sqlite-ok full-sql "GROUP BY"))

(test-case "sqlite: HAVING"
  (define full-sql (string-append products-data (sq "(select [category (count id :as cnt)] (from products) (group-by category) (having (> (count id) 1)))") ";"))
  (check-sqlite-ok full-sql "HAVING"))

;; =====================================================================
;; JOINs round-trip
;; =====================================================================

(define join-data
  (string-append
    products-data
    "CREATE TABLE orders (id INTEGER PRIMARY KEY, product_id INTEGER, quantity INTEGER);\n"
    "INSERT INTO orders VALUES (1, 1, 5);\n"
    "INSERT INTO orders VALUES (2, 2, 3);\n"))

(test-case "sqlite: LEFT JOIN"
  (define full-sql (string-append join-data (sq "(select [p.name o.quantity] (from products :as p) (left-join orders :as o (= o.product_id p.id)))") ";"))
  (check-sqlite-ok full-sql "LEFT JOIN"))

(test-case "sqlite: CROSS JOIN"
  (define full-sql (string-append join-data (sq "(select [p.name o.id] (from products :as p) (cross-join orders :as o))") ";"))
  (check-sqlite-ok full-sql "CROSS JOIN"))

;; =====================================================================
;; Window functions round-trip
;; =====================================================================

(test-case "sqlite: ROW_NUMBER"
  (define full-sql (string-append products-data (sq "(select [name (row_number :as rn :over (order-by price :asc))] (from products))") ";"))
  (check-sqlite-ok full-sql "ROW_NUMBER"))

(test-case "sqlite: SUM OVER PARTITION BY"
  (define full-sql (string-append products-data (sq "(select [name (sum price :as running :over (partition-by category) (order-by id :asc))] (from products))") ";"))
  (check-sqlite-ok full-sql "SUM OVER PARTITION"))

(test-case "sqlite: RANK"
  (define full-sql (string-append products-data (sq "(select [name (rank :as rnk :over (order-by price :desc))] (from products))") ";"))
  (check-sqlite-ok full-sql "RANK"))

;; =====================================================================
;; Subqueries round-trip
;; =====================================================================

(test-case "sqlite: EXISTS subquery"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (exists (select [1] (from products) (where (> price 5))))))") ";"))
  (check-sqlite-ok full-sql "EXISTS"))

(test-case "sqlite: IN subquery"
  (define full-sql (string-append products-data (sq "(select [name] (from products) (where (in id (select [id] (from products) (where (> price 5))))))") ";"))
  (check-sqlite-ok full-sql "IN subquery"))

;; =====================================================================
;; CTEs round-trip
;; =====================================================================

(test-case "sqlite: single CTE"
  (define full-sql (string-append products-data (sq "(with (expensive (select [*] (from products) (where (> price 10)))) (select [name price] (from expensive)))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Gadget")))

(test-case "sqlite: multiple CTEs"
  (define full-sql (string-append products-data (sq "(with (expensive (select [name] (from products) (where (> price 10)))) (cheap (select [name] (from products) (where (< price 1)))) (select [*] (from expensive)))") ";"))
  (check-sqlite-ok full-sql "multiple CTEs"))

;; =====================================================================
;; Set operations round-trip
;; =====================================================================

(test-case "sqlite: UNION"
  (define full-sql (string-append products-data (sq "(union (select [name] (from products) (where (= category \"tools\"))) (select [name] (from products) (where (= category \"electronics\"))))") ";"))
  (check-sqlite-ok full-sql "UNION"))

(test-case "sqlite: UNION ALL"
  (define full-sql (string-append products-data (sq "(union-all (select [name] (from products) (where (= category \"tools\"))) (select [name] (from products) (where (= category \"tools\"))))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Widget")))

(test-case "sqlite: INTERSECT"
  (define full-sql (string-append products-data (sq "(intersect (select [name] (from products)) (select [name] (from products) (where (= category \"tools\"))))") ";"))
  (check-sqlite-ok full-sql "INTERSECT"))

(test-case "sqlite: EXCEPT"
  (define full-sql (string-append products-data (sq "(except (select [name] (from products)) (select [name] (from products) (where (= category \"tools\"))))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Gadget")))

;; =====================================================================
;; DDL operations round-trip
;; =====================================================================

(test-case "sqlite: CREATE INDEX"
  (define full-sql (string-append "CREATE TABLE t (id INTEGER, name TEXT);\n" (sq "(create-index idx_t_name t [name])") ";"))
  (check-sqlite-ok full-sql "CREATE INDEX"))

(test-case "sqlite: CREATE UNIQUE INDEX"
  (define full-sql (string-append "CREATE TABLE t (id INTEGER, email TEXT);\n" (sq "(create-unique-index idx_t_email t [email])") ";"))
  (check-sqlite-ok full-sql "CREATE UNIQUE INDEX"))

(test-case "sqlite: DROP TABLE IF EXISTS"
  (check-sqlite-ok (sq "(drop-table-if-exists nonexistent)") "DROP TABLE IF EXISTS"))

(test-case "sqlite: DROP TABLE"
  (define full-sql (string-append "CREATE TABLE temp (id INTEGER);\n" (sq "(drop-table temp)") ";"))
  (check-sqlite-ok full-sql "DROP TABLE"))

(test-case "sqlite: ALTER TABLE add column"
  (define full-sql (string-append "CREATE TABLE t (id INTEGER);\n" (sq "(alter-table t (add-column name : String))") ";"))
  (check-sqlite-ok full-sql "ALTER TABLE ADD"))

(test-case "sqlite: ALTER TABLE rename column"
  (define full-sql (string-append "CREATE TABLE t (id INTEGER, old_name TEXT);\n" (sq "(alter-table t (rename-column old_name new_name))") ";"))
  (check-sqlite-ok full-sql "ALTER TABLE RENAME"))

;; =====================================================================
;; INSERT...SELECT round-trip
;; =====================================================================

(test-case "sqlite: INSERT...SELECT"
  (define full-sql (string-append products-data "CREATE TABLE archive (name TEXT, price REAL);\n" (sq "(insert-select archive [name price] (select [name price] (from products) (where (> price 5))))") ";\nSELECT * FROM archive;"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Widget")))

;; =====================================================================
;; Stdlib functions round-trip
;; =====================================================================

(test-case "sqlite: COALESCE"
  (define full-sql (string-append products-data (sq "(select [(coalesce category \"unknown\")] (from products))") ";"))
  (check-sqlite-ok full-sql "COALESCE"))

(test-case "sqlite: UPPER/LOWER"
  (define full-sql (string-append products-data (sq "(select [(upper name) (lower category)] (from products))") ";"))
  (check-sqlite-ok full-sql "UPPER/LOWER"))

(test-case "sqlite: SUBSTR"
  (define full-sql (string-append products-data (sq "(select [(substring name 1 3)] (from products))") ";"))
  (check-sqlite-ok full-sql "SUBSTRING"))

(test-case "sqlite: ABS/ROUND"
  (define full-sql (string-append products-data (sq "(select [(abs price) (round price 0)] (from products))") ";"))
  (check-sqlite-ok full-sql "ABS/ROUND"))

(test-case "sqlite: LENGTH"
  (define full-sql (string-append products-data (sq "(select [(length name)] (from products))") ";"))
  (check-sqlite-ok full-sql "LENGTH"))

(test-case "sqlite: REPLACE"
  (define full-sql (string-append products-data (sq "(select [(replace name \"Widget\" \"Gizmo\")] (from products))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Gizmo")))

;; =====================================================================
;; Complex e-commerce round-trip
;; =====================================================================

(test-case "sqlite: e-commerce revenue by category"
  (define full-sql (string-append ecommerce-data (sq "(select [p.category (sum oi.unit_price :as revenue)] " "(from order_items :as oi) " "(left-join products :as p (= oi.product_id p.id)) " "(group-by p.category))") ";"))
  (check-sqlite-ok full-sql "revenue by category"))

(test-case "sqlite: e-commerce CTE top products"
  (define full-sql (string-append ecommerce-data (sq "(with (popular (select [p.name (count oi.id :as order_count)] " "(from order_items :as oi) " "(left-join products :as p (= oi.product_id p.id)) " "(group-by p.name))) " "(select [name order_count] (from popular) (order-by order_count :desc)))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Widget")))

(test-case "sqlite: e-commerce CASE status"
  (define full-sql (string-append ecommerce-data (sq "(select [o.id (case (when (= o.status \"shipped\") \"in transit\") " "(when (= o.status \"delivered\") \"complete\") " ":else \"waiting\") :as display_status] " "(from orders :as o))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "in transit")))

(test-case "sqlite: e-commerce NOT EXISTS"
  (define full-sql (string-append ecommerce-data (sq "(select [c.name] (from customers :as c) " "(where (not (exists (select [1] (from orders :as o) (where (= o.customer_id c.id)))))))") ";"))
  (check-sqlite-ok full-sql "NOT EXISTS"))

(test-case "sqlite: e-commerce window ranking"
  (define full-sql (string-append ecommerce-data (sq "(select [p.name p.price (row_number :as price_rank :over (order-by p.price :desc))] " "(from products :as p))") ";"))
  (define-values (code out err) (run-sqlite full-sql))
  (check-equal? code 0 (format "SQLite error: ~a" err))
  (check-true (string-contains? out "Gadget")))

(test-case "sqlite: e-commerce UNION"
  (define full-sql (string-append ecommerce-data (sq "(union " "(select [o.id o.status] (from orders :as o) (where (= o.status \"shipped\"))) " "(select [o.id o.status] (from orders :as o) (where (= o.status \"delivered\"))))") ";"))
  (check-sqlite-ok full-sql "UNION"))
