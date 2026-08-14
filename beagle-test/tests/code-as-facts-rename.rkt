#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/match
         racket/string
         beagle/private/facts-roundtrip)

;; The active tier owns the cheap structural floor: selected symbol leaves can
;; change while the recursive fact graph and every unrelated graph remain
;; intact. Scope resolution and qualified-reader selection stay in the focused
;; Fram-backed shell gate; duplicating that engine here would test a substitute.
(define (rename-symbol-facts triples replacements)
  (define changed 0)
  (define renamed
    (for/list ([triple (in-list triples)])
      (match triple
        [(list subject "v" (? symbol? value))
         (if (hash-has-key? replacements value)
             (begin
               (set! changed (add1 changed))
               (list subject "v" (hash-ref replacements value)))
             triple)]
        [_ triple])))
  (values renamed changed))

(define provider
  '(beagle-file
    (define-target clj)
    (ns facts.provider)
    (defn helper #((x Int)) Int (+ x 1))
    (defn caller #((x Int)) Int (helper x))))

(define consumer
  '(beagle-file
    (define-target clj)
    (ns facts.consumer (require facts.provider :as provider))
    (defn use #((x Int)) Int (provider/helper x))))

(define collision
  '(beagle-file
    (define-target clj)
    (ns facts.collision)
    (defn helper #((x Int)) Int (* x 2))))

(define (project-and-rename datum replacements)
  (define-values (root triples) (datum->facts datum))
  (define-values (renamed changed)
    (rename-symbol-facts triples replacements))
  (values (facts->datum root renamed) changed (length triples) (length renamed)))

(run-tests
 (test-suite
  "code-as-facts rename structural floor"

  (test-case "binding and qualified reader rename through recursive facts"
    (define-values (renamed-provider provider-count provider-before provider-after)
      (project-and-rename provider (hash 'helper 'safe-add)))
    (define-values (renamed-consumer consumer-count consumer-before consumer-after)
      (project-and-rename consumer (hash 'provider/helper 'provider/safe-add)))
    (define-values (untouched-collision collision-count collision-before collision-after)
      (project-and-rename collision (hash)))

    (check-equal? provider-count 2)
    (check-equal? consumer-count 1)
    (check-equal? collision-count 0)
    (check-equal? provider-before provider-after)
    (check-equal? consumer-before consumer-after)
    (check-equal? collision-before collision-after)
    (check-equal? untouched-collision collision)

    (define provider-source (datum->pretty renamed-provider))
    (define consumer-source (datum->pretty renamed-consumer))
    (check-true
     (string-contains? provider-source
                       "(defn safe-add [(x Int)] Int (+ x 1))"))
    (check-true
     (string-contains? provider-source
                       "(defn caller [(x Int)] Int (safe-add x))"))
    (check-true
     (string-contains? consumer-source "(provider/safe-add x)"))
    (check-false (string-contains? provider-source "helper"))
    (check-false (string-contains? consumer-source "provider/helper")))))
