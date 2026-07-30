#lang racket/base

;; doc-fill: splice compiler-rendered spans into committed docs, in place.
;;
;; A doc says what it always said; the parts that ROT (the target list, the
;; extension table, the pipeline diagram) are wrapped in markers and owned by
;; the compiler:
;;
;;   block   <!-- beagle:langs table -->
;;           …rendered…
;;           <!-- /beagle:langs -->
;;
;;   inline  …compiles to idiomatic <!-- beagle:langs names -->Clojure, …<!--
;;           /beagle:langs -->.
;;
;; A view that renders one line splices INLINE (no newlines introduced); a view
;; that renders several lines becomes a BLOCK. The view decides — a doc never
;; picks a shape, so the same marker cannot mean two things in two files.
;;
;; Sites are listed in contrib/docfill/sites.rktd (sibling of
;; contrib/downstream/consumers.rktd). `--check` exits 3 on drift, the same
;; convention as bin/beagle-downstream, and beagle-test/tests/docfill.rkt runs
;; that comparison as an ordinary check-equal? so the existing `raco test` CI
;; step is the gate — no new CI wiring.

(require racket/string
         racket/list
         racket/file
         racket/path
         racket/runtime-path
         "langs.rkt")

(define-runtime-path beagle-root-default "../..")

(define (default-root) (simplify-path beagle-root-default))

(define (default-registry root)
  (build-path root "contrib" "docfill" "sites.rktd"))

