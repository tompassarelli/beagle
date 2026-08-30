#lang racket/base

;; A `js/export`-wrapped definition is still a definition: its signature must cross
;; the module boundary and appear on the query surface.

(require rackunit
         racket/runtime-path
         racket/port
         racket/string
         beagle/private/module-interface
         beagle/private/foreign-interface-v1
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/ast-json
         beagle/private/query)

(define-runtime-path fixtures-dir "fixtures/export-xmodule")

(define ZERO-SHA256 (make-string 64 #\0))

(define (foreign-function-source module-specifier exports)
  (foreign-interface-v1->module-source
   (validate-foreign-interface-v1
    (hash
     'kind FOREIGN-INTERFACE-KIND
     'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
     'frontend "typescript"
     'moduleSpecifier module-specifier
     'exports
     (for/list ([export (in-list exports)])
       (hash 'name (car export)
             'space "value"
             'node "n:function"
             'runtimeName (cdr export)))
     'nodes
     (list
      (hash 'id "n:function"
            'kind "function"
            'overloads
            (list
             (hash 'typeParameters '()
                   'parameters
                   (list
                    (hash 'name "value"
                          'type "n:string"
                          'optional #f
                          'rest #f))
                   'return "n:string")))
      (hash 'id "n:string" 'kind "primitive" 'name "string"))
     'obligations '()
     'provenance
     (hash
      'adapter
      (hash 'source "src/adapter.bjs"
            'sourceSha256 ZERO-SHA256
            'compiled (format "compiled/~a.mjs" ZERO-SHA256)
            'compiledSha256 ZERO-SHA256
            'version "1.0.0")
      'typescript
      (hash 'version "5.9.3"
            'path "node_modules/typescript/lib/typescript.js"
            'sha256 ZERO-SHA256)
      'compilerOptions (hash)
      'moduleSpecifier module-specifier
      'conditions '()
      'package (hash 'path "package.json" 'sha256 ZERO-SHA256)
      'lockfile (hash 'path "bun.lock" 'sha256 ZERO-SHA256)
      'consultedFiles '())
     'stats
     (hash 'nodeCount 2
           'exportCount (length exports)
           'obligationCount 0
           'anyCount 0
           'generatedSourceCount 0)))))

(define PACKAGE-SOURCE
  (foreign-function-source "@scope/package/subpath"
                           (list (cons "make" "make"))))

(define (fixture-foreign-module-resolver identity _importer)
  (and (equal? identity
               (module-identity 'native-esm "@scope/package/subpath"))
       PACKAGE-SOURCE))

(define (fixture-provider relative namespace)
  (define provider-id (string-append "fixtures/export-xmodule/" relative))
  (define provider-path (build-path fixtures-dir relative))
  (define provider
    (parse-program
     (read-beagle-syntax provider-path)
     #:source-path provider-id
     #:foreign-module-resolver fixture-foreign-module-resolver))
  (type-check! provider)
  (module-source
   namespace
   provider-id
   #f
   (program->module-interface provider #:source-id provider-id)))

(define (fixture-providers name)
  (cond
    [(string-prefix? name "same-basename/")
     (list
      (fixture-provider "same-basename/game/notifications.bjs" 'game.notifications)
      (fixture-provider "same-basename/host/notifications.bjs" 'host.notifications))]
    [(string-suffix? name ".bclj")
     (list (fixture-provider "clj-prov.bclj" 'export-xmodule.clj-prov))]
    [(member name '("public-esm-consumer.bjs"
                    "public-esm-qualified-consumer.bjs"))
     (list
      (fixture-provider "public-esm-names.bjs"
                        'export-xmodule.public-esm-names))]
    [else
     (list (fixture-provider "provider.bjs" 'export-xmodule.provider))]))

(define (fixture-program name)
  (define providers (fixture-providers name))
  (define providers-by-namespace
    (for/hash ([provider (in-list providers)])
      (values (module-source-namespace provider) provider)))
  (parse-program
   (read-beagle-syntax (build-path fixtures-dir name))
   #:source-path (string-append "fixtures/export-xmodule/" name)
   #:module-resolver
   (lambda (namespace _importer)
     (hash-ref providers-by-namespace namespace #f))
   #:foreign-module-resolver fixture-foreign-module-resolver))

(define (check-file name)
  (type-check! (fixture-program name)))

(test-case "canonical string libspec preserves native ESM identity"
  (define spec
    (normalize-canonical-libspec
     (list "@scope/package/subpath" ':as 'pkg ':refer '(make) ':rename
           (hasheq 'make 'build))))
  (check-equal?
   (canonical-libspec-identity spec)
   (module-identity 'native-esm "@scope/package/subpath"))
  (check-equal? (canonical-libspec-alias spec) 'pkg)
  (check-equal? (canonical-libspec-refer spec) '(make))
  (check-equal? (canonical-libspec-rename spec) (hasheq 'make 'build)))

(test-case "namespace and native ESM identities never collapse"
  (define namespace-spec
    (normalize-canonical-libspec (list 'react ':as 'react)))
  (define esm-spec
    (normalize-canonical-libspec (list "react" ':as 'react)))
  (check-equal?
   (module-identity-kind (canonical-libspec-identity namespace-spec))
   'beagle-namespace)
  (check-equal?
   (module-identity-kind (canonical-libspec-identity esm-spec))
   'native-esm)
  (check-not-equal? (canonical-libspec-identity namespace-spec)
                    (canonical-libspec-identity esm-spec)))

(test-case "native ESM resolution and emission preserve exact identity"
  (define provider-interface
    (struct-copy
     module-interface
     (module-source-interface
      (fixture-provider "public-esm-names.bjs" 'pkg.name))
     [namespace 'pkg.name]))
  (define native-provider-source
    (foreign-function-source
     "pkg.name"
     (list (cons "send-message" "native.marker"))))
  (define namespace-provider-source
    (module-source
     'pkg.name
     "pkg/name.bjs"
     #f
     (struct-copy module-interface provider-interface
                  [public-esm-exports (hasheq 'wire_name "local.marker")])))
  (define native-identity (module-identity 'native-esm "pkg.name"))
  (define namespace-requests '())
  (define foreign-requests '())
  (define prog
    (parse-program
     (read-beagle-syntax
      (build-path fixtures-dir "native-esm-identity.bjs"))
     #:source-path "fixtures/export-xmodule/native-esm-identity.bjs"
     #:module-resolver
     (lambda (namespace _importer)
       (set! namespace-requests (cons namespace namespace-requests))
       (and (eq? namespace 'pkg.name) namespace-provider-source))
     #:foreign-module-resolver
     (lambda (identity _importer)
       (set! foreign-requests (cons identity foreign-requests))
       (and (equal? identity native-identity) native-provider-source))))
  (type-check! prog)
  (check-true (pair? namespace-requests))
  (check-true
   (andmap (lambda (namespace) (eq? namespace 'pkg.name))
           namespace-requests))
  (check-true (pair? foreign-requests))
  (check-true
   (andmap (lambda (identity) (equal? identity native-identity))
           foreign-requests))
  (define import-identities
    (map module-import-identity (program-imported-module-interfaces prog)))
  (check-not-false (member native-identity import-identities equal?))
  (check-not-false
   (member (module-identity 'beagle-namespace 'pkg.name)
           import-identities equal?))
  (define js (emit-program prog))
  (check-regexp-match
   #rx"import \\{ \"native[.]marker\" as send_message \\} from \"pkg[.]name\";"
   js)
  (check-regexp-match
   #rx"import \\{ \"local[.]marker\" as wire__name \\} from \"[.][.]/pkg/name[.]js\";"
   js))

(test-case "require-global preserves a global rather than ESM identity"
  (define spec
    (normalize-canonical-libspec (list 'Idiomorph ':as 'idio)
                                 #:kind 'require-global))
  (check-equal?
   (canonical-libspec-identity spec)
   (module-identity 'global 'Idiomorph)))

(test-case "refer-global has an explicit closed rename contract"
  (define globals
    (normalize-refer-global
     (list ':only '(Date String) ':rename (hasheq 'Date 'my-date))))
  (check-equal? (canonical-global-refer-refer globals) '(Date String))
  (check-equal? (canonical-global-refer-rename globals)
                (hasheq 'Date 'my-date)))

(test-case "libspec validation rejects duplicate, implicit, and ambiguous renames"
  (check-exn #rx"appears more than once"
             (lambda ()
               (normalize-canonical-libspec
                (list "react" ':as 'react ':as 'again))))
  (check-exn #rx"explicitly referred"
             (lambda ()
               (normalize-canonical-libspec
                (list "react" ':rename (hasheq 'make 'build)))))
  (check-exn #rx"duplicate-free list"
             (lambda ()
               (normalize-canonical-libspec
                (list "react" ':refer '(make make)))))
  (check-exn #rx"cannot rename a symbol to itself"
             (lambda ()
               (normalize-refer-global
                (list ':only '(Date) ':rename (hasheq 'Date 'Date))))))

(test-case "top-level canonical libspecs retain module identities and renames"
  (define prog (fixture-program "top-level-libspec.bjs"))
  (type-check! prog)
  (define requires (program-requires prog))
  (check-equal? (length requires) 1)
  (define native
    (for/first ([entry (in-list requires)]
                #:when (eq? (module-identity-kind (require-entry-identity entry))
                            'native-esm))
      entry))
  (check-equal?
   (module-identity-value (require-entry-identity native))
   "@scope/package/subpath")
  (check-equal? (require-entry-rename native) (hasheq 'make 'build))
  (define serialized-requires (hash-ref (program->json prog) 'requires))
  (define serialized-native
    (for/first ([entry (in-list serialized-requires)]
                #:when (equal? (hash-ref (hash-ref entry 'identity) 'kind)
                               "native-esm"))
      entry))
  (check-equal? (hash-ref (hash-ref serialized-native 'identity) 'value)
                "@scope/package/subpath")
  (check-equal? (hash->list (hash-ref serialized-native 'rename))
                (list (cons "make" "build")))
  (define interface
    (program->module-interface prog #:source-id "top-level-libspec.bjs"))
  (check-equal? (module-interface-requires interface) requires))

(test-case "module interfaces carry verbatim public ESM names"
  (define prog (fixture-program "public-esm-names.bjs"))
  (type-check! prog)
  (define interface
    (program->module-interface prog #:source-id "public-esm-names.bjs"))
  (check-equal?
   (module-interface-public-esm-exports interface)
   (hasheq 'send-message "send-message"
           'wire_name "wire_name"))
  (check-equal?
   (module-interface-public-esm-name interface 'send-message)
   "send-message")
  (check-false
   (module-interface-public-esm-name interface 'private-helper))
  (define native
    (car (module-interface-requires interface)))
  (check-equal?
   (require-entry-identity native)
   (module-identity 'native-esm "@scope/package/subpath")))

(test-case "JS emission aliases private bindings to verbatim public ESM names"
  (define js (emit-program (fixture-program "public-esm-names.bjs")))
  (check-regexp-match #rx"import [*] as package[$] from \"@scope/package/subpath\";" js)
  (check-regexp-match #rx"function send_message\\(" js)
  (check-regexp-match #rx"function wire__name\\(" js)
  (check-regexp-match #rx"export \\{ send_message as \"send-message\" \\};" js)
  (check-regexp-match #rx"export \\{ wire__name as \"wire_name\" \\};" js)
  (check-false (regexp-match? #rx"export function send_message" js)))

(test-case "JS imports use the provider's verbatim public ESM names"
  (define js (emit-program (fixture-program "public-esm-consumer.bjs")))
  (check-regexp-match
   #rx"import \\{ \"send-message\" as send_message, \"wire_name\" as wire__name \\} from \"[.]/public-esm-names[.]js\";"
   js)
  (check-regexp-match #rx"send_message\\(wire__name\\(text\\)\\)" js))

(test-case "record type and constructor refers share one JS local binding"
  (define js
    (emit-program (fixture-program "record-refer-consumer.bjs")))
  (check-regexp-match
   #rx"import \\{ \"Pos\" as Pos, \"pos-x\" as pos_x \\} from \"[.]/provider[.]js\";"
   js)
  (check-false (regexp-match? #rx"\"->Pos\" as Pos" js)))

(test-case "qualified JS imports use authored public ESM names"
  (define js
    (emit-program (fixture-program "public-esm-qualified-consumer.bjs")))
  (check-regexp-match
   #rx"names\\[\"send-message\"\\]\\(names\\[\"wire_name\"\\]\\(text\\)\\)"
   js)
  (check-false (regexp-match? #rx"names[.]send_message" js)))

(test-case "a correct call to a js/export'd function still checks"
  (check-not-exn (lambda () (check-file "ok.bjs"))))

(test-case "same-basename required modules resolve by full namespace"
  (check-not-exn
   (lambda ()
     (check-file "same-basename/host/consumer.bjs"))))

(test-case "a bad call to a :refer'd js/export'd function is rejected"
  (check-exn #rx"arg 1 expected Float, got String"
             (lambda () (check-file "bad.bjs"))))

(test-case "a bad call through an :as alias is rejected too"
  (check-exn #rx"arg 1 expected Float, got String"
             (lambda () (check-file "aliased.bjs"))))

;; Making the exported name KNOWN to the consumer changed which emission path it
;; took: the bound-name early-out returned the raw `p/scale` spelling, emitting
;; the syntactically invalid `p/scale(x, 2.0)`.
(test-case "a qualified call to an imported export emits a member access"
  (define js (emit-program (fixture-program "consumer.bjs")))
  (check-regexp-match #rx"p\\[\"scale\"\\]\\(" js)
  (check-false (regexp-match? #rx"p/scale" js)))

(test-case "an imported union member instance check keeps provider identity"
  (define js (emit-program (fixture-program "variant-instance.bjs")))
  (check-regexp-match
   #rx"record_instance_p\\(\"export-xmodule[.]provider/JsonObjectStart\""
   js)
  (check-false
   (regexp-match?
    #rx"export-xmodule[.]variant-instance/JsonObjectStart"
    js)))

(test-case "a local binding cannot capture a qualified import alias"
  (define js
    (emit-program (fixture-program "shadowed-alias.bjs")))
  (check-true
   (string-contains?
    js "import * as $beagle$import$p from \"./provider.js\";"))
  (check-true (string-contains? js "function go(p)"))
  (check-true
   (string-contains? js "return $beagle$import$p[\"scale\"](p, 2.0);"))
  (check-false (string-contains? js "return p[\"scale\"](p, 2.0);")))

(test-case "js/export'd definitions reach the query surface"
  (define out
    (with-output-to-string
      (lambda () (query-provides (path->string (build-path fixtures-dir "provider.bjs"))))))
  (check-regexp-match #rx"scale" out)
  (check-regexp-match #rx"Pos" out)
  ;; Internal definitions are listed as before: the wrapper is an export marker,
  ;; not a visibility boundary for the query surface.
  (check-regexp-match #rx"internal" out))

;; The call path was fixed in c3a803e0; the REFERENCE path kept the same
;; early-out. `p/cell` is not a syntax error in JS — it parses as division — so
;; this emitted silently wrong code rather than failing the build.
(test-case "a qualified reference to an imported export emits a member access"
  (define js (emit-program (fixture-program "refconsumer.bjs")))
  (check-regexp-match #rx"p\\[\"cell\"\\][.]value" js)
  (check-false (regexp-match? #rx"p/cell" js)))

;; `js/export` prefixes the string "export " onto what the inner form emits, so
;; on a record — which emits a factory AND one accessor per field — it reached
;; only the factory. The ctor also mangled to `__gtPos` at call sites because
;; build-known-fns! never unwrapped the marker to see the record at all.
(test-case "an exported record exports its constructor and every accessor"
  (define prog (fixture-program "exported-record.bjs"))
  (check-not-exn (lambda () (type-check! prog)))
  (define js (emit-program prog))
  (check-regexp-match #rx"function Pos\\(" js)
  (check-regexp-match #rx"function pos_x\\(" js)
  (check-regexp-match #rx"function pos_z\\(" js)
  (check-regexp-match #rx"export \\{ Pos as \"->Pos\" \\};" js)
  ;; Generated cross-module consumers call the runtime factory name, while
  ;; authored Beagle consumers retain the constructor spelling.
  (check-regexp-match #rx"export \\{ Pos as \"Pos\" \\};" js)
  (check-regexp-match #rx"export \\{ pos_x as \"pos-x\" \\};" js)
  (check-regexp-match #rx"export \\{ pos_z as \"pos-z\" \\};" js)
  ;; The constructor is called by the name it is defined under.
  (check-regexp-match #rx"return Pos\\(0[.]0, 0[.]0\\)" js)
  (check-false (regexp-match? #rx"__gtPos" js)))

;; `js/export` is the deliberate publication surface on the js target: the
;; emitter exports exactly the wrapped definitions, so the checker must reject
;; a cross-module reference to anything else — the emitted namespace object
;; has no such member and the reference would only die at runtime.
(test-case "a qualified reference to a non-exported js function is rejected at check time"
  (check-exn #rx"does not export internal.*js/export"
             (lambda () (check-file "internal-consumer.bjs"))))

(test-case "a qualified reference to a non-exported js def is rejected at check time"
  (check-exn #rx"does not export hidden-offset.*js/export"
             (lambda () (check-file "def-consumer.bjs"))))

(test-case "a :refer of a non-exported js member is rejected"
  (check-exn #rx"does not export referred name internal"
             (lambda () (check-file "refer-internal.bjs"))))

(test-case "the emitter leaves a non-exported js definition unexported"
  (define src (build-path fixtures-dir "provider.bjs"))
  (define js (emit-program (parse-program (read-beagle-syntax src) #:source-path src)))
  (check-regexp-match #rx"function internal\\(" js)
  (check-false (regexp-match? #rx"export function internal" js)))

;; The clj target keeps its own rules: a plain defn crosses the module
;; boundary, only defn- is private — js/export gating is js-only.
(test-case "a clj cross-module call to a plain defn still checks"
  (check-not-exn (lambda () (check-file "clj-open.bclj"))))

(test-case "a clj cross-module call to a defn- stays rejected without js guidance"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"does not export hidden-scale" (exn-message e))
                    (not (regexp-match? #rx"js/export" (exn-message e)))))
             (lambda () (check-file "clj-hidden.bclj"))))
