#lang racket/base

(require rackunit
         json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         beagle/private/facts-roundtrip
         beagle/private/module-interface
         beagle/private/parse
         beagle/private/world-check)

(define-runtime-path world-cli
  "../../beagle-lib/private/facts-check-world.rkt")

(define (write-text! path text)
  (make-directory* (path-only path))
  (call-with-output-file
   path
   (lambda (out) (display text out))
   #:exists 'truncate/replace))

(define (source->edn! edn-path source-id source-text)
  (define reader-path
    (make-temporary-file "beagle-world-reader-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (write-text! reader-path source-text)
     (define stxs (read-beagle-syntax reader-path))
     (define lines
       (datum->edn-lines
        (cons 'beagle-file (map syntax->datum stxs))))
     (call-with-output-file
      edn-path
      (lambda (out)
        (fprintf out "@file ~a\n" source-id)
        (for ([line (in-list lines)])
          (displayln line out)))
      #:exists 'truncate/replace))
   (lambda ()
     (when (file-exists? reader-path)
       (delete-file reader-path)))))

(define (diagnostic-text result)
  (string-join
   (map world-diagnostic-message
        (world-check-result-diagnostics result))
   "\n"))

(define (with-world-files thunk)
  (define root (make-temporary-file "beagle-world-check-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define provider-source
       (build-path root "world" "provider.bclj"))
     (define consumer-source
       (build-path root "world" "consumer.bclj"))
     (make-directory* (path-only provider-source))
     (thunk root provider-source consumer-source))
   (lambda ()
     (when (directory-exists? root)
       (delete-directory/files root)))))

(define (candidate! root stem source-id source-text)
  (define edn (build-path root (string-append stem ".edn")))
  (source->edn! edn source-id source-text)
  edn)

(define (append-edn-lines! path lines)
  (call-with-output-file
   path
   (lambda (out)
     (for ([line (in-list lines)])
       (displayln line out)))
   #:exists 'append))

(define (structural-edge-predicate? predicate)
  (or (equal? predicate "child")
      (equal? predicate "tail")
      (regexp-match?
       #px"^f[0-9]+(?:\\.[0-9]+)*(?:~[0-9]+)?$"
       predicate)))

(define (shift-edn-node-ids! path delta)
  (define source-line (car (file->lines path)))
  (define triples (read-edn-triples path))
  (call-with-output-file
   path
   (lambda (out)
     (displayln source-line out)
     (for ([triple (in-list triples)])
       (define subject (car triple))
       (define predicate (cadr triple))
       (define object (caddr triple))
       (fprintf
        out
        "[~s ~s ~s]\n"
        (+ subject delta)
        predicate
        (if (and (exact-integer? object)
                 (structural-edge-predicate? predicate))
            (+ object delta)
            object))))
   #:exists 'truncate/replace))

(define (run-world-cli . args)
  ;; Stay on the exact runtime driving this test (Fram pins Racket 9.1).  Using
  ;; PATH here can accidentally spawn a newer system Racket and create
  ;; incompatible compiled linklets.
  (define racket-exe
    (build-path (path-only (find-system-path 'exec-file)) "racket"))
  (define-values (process stdout stdin stderr)
    (apply subprocess #f #f #f racket-exe world-cli args))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait process)
  (values (subprocess-status process) out err))

(define provider-string-signature
  (string-append
   "#lang beagle/clj\n"
   "(ns world.provider)\n"
   "(defn f [x :- String] :- String x)\n"))

(define consumer-string-call
  (string-append
   "#lang beagle/clj\n"
   "(ns world.consumer (:require [world.provider :as p]))\n"
   "(defn use [x :- String] :- String (p/f x))\n"))

(test-case "candidate provider overlays an older provider on disk"
  (with-world-files
   (lambda (root provider-source consumer-source)
     ;; The filesystem provider has the incompatible old signature.  The
     ;; candidate world updates provider and consumer coherently.
     (write-text!
      provider-source
      (string-append
       "#lang beagle/clj\n"
       "(ns world.provider)\n"
       "(defn f [x :- Int] :- Int x)\n"))
     (write-text! consumer-source consumer-string-call)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source
        provider-string-signature))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        consumer-string-call))
     (define result
       (check-edn-world (list consumer-edn provider-edn)))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result))
     (check-equal? (length (world-check-result-modules result)) 2)
     (check-true
      (andmap string?
              (map checked-world-module-emitted
                   (world-check-result-modules result)))))))

(test-case "full overlay can provide context while only an explicit set is checked"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source
        provider-string-signature))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        consumer-string-call))
     (define result
       (check-edn-world
        (list provider-edn consumer-edn)
        #:check-namespaces '(world.consumer)))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result))
     (check-equal?
      (map checked-world-module-namespace
           (world-check-result-modules result))
      '(world.consumer))
     (check-true
      (string-prefix?
       (world-check-result-world-digest result)
       "sha256:")))))

(test-case "an explicit checked namespace absent from the overlay fails closed"
  (with-world-files
   (lambda (root provider-source _consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source
        provider-string-signature))
     (define result
       (check-edn-world
        (list provider-edn)
        #:check-namespaces '(world.missing)))
     (check-false (world-check-result-ok? result))
     (check-regexp-match
      #rx"checked namespace world\\.missing is absent"
      (diagnostic-text result)))))

(test-case "@file source selectors support namespace-free graph modules"
  (with-world-files
   (lambda (root _provider-source _consumer-source)
     (define selected-edn (build-path root "selected.edn"))
     (define context-edn (build-path root "context.edn"))
     (source->edn!
      selected-edn
      "graph.fixture.selected"
      "#lang beagle/clj\n(def answer :- Int 42)\n")
     (source->edn!
      context-edn
      "graph.fixture.context"
      "#lang beagle/clj\n(def context :- String \"ok\")\n")
     (define result
       (check-edn-world
        (list context-edn selected-edn)
        #:check-sources '("graph.fixture.selected")))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result))
     (check-equal? (length (world-check-result-modules result)) 1)
     (define checked (car (world-check-result-modules result)))
     (check-false (checked-world-module-namespace checked))
     (check-equal?
      (checked-world-module-source checked)
      "graph.fixture.selected"))))

(test-case "explicit file wrapper wins over orphaned legacy body lists"
  (with-world-files
   (lambda (root _provider-source _consumer-source)
     (define selected-edn (build-path root "selected-with-orphans.edn"))
     (source->edn!
      selected-edn
      "graph.fixture.selected"
      "#lang beagle/clj\n(def answer :- Int 42)\n")
     ;; Match the stable IDs of the post-commit Fram regression so the old
     ;; hash-order root heuristic deterministically selects an orphan body.
     (shift-edn-node-ids! selected-edn 1543)
     ;; Fram's historical `child` overlay can retain old list bodies after the
     ;; authoritative fN slot moves. They are harmless unreachable facts, but
     ;; they must not outrank the explicit beagle-file wrapper as EDN root.
     (append-edn-lines!
      selected-edn
      '("[1936 \"kind\" \"list\"]"
        "[1938 \"kind\" \"symbol\"]"
        "[1938 \"v\" \"orphan-a\"]"
        "[1936 \"f0\" 1938]"
        "[2186 \"kind\" \"list\"]"
        "[2188 \"kind\" \"symbol\"]"
        "[2188 \"v\" \"orphan-b\"]"
        "[2186 \"f0\" 2188]"))
     (define result
       (check-edn-world
        (list selected-edn)
        #:check-sources '("graph.fixture.selected")))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result)))))

(test-case "an unwrapped candidate remains a malformed world"
  (with-world-files
   (lambda (root _provider-source _consumer-source)
     (define malformed-edn (build-path root "unwrapped.edn"))
     (call-with-output-file
      malformed-edn
      (lambda (out)
        (displayln "@file graph.fixture.unwrapped" out)
        (for ([line (in-list (datum->edn-lines '(def answer :- Int 42)))])
          (displayln line out)))
      #:exists 'truncate/replace)
     (define result (check-edn-world (list malformed-edn)))
     (check-false (world-check-result-ok? result))
     (check-regexp-match
      #rx"EDN root is not a beagle-file wrapper"
      (diagnostic-text result)))))

(test-case "CLI source selector returns one atomic JSON receipt"
  (with-world-files
   (lambda (root _provider-source _consumer-source)
     (define selected-edn (build-path root "selected.edn"))
     (define context-edn (build-path root "context.edn"))
     (source->edn!
      selected-edn
      "graph.fixture.selected"
      "#lang beagle/clj\n(def answer :- Int 42)\n")
     (source->edn!
      context-edn
      "graph.fixture.context"
      "#lang beagle/clj\n(def context :- String \"ok\")\n")
     (define-values (status out err)
       (run-world-cli
        "--check-source"
        "graph.fixture.selected"
        (path->string context-edn)
        (path->string selected-edn)))
     (check-equal? status 0 err)
     (check-equal? err "")
     (define receipt (string->jsexpr out))
     (check-true (hash-ref receipt 'ok))
     (check-equal? (length (hash-ref receipt 'modules)) 1)
     (check-equal?
      (hash-ref (car (hash-ref receipt 'modules)) 'source)
      "graph.fixture.selected"))))

(test-case "removed qualified provider export fails closed instead of typing as Any"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defn replacement [x :- String] :- String x)\n")))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        consumer-string-call))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-false (world-check-result-ok? result))
     (check-regexp-match
      #rx"world\\.provider does not export f"
      (diagnostic-text result))
     (check-true
      (andmap
       (lambda (module)
         (not (checked-world-module-emitted module)))
       (world-check-result-modules result))))))

(test-case "CLI rejection keeps stdout empty so no partial world can publish"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defn replacement [x :- String] :- String x)\n")))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        consumer-string-call))
     (define-values (status out err)
       (run-world-cli
        "--check"
        "world.consumer"
        (path->string provider-edn)
        (path->string consumer-edn)))
     (check-equal? status 1)
     (check-equal? out "")
     (check-regexp-match
      #rx"world\\.provider does not export f"
      err)
     (check-regexp-match
      #rx"nothing emitted"
      err))))

(test-case "removed qualified nominal types fail closed in alias and full-ns spellings"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "type-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defrecord Replacement [name :- String])\n")))
     (for ([type-name (in-list '("p/User" "world.provider/User"))]
           [stem (in-list '("missing-alias-type" "missing-full-type"))])
       (define consumer-edn
         (candidate!
          root stem consumer-source
          (string-append
           "#lang beagle/clj\n"
           "(ns world.consumer (:require [world.provider :as p]))\n"
           (format
            "(defn keep [x :- ~a] :- ~a x)\n"
            type-name
            type-name))))
       (define result
         (check-edn-world (list provider-edn consumer-edn)))
       (check-false (world-check-result-ok? result))
       (check-regexp-match
        #rx"world\\.provider does not export type User"
        (diagnostic-text result)))
     (define cli-consumer
       (candidate!
        root "missing-cli-type" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- p/User] :- p/User x)\n")))
     (define-values (status out err)
       (run-world-cli
        "--check"
        "world.consumer"
        (path->string provider-edn)
        (path->string cli-consumer)))
     (check-equal? status 1)
     (check-equal? out "")
     (check-regexp-match
      #rx"world\\.provider does not export type User"
      err)
     (check-regexp-match #rx"nothing emitted" err))))

(test-case "exported qualified nominal type checks through the candidate interface"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "record-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defrecord User [name :- String])\n")))
     (define consumer-edn
       (candidate!
        root "record-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- p/User] :- p/User x)\n")))
     (define result
       (check-edn-world (list consumer-edn provider-edn)))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result))
     (define provider
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.provider))
         module))
     (check-true
       (module-interface-type-export?
       (checked-world-module-interface provider)
       'User)))))

(test-case "cross-module aliases expand transparently in source order"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "alias-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defalias Text String)\n"
         "(defalias MaybeText (U Text Nil))\n")))
     (define consumer-edn
       (candidate!
        root "alias-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn none [] :- p/MaybeText nil)\n"
         "(defn full [] :- world.provider/Text \"ok\")\n")))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result)))))

(test-case "exported alias to provider record keeps provider-qualified identity"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "record-alias-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defrecord User [name :- String])\n"
         "(defalias Users (Vec User))\n")))
     (define consumer-edn
       (candidate!
        root "record-alias-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [xs :- p/Users] :- p/Users xs)\n")))
     (define result
       (check-edn-world (list consumer-edn provider-edn)))
     (check-true (world-check-result-ok? result) (diagnostic-text result))
     (define expected '(app Vec (prim world.provider/User)))
     (define provider
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.provider))
         module))
     (define consumer
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.consumer))
         module))
     (define users-export
       (module-interface-type-export-ref
        (checked-world-module-interface provider)
        'Users))
     (check-equal?
      (type->canonical-datum
       (interface-type-export-expansion users-export))
      expected)
     (define keep
       (for/first
           ([form
             (in-list
              (program-forms
               (checked-world-module-program consumer)))]
            #:when
            (and (defn-form? form)
                 (eq? (defn-form-name form) 'keep)))
         form))
     (check-equal?
      (type->canonical-datum
       (param-type (car (defn-form-params keep))))
      expected)
     (check-equal?
      (type->canonical-datum (defn-form-return-type keep))
      expected))))

(test-case "exported alias to provider parametric type keeps canonical ctor"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "param-alias-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defunion (Box T) (BoxValue [value :- T]))\n"
         "(defalias TextBox (Box String))\n")))
     (define consumer-edn
       (candidate!
        root "param-alias-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [box :- p/TextBox] :- p/TextBox box)\n")))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-true (world-check-result-ok? result) (diagnostic-text result))
     (define expected '(app world.provider/Box (prim String)))
     (define provider
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.provider))
         module))
     (define consumer
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.consumer))
         module))
     (define alias-export
       (module-interface-type-export-ref
        (checked-world-module-interface provider)
        'TextBox))
     (check-equal?
      (type->canonical-datum
       (interface-type-export-expansion alias-export))
      expected)
     (define keep
       (for/first
           ([form
             (in-list
              (program-forms
               (checked-world-module-program consumer)))]
            #:when
            (and (defn-form? form)
                 (eq? (defn-form-name form) 'keep)))
         form))
     (check-equal?
      (type->canonical-datum
       (param-type (car (defn-form-params keep))))
      expected)
     (check-equal?
      (type->canonical-datum (defn-form-return-type keep))
      expected))))

(test-case "record alias re-export preserves the origin provider identity"
  (with-world-files
   (lambda (root origin-source consumer-source)
     (define bridge-source (build-path root "world" "bridge.bclj"))
     (define origin-edn
       (candidate!
        root "record-origin" origin-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.origin)\n"
         "(defrecord User [name :- String])\n")))
     (define bridge-edn
       (candidate!
        root "record-bridge" bridge-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.bridge (:require [world.origin :as local]))\n"
         "(defalias Users (Vec local/User))\n")))
     (define consumer-edn
       (candidate!
        root "record-reexport-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.bridge :as b]))\n"
         "(defn keep [xs :- b/Users] :- b/Users xs)\n")))
     (define result
       (check-edn-world (list consumer-edn bridge-edn origin-edn)))
     (check-true (world-check-result-ok? result) (diagnostic-text result))
     (define expected '(app Vec (prim world.origin/User)))
     (define bridge
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.bridge))
         module))
     (define consumer
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.consumer))
         module))
     (define users-export
       (module-interface-type-export-ref
        (checked-world-module-interface bridge)
        'Users))
     (check-equal?
      (type->canonical-datum
       (interface-type-export-expansion users-export))
      expected)
     (define keep
       (for/first
           ([form
             (in-list
              (program-forms
               (checked-world-module-program consumer)))]
            #:when
            (and (defn-form? form)
                 (eq? (defn-form-name form) 'keep)))
         form))
     (check-equal?
      (type->canonical-datum
       (param-type (car (defn-form-params keep))))
      expected)
     (check-equal?
      (type->canonical-datum (defn-form-return-type keep))
      expected))))

(test-case "parametric alias re-export preserves the origin provider ctor"
  (with-world-files
   (lambda (root origin-source consumer-source)
     (define bridge-source (build-path root "world" "bridge.bclj"))
     (define origin-edn
       (candidate!
        root "param-origin" origin-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.origin)\n"
         "(defunion (Box T) (BoxValue [value :- T]))\n")))
     (define bridge-edn
       (candidate!
        root "param-bridge" bridge-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.bridge (:require [world.origin :as local]))\n"
         "(defalias TextBox (local/Box String))\n")))
     (define consumer-edn
       (candidate!
        root "param-reexport-consumer" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.bridge :as b]))\n"
         "(defn keep [box :- b/TextBox] :- b/TextBox box)\n")))
     (define result
       (check-edn-world (list bridge-edn origin-edn consumer-edn)))
     (check-true (world-check-result-ok? result) (diagnostic-text result))
     (define expected '(app world.origin/Box (prim String)))
     (define bridge
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.bridge))
         module))
     (define consumer
       (for/first
           ([module (in-list (world-check-result-modules result))]
            #:when
            (eq? (checked-world-module-namespace module) 'world.consumer))
         module))
     (define alias-export
       (module-interface-type-export-ref
        (checked-world-module-interface bridge)
        'TextBox))
     (check-equal?
      (type->canonical-datum
       (interface-type-export-expansion alias-export))
      expected)
     (define keep
       (for/first
           ([form
             (in-list
              (program-forms
               (checked-world-module-program consumer)))]
            #:when
            (and (defn-form? form)
                 (eq? (defn-form-name form) 'keep)))
         form))
     (check-equal?
      (type->canonical-datum
       (param-type (car (defn-form-params keep))))
      expected)
     (check-equal?
      (type->canonical-datum (defn-form-return-type keep))
      expected))))

(test-case "qualified parametric exports prove existence and arity"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "param-provider" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defunion (Box T) (BoxValue [value :- T]))\n")))
     (define good-edn
       (candidate!
        root "param-good" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- (p/Box String)] :- (p/Box String) x)\n")))
     (define good
       (check-edn-world (list good-edn provider-edn)))
     (check-true (world-check-result-ok? good) (diagnostic-text good))
     (define missing-edn
       (candidate!
        root "param-missing" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- (p/Missing String)] :- String \"no\")\n")))
     (define missing
       (check-edn-world (list provider-edn missing-edn)))
     (check-false (world-check-result-ok? missing))
     (check-regexp-match
      #rx"world\\.provider does not export type Missing"
      (diagnostic-text missing))
     (define arity-edn
       (candidate!
        root "param-arity" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- (p/Box String Int)] :- String \"no\")\n")))
     (define arity
       (check-edn-world (list provider-edn arity-edn)))
     (check-false (world-check-result-ok? arity))
     (check-regexp-match
      #rx"p/Box expects 1 argument, got 2"
      (diagnostic-text arity))
     (define unapplied-edn
       (candidate!
        root "param-unapplied" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn keep [x :- p/Box] :- String \"no\")\n")))
     (define unapplied
       (check-edn-world (list provider-edn unapplied-edn)))
     (check-false (world-check-result-ok? unapplied))
     (check-regexp-match
      #rx"p/Box expects 1 argument, got 0"
      (diagnostic-text unapplied)))))

