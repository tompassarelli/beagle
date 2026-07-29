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
