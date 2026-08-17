#lang racket/base

;; G-A — cross-module `binding` of a required module's `^:dynamic` var.
;;
;; Clojure binds any other-namespace dynamic var (`(binding [other/*x* v] ...)`
;; is standard); beagle used to REJECT it ("a/*v* is not a dynamic var") because
;; the checker only consulted the CURRENT module's dynamic-var set, never the
;; required module's. The importer now carries each imported `^:dynamic` var's
;; dynamic-ness (keyed by the use-site name), so `binding` resolves it across the
;; module boundary — matching Clojure. This blocked store's resolver-woven daemon
;; port (handlers bind resolve/* dynvars cross-module). Logged to
;; hallucinations.jsonl as a surface-coherence divergence.
;;
;; The fix must stay PRECISE: binding a non-dynamic imported var is still an error.

(require rackunit
         racket/runtime-path
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/dynvar-xmodule")

(define fixture-root
  (make-module-source-root-v0 "fixtures/dynvar-xmodule" fixtures-dir))

(define (fixture-program name)
  (define source-id (string-append "fixtures/dynvar-xmodule/" name))
  (define closure
    (resolve-module-source-closure
     (list (module-source-input source-id (build-path fixtures-dir name)))
     (list fixture-root)))
  (define checked (check-module-source-closure closure #:emit? #f))
  (unless (overlay-check-result-ok? checked)
    (error 'beagle "~a"
           (overlay-diagnostic-message
            (car (overlay-check-result-diagnostics checked)))))
  (checked-overlay-module-program
   (for/first ([module (in-list (overlay-check-result-modules checked))]
               #:when (equal? (checked-overlay-module-source module) source-id))
     module)))

(define (check-file name)
  (fixture-program name))

(test-case "a requiring module can `binding` an imported ^:dynamic var (G-A, matches Clojure)"
  (check-not-exn (lambda () (check-file "ok.bclj"))))

(test-case "binding a NON-dynamic imported var is still rejected (fix stays precise)"
  (check-exn #rx"not a dynamic var"
             (lambda () (check-file "bad.bclj"))))

;; Coverage for the requiring module living in a DIFFERENT directory than the
;; dynvar's module (resolved via the module-path walk-up) — the same-dir-only
;; case was the original test gap (flagged by store-2). The directly-resolvable
;; cross-dir case must populate imported-dynamic-vars too.
(test-case "cross-DIRECTORY binding of an imported ^:dynamic var also type-checks"
  (check-not-exn (lambda () (check-file "sub/xconsumer.bclj"))))

;; The repaired shape store-2 actually hit: cross-DIRECTORY *and* via a macro whose
;; syntax-quoted body binds the imported dynvar. The expander must keep the
;; use-site alias (`p/*v*`, not `prov/*v*`) so the use-site-keyed import set
;; resolves its dynamic-ness post-expansion. A "macro qualifies past the use-site
;; key" regression — or a same-dir-only one — turns this red.
(test-case "cross-DIRECTORY binding via a macro-expanded `binding` type-checks"
  (check-not-exn (lambda () (check-file "sub/mac-xconsumer.bclj"))))
