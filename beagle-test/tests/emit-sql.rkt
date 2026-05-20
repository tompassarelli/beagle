#lang racket/base

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/private/check
         beagle/private/types)

(define (br . xs) (cons '#%brackets xs))

(define (sql-emit src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (begin
         (type-check! prog)
         (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
           (string-trim (emit-program prog))))))

(define (sql-check-error src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
      (parse-program stxs)))
  (cond
    [(string? prog) prog]
    [else
     (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
       (type-check! prog)
       #f)]))

;; helper: build sql-emit input via string-append (avoids formatter splitting calls)
(define (se . parts) (sql-emit (apply string-append parts)))
(define (sce . parts) (sql-check-error (apply string-append parts)))

;; =====================================================================
;; DDL — CREATE TABLE
;; =====================================================================

(test-case "deftable emits CREATE TABLE"
  (define out (sql-emit "(define-target sql) (deftable products [(id : Int :primary-key) (name : String :not-null)])"))
  (check-true (string-contains? out "CREATE TABLE \"products\""))
  (check-true (string-contains? out "\"id\" INTEGER PRIMARY KEY"))
  (check-true (string-contains? out "\"name\" TEXT NOT NULL")))

(test-case "deftable nullable column skips NOT NULL"
  (define out (sql-emit "(define-target sql) (deftable items [(id : Int) (note : (U String Nil))])"))
  (check-true (string-contains? out "\"id\" INTEGER NOT NULL"))
  (check-true (string-contains? out "\"note\" TEXT"))
  (check-false (string-contains? out "\"note\" TEXT NOT NULL")))

(test-case "deftable with unique constraint"
  (define out (sql-emit "(define-target sql) (deftable users [(id : Int :primary-key) (email : String :unique)])"))
  (check-true (string-contains? out "\"email\" TEXT NOT NULL UNIQUE")))

(test-case "deftable Float maps to REAL"
  (define out (sql-emit "(define-target sql) (deftable prices [(amount : Float)])"))
  (check-true (string-contains? out "\"amount\" REAL NOT NULL")))

(test-case "deftable Bool maps to BOOLEAN"
  (define out (sql-emit "(define-target sql) (deftable flags [(active : Bool)])"))
  (check-true (string-contains? out "\"active\" BOOLEAN NOT NULL")))

;; =====================================================================
;; SELECT basics
;; =====================================================================

(test-case "simple select"
  (define out (sql-emit "(define-target sql) (select [name price] (from products) (where (= category \"electronics\")))"))
  (check-true (string-contains? out "SELECT \"name\", \"price\""))
  (check-true (string-contains? out "FROM \"products\""))
  (check-true (string-contains? out "WHERE \"category\" = 'electronics'")))

(test-case "select with column refs"
  (define out (sql-emit "(define-target sql) (select [p.id p.name] (from products :as p))"))
  (check-true (string-contains? out "SELECT \"p\".\"id\", \"p\".\"name\""))
  (check-true (string-contains? out "FROM \"products\" AS \"p\"")))

(test-case "select with numeric where"
  (define out (sql-emit "(define-target sql) (select [name] (from products) (where (> price 10)))"))
  (check-true (string-contains? out "SELECT \"name\""))
  (check-true (string-contains? out "WHERE \"price\" > 10")))

(test-case "select star"
  (define out (sql-emit "(define-target sql) (select [*] (from products))"))
  (check-true (string-contains? out "SELECT *"))
  (check-true (string-contains? out "FROM \"products\"")))

;; =====================================================================
;; SELECT DISTINCT
;; =====================================================================

(test-case "select distinct"
  (define out (sql-emit "(define-target sql) (select-distinct [category] (from products))"))
  (check-true (string-contains? out "SELECT DISTINCT \"category\"")))

;; =====================================================================
;; JOINs
;; =====================================================================

(test-case "select with left join"
  (define out (se "(define-target sql) " "(select [p.id p.name (count o.id :as order_count)] " "(from products :as p) " "(left-join orders :as o (= o.product_id p.id)) " "(where (> p.stock 0)) " "(group-by p.id p.name))"))
  (check-true (string-contains? out "SELECT \"p\".\"id\", \"p\".\"name\", COUNT(\"o\".\"id\") AS \"order_count\""))
  (check-true (string-contains? out "FROM \"products\" AS \"p\""))
  (check-true (string-contains? out "LEFT JOIN \"orders\" AS \"o\" ON \"o\".\"product_id\" = \"p\".\"id\""))
  (check-true (string-contains? out "WHERE \"p\".\"stock\" > 0"))
  (check-true (string-contains? out "GROUP BY \"p\".\"id\", \"p\".\"name\"")))

(test-case "select with full join"
  (define out (se "(define-target sql) " "(select [a.id b.id] (from tableA :as a) (full-join tableB :as b (= a.key b.key)))"))
  (check-true (string-contains? out "FULL JOIN \"tableB\" AS \"b\" ON \"a\".\"key\" = \"b\".\"key\"")))

(test-case "select with cross join"
  (define out (se "(define-target sql) " "(select [a.x b.y] (from colors :as a) (cross-join sizes :as b))"))
  (check-true (string-contains? out "CROSS JOIN \"sizes\" AS \"b\"")))

;; =====================================================================
;; ORDER BY / LIMIT / OFFSET
;; =====================================================================

(test-case "select with order-by and limit"
  (define out (se "(define-target sql) " "(select [name price] (from products) (order-by price :desc) (limit 10))"))
  (check-true (string-contains? out "SELECT \"name\", \"price\""))
  (check-true (string-contains? out "ORDER BY \"price\" DESC"))
  (check-true (string-contains? out "LIMIT 10")))

(test-case "select with offset"
  (define out (se "(define-target sql) " "(select [name] (from products) (limit 10) (offset 20))"))
  (check-true (string-contains? out "LIMIT 10"))
  (check-true (string-contains? out "OFFSET 20")))

;; =====================================================================
;; INSERT
;; =====================================================================

(test-case "insert with values"
  (define out (se "(define-target sql) " "(deftable products [(name : String) (price : Float) (stock : Int)]) " "(insert products [name price stock] (values [\"Widget\" 9.99 100] [\"Gadget\" 19.99 50]))"))
  (check-true (string-contains? out "INSERT INTO \"products\" (\"name\", \"price\", \"stock\")"))
  (check-true (string-contains? out "VALUES ('Widget', 9.99, 100), ('Gadget', 19.99, 50)")))

;; =====================================================================
;; UPDATE
;; =====================================================================

(test-case "update with set and where"
  (define out (se "(define-target sql) " "(deftable products [(price : Float) (stock : Int) (category : String)]) " "(update products (set [price (* price 0.9)] [stock (+ stock 10)]) (where (= category \"clearance\")))"))
  (check-true (string-contains? out "UPDATE \"products\" SET"))
  (check-true (string-contains? out "\"price\" = \"price\" * 0.9"))
  (check-true (string-contains? out "\"stock\" = \"stock\" + 10"))
  (check-true (string-contains? out "WHERE \"category\" = 'clearance'")))

;; =====================================================================
;; DELETE
;; =====================================================================

(test-case "delete with where"
  (define out (se "(define-target sql) " "(deftable products [(total : Float)]) " "(delete products (where (< total 0)))"))
  (check-true (string-contains? out "DELETE FROM \"products\""))
  (check-true (string-contains? out "WHERE \"total\" < 0")))

;; =====================================================================
;; Expressions — IS NULL, CASE, CAST, boolean, string ops
;; =====================================================================

(test-case "is-null and is-not-null"
  (define out (se "(define-target sql) " "(select [name] (from users) (where (is-null email)))"))
  (check-true (string-contains? out "WHERE \"email\" IS NULL")))

(test-case "CASE expression"
  (define out (se "(define-target sql) " "(select [(case (when (> price 100) \"expensive\") (when (> price 50) \"medium\") :else \"cheap\") :as tier] (from products))"))
  (check-true (string-contains? out "CASE"))
  (check-true (string-contains? out "WHEN \"price\" > 100 THEN 'expensive'"))
  (check-true (string-contains? out "WHEN \"price\" > 50 THEN 'medium'"))
  (check-true (string-contains? out "ELSE 'cheap'"))
  (check-true (string-contains? out "END")))

(test-case "CAST expression"
  (define out (se "(define-target sql) " "(select [(cast price integer)] (from products))"))
  (check-true (string-contains? out "CAST(\"price\" AS INTEGER)")))

(test-case "where with and/or"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (and (> price 5) (< stock 100))))"))
  (check-true (string-contains? out "WHERE (\"price\" > 5 AND \"stock\" < 100)")))

(test-case "string concatenation with ||"
  (define out (se "(define-target sql) " "(select [(|| first_name \" \" last_name) :as full_name] (from users))"))
  (check-true (string-contains? out "\"first_name\" || ' ' || \"last_name\"")))

(test-case "BETWEEN expression"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (between price 10 50)))"))
  (check-true (string-contains? out "WHERE \"price\" BETWEEN 10 AND 50")))

(test-case "IN expression with values"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (in category \"electronics\" \"books\" \"toys\")))"))
  (check-true (string-contains? out "WHERE \"category\" IN ('electronics', 'books', 'toys')")))