;; kind : 'markers — fill every marked span in place
;;        'generated — the whole file IS one view's render
(struct site (path kind view note) #:transparent)

(define (parse-site form)
  (unless (and (pair? form) (eq? (car form) 'site))
    (error 'doc-fill "registry entry is not a (site …) form: ~v" form))
  (define (field name)
    (define hit (assq name (cdr form)))
    (and hit (cadr hit)))
  (define path (field 'path))
  (unless (string? path)
    (error 'doc-fill "registry entry has no (path \"…\"): ~v" form))
  (define kind (or (field 'kind) 'markers))
  (unless (memq kind '(markers generated))
    (error 'doc-fill "site ~a: unknown kind ~v (markers | generated)" path kind))
  (define view (field 'view))
  (when (and (eq? kind 'generated) (not view))
    (error 'doc-fill "site ~a: kind generated needs a (view NAME)" path))
  (site path kind (and view (if (symbol? view) view (string->symbol view)))
        (field 'note)))

(define (load-sites [registry #f] #:root [root (default-root)])
  (define path (or registry (default-registry root)))
  (define forms
    (call-with-input-file path
      (lambda (in)
        (let loop ()
          (define d (read in))
          (if (eof-object? d) '() (cons d (loop)))))))
  (define entries
    (cond
      [(null? forms) '()]
      ;; the registry is one parenthesised list of (site …) forms
      [(and (= 1 (length forms)) (list? (car forms))) (car forms)]
      [else forms]))
  (map parse-site entries))

;; --- marker machinery ------------------------------------------------------

(define OPEN-RX  #px"<!--\\s*beagle:langs\\s+([A-Za-z][A-Za-z0-9_-]*)\\s*-->")
(define CLOSE-RX #px"<!--\\s*/beagle:langs\\s*-->")
(define SPAN-RX
  #px"(?s:<!--\\s*beagle:langs\\s+([A-Za-z][A-Za-z0-9_-]*)\\s*-->.*?<!--\\s*/beagle:langs\\s*-->)")

(define (rendered-body view-name where)
  (define out (render-view view-name))
  (unless out
    (error 'doc-fill "~a: unknown view '~a' (one of: ~a)"
           where view-name (string-join (view-names-list) ", ")))
  (if (string-contains? out "\n")
      (string-append "\n" out "\n")     ; block
      out))                              ; inline

;; Fill every marked span; returns the new text. Fails loudly on an unbalanced
;; marker pair rather than silently leaving a doc half-owned.
(define (fill-markers text where)
  (define opens (length (regexp-match* OPEN-RX text)))
  (define closes (length (regexp-match* CLOSE-RX text)))
  (unless (= opens closes)
    (error 'doc-fill "~a: ~a opening marker(s) but ~a closing marker(s)"
           where opens closes))
  (when (zero? opens)
    (error 'doc-fill "~a: registered as a doc-fill site but has no beagle:langs marker"
           where))
  (regexp-replace*
   SPAN-RX text
   (lambda (whole view-name)
     (string-append "<!-- beagle:langs " view-name " -->"
                    (rendered-body view-name where)
                    "<!-- /beagle:langs -->"))))

;; --- per-site expected content --------------------------------------------

(define (site-file root s) (build-path root (site-path s)))

;; The authority every consumer compares against: what this file SHOULD contain.
(define (expected-content root s)
  (case (site-kind s)
    [(generated)
     (define out (render-view (site-view s)))
     (unless out
       (error 'doc-fill "~a: unknown view '~a'" (site-path s) (site-view s)))
     (string-append out "\n")]
    [else
     (fill-markers (file->string (site-file root s)) (site-path s))]))

(define (site-drift? root s)
  (not (string=? (file->string (site-file root s)) (expected-content root s))))

;; The marked spans of a file, in order, as (view . span-text) pairs. The drift
;; test compares THESE rather than whole files: a failure then prints the ~10
;; lines the compiler owns instead of a 400-line README twice over.
(define (marked-spans text)
  (for/list ([m (in-list (regexp-match* SPAN-RX text #:match-select values))])
    (cons (cadr m) (car m))))

;; What a site's spans SHOULD be. For a `generated` site the whole file is the
;; span, so the two comparisons stay uniform.
(define (expected-spans root s)
  (case (site-kind s)
    [(generated) (list (cons (symbol->string (site-view s)) (expected-content root s)))]
    [else (marked-spans (expected-content root s))]))

(define (actual-spans root s)
  (case (site-kind s)
    [(generated) (list (cons (symbol->string (site-view s))
                             (file->string (site-file root s))))]
    [else (marked-spans (file->string (site-file root s)))]))

(provide (struct-out site)
         load-sites
         default-root
         default-registry
         site-file
         expected-content
         site-drift?
         marked-spans
         expected-spans
         actual-spans)

;; --- CLI -------------------------------------------------------------------

(module+ main
  (define check? #f)
  (define registry #f)
  (define root (default-root))
  (let loop ([args (vector->list (current-command-line-arguments))])
    (cond
      [(null? args) (void)]
      [(equal? (car args) "--check") (set! check? #t) (loop (cdr args))]
      [(equal? (car args) "--registry")
       (when (null? (cdr args))
         (eprintf "beagle doc-fill: --registry needs a path\n") (exit 2))
       (set! registry (cadr args)) (loop (cddr args))]
      [(equal? (car args) "--root")
       (when (null? (cdr args))
         (eprintf "beagle doc-fill: --root needs a path\n") (exit 2))
       (set! root (cadr args)) (loop (cddr args))]
      [(member (car args) '("--help" "-h"))
       (displayln "usage: beagle doc-fill [--check] [--registry PATH] [--root PATH]")
       (displayln "  fills <!-- beagle:langs VIEW --> spans from the canonical target table")
       (displayln "  --check: report drift and exit 3 instead of writing")
       (exit 0)]
      [else (eprintf "beagle doc-fill: unknown argument '~a'\n" (car args)) (exit 2)]))

  (define sites
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "beagle doc-fill: ~a\n" (exn-message e))
                                 (exit 2))])
      (load-sites registry #:root root)))

  (define drifted
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "beagle doc-fill: ~a\n" (exn-message e))
                                 (exit 2))])
      (for/list ([s (in-list sites)]
                 #:when (site-drift? root s))
        s)))

  (cond
    [check?
     (cond
       [(null? drifted)
        (printf "doc-fill: ~a site(s) in sync\n" (length sites))
        (exit 0)]
       [else
        (eprintf "doc-fill: ~a of ~a site(s) DRIFTED from beagle-lib/private/targets.rkt:\n"
                 (length drifted) (length sites))
        (for ([s (in-list drifted)]) (eprintf "  ~a\n" (site-path s)))
        (eprintf "regenerate with: bin/beagle doc-fill\n")
        (exit 3)])]
    [else
     (for ([s (in-list drifted)])
       (call-with-atomic-output-file
        (site-file root s)
        (lambda (out _path) (display (expected-content root s) out)))
       (printf "  filled ~a\n" (site-path s)))
     (printf "doc-fill: ~a site(s) updated, ~a already in sync\n"
             (length drifted) (- (length sites) (length drifted)))
     (exit 0)]))
