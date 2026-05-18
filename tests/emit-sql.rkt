#lang racket/base

(require rackunit
         racket/string
         racket/port
         "../private/parse.rkt"
         "../private/emit.rkt"
         "../private/check.rkt"
         "../private/types.rkt")

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
  ;; Returns the error message if type-check fails, #f otherwise
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
    [(string? prog) prog]  ; parse error
    [else
     (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
       (type-check! prog)
       #f)]))

;; --- deftable produces no output -------------------------------------------

(test-case "deftable produces no output"
  (define out (sql-emit "(define-target sql) (deftable products [(id : Int :primary-key) (name : String :not-null)])"))
  (check-equal? out ""))

;; --- simple SELECT ---------------------------------------------------------

(test-case "simple select"
  (define out (sql-emit "(define-target sql) (select [name price] (from products) (where (= category \"electronics\")))"))
  (check-true (string-contains? out "SELECT name, price"))
  (check-true (string-contains? out "FROM products"))
  (check-true (string-contains? out "WHERE category = 'electronics'")))

(test-case "select with column refs"
  (define out (sql-emit "(define-target sql) (select [p.id p.name] (from products :as p))"))
  (check-true (string-contains? out "SELECT p.id, p.name"))
  (check-true (string-contains? out "FROM products AS p")))

;; --- SELECT with WHERE -----------------------------------------------------

(test-case "select with numeric where"
  (define out (sql-emit "(define-target sql) (select [name] (from products) (where (> price 10)))"))
  (check-true (string-contains? out "SELECT name"))
  (check-true (string-contains? out "WHERE price > 10")))

;; --- SELECT with JOIN ------------------------------------------------------

(test-case "select with left join"
  (define out (sql-emit
    "(define-target sql) (select [p.id p.name (count o.id :as order_count)] (from products :as p) (left-join orders :as o (= o.product_id p.id)) (where (> p.stock 0)) (group-by p.id p.name))"))
  (check-true (string-contains? out "SELECT p.id, p.name, COUNT(o.id) AS order_count"))
  (check-true (string-contains? out "FROM products AS p"))
  (check-true (string-contains? out "LEFT JOIN orders AS o ON o.product_id = p.id"))
  (check-true (string-contains? out "WHERE p.stock > 0"))
  (check-true (string-contains? out "GROUP BY p.id, p.name")))

;; --- SELECT with ORDER BY and LIMIT ----------------------------------------

(test-case "select with order-by and limit"
  (define out (sql-emit
    "(define-target sql) (select [name price] (from products) (order-by price :desc) (limit 10))"))
  (check-true (string-contains? out "SELECT name, price"))
  (check-true (string-contains? out "ORDER BY price DESC"))
  (check-true (string-contains? out "LIMIT 10")))

(test-case "select with offset"
  (define out (sql-emit
    "(define-target sql) (select [name] (from products) (limit 10) (offset 20))"))
  (check-true (string-contains? out "LIMIT 10"))
  (check-true (string-contains? out "OFFSET 20")))

;; --- INSERT ----------------------------------------------------------------

(test-case "insert with values"
  (define out (sql-emit
    "(define-target sql) (deftable products [(name : String) (price : Float) (stock : Int)]) (insert products [name price stock] (values [\"Widget\" 9.99 100] [\"Gadget\" 19.99 50]))"))
  (check-true (string-contains? out "INSERT INTO products (name, price, stock)"))
  (check-true (string-contains? out "VALUES ('Widget', 9.99, 100), ('Gadget', 19.99, 50)")))

;; --- UPDATE ----------------------------------------------------------------

(test-case "update with set and where"
  (define out (sql-emit
    "(define-target sql) (deftable products [(price : Float) (stock : Int) (category : String)]) (update products (set [price (* price 0.9)] [stock (+ stock 10)]) (where (= category \"clearance\")))"))
  (check-true (string-contains? out "UPDATE products SET"))
  (check-true (string-contains? out "price = price * 0.9"))
  (check-true (string-contains? out "stock = stock + 10"))
  (check-true (string-contains? out "WHERE category = 'clearance'")))

;; --- DELETE ----------------------------------------------------------------

(test-case "delete with where"
  (define out (sql-emit
    "(define-target sql) (deftable products [(total : Float)]) (delete products (where (< total 0)))"))
  (check-true (string-contains? out "DELETE FROM products"))
  (check-true (string-contains? out "WHERE total < 0")))

;; --- Column reference to nonexistent table -> check error -------------------

(test-case "insert to unknown table raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable users [(id : Int) (name : String)]) (insert products [name] (values [\"x\"]))"))
  (check-true (and (string? err) (string-contains? err "unknown table products"))))

(test-case "insert with unknown column raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable products [(id : Int) (name : String)]) (insert products [id name bogus] (values [1 \"x\" 42]))"))
  (check-true (and (string? err) (string-contains? err "unknown column bogus"))))

(test-case "update to unknown table raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable products [(id : Int) (price : Float)]) (update orders (set [price 10]) (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown table orders"))))

(test-case "update with unknown column raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable products [(id : Int) (price : Float)]) (update products (set [bogus 10]) (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown column bogus"))))

(test-case "delete from unknown table raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable products [(id : Int)]) (delete orders (where (= id 1)))"))
  (check-true (and (string? err) (string-contains? err "unknown table orders"))))

;; --- Column ref to valid table passes checking -----------------------------

(test-case "select with validated column refs passes"
  (define out (sql-emit
    "(define-target sql) (deftable products [(id : Int) (name : String) (price : Float)]) (select [p.id p.name] (from products :as p))"))
  (check-true (string-contains? out "SELECT p.id, p.name")))

(test-case "select with invalid column ref raises error"
  (define err (sql-check-error
    "(define-target sql) (deftable products [(id : Int) (name : String)]) (select [p.id p.bogus] (from products :as p))"))
  (check-true (and (string? err) (string-contains? err "no column bogus"))))

;; --- Target gating: SQL forms rejected in non-SQL targets -------------------

(test-case "select in clj target raises error"
  (define err (sql-check-error
    "(define-target clj) (select [name] (from products))"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

(test-case "deftable in js target raises error"
  (define err (sql-check-error
    "(define-target js) (deftable users [(id : Int)])"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

(test-case "insert in nix target raises error"
  (define err (sql-check-error
    "(define-target nix) (insert products [name] (values [\"x\"]))"))
  (check-true (and (string? err) (string-contains? err "only supported in beagle/sql"))))

;; --- Aggregates in select --------------------------------------------------

(test-case "select with multiple aggregates"
  (define out (sql-emit
    "(define-target sql) (select [(count id) (avg price :as avg_price)] (from products))"))
  (check-true (string-contains? out "COUNT(id)"))
  (check-true (string-contains? out "AVG(price) AS avg_price")))

;; --- Boolean expressions ---------------------------------------------------

(test-case "where with and/or"
  (define out (sql-emit
    "(define-target sql) (select [name] (from products) (where (and (> price 5) (< stock 100))))"))
  (check-true (string-contains? out "WHERE (price > 5 AND stock < 100)")))