(test-case "LIKE expression"
  (define out (se "(define-target sql) " "(select [name] (from users) (where (like name \"%smith%\")))"))
  (check-true (string-contains? out "WHERE \"name\" LIKE '%smith%'")))

(test-case "NOT expression"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (not (= active #f))))"))
  (check-true (string-contains? out "NOT \"active\" = FALSE")))

;; =====================================================================
;; Aggregates
;; =====================================================================

(test-case "select with multiple aggregates"
  (define out (se "(define-target sql) " "(select [(count id) (avg price :as avg_price)] (from products))"))
  (check-true (string-contains? out "COUNT(\"id\")"))
  (check-true (string-contains? out "AVG(\"price\") AS \"avg_price\"")))

(test-case "count distinct"
  (define out (se "(define-target sql) " "(select [(count-distinct category)] (from products))"))
  (check-true (string-contains? out "COUNT(DISTINCT \"category\")")))

(test-case "count star"
  (define out (se "(define-target sql) " "(select [(count *)] (from products))"))
  (check-true (string-contains? out "COUNT(*)")))

(test-case "sum and min/max"
  (define out (se "(define-target sql) " "(select [(sum price :as total) (min price :as cheapest) (max price :as priciest)] (from products))"))
  (check-true (string-contains? out "SUM(\"price\") AS \"total\""))
  (check-true (string-contains? out "MIN(\"price\") AS \"cheapest\""))
  (check-true (string-contains? out "MAX(\"price\") AS \"priciest\"")))

;; =====================================================================
;; Window functions
;; =====================================================================

(test-case "row_number window function"
  (define out (se "(define-target sql) " "(select [name (row_number :as rn :over (order-by price :asc))] (from products))"))
  (check-true (string-contains? out "ROW_NUMBER() OVER (ORDER BY \"price\" ASC) AS \"rn\"")))

(test-case "sum window function with partition"
  (define out (se "(define-target sql) " "(select [category (sum price :as running :over (partition-by category) (order-by name :asc))] (from products))"))
  (check-true (string-contains? out "SUM(\"price\") OVER (PARTITION BY \"category\" ORDER BY \"name\" ASC) AS \"running\"")))

(test-case "rank window function"
  (define out (se "(define-target sql) " "(select [name (rank :as rnk :over (order-by score :desc))] (from players))"))
  (check-true (string-contains? out "RANK() OVER (ORDER BY \"score\" DESC) AS \"rnk\"")))

;; =====================================================================
;; Subqueries
;; =====================================================================

(test-case "EXISTS subquery"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (exists (select [1] (from orders) (where (= orders.product_id products.id))))))"))
  (check-true (string-contains? out "WHERE EXISTS"))
  (check-true (string-contains? out "SELECT 1"))
  (check-true (string-contains? out "FROM \"orders\"")))

