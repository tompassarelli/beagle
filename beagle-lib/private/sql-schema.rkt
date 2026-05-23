#lang racket/base

;; SQL schema loader: reads .beagle-cache/sql-schema.json (project-rooted,
;; walks up from the source file). The JSON describes tables and columns;
;; check.rkt merges this into SQL-TABLES so queries in any .bsql file can
;; reference tables defined anywhere in the project.
;;
;; Cache file format:
;;   { "tables": {
;;       "users":  { "columns": { "id":      { "type": "Int", "primary_key": true },
;;                                "name":    { "type": "String" },
;;                                "email":   { "type": "String", "nullable": false } } },
;;       "posts":  { "columns": { "id":      { "type": "Int", "primary_key": true },
;;                                "user_id": { "type": "Int",
;;                                             "fk_table": "users",
;;                                             "fk_column": "id" },
;;                                "title":   { "type": "String" } } } } }

(require json
         racket/file
         racket/path
         "types.rkt")

(provide
 load-sql-schema-cached
 find-sql-schema-json
 sql-schema-tables           ; hash : table-symbol → col-map (col-symbol → type)
 sql-schema-fks)             ; hash : (table-sym . col-sym) → (target-table-sym . target-col-sym)

(struct sql-schema (tables fks) #:transparent)

(define (find-sql-schema-json source-path)
  (define dir
    (cond
      [(path? source-path)
       (let-values ([(base name dir?) (split-path source-path)])
         (if (path? base) base (current-directory)))]
      [(string? source-path)
       (let-values ([(base name dir?) (split-path (string->path source-path))])
         (if (path? base) base (current-directory)))]
      [else #f]))
  (and dir
       (let loop ([d (simplify-path (path->complete-path dir))])
         (define candidate (build-path d ".beagle-cache" "sql-schema.json"))
         (cond
           [(file-exists? candidate) candidate]
           [else
            (define-values (parent name dir?) (split-path d))
            (and (path? parent)
                 (not (equal? parent d))
                 (loop parent))]))))

(define schema-cache (make-hash))

(define (load-sql-schema-cached source-path)
  (define schema-path (find-sql-schema-json source-path))
  (and schema-path
       (let ([mtime (file-or-directory-modify-seconds schema-path)])
         (define cached (hash-ref schema-cache schema-path #f))
         (if (and cached (= (car cached) mtime))
             (cdr cached)
             (let ([schema (load-sql-schema schema-path)])
               (hash-set! schema-cache schema-path (cons mtime schema))
               schema)))))

(define (load-sql-schema path)
  (define raw (with-input-from-file path read-json))
  (define tables (make-hash))
  (define fks (make-hash))
  (define raw-tables (hash-ref raw 'tables (hasheq)))
  (for ([(tbl-key tbl-val) (in-hash raw-tables)])
    (define tbl-sym (if (symbol? tbl-key) tbl-key (string->symbol (symbol->string tbl-key))))
    (define col-map (make-hash))
    (define raw-cols (hash-ref tbl-val 'columns (hasheq)))
    (for ([(col-key col-val) (in-hash raw-cols)])
      (define col-sym (if (symbol? col-key) col-key (string->symbol (symbol->string col-key))))
      (define type-name (hash-ref col-val 'type "Any"))
      (define type-val (type-prim (string->symbol type-name)))
      (hash-set! col-map col-sym type-val)
      (define fk-table (hash-ref col-val 'fk_table #f))
      (define fk-column (hash-ref col-val 'fk_column #f))
      (when (and fk-table fk-column)
        (hash-set! fks (cons tbl-sym col-sym)
                       (cons (string->symbol fk-table) (string->symbol fk-column)))))
    (hash-set! tables tbl-sym col-map))
  (sql-schema tables fks))
