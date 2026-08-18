#lang racket/base

;; One structured-diagnostic vertical slice. The same type-mismatch fact is
;; emitted by every live source profile; the human line and V2 JSON are
;; projections of that fact, while the default checker result remains unchanged.

(require rackunit
         json
         racket/file
         racket/list
         racket/string
         beagle/private/ast
         beagle/private/check
         beagle/private/check-all
         beagle/private/parse
         beagle/private/type-facts-v1)

(define TARGETS
  (list (cons 'core (cons "bgl" "#lang beagle"))
        (cons 'hosted-clj (cons "bclj" "#lang beagle/clj"))
        (cons 'hosted-js (cons "bjs" "#lang beagle/js"))
        (cons 'hosted-nix (cons "bnix" "#lang beagle/nix"))))

(define (source-for lang)
  (string-append
   lang "\n"
   "(ns structured.diagnostics)\n"
   "(defn g [(n Int)] Nil nil)\n"
   "(defn f [] Nil\n"
   "  (g \"boom\"))\n"))

(define (capture-diagnostic path)
  (with-handlers ([beagle-diagnostic? values])
    (type-check! (parse-program/file path))
    #f))

(define (with-target-file target thunk)
  (define extension (car (cdr target)))
  (define language (cdr (cdr target)))
  (define path
    (make-temporary-file
     (format "structured-diagnostic-~a-~a-~~a.~a"
             (car target) extension extension)))
  (call-with-output-file path
    (lambda (out) (display (source-for language) out))
    #:exists 'truncate/replace)
  (dynamic-wind void (lambda () (thunk path)) (lambda () (delete-file path))))

(test-case "type-mismatch fact schema has identity, facets, evidence, and no repair"
  (with-target-file (car TARGETS)
    (lambda (path)
      (define diagnostic (capture-diagnostic path))
      (check-pred beagle-diagnostic? diagnostic)
      (define fact (beagle-diagnostic-fact diagnostic))
      (check-pred diagnostic-fact-v2? fact)
      (check-equal? (diagnostic-fact-v2-code fact) "E002")
      (check-equal? (semantic-fact-v1-kind (diagnostic-fact-v2-fact fact))
                    "BeagleDiagnosticV2")
      (check-equal? (semantic-fact-v1-schema-version
                     (diagnostic-fact-v2-fact fact))
                    1)
      (check-true (string-prefix?
                   (semantic-fact-v1-id (diagnostic-fact-v2-fact fact))
                   "sha256:"))
      (check-equal? (vector-length (diagnostic-fact-v2-source-anchors fact)) 1)
      (define anchor
        (vector-ref (diagnostic-fact-v2-source-anchors fact) 0))
      (check-true (string-prefix?
                   (diagnostic-source-anchor-v2-source-text-fact-id anchor)
                   "sha256:"))
      (check-true (string-prefix?
                   (diagnostic-source-anchor-v2-source-semantic-fact-id anchor)
                   "sha256:"))
      (check-true
       (andmap (lambda (id) (string-prefix? id "sha256:"))
               (vector->list (diagnostic-fact-v2-relevant-fact-ids fact))))
      (check-false (diagnostic-fact-v2-repair fact))
      (check-pred attestation-v1? (diagnostic-fact-v2-attestation fact))
      (check-pred derivation-edge-v1? (diagnostic-fact-v2-derivation fact)))))

(test-case "current human message is a rendering of the authoritative fact"
  (with-target-file (cadr TARGETS)
    (lambda (path)
      (define diagnostic (capture-diagnostic path))
      (define fact (beagle-diagnostic-fact diagnostic))
      (define rendered (diagnostic-fact-v2-render-message fact))
      (check-equal? rendered (exn-message diagnostic))
      (define current-human (format-diagnostic diagnostic #f path))
      (check-equal? (car (string-split current-human "\n"))
                    (format "error[E002]: ~a" rendered))
      (check-true (string-contains?
                   (diagnostic-fact-v2-render-human fact)
                   "profile: hosted-clj")))))

(test-case "V2 JSONL and human renderings preserve one semantic cause"
  (for ([target (in-list TARGETS)])
    (with-target-file target
      (lambda (path)
        (define diagnostic (capture-diagnostic path))
        (define fact (beagle-diagnostic-fact diagnostic))
        (define v2 (diagnostic->v2-json diagnostic #f path))
        (check-equal? (hash-ref v2 'kind) "BeagleDiagnosticV2")
        (check-equal? (hash-ref v2 'code) "E002")
        (check-equal? (hash-ref (hash-ref v2 'typedPayload)
                                'classification)
                      "type-error")
        (check-equal? (hash-ref (hash-ref v2 'typedPayload)
                                'classification)
                      (hash-ref (beagle-diagnostic-details diagnostic)
                                'cause))
        (check-true (string-contains?
                     (hash-ref v2 'human)
                     (diagnostic-fact-v2-render-message fact)))
        (check-not-exn (lambda () (jsexpr->string v2)))))))