(test-case "interface v2 rejects stale schemas and malformed export arity"
  (with-world-files
   (lambda (_root provider-source consumer-source)
     (write-text!
      provider-source
      (string-append
       "#lang beagle/clj\n"
       "(ns world.provider)\n"
       "(defunion (Box T) (BoxValue [value :- T]))\n"))
     (write-text!
      consumer-source
      (string-append
       "#lang beagle/clj\n"
       "(ns world.consumer (:require [world.provider :as p]))\n"
       "(defn keep [x :- (p/Box String)] :- (p/Box String) x)\n"))
     (define provider-stxs (read-beagle-syntax provider-source))
     (define provider-datums (map syntax->datum provider-stxs))
     (define valid-interface
       (program->module-interface
        (parse-program provider-stxs #:source-path provider-source)
        #:source-id (path->string provider-source)
        #:datums provider-datums))
     (define (parse-consumer interface)
       (define candidate
         (module-source
          'world.provider
          (path->string provider-source)
          provider-stxs
          provider-datums
          interface))
       (parse-program
        (read-beagle-syntax consumer-source)
        #:source-path consumer-source
        #:module-resolver
        (lambda (namespace _importer-source)
          (and (eq? namespace 'world.provider) candidate))))
     (define stale-interface
       (struct-copy
        module-interface
        valid-interface
        [schema-version 1]))
     (check-exn
      #rx"uses interface schema v1; this compiler requires v2"
      (lambda () (parse-consumer stale-interface)))
     (define valid-box
       (module-interface-type-export-ref valid-interface 'Box))
     (define malformed-exports
       (hash-copy (module-interface-type-exports valid-interface)))
     (hash-set!
      malformed-exports
      'Box
      (struct-copy
       interface-type-export
       valid-box
       [arity 'one]))
     (define malformed-interface
       (struct-copy
        module-interface
        valid-interface
        [type-exports malformed-exports]))
     (check-exn
      #rx"Box: arity must be an exact nonnegative integer, got 'one"
      (lambda () (parse-consumer malformed-interface))))))

(test-case "type aliases and parametric names cannot leak between parses"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define aliases-edn
       (candidate!
        root "leak-source" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.aliases)\n"
         "(defalias Leaked (U String Nil))\n")))
     (define first (check-edn-world (list aliases-edn)))
     (check-true (world-check-result-ok? first) (diagnostic-text first))
     (define unrelated-edn
       (candidate!
        root "leak-sink" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.unrelated)\n"
         "(defn accidental [] :- Leaked nil)\n")))
     (define second (check-edn-world (list unrelated-edn)))
     (check-false
      (world-check-result-ok? second)
      "a prior parse must not license an unrelated bare alias"))))

(test-case "interface v2 forbids interface-only consumer pruning"
  (with-world-files
   (lambda (root provider-source _consumer-source)
     (check-equal? INTERFACE-SCHEMA-VERSION 2)
     (check-false INTERFACE-DIGEST-CONSUMER-PRUNING-SAFE?)
     (define plain-edn
       (candidate!
        root "plain-dynamic" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(def *setting* \"default\")\n")))
     (define dynamic-edn
       (candidate!
        root "marked-dynamic" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(def ^:dynamic *setting* \"default\")\n")))
     (define (digests edn)
       (define result (check-edn-world (list edn) #:emit? #f))
       (check-true (world-check-result-ok? result)
                   (diagnostic-text result))
       (values
        (module-interface-digest
         (checked-world-module-interface
          (car (world-check-result-modules result))))
        (world-check-result-world-digest result)))
     (define-values (plain-interface plain-world) (digests plain-edn))
     (define-values (dynamic-interface dynamic-world) (digests dynamic-edn))
     (check-equal?
      plain-interface
      dynamic-interface
      "^:dynamic is not yet an interface-pruning key")
     (check-not-equal?
      plain-world
      dynamic-world
      "the full world receipt must still force reverse-closure checking"))))

(define raising-provider
  (string-append
   "#lang beagle/clj\n"
   "(ns world.provider)\n"
   "(defunion :throwable RewriteError\n"
   "  (RewriteFailure [message :- String path :- String refusal :- Bool]))\n"
   "(defn classify [path :- String] :- String\n"
   "  :raises RewriteError\n"
   "  (throw (ex-info \"missing\" {:path path :refusal true})))\n"))

(test-case "imported :raises remains visible and rejects an unhandled call"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source raising-provider))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn use [path :- String] :- String (p/classify path))\n")))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-false (world-check-result-ok? result))
     (check-regexp-match
      #rx"p/classify raises RewriteError and must be wrapped in check or rescue"
      (diagnostic-text result)))))

(test-case "fully-qualified imported :raises is also enforced"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source raising-provider))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider]))\n"
         "(defn use [path :- String] :- String\n"
         "  (world.provider/classify path))\n")))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-false (world-check-result-ok? result))
     (check-regexp-match
      #rx"world\\.provider/classify raises RewriteError"
      (diagnostic-text result)))))

