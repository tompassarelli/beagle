#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         beagle/lang/reader-impl
         beagle/private/ast
         beagle/private/check
         beagle/private/module-interface
         beagle/private/parse
         beagle/private/type-facts-v1)

(define SOURCE
  (string-append
   "(ns evidence.edges)\n"
   "(define-target clj)\n"
   "(defn leaf [(x Int)] Int x)\n"
   "(defn checked [(x Int)] Int (leaf x))\n"))

(define (read-forms source)
  (parameterize ([current-readtable beagle-readtable])
    (define input (open-input-string source))
    (let loop ()
      (define form (read-syntax 'evidence-edges-v1 input))
      (if (eof-object? form) '() (cons form (loop))))))

(define (compile-source source epoch)
  (define prog (parse-program (read-forms source)))
  (parameterize ([current-check-profile 2]
                 [current-type-facts-checker-epoch-v1 epoch])
    (type-check! prog)
    (define interface (program->module-interface prog))
    (values prog interface (program-shadow-evidence-edges prog))))

(define (definition-edge edges id)
  (for/first ([edge (in-vector edges)]
              #:when (equal? (derivation-edge-v1-claim edge) id))
    edge))

(define (checked-claim-id prog)
  (hash-ref (program-shadow-definition-fact-ids prog) 'checked))

(define tests
  (test-suite
   "type-fact evidence edges"

   (test-case "checked definition emits a complete semantic evidence chain"
     (define-values (prog interface edges)
       (compile-source SOURCE "checker:epoch-1"))
     (define checked-id (checked-claim-id prog))
     (define leaf-id
       (hash-ref (program-shadow-definition-fact-ids prog) 'leaf))
     (define edge (definition-edge edges checked-id))
     (check-true (derivation-edge-v1? edge))
     (check-equal? (derivation-edge-v1-using edge) (vector leaf-id))
     (check-true
      (string-prefix? (derivation-edge-v1-checker-identity edge) "sha256:"))
     (check-equal? checked-id
                   (attestation-v1-semantic-fact-id
                    (derivation-edge-v1-produced edge)))
     (check-equal? "checker:epoch-1"
                   (attestation-v1-checker-epoch
                    (derivation-edge-v1-produced edge)))
     (check-true (module-interface? interface))
     (check-equal? 3 (vector-length edges)))

   (test-case "identical recompiles produce identical evidence edges"
     (define-values (_prog-a _interface-a edges-a)
       (compile-source SOURCE "checker:epoch-1"))
     (define-values (_prog-b _interface-b edges-b)
       (compile-source SOURCE "checker:epoch-1"))
     (check-equal? (vector->list edges-a) (vector->list edges-b))
     (check-equal?
      (for/list ([edge (in-vector edges-a)])
        (derivation-edge-v1-canonical-bytes edge))
      (for/list ([edge (in-vector edges-b)])
        (derivation-edge-v1-canonical-bytes edge))))

   (test-case "epoch changes re-attestation but not semantic chain identities"
     (define-values (prog-a _interface-a edges-a)
       (compile-source SOURCE "checker:epoch-1"))
     (define-values (prog-b _interface-b edges-b)
       (compile-source SOURCE "checker:epoch-2"))
     (define before (definition-edge edges-a (checked-claim-id prog-a)))
     (define after (definition-edge edges-b (checked-claim-id prog-b)))
     (check-equal? (derivation-edge-v1-claim before)
                   (derivation-edge-v1-claim after))
     (check-equal? (derivation-edge-v1-checker-identity before)
                   (derivation-edge-v1-checker-identity after))
     (check-equal? (derivation-edge-v1-using before)
                   (derivation-edge-v1-using after))
     (check-not-equal? (attestation-v1-id (derivation-edge-v1-produced before))
                       (attestation-v1-id (derivation-edge-v1-produced after)))
     (check-not-equal? (derivation-edge-v1-id before)
                       (derivation-edge-v1-id after)))))

(run-tests tests)