(test-case "IN subquery"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (in id (select [product_id] (from orders)))))"))
  (check-true (string-contains? out "WHERE \"id\" IN"))
  (check-true (string-contains? out "SELECT \"product_id\""))
  (check-true (string-contains? out "FROM \"orders\"")))

;; =====================================================================
;; CTEs — WITH
;; =====================================================================

(test-case "single CTE"
  (define out (se "(define-target sql) " "(with (recent_orders (select [*] (from orders) (where (> created_at \"2024-01-01\")))) (select [*] (from recent_orders)))"))
  (check-true (string-contains? out "WITH \"recent_orders\" AS"))
  (check-true (string-contains? out "FROM \"recent_orders\"")))

(test-case "multiple CTEs"
  (define out (se "(define-target sql) " "(with (big (select [id] (from products) (where (> price 100)))) (cheap (select [id] (from products) (where (< price 10)))) (select [*] (from big)))"))
  (check-true (string-contains? out "WITH \"big\" AS"))
  (check-true (string-contains? out "\"cheap\" AS"))
  (check-true (string-contains? out "FROM \"big\"")))

;; =====================================================================
;; Set operations
;; =====================================================================

(test-case "UNION"
  (define out (se "(define-target sql) " "(union (select [name] (from products)) (select [name] (from archived_products)))"))
  (check-true (string-contains? out "UNION"))
  (check-true (string-contains? out "FROM \"products\""))
  (check-true (string-contains? out "FROM \"archived_products\"")))