(test-case "rescuing an imported raising call makes the coherent world pass"
  (with-world-files
   (lambda (root provider-source consumer-source)
     (define provider-edn
       (candidate!
        root "provider-candidate" provider-source raising-provider))
     (define consumer-edn
       (candidate!
        root "consumer-candidate" consumer-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.consumer (:require [world.provider :as p]))\n"
         "(defn use [path :- String] :- String\n"
         "  (rescue (p/classify path) err (:message err)))\n")))
     (define result
       (check-edn-world (list provider-edn consumer-edn)))
     (check-true
      (world-check-result-ok? result)
      (diagnostic-text result)))))

(test-case "interface digest ignores bodies but changes with signatures"
  (with-world-files
   (lambda (root provider-source _consumer-source)
     (define same-a
       (candidate!
        root "same-a" provider-source provider-string-signature))
     (define same-b
       (candidate!
        root "same-b" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defn f [x :- String] :- String (str x))\n")))
     (define changed
       (candidate!
        root "changed" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defn f [x :- Int] :- Int x)\n")))
     (define schema-a
       (candidate!
        root "schema-a" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defunion Choice Left Right)\n")))
     (define schema-b
       (candidate!
        root "schema-b" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defunion Choice Left Middle Right)\n")))
     (define macro-a
       (candidate!
        root "macro-a" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defmacro passthrough [x] x)\n")))
     (define macro-b
       (candidate!
        root "macro-b" provider-source
        (string-append
         "#lang beagle/clj\n"
         "(ns world.provider)\n"
         "(defmacro passthrough [x] `(do ~x))\n")))
     (define (digests edn)
       (define result (check-edn-world (list edn) #:emit? #f))
       (check-true (world-check-result-ok? result)
                   (diagnostic-text result))
       (values
        (module-interface-digest
         (checked-world-module-interface
          (car (world-check-result-modules result))))
        (world-check-result-world-digest result)))
     (define-values (interface-a world-a) (digests same-a))
     (define-values (interface-b world-b) (digests same-b))
     (define-values (interface-changed _world-changed) (digests changed))
     (define-values (interface-schema-a _world-schema-a) (digests schema-a))
     (define-values (interface-schema-b _world-schema-b) (digests schema-b))
     (define-values (interface-macro-a _world-macro-a) (digests macro-a))
     (define-values (interface-macro-b _world-macro-b) (digests macro-b))
     (check-equal? interface-a interface-b)
     (check-not-equal? world-a world-b
                       "body-only changes must alter the exact world receipt")
     (check-not-equal? interface-a interface-changed)
     (check-not-equal?
      interface-schema-a interface-schema-b
      "union member evolution must invalidate the public interface")
     (check-not-equal?
      interface-macro-a interface-macro-b
      "macro body evolution must invalidate all conservative consumers"))))
