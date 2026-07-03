#lang racket/base

;; Regression tests for ast-json.rkt binding->json with destructure targets.
;;
;; Before the fix: binding->json crashed (symbol->string on seq/map-destructure
;; struct) whenever a let/loop/binding/with-open/for:let position held a
;; destructure pattern.
;;
;; Load all beagle modules by FILE PATH (same pattern as bin/beagle-ast) so the
;; WORKTREE's edited ast-json.rkt is used, not the canonical collection's .zo.

(require rackunit
         rackunit/text-ui
         racket/string
         racket/file
         racket/path
         json)

;; Worktree root = current-directory when invoked via `raco test` from root.
;; Fallback: walk up from this source file's location.
(define root
  (path->string
   (simplify-path
    (if (file-exists? (build-path (current-directory) "beagle-lib/private/ast-json.rkt"))
        (current-directory)
        (build-path (path-only (build-path (syntax-source #'here))) ".." "..")))))

(define (root/ . parts) (apply string-append root "/" parts))

;; Load parse + check + ast-json from worktree source files.
(define-values (read-beagle-syntax parse-program)
  (values
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'read-beagle-syntax)
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'parse-program)))

(define type-check!
  (dynamic-require `(file ,(root/ "beagle-lib/private/check.rkt")) 'type-check!))

(define-values (program->json program->json-string)
  (values
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'program->json)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'program->json-string)))

;; Parse + check a beagle/clj source string; return program->json result.
(define (parse+check-json src-string)
  (define tmp (make-temporary-file "beagle-ast-json-test-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out)
          (display "#lang beagle/clj\n" out)
          (display src-string out)))
      (define forms (read-beagle-syntax tmp))
      (define prog (parse-program forms #:source-path (path->string tmp)))
      (type-check! prog)
      (program->json prog))
    (lambda () (delete-file tmp))))

(define (first-let-binding json)
  ;; First binding of the first let node in the first defn's body.
  (define defn (car (hash-ref json 'forms)))
  (define let-node (car (hash-ref defn 'body)))
  (car (hash-ref let-node 'bindings)))

(define tests
  (test-suite
   "ast-json binding->json destructure targets"

   (test-case "plain symbol binding still works"
     (define json
       (parse+check-json "(ns t)\n(defn f [] :- String (let [x \"hello\"] x))"))
     (check-equal? (hash-ref (first-let-binding json) 'name) "x"))

   (test-case "seq-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] :- String (let [[a b] [\"x\" \"y\"]] (str a b)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type)  "seq-destructure")
     (check-equal? (hash-ref name 'names) '("a" "b"))
     (check-false  (hash-ref name 'rest)))

   (test-case "map-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] :- String (let [{:keys [x y]} {:x \"a\" :y \"b\"}] (str x y)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'keys) '("x" "y"))
     (check-false  (hash-ref name 'as)))

   (test-case "map-destructure with :as"
     (define json
       (parse+check-json "(ns t)\n(defn f [] :- String (let [{:keys [x] :as m} {:x \"z\"}] x))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'as)   "m"))

   (test-case "nested seq-destructure"
     (define json
       (parse+check-json "(ns t)\n(defn f [] :- String (let [[[a b] c] [[\"p\" \"q\"] \"r\"]] (str a b c)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "seq-destructure")
     (define inner (car (hash-ref name 'names)))
     (check-equal? (hash-ref inner 'type)  "seq-destructure")
     (check-equal? (hash-ref inner 'names) '("a" "b")))

   (test-case "fixture file: all destructure forms round-trip without crash"
     (define fixture-path
       (root/ "beagle-test/tests/fixtures/let-destructure.bclj"))
     (define forms (read-beagle-syntax fixture-path))
     (define prog (parse-program forms #:source-path fixture-path))
     (type-check! prog)
     (define json-str (program->json-string prog))
     (check-true (string? json-str))
     (check-true (> (string-length json-str) 0)))))

(run-tests tests)
