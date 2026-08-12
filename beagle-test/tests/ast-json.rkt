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
         openssl/sha1
         racket/port
         racket/system
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
        (build-path (path-only (build-path (syntax-source #'here))) ".." ".."))
    #t)))

(define (root/ . parts) (apply string-append root "/" parts))

(define (sha256-prefixed bytes)
  (string-append "sha256:"
                 (bytes->hex-string (sha256-bytes bytes))))

(define write-canonical-json
  (dynamic-require
   `(file ,(root/ "beagle-lib/private/semantic-index.rkt"))
   'write-canonical-json))

(define (projection-sha256 json)
  (define out (open-output-bytes))
  (write-canonical-json (hash-remove json 'projectionSha256) out)
  (sha256-prefixed (get-output-bytes out)))

;; Load parse + check + ast-json from worktree source files.
(define-values (read-beagle-syntax parse-program
                                   parse-program/bytes parse-program/file)
  (values
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'read-beagle-syntax)
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'parse-program)
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'parse-program/bytes)
   (dynamic-require `(file ,(root/ "beagle-lib/private/parse.rkt")) 'parse-program/file)))

(define-values (type-check! type-check-with-locs!)
  (values
   (dynamic-require `(file ,(root/ "beagle-lib/private/check.rkt")) 'type-check!)
   (dynamic-require `(file ,(root/ "beagle-lib/private/check.rkt"))
                    'type-check-with-locs!)))

(define-values (program->json program->json-string
                             checked-program->json write-checked-program-json
                             expr->json type->json)
  (values
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'program->json)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'program->json-string)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'checked-program->json)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'write-checked-program-json)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'expr->json)
   (dynamic-require `(file ,(root/ "beagle-lib/private/ast-json.rkt")) 'type->json)))

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
      (define prog (parse-program/file tmp))
      (type-check! prog)
      (program->json prog))
    (lambda () (delete-file tmp))))

(define (parse+check-json/js src-string)
  (define tmp (make-temporary-file "beagle-ast-json-js-test-~a.bjs"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out)
          (display "#lang beagle/js\n" out)
          (display src-string out)))
      (define prog (parse-program/file tmp))
      (type-check! prog)
      (program->json prog))
    (lambda () (delete-file tmp))))

(define (parse+checked-json src-string extension source-id)
  (define tmp (make-temporary-file
               (string-append "beagle-checked-program-test-~a" extension)))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out)
          (display (if (string=? extension ".bjs")
                       "#lang beagle/js\n"
                       "#lang beagle/clj\n")
                   out)
          (display src-string out)))
      (define prog (parse-program/file tmp))
      (type-check-with-locs!
       prog
       (lambda (e _loc-stx) (raise e))
       #:capture-types? #t)
      (checked-program->json
       prog
       #:source-id source-id))
    (lambda () (delete-file tmp))))

(define (parse+checked-json/path path source-id)
  (define prog (parse-program/file path))
  (type-check-with-locs!
   prog
   (lambda (e _loc-stx) (raise e))
   #:capture-types? #t)
  (values prog
          (checked-program->json
           prog
           #:source-id source-id)))

(define (find-form-node json node-name)
  (for/first ([form (in-list (hash-ref json 'forms))]
              #:when (equal? (hash-ref form 'node #f) node-name))
    form))

(define (run-ast-cli source)
  (parameterize ([current-directory root])
    (define-values (process stdout stdin stderr)
      (subprocess #f #f #f (root/ "bin/beagle") "ast" source))
    (close-output-port stdin)
    (define output (port->string stdout))
    (define errors (port->string stderr))
    (subprocess-wait process)
    (values (subprocess-status process) output errors)))

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
       (parse+check-json "(ns t)\n(defn f [] -> String (let [x \"hello\"] x))"))
     (check-equal? (hash-ref (first-let-binding json) 'name) "x"))

   (test-case "seq-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] -> String (let [[a b] [\"x\" \"y\"]] (str a b)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type)  "seq-destructure")
     (check-equal? (hash-ref name 'names) '("a" "b"))
     (check-false  (hash-ref name 'rest)))

   (test-case "map-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] -> String (let [{:keys [x y]} {:x \"a\" :y \"b\"}] (str x y)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'keys) '("x" "y"))
     (check-false  (hash-ref name 'as)))

   (test-case "map-destructure with :as"
     (define json
       (parse+check-json "(ns t)\n(defn f [] -> String (let [{:keys [x] :as m} {:x \"z\"}] x))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'as)   "m"))

   (test-case "nested seq-destructure"
     (define json
       (parse+check-json "(ns t)\n(defn f [] -> String (let [[[a b] c] [[\"p\" \"q\"] \"r\"]] (str a b c)))"))
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
     (check-true (> (string-length json-str) 0)))

   (test-case "js/quote serializes complete nested wire shape and source"
     (define json
       (parse+check-json/js
        (string-append
         "(ns t)\n"
         "(js/quote (function render (input_value) "
         "(const payload (object total_str input_value delete 1 ready? true)) "
         "(return (.ready? payload))))")))
     (define quote-node (car (hash-ref json 'forms)))
     (define body (hash-ref quote-node 'body))
     (check-equal? (hash-ref quote-node 'node) "js-quote")
     (check-equal? (hash-ref body 'jsk) "function")
     (check-equal? (hash-ref body 'params) '("input_value"))
     (check-equal? (hash-ref (hash-ref body 'body) 'jsk) "block")
     (check-true (exact-positive-integer? (hash-ref (hash-ref quote-node 'source) 'line))))

   (test-case "malformed js/quote remains a pointed parse error"
     (check-exn #rx"js/quote"
                (lambda ()
                  (parse+check-json/js
                   "(ns t)\n(js/quote (const x (object dangling-key)))"))))

   (test-case "checked-program v1 expands an imported typed declaration macro"
     (define path
       (root/ "beagle-test/tests/fixtures/checked-projection/wiki.bjs"))
     (define-values (_prog json)
       (parse+checked-json/path path "checked-projection/wiki.bjs"))
     (check-equal? (hash-ref json 'kind) "beagle.checked-program")
     (check-equal? (hash-ref json 'schemaVersion) 1)
     (check-equal? (hash-ref json 'phase) "checked")
     (check-equal? (hash-ref json 'sourceId) "checked-projection/wiki.bjs")
     (check-equal? (hash-ref json 'sourceSha256)
                   (sha256-prefixed (file->bytes path)))
     (check-equal? (hash-ref json 'projectionSha256)
                   (projection-sha256 json))
     (define declaration (car (hash-ref json 'forms)))
     (check-equal? (hash-ref declaration 'node) "def")
     (check-equal? (hash-ref declaration 'name) "revision")
     (check-equal? (hash-ref (hash-ref declaration 'ann) 'name)
                   "wake/EntityDeclaration")
     (define provenance (hash-ref declaration 'provenance))
     (check-equal?
      (hash-ref
       (car (hash-ref (hash-ref provenance 'macroExpansion) 'chain))
       'name)
      "wake/entity")
     (define source (hash-ref provenance 'source))
     (check-equal? (hash-ref source 'origin) "synthetic")
     (check-true (hash-ref source 'canonical))
     (check-equal? (hash-ref source 'sourceId)
                   "checked-projection/wiki.bjs")
     (define constructor (hash-ref declaration 'value))
     (check-equal? (hash-ref (hash-ref constructor 'fn) 'name)
                   "wake/->EntityDeclaration")
     (check-equal? (hash-ref (hash-ref constructor 'inferredType) 'name)
                   "EntityDeclaration")
     (define field-constructor
       (car (hash-ref (cadr (hash-ref constructor 'args)) 'items)))
     (check-equal? (hash-ref (hash-ref field-constructor 'fn) 'name)
                   "wake/->FieldDeclaration")
     (define encoded (jsexpr->string json))
     (check-false (regexp-match? #rx"\\\"(?:node|kind|type)\\\":\\\"unknown\\\""
                                 encoded))
     (check-false (regexp-match? #rx"\\\"raw\\\":" encoded)))

   (test-case "checked-program output is canonical and externs are sorted"
     (define path
       (root/ "beagle-test/tests/fixtures/checked-projection/wiki.bjs"))
     (define-values (prog json)
       (parse+checked-json/path path "checked-projection/wiki.bjs"))
     (define names (map (lambda (entry) (hash-ref entry 'name))
                        (hash-ref json 'externs)))
     (check-equal? names (sort names string<?))
     (define first-out (open-output-string))
     (define second-out (open-output-string))
     (write-checked-program-json
      prog first-out
      #:source-id "checked-projection/wiki.bjs")
     (write-checked-program-json
      prog second-out
      #:source-id "checked-projection/wiki.bjs")
     (check-equal? (get-output-string first-out)
                   (get-output-string second-out)))

   (test-case "checked-program serializes destructured for bindings"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.for-destructure)\n"
         "(def result: (Vec Int) (for [[a b] [[1 2]]] a))\n")
        ".bclj"
        "checked-for-destructure.bclj"))
     (define clause
       (car (hash-ref (hash-ref (car (hash-ref json 'forms)) 'value)
                      'clauses)))
     (define name (hash-ref clause 'name))
     (check-equal? (hash-ref name 'type) "seq-destructure")
     (check-equal? (hash-ref name 'names) '("a" "b")))

   (test-case "ast CLI canonicalizes equivalent checkout paths"
     (define relative "beagle-test/tests/fixtures/checked-projection/wiki.bjs")
     (define dotted (string-append "./" relative))
     (define absolute (root/ relative))
     (define-values (relative-status relative-output relative-error)
       (run-ast-cli relative))
     (define-values (dotted-status dotted-output dotted-error)
       (run-ast-cli dotted))
     (define-values (absolute-status absolute-output absolute-error)
       (run-ast-cli absolute))
     (check-equal? (list relative-status dotted-status absolute-status)
                   '(0 0 0))
     (check-equal? (list relative-error dotted-error absolute-error)
                   '("" "" ""))
     (check-equal? relative-output dotted-output)
     (check-equal? relative-output absolute-output)
     (check-equal? (hash-ref (string->jsexpr relative-output) 'sourceId)
                   relative))

   (test-case "ast CLI binds same-length source changes to both digests"
     (define source (make-temporary-file "beagle-ast-source-digest-~a.bjs"))
     (define source-a
       "#lang beagle/js\n(ns checked.digest)\n(def x: Int 1) ; a\n")
     (define source-b
       "#lang beagle/js\n(ns checked.digest)\n(def x: Int 1) ; b\n")
     (check-equal? (string-length source-a) (string-length source-b))
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file source #:exists 'truncate
           (lambda (out) (display source-a out)))
         (define-values (status-a output-a errors-a)
           (run-ast-cli (path->string source)))
         (call-with-output-file source #:exists 'truncate
           (lambda (out) (display source-b out)))
         (define-values (status-b output-b errors-b)
           (run-ast-cli (path->string source)))
         (check-equal? (list status-a status-b) '(0 0))
         (check-equal? (list errors-a errors-b) '("" ""))
         (define json-a (string->jsexpr output-a))
         (define json-b (string->jsexpr output-b))
         (check-equal? (hash-ref json-a 'sourceId)
                       (hash-ref json-b 'sourceId))
         (check-not-equal? (hash-ref json-a 'sourceSha256)
                           (hash-ref json-b 'sourceSha256))
         (check-not-equal? (hash-ref json-a 'projectionSha256)
                           (hash-ref json-b 'projectionSha256))
         (check-equal? (hash-ref json-a 'sourceSha256)
                       (sha256-prefixed (string->bytes/utf-8 source-a)))
         (check-equal? (hash-ref json-b 'sourceSha256)
                       (sha256-prefixed (string->bytes/utf-8 source-b)))
         (check-equal? (hash-ref json-a 'projectionSha256)
                       (projection-sha256 json-a))
         (check-equal? (hash-ref json-b 'projectionSha256)
                       (projection-sha256 json-b)))
       (lambda () (delete-file source))))

   (test-case "checked projection binds AST and digest to one immutable snapshot"
     (define source-path
       (root/ "beagle-test/tests/fixtures/checked-projection/snapshot.bjs"))
     (define source-a
       (string->bytes/utf-8
        "#lang beagle/js\n(ns checked.snapshot-a)\n(def value: Int 1)\n"))
     (define source-b
       (string->bytes/utf-8
        "#lang beagle/js\n(ns checked.snapshot-b)\n(def value: Int 2)\n"))
     (define mutable-source (bytes-copy source-a))
     (define prog
       (parse-program/bytes mutable-source #:source-path source-path))
     ;; A caller cannot change the program's retained snapshot after parsing,
     ;; and the serializer has no detached source-bytes argument to substitute.
     (bytes-copy! mutable-source 0 source-b)
     (type-check-with-locs!
      prog
      (lambda (e _loc-stx) (raise e))
      #:capture-types? #t)
     (define json
       (checked-program->json prog #:source-id "snapshot.bjs"))
     (check-equal? (hash-ref json 'namespace) "checked.snapshot-a")
     (check-equal? (hash-ref json 'sourceSha256)
                   (sha256-prefixed source-a))
     (check-not-equal? (hash-ref json 'sourceSha256)
                       (sha256-prefixed source-b))
     (check-equal? (hash-ref json 'projectionSha256)
                   (projection-sha256 json)))

   (test-case "checked projection rejects programs without parser-bound bytes"
     (define path
       (root/ "beagle-test/tests/fixtures/checked-projection/wiki.bjs"))
     (define prog
       (parse-program (read-beagle-syntax path) #:source-path path))
     (type-check-with-locs!
      prog
      (lambda (e _loc-stx) (raise e))
      #:capture-types? #t)
     (check-exn #rx"parsed from an exact source-byte snapshot"
                (lambda ()
                  (checked-program->json prog #:source-id "wiki.bjs"))))

   (test-case "ast CLI emits no partial stdout on serialization failure"
     (define source (make-temporary-file "beagle-ast-non-json-~a.bclj"))
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file source #:exists 'truncate
           (lambda (out)
             (display
              "#lang beagle/clj\n(ns checked.non-json)\n(def x: Float +nan.0)\n"
              out)))
         (define-values (status output errors)
           (run-ast-cli (path->string source)))
         (check-not-equal? status 0)
         (check-equal? output "")
         (check-regexp-match #rx"legal JSON value" errors))
       (lambda () (delete-file source))))

   (test-case "checked-program preserves live protocol implementation nodes"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.protocol)\n"
         "(defrecord Box [value: String])\n"
         "(defprotocol Labelled (label [self] -> String))\n"
         "(extend-type Box Labelled (label [self] -> String (:value self)))\n")
        ".bclj"
        "checked-protocol.bclj"))
     (check-not-false (find-form-node json "defprotocol"))
     (check-not-false (find-form-node json "extend-type")))

   (test-case "checked-program preserves live typed JavaScript nodes"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.js)\n"
         "(js/export (defn add [] -> Int (js/+ 1 2)))\n"
         "(js/export (js/class App (constructor [] (js/return))))\n")
        ".bjs"
        "checked-js.bjs"))
     (define exported-defn (car (hash-ref json 'forms)))
     (check-equal? (hash-ref exported-defn 'node) "js-export")
     (check-equal?
      (hash-ref (car (hash-ref (hash-ref exported-defn 'form) 'body)) 'node)
      "js-binary")
     (check-not-false (find-form-node json "js-class")))

   (test-case "checked-program fails closed for unsupported values"
     (check-exn #rx"unsupported checked AST node"
                (lambda () (expr->json (vector 'future-node))))
     (check-exn #rx"unsupported checked type"
                (lambda () (type->json (vector 'future-type)))))

   (test-case "checked-program requires captured strict checking"
     (define tmp (make-temporary-file "beagle-unchecked-program-~a.bjs"))
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file tmp #:exists 'truncate
           (lambda (out)
             (display "#lang beagle/js\n(ns unchecked)\n(def x: Int 1)\n" out)))
         (define prog (parse-program/file tmp))
         (check-exn #rx"capture-types"
                    (lambda ()
                      (checked-program->json prog))))
       (lambda () (delete-file tmp))))))

(run-tests tests)
