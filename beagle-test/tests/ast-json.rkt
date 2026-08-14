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

(define register-program-type-table!
  (dynamic-require
   `(file ,(root/ "beagle-lib/private/ast.rkt"))
   'register-program-type-table!))

(define fresh-type-meta
  (dynamic-require
   `(file ,(root/ "beagle-lib/private/types.rkt"))
   'fresh-type-meta))

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

(define (find-named-form json node-name name)
  (for/first ([form (in-list (hash-ref json 'forms))]
              #:when (and (equal? (hash-ref form 'node #f) node-name)
                          (equal? (hash-ref form 'name #f) name)))
    form))

(define (definition-value json name)
  (hash-ref (find-named-form json "def" name) 'value))

(define (wire-ref name)
  (hasheq 'node "ref" 'name name))

(define (wire-number value)
  (hasheq 'node "literal" 'kind "number" 'value value))

(define (wire-selector name)
  (hasheq 'node "js-selector" 'name name))

(define receiver-first-js-source
  (string-append
   "(ns checked.js-members)\n"
   "(define-mode strict)\n"
   "(declare-extern object Any)\n"
   "(declare-extern key Any)\n"
   "(declare-extern Constructor Any)\n"
   "(def static-get Any (js/get object .field))\n"
   "(def dynamic-get Any (js/get object key))\n"
   "(def static-call Any (js/call object .method 1 2))\n"
   "(def dynamic-call Any (js/call object key 1 2))\n"
   "(def static-set Any (js/set! object .field 3))\n"
   "(def dynamic-set Any (js/set! object key 3))\n"
   "(def constructed Any (js/new Constructor 1 2))\n"
   "(def static-delete Bool (js/delete! object .field))\n"
   "(def dynamic-delete Bool (js/delete! object key))\n"
   "(def static-in Bool (js/in? object .field))\n"
   "(def dynamic-in Bool (js/in? object key))\n"
   "(def object-type String (js/typeof object))\n"))

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
       (parse+check-json "(ns t)\n(defn f [] String (let [x \"hello\"] x))"))
     (check-equal? (hash-ref (first-let-binding json) 'name) "x"))

   (test-case "seq-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] String (let [[a b] [\"x\" \"y\"]] (str a b)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type)  "seq-destructure")
     (check-equal? (hash-ref name 'names) '("a" "b"))
     (check-false  (hash-ref name 'rest)))

   (test-case "map-destructure let target"
     (define json
       (parse+check-json "(ns t)\n(defn f [] String (let [{:keys [x y]} {:x \"a\" :y \"b\"}] (str x y)))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'keys) '("x" "y"))
     (check-false  (hash-ref name 'as)))

   (test-case "map-destructure with :as"
     (define json
       (parse+check-json
        "(ns t)\n(defn f [] String (let [({:keys [x] :or {x \"\"} :as m} (Map Keyword String)) {:x \"z\"}] x))"))
     (define name (hash-ref (first-let-binding json) 'name))
     (check-equal? (hash-ref name 'type) "map-destructure")
     (check-equal? (hash-ref name 'as)   "m"))

   (test-case "nested seq-destructure"
     (define json
       (parse+check-json
        "(ns t)\n(defn f [] String (let [([[a b] c] (HVec (Vec String) String)) [[\"p\" \"q\"] \"r\"]] (str a b c)))"))
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

   (test-case "program JSON preserves JVM imports"
     (define json
       (parse+check-json
        (string-append
         "(ns program.imports (:import [java.nio.charset StandardCharsets] "
         "[java.util.zip CRC32]))\n"
         "(def value Int 1)\n")))
     (check-equal? (hash-ref json 'imports)
                   '("java.nio.charset.StandardCharsets" "java.util.zip.CRC32")))

   (test-case "checked-program v4 expands an imported typed declaration macro"
     (define path
       (root/ "beagle-test/tests/fixtures/checked-projection/wiki.bjs"))
     (define-values (_prog json)
       (parse+checked-json/path path "checked-projection/wiki.bjs"))
     (check-equal? (hash-ref json 'kind) "beagle.checked-program")
     (check-equal? (hash-ref json 'schemaVersion) 4)
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
         "(def result (Vec (U Int Nil)) (for [([a b] (Vec Int)) [[1 2]]] a))\n")
        ".bclj"
        "checked-for-destructure.bclj"))
     (define clause
       (car (hash-ref (hash-ref (car (hash-ref json 'forms)) 'value)
                      'clauses)))
     (define name (hash-ref clause 'name))
     (check-equal? (hash-ref name 'type) "seq-destructure")
     (check-equal? (hash-ref name 'names) '("a" "b")))

   (test-case "checked-program v4 retains binding-local constraints"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.binding-constraints)\n"
         "(defn positive? [(value Int)] Bool (> value 0))\n"
         "(defrecord Score [(value Int positive?)])\n"
         "(defunion Sample (Present [(value Int positive?)]))\n"
         "(defunion :throwable SampleError (Invalid [(value Int positive?)]))\n"
         "(defn constrained [(input Int positive?)] (Vec (U Int Nil))\n"
         "  (let [(local Int positive?) input]\n"
         "    (doseq [(seen Int positive?) [local]] seen)\n"
         "    (for [(item Int positive?) [local]] item)))\n")
        ".bclj"
        "checked-binding-constraints.bclj"))
     (check-equal? (hash-ref json 'schemaVersion) 4)
     (define predicate (find-named-form json "defn" "positive?"))
     (check-equal?
      (hash-ref (car (hash-ref predicate 'params)) 'constraint)
      'null)
     (check-false
      (hash-ref (car (hash-ref predicate 'params))
                'constraintSynchronous))
     (define record (find-named-form json "record" "Score"))
     (check-equal?
      (hash-ref (hash-ref (car (hash-ref record 'fields)) 'constraint) 'name)
      "positive?")
     (check-true
      (hash-ref (car (hash-ref record 'fields)) 'constraintSynchronous))
     (define union (find-named-form json "defunion" "Sample"))
     (check-equal?
      (hash-ref
       (hash-ref
        (car (hash-ref (hash-ref union 'member-fields) 'Present))
        'constraint)
       'name)
      "positive?")
     (check-true
      (hash-ref
       (car (hash-ref (hash-ref union 'member-fields) 'Present))
       'constraintSynchronous))
     (define error (find-named-form json "deferror" "SampleError"))
     (check-equal?
      (hash-ref
       (hash-ref
        (car (hash-ref (hash-ref error 'member-fields) 'Invalid))
        'constraint)
       'name)
      "positive?")
     (check-true
      (hash-ref
       (car (hash-ref (hash-ref error 'member-fields) 'Invalid))
       'constraintSynchronous))
     (define function (find-named-form json "defn" "constrained"))
     (check-equal?
      (hash-ref (hash-ref (car (hash-ref function 'params)) 'constraint) 'name)
      "positive?")
     (check-true
      (hash-ref (car (hash-ref function 'params))
                'constraintSynchronous))
     (define let-node (car (hash-ref function 'body)))
     (check-equal?
      (hash-ref
      (hash-ref (car (hash-ref let-node 'bindings)) 'constraint)
       'name)
      "positive?")
     (check-true
      (hash-ref (car (hash-ref let-node 'bindings))
                'constraintSynchronous))
     (define doseq-node (car (hash-ref let-node 'body)))
     (check-equal?
      (hash-ref
       (hash-ref (car (hash-ref doseq-node 'clauses)) 'constraint)
       'name)
      "positive?")
     (check-true
      (hash-ref (car (hash-ref doseq-node 'clauses))
                'constraintSynchronous))
     (define for-node (cadr (hash-ref let-node 'body)))
     (check-equal?
      (hash-ref
       (hash-ref (car (hash-ref for-node 'clauses)) 'constraint)
       'name)
      "positive?")
     (check-true
      (hash-ref (car (hash-ref for-node 'clauses))
                'constraintSynchronous)))

   (test-case "checked-program v4 publishes the record validator for with"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.with-contract)\n"
         "(defn positive? [(value Int)] Bool (> value 0))\n"
         "(defrecord Score [(value Int positive?)])\n"
         "(defn replace [(score Score)] Score\n"
         "  (with score [:value 2]))\n")
        ".bclj"
        "checked-with-contract.bclj"))
     (define function (find-named-form json "defn" "replace"))
     (define update (car (hash-ref function 'body)))
     (check-equal? (hash-ref update 'node) "with")
     (check-false (hash-has-key? update 'validator))
     (define contract (hash-ref update 'recordUpdate))
     (check-equal? (sort (hash-keys contract) symbol<?)
                   '(fieldOrder recordName validator))
     (check-equal? (hash-ref contract 'recordName) "Score")
     (check-equal? (hash-ref contract 'fieldOrder) '(":value"))
     (check-equal? (hash-ref contract 'validator)
                   "$beagle$record$Score$validate")
     (check-equal? (hash-ref json 'projectionSha256)
                   (projection-sha256 json)))

   (test-case "checked-program v4 always emits null validator for dynamic with"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.dynamic-with)\n"
         "(defn replace [(value Any)] Any (with value [:field 2]))\n")
        ".bclj"
        "checked-dynamic-with.bclj"))
     (define update
       (car (hash-ref (find-named-form json "defn" "replace") 'body)))
     (check-equal? (hash-ref update 'recordUpdate) 'null)
     (check-false (hash-has-key? update 'validator)))

   (test-case "checked-program v4 publishes exact record field access identity"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.field-contract)\n"
         "(defrecord Score [(value Int)])\n"
         "(defn read-score [(score Score)] Int (:value score))\n"
         "(defn read-map [(value Any)] Any (:value value))\n")
        ".bclj"
        "checked-field-contract.bclj"))
     (define typed
       (car (hash-ref (find-named-form json "defn" "read-score") 'body)))
     (define dynamic
       (car (hash-ref (find-named-form json "defn" "read-map") 'body)))
     (check-equal? (hash-ref (hash-ref typed 'recordFieldAccess) 'recordName)
                   "Score")
     (check-equal? (hash-ref dynamic 'recordFieldAccess) 'null))

   (test-case "checked-program v4 keeps one aggregate parameter with a structural name"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.typed-destructure)\n"
         "(defn first-coordinate [([x y] (HVec Float Float))] Float x)\n")
        ".bclj"
        "checked-typed-destructure.bclj"))
     (define parameter
       (car (hash-ref (car (hash-ref json 'forms)) 'params)))
     (define binding (hash-ref parameter 'name))
     (check-equal? (hash-ref json 'schemaVersion) 4)
     (check-equal? (hash-ref binding 'type) "seq-destructure")
     (check-equal? (hash-ref binding 'names) '("x" "y"))
     (check-equal? (hash-ref (hash-ref parameter 'ann) 'name) "HVec"))

   (test-case "checked-program v4 publishes inference separately from authored annotations"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.inferred-signature)\n"
         "(defn identity [value] Int value)\n")
        ".bclj"
        "checked-inferred-signature.bclj"))
     (define definition (car (hash-ref json 'forms)))
     (define parameter (car (hash-ref definition 'params)))
     (define effective (hash-ref definition 'effectiveType))
     (check-equal? (hash-ref json 'schemaVersion) 4)
     (check-equal? (hash-ref parameter 'ann) 'null)
     (check-equal? (hash-ref effective 'kind) "fn")
     (check-equal?
      (hash-ref (car (hash-ref effective 'params)) 'name)
      "Int")
     (check-equal? (hash-ref (hash-ref effective 'ret) 'name) "Int"))

   (test-case "checked-program v4 publishes one finalized multi-arity signature"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.inferred-multi)\n"
         "(defn choose ([x] Int x) ([x y] String y))\n")
        ".bclj"
        "checked-inferred-multi.bclj"))
     (define effective
       (hash-ref (car (hash-ref json 'forms)) 'effectiveType))
     (check-equal? (hash-ref effective 'kind) "poly")
     (check-equal? (hash-ref (hash-ref effective 'body) 'kind) "union"))

   (test-case "checked-program v4 preserves JVM imports as semantic metadata"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.imports (:import [java.nio.charset StandardCharsets] "
         "[java.util.zip CRC32]))\n"
         "(def value Int 1)\n")
        ".bclj"
        "checked-imports.bclj"))
     (check-equal? (hash-ref json 'schemaVersion) 4)
     (check-equal? (hash-ref json 'imports)
                   '("java.nio.charset.StandardCharsets" "java.util.zip.CRC32")))

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
       "#lang beagle/js\n(ns checked.digest)\n(def x Int 1) ; a\n")
     (define source-b
       "#lang beagle/js\n(ns checked.digest)\n(def x Int 1) ; b\n")
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
        "#lang beagle/js\n(ns checked.snapshot-a)\n(def value Int 1)\n"))
     (define source-b
       (string->bytes/utf-8
        "#lang beagle/js\n(ns checked.snapshot-b)\n(def value Int 2)\n"))
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
              "#lang beagle/clj\n(ns checked.non-json)\n(def x Float +nan.0)\n"
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
         "(defrecord Box [(value String)])\n"
         "(defprotocol Labelled (label [(self Any)] String))\n"
         "(extend-type Box Labelled (label [(self Box)] String (:value self)))\n")
        ".bclj"
        "checked-protocol.bclj"))
     (check-not-false (find-form-node json "defprotocol"))
     (check-not-false (find-form-node json "extend-type")))

   (test-case "AST JSON preserves static JavaScript selector wire shapes"
     (define json (parse+check-json/js receiver-first-js-source))
     (define object (wire-ref "object"))
     (define field (wire-selector "field"))
     (check-equal?
      (definition-value json "static-get")
      (hasheq 'node "js-get" 'receiver object 'key field))
     (check-equal?
      (definition-value json "static-call")
      (hasheq 'node "js-call"
              'receiver object
              'key (wire-selector "method")
              'args (list (wire-number 1) (wire-number 2))))
     (check-equal?
      (definition-value json "static-set")
      (hasheq 'node "js-set"
              'receiver object
              'key field
              'value (wire-number 3)))
     (check-equal?
      (definition-value json "constructed")
      (hasheq 'node "js-new"
              'callee (wire-ref "Constructor")
              'args (list (wire-number 1) (wire-number 2))))
     (check-equal?
      (definition-value json "static-delete")
      (hasheq 'node "js-delete" 'receiver object 'key field))
     (check-equal?
      (definition-value json "static-in")
      (hasheq 'node "js-in" 'receiver object 'key field))
     (check-equal?
      (definition-value json "object-type")
      (hasheq 'node "js-typeof" 'expr object)))

   (test-case "AST JSON preserves dynamic JavaScript key wire shapes"
     (define json (parse+check-json/js receiver-first-js-source))
     (define object (wire-ref "object"))
     (define key (wire-ref "key"))
     (check-equal?
      (definition-value json "dynamic-get")
      (hasheq 'node "js-get" 'receiver object 'key key))
     (check-equal?
      (definition-value json "dynamic-call")
      (hasheq 'node "js-call"
              'receiver object
              'key key
              'args (list (wire-number 1) (wire-number 2))))
     (check-equal?
      (definition-value json "dynamic-set")
      (hasheq 'node "js-set"
              'receiver object
              'key key
              'value (wire-number 3)))
     (check-equal?
      (definition-value json "dynamic-delete")
      (hasheq 'node "js-delete" 'receiver object 'key key))
     (check-equal?
      (definition-value json "dynamic-in")
      (hasheq 'node "js-in" 'receiver object 'key key)))

   (test-case "checked-program v4 preserves receiver-first JavaScript nodes"
     (define json
       (parse+checked-json receiver-first-js-source
                           ".bjs"
                           "checked-js-members.bjs"))
     (check-equal? (hash-ref json 'schemaVersion) 4)
     (check-equal?
      (for/list ([name (in-list '("static-get"
                                  "dynamic-get"
                                  "static-call"
                                  "dynamic-call"
                                  "static-set"
                                  "dynamic-set"
                                  "constructed"
                                  "static-delete"
                                  "dynamic-delete"
                                  "static-in"
                                  "dynamic-in"
                                  "object-type"))])
        (hash-ref (definition-value json name) 'node))
      '("js-get"
        "js-get"
        "js-call"
        "js-call"
        "js-set"
        "js-set"
        "js-new"
        "js-delete"
        "js-delete"
        "js-in"
        "js-in"
        "js-typeof"))
     (check-equal?
      (hash-ref (hash-ref (definition-value json "static-get") 'key) 'node)
      "js-selector")
     (check-equal?
      (hash-ref (hash-ref (definition-value json "dynamic-get") 'key) 'node)
      "ref"))

   (test-case "checked-program v4 retains constrained protocol rest bindings"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.protocol-rest)\n"
         "(defn nonempty? [(values (Vec Int))] Bool (> (count values) 0))\n"
         "(defprotocol Variadic\n"
         "  (combine [(self Any) & (values (Vec Int) nonempty?)] Int))\n"
         "(extend-type String Variadic\n"
         "  (combine [(self String) & (values (Vec Int) nonempty?)] Int\n"
         "    (count values)))\n")
        ".bclj"
        "checked-protocol-rest.bclj"))
     (define protocol (find-named-form json "defprotocol" "Variadic"))
     (define signature (car (hash-ref protocol 'methods)))
     (check-equal?
      (hash-ref (hash-ref (hash-ref signature 'rest) 'constraint) 'name)
      "nonempty?")
     (check-true
      (hash-ref (hash-ref signature 'rest) 'constraintSynchronous))
     (define extension (find-form-node json "extend-type"))
     (define implementation
       (car (hash-ref (car (hash-ref extension 'impls)) 'methods)))
     (check-equal?
      (hash-ref
       (hash-ref (hash-ref implementation 'rest) 'constraint)
       'name)
      "nonempty?")
     (check-true
      (hash-ref (hash-ref implementation 'rest) 'constraintSynchronous)))

   (test-case "checked-program preserves live typed JavaScript nodes"
     (define json
       (parse+checked-json
        (string-append
         "(ns checked.js)\n"
         "(js/export (defn add [] Int (js/+ 1 2)))\n"
         "(js/export (js/class App (constructor [] Nil (js/return))))\n")
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
                (lambda () (type->json (vector 'future-type))))
     (check-exn #rx"inference metavariable"
                (lambda () (type->json (fresh-type-meta)))))

   (test-case "checked-program refuses captured AST without finalized signatures"
     (define tmp (make-temporary-file "beagle-no-effective-signatures-~a.bjs"))
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file tmp #:exists 'truncate
           (lambda (out)
             (display
              "#lang beagle/js\n(ns checked.no-signatures)\n(defn id [x] Int x)\n"
              out)))
         (define prog (parse-program/file tmp))
         (register-program-type-table! prog (make-hasheq))
         (check-exn #rx"effective definition signatures"
                    (lambda () (checked-program->json prog))))
       (lambda () (delete-file tmp))))

   (test-case "checked-program requires captured strict checking"
     (define tmp (make-temporary-file "beagle-unchecked-program-~a.bjs"))
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file tmp #:exists 'truncate
           (lambda (out)
             (display "#lang beagle/js\n(ns unchecked)\n(def x Int 1)\n" out)))
         (define prog (parse-program/file tmp))
         (check-exn #rx"capture-types"
                    (lambda ()
                      (checked-program->json prog))))
       (lambda () (delete-file tmp))))))

(run-tests tests)