(test-case "UNION ALL"
  (define out (se "(define-target sql) " "(union-all (select [name] (from products)) (select [name] (from archived_products)))"))
  (check-true (string-contains? out "UNION ALL")))

(test-case "INTERSECT"
  (define out (se "(define-target sql) " "(intersect (select [name] (from products)) (select [name] (from featured_products)))"))
  (check-true (string-contains? out "INTERSECT")))

(test-case "EXCEPT"
  (define out (se "(define-target sql) " "(except (select [id] (from all_users)) (select [id] (from banned_users)))"))
  (check-true (string-contains? out "EXCEPT")))

;; =====================================================================
;; DML extensions
;; =====================================================================

(test-case "INSERT...SELECT"
  (define out (se "(define-target sql) " "(insert-select archive [name price] (select [name price] (from products) (where (= discontinued #t))))"))
  (check-true (string-contains? out "INSERT INTO \"archive\" (\"name\", \"price\")"))
  (check-true (string-contains? out "SELECT \"name\", \"price\""))
  (check-true (string-contains? out "FROM \"products\"")))

(test-case "RETURNING clause"
  (define out (se "(define-target sql) " "(deftable users [(id : Int) (name : String)]) " "(returning (insert users [name] (values [\"Alice\"])) [id name])"))
  (check-true (string-contains? out "INSERT INTO \"users\" (\"name\")"))
  (check-true (string-contains? out "RETURNING \"id\", \"name\"")))

(test-case "CREATE INDEX"
  (define out (sql-emit "(define-target sql) (create-index idx_products_name products [name])"))
  (check-true (string-contains? out "CREATE INDEX \"idx_products_name\" ON \"products\" (\"name\")")))

(test-case "CREATE UNIQUE INDEX"
  (define out (sql-emit "(define-target sql) (create-unique-index idx_users_email users [email])"))
  (check-true (string-contains? out "CREATE UNIQUE INDEX \"idx_users_email\" ON \"users\" (\"email\")")))

(test-case "DROP TABLE"
  (define out (sql-emit "(define-target sql) (drop-table old_data)"))
  (check-equal? out "DROP TABLE \"old_data\""))

(test-case "DROP TABLE IF EXISTS"
  (define out (sql-emit "(define-target sql) (drop-table-if-exists temp_staging)"))
  (check-equal? out "DROP TABLE IF EXISTS \"temp_staging\""))

(test-case "ALTER TABLE add column"
  (define out (sql-emit "(define-target sql) (alter-table users (add-column age : Int))"))
  (check-true (string-contains? out "ALTER TABLE \"users\" ADD COLUMN \"age\" INTEGER")))

(test-case "ALTER TABLE rename column"
  (define out (sql-emit "(define-target sql) (alter-table users (rename-column name full_name))"))
  (check-true (string-contains? out "ALTER TABLE \"users\" RENAME COLUMN \"name\" TO \"full_name\"")))

(test-case "ALTER TABLE drop column"
  (define out (sql-emit "(define-target sql) (alter-table users (drop-column temp_flag))"))
  (check-true (string-contains? out "ALTER TABLE \"users\" DROP COLUMN \"temp_flag\"")))

(test-case "TRUNCATE"
  (define out (sql-emit "(define-target sql) (truncate staging)"))
  (check-equal? out "TRUNCATE TABLE \"staging\""))

;; =====================================================================
;; Type checking errors — table/column validation
;; =====================================================================

