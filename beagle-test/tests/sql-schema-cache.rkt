#lang racket/base

;; Tests for cross-file SQL schema loaded from .beagle-cache/sql-schema.json.
;; Validates that queries in any .bsql file can reference tables declared
;; in the project's shared schema, and that typos get "did you mean?" hints.
;;
;; We shell out to `bin/beagle-build` so the source-path / cache lookup
;; behaves exactly the same as in user invocations.

(require rackunit
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/file)

(define-runtime-path schema-demo-dir "fixtures/sql-schema-demo")
(define-runtime-path beagle-build "../../bin/beagle-build")

(define (build-fixture name)
  (define src (build-path schema-demo-dir name))
  (define out (make-temporary-file "beagle-sql-out-~a.sql"))
  (define stderr (open-output-string))
  (define stdout (open-output-string))
  (define ok?
    (parameterize ([current-output-port stdout]
                   [current-error-port stderr])
      (system* (path->string beagle-build) (path->string src) (path->string out))))
  (define out-str (if (file-exists? out) (file->string out) ""))
  (delete-file out)
  (values ok? out-str (get-output-string stderr)))

;; --- cross-file schema: queries compile against cached schema --------------

(test-case "list-posts.bsql — query against cached schema compiles"
  (define-values (ok? out err) (build-fixture "list-posts.bsql"))
  (check-true ok? err)
  (check-true (string-contains? out "FROM \"posts\""))
  (check-true (string-contains? out "JOIN \"users\""))
  (check-true (string-contains? out "WHERE \"posts\".\"views\" > 100")))

(test-case "update-post.bsql — insert + update against cached schema"
  (define-values (ok? out err) (build-fixture "update-post.bsql"))
  (check-true ok? err)
  (check-true (string-contains? out "INSERT INTO \"posts\""))
  (check-true (string-contains? out "UPDATE \"posts\"")))

;; --- did-you-mean: column typo gets suggestion -----------------------------

(test-case "typo-column.bsql — unknown column reports `did you mean?`"
  (define-values (ok? out err) (build-fixture "typo-column.bsql"))
  (check-false ok?)
  (check-true (string-contains? err "unknown column viewz") err)
  (check-true (string-contains? err "did you mean: views?") err))