(test-case "insert to unknown table raises error"
  (define err (sce "(define-target sql) " "(deftable users [(id : Int) (name : String)]) " "(insert products [name] (values [\"x\"]))"))
  (check-true (and (string? err) (string-contains? err "unknown table products"))))

(test-case "insert with unknown column raises error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (name : String)]) " "(insert products [id name bogus] (values [1 \"x\" 42]))"))
  (check-true (and (string? err) (string-contains? err "unknown column bogus"))))

(test-case "update to unknown table raises error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (price : Float)]) " "(update orders (set [price 10]) (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown table orders"))))

(test-case "update with unknown column raises error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (price : Float)]) " "(update products (set [bogus 10]) (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown column bogus"))))

(test-case "delete from unknown table raises error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int)]) " "(delete orders (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown table orders"))))

(test-case "select with validated column refs passes"
  (define out (se "(define-target sql) " "(deftable products [(id : Int) (name : String) (price : Float)]) " "(select [p.id p.name] (from products :as p))"))
  (check-true (string-contains? out "SELECT \"p\".\"id\", \"p\".\"name\"")))

(test-case "select with invalid column ref raises error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (name : String)]) " "(select [p.id p.bogus] (from products :as p))"))
  (check-true (and (string? err) (string-contains? err "no column bogus"))))

;; =====================================================================
;; INSERT type checking — value type vs column type
;; =====================================================================

(test-case "insert string into Int column raises type error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (name : String)]) " "(insert products [id name] (values [\"not-a-number\" \"Widget\"]))"))
  (check-true (and (string? err) (string-contains? err "expected Int"))))

(test-case "insert int into String column raises type error"
  (define err (sce "(define-target sql) " "(deftable products [(id : Int) (name : String)]) " "(insert products [id name] (values [1 42]))"))
  (check-true (and (string? err) (string-contains? err "expected String"))))

(test-case "insert correct types passes"
  (define out (se "(define-target sql) " "(deftable products [(id : Int) (name : String) (price : Float)]) " "(insert products [id name price] (values [1 \"Widget\" 9.99]))"))
  (check-true (string? out)))

;; =====================================================================
;; Target gating — SQL forms rejected in other targets
;; =====================================================================

(test-case "select in clj target raises error"
  (define err (sql-check-error "(define-target clj) (select [name] (from products))"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

(test-case "deftable in js target raises error"
  (define err (sql-check-error "(define-target js) (deftable users [(id : Int)])"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

(test-case "insert in nix target raises error"
  (define err (sql-check-error "(define-target nix) (insert products [name] (values [\"x\"]))"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

;; =====================================================================
;; HAVING clause
;; =====================================================================

(test-case "select with having"
  (define out (se "(define-target sql) " "(select [category (count id :as cnt)] (from products) (group-by category) (having (> (count id) 5)))"))
  (check-true (string-contains? out "GROUP BY \"category\""))
  (check-true (string-contains? out "HAVING COUNT(\"id\") > 5")))

;; =====================================================================
;; SQL stdlib functions
;; =====================================================================

(test-case "upper/lower string functions"
  (define out (se "(define-target sql) " "(select [(upper name) (lower email)] (from users))"))
  (check-true (string-contains? out "UPPER(\"name\")"))
  (check-true (string-contains? out "LOWER(\"email\")")))

(test-case "coalesce function"
  (define out (se "(define-target sql) " "(select [(coalesce nickname name)] (from users))"))
  (check-true (string-contains? out "COALESCE(\"nickname\", \"name\")")))

(test-case "substring function"
  (define out (se "(define-target sql) " "(select [(substring name 1 3)] (from users))"))
  (check-true (string-contains? out "SUBSTRING(\"name\", 1, 3)")))

;; =====================================================================
;; Complex e-commerce schema — multi-table integration tests
;; =====================================================================

(define ecommerce-schema
  (string-append
    "(define-target sql) "
    "(deftable customers [(id : Int :primary-key) (name : String :not-null) (email : String :unique)]) "
    "(deftable products [(id : Int :primary-key) (name : String :not-null) (price : Float :not-null) (category : String)]) "
    "(deftable orders [(id : Int :primary-key) (customer_id : Int) (order_date : String) (status : String)]) "
    "(deftable order_items [(id : Int :primary-key) (order_id : Int) (product_id : Int) (quantity : Int) (unit_price : Float)]) "
    "(deftable reviews [(id : Int :primary-key) (product_id : Int) (customer_id : Int) (rating : Int) (body : String)]) "))

(test-case "e-commerce: multi-table DDL emission"
  (define out (sql-emit ecommerce-schema))
  (check-true (string-contains? out "CREATE TABLE \"customers\""))
  (check-true (string-contains? out "CREATE TABLE \"products\""))
  (check-true (string-contains? out "CREATE TABLE \"orders\""))
  (check-true (string-contains? out "CREATE TABLE \"order_items\""))
  (check-true (string-contains? out "CREATE TABLE \"reviews\"")))

(test-case "e-commerce: revenue by category with window ranking"
  (define out (se ecommerce-schema "(select [p.category (sum oi.unit_price :as revenue) " "(rank :as rev_rank :over (order-by (sum oi.unit_price) :desc))] " "(from order_items :as oi) " "(left-join products :as p (= oi.product_id p.id)) " "(group-by p.category))"))
  (check-true (string-contains? out "SUM(\"oi\".\"unit_price\") AS \"revenue\""))
  (check-true (string-contains? out "RANK() OVER"))
  (check-true (string-contains? out "LEFT JOIN \"products\" AS \"p\" ON \"oi\".\"product_id\" = \"p\".\"id\""))
  (check-true (string-contains? out "GROUP BY \"p\".\"category\"")))

(test-case "e-commerce: CTE with aggregation"
  (define out (se ecommerce-schema "(with " "(top_products (select [p.id p.name (avg r.rating :as avg_rating)] " "(from products :as p) " "(left-join reviews :as r (= r.product_id p.id)) " "(group-by p.id p.name) " "(having (> (avg r.rating) 4)))) " "(select [*] (from top_products) (order-by avg_rating :desc)))"))
  (check-true (string-contains? out "WITH \"top_products\" AS"))
  (check-true (string-contains? out "AVG(\"r\".\"rating\") AS \"avg_rating\""))
  (check-true (string-contains? out "HAVING AVG(\"r\".\"rating\") > 4"))
  (check-true (string-contains? out "FROM \"top_products\""))
  (check-true (string-contains? out "ORDER BY \"avg_rating\" DESC")))

(test-case "e-commerce: CASE with status classification"
  (define out (se ecommerce-schema "(select [o.id (case (when (= o.status \"shipped\") \"in transit\") " "(when (= o.status \"delivered\") \"complete\") " ":else \"pending\") :as display_status] " "(from orders :as o))"))
  (check-true (string-contains? out "CASE"))
  (check-true (string-contains? out "WHEN \"o\".\"status\" = 'shipped' THEN 'in transit'"))
  (check-true (string-contains? out "WHEN \"o\".\"status\" = 'delivered' THEN 'complete'"))
  (check-true (string-contains? out "ELSE 'pending'"))
  (check-true (string-contains? out "END")))

(test-case "e-commerce: NOT EXISTS anti-join"
  (define out (se ecommerce-schema "(select [c.name c.email] (from customers :as c) " "(where (not (exists (select [1] (from orders :as o) (where (= o.customer_id c.id)))))))"))
  (check-true (string-contains? out "NOT EXISTS"))
  (check-true (string-contains? out "SELECT 1"))
  (check-true (string-contains? out "FROM \"orders\" AS \"o\"")))

(test-case "e-commerce: union queries"
  (define out (se ecommerce-schema "(union " "(select [name price] (from products) (where (= category \"electronics\"))) " "(select [name price] (from products) (where (= category \"books\"))))"))
  (check-true (string-contains? out "UNION"))
  (check-true (string-contains? out "WHERE \"category\" = 'electronics'"))
  (check-true (string-contains? out "WHERE \"category\" = 'books'")))

;; =====================================================================
;; Multi-statement programs
;; =====================================================================

(test-case "multiple statements separated by semicolons"
  (define out (se "(define-target sql) " "(deftable users [(id : Int :primary-key) (name : String)]) " "(insert users [name] (values [\"Alice\"])) " "(select [*] (from users))"))
  (check-true (string-contains? out "CREATE TABLE \"users\""))
  (check-true (string-contains? out "INSERT INTO \"users\""))
  (check-true (string-contains? out "SELECT *")))

;; =====================================================================
;; Edge cases
;; =====================================================================

(test-case "delete without where"
  (define out (se "(define-target sql) " "(deftable temp [(id : Int)]) " "(delete temp)"))
  (check-true (string-contains? out "DELETE FROM \"temp\""))
  (check-false (string-contains? out "WHERE")))

(test-case "select with multiple order-by columns"
  (define out (se "(define-target sql) " "(select [name price] (from products) (order-by category :asc price :desc))"))
  (check-true (string-contains? out "ORDER BY \"category\" ASC, \"price\" DESC")))

(test-case "nested arithmetic in where"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (> (* price quantity) 1000)))"))
  (check-true (string-contains? out "WHERE \"price\" * \"quantity\" > 1000")))

(test-case "boolean literal values"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (= active #t)))"))
  (check-true (string-contains? out "WHERE \"active\" = TRUE")))

(test-case "insert-select to unknown table is permissive"
  (define out (se "(define-target sql) " "(insert-select archive [name price] (select [name price] (from products)))"))
  (check-true (string-contains? out "INSERT INTO \"archive\" (\"name\", \"price\")")))

(test-case "multi-column create index"
  (define out (se "(define-target sql) " "(create-index idx_orders_cust_date orders [customer_id order_date])"))
  (check-true (string-contains? out "CREATE INDEX \"idx_orders_cust_date\" ON \"orders\" (\"customer_id\", \"order_date\")")))

;; --- GROUP BY semantic validation ------------------------------------------

(test-case "group-by: bare column not in group-by raises error"
  (define err (sce "(define-target sql) " "(select [name (count id)] (from products) (group-by category))"))
  (check-true (and (string? err) (string-contains? err "must appear in GROUP BY or be an aggregate"))))

(test-case "group-by: qualified column not in group-by raises error"
  (define err (sce "(define-target sql) " "(select [p.name (count p.id)] (from products :as p) (group-by p.category))"))
  (check-true (and (string? err) (string-contains? err "must appear in GROUP BY or be an aggregate"))))

(test-case "group-by: all columns in group-by passes"
  (define out (se "(define-target sql) " "(select [category (count id)] (from products) (group-by category))"))
  (check-true (string-contains? out "GROUP BY \"category\"")))

(test-case "group-by: qualified columns in group-by passes"
  (define out (se "(define-target sql) " "(select [p.category (count p.id)] (from products :as p) (group-by p.category))"))
  (check-true (string-contains? out "GROUP BY \"p\".\"category\"")))

(test-case "group-by: aggregate alias passes"
  (define out (se "(define-target sql) " "(select [category (count id :as total)] (from products) (group-by category))"))
  (check-true (string-contains? out "COUNT(\"id\") AS \"total\"")))

(test-case "group-by: select without group-by still works"
  (define out (se "(define-target sql) " "(select [name price] (from products))"))
  (check-true (string-contains? out "SELECT \"name\", \"price\"")))

(test-case "group-by: all aggregates with group-by passes"
  (define out (se "(define-target sql) " "(select [(count id) (avg price)] (from products) (group-by category))"))
  (check-true (string-contains? out "COUNT(\"id\")"))
  (check-true (string-contains? out "AVG(\"price\")")))

;; =====================================================================
;; Security — injection prevention
;; =====================================================================

(test-case "string literal with single quote is properly escaped"
  (define out (se "(define-target sql) " "(select [name] (from users) (where (= name \"O'Brien\")))"))
  (check-true (string-contains? out "'O''Brien'")))

(test-case "identifier quoting prevents injection in table names"
  (define out (sql-emit "(define-target sql) (drop-table my_table)"))
  (check-true (string-contains? out "\"my_table\"")))

(test-case "+inf.0 rejected as numeric literal"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (> price +inf.0)))"))
  (check-true (and (string? out) (string-contains? out "cannot emit +inf.0"))))

(test-case "-inf.0 rejected as numeric literal"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (> price -inf.0)))"))
  (check-true (and (string? out) (string-contains? out "cannot emit -inf.0"))))

(test-case "+nan.0 rejected as numeric literal"
  (define out (se "(define-target sql) " "(select [name] (from products) (where (> price +nan.0)))"))
  (check-true (and (string? out) (string-contains? out "cannot emit +nan.0"))))
