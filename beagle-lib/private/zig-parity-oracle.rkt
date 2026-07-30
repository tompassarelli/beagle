#lang racket/base

;; Oracle side of the self-host Zig parity gate (bin/beagle-selfhost-zig-parity).
;;
;;   zig-parity-oracle.rkt emit [--strip-srcloc] --out-dir DIR KEY=SRC ...
;;   zig-parity-oracle.rkt diag [--strip-srcloc] [--target T] --out-dir DIR KEY=SRC ...
;;
;; Must replay the same compile path as beagle-test/tests/emit-zig.rkt (read →
;; inject define-target → parse → type-check! → emit-program), or a parity
;; mismatch would be an artifact of a different invocation. Per item: bytes to
;; DIR/KEY.out or diagnostic to DIR/KEY.err, one `KEY<TAB>status` line to
;; stdout; one item's exception never ends the batch.

(require racket/file
         racket/list
         racket/string
         beagle/private/ast
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define repo-root
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (path->string (simplify-path (build-path dir 'up 'up)))))

;; Absolute checkout paths in a diagnostic are incidental: the same gate runs
;; from main/ and from every worktree.
(define (normalize-diag s)
  (regexp-replace* (regexp (regexp-quote repo-root)) s ""))

;; The golden suite injects the target when the source declares none, and for
;; the semantic-contract family additionally drops syntax source locations
;; (its goldens are cross-worktree byte-stable). Both variants live here so the
;; harness reproduces each family exactly.
(define (parse-target-src target src-path strip-srcloc?)
  (define stxs (read-beagle-syntax src-path))
  (define datums
    (if strip-srcloc?
        (for/list ([stx (in-list stxs)]) (datum->syntax #f (syntax->datum stx)))
        stxs))
  (define has-target?
    (for/or ([stx (in-list datums)])
      (define d (syntax->datum stx))
      (and (pair? d) (eq? (car d) 'define-target))))
  (define forms
    (if has-target?
        datums
        (cons (datum->syntax #f `(define-target ,target)) datums)))
  (if strip-srcloc?
      (parse-program forms)
      (parse-program forms #:source-path src-path)))

(define (compile-src target src-path strip-srcloc?)
  (define prog (parse-target-src target src-path strip-srcloc?))
  (type-check! prog)
  (emit-program prog))

(define (parse-args args)
  (let loop ([args args] [mode #f] [target 'zig] [out-dir #f] [strip? #f] [items '()])
    (cond
      [(null? args) (values mode target out-dir strip? (reverse items))]
      [(and (not mode) (member (car args) '("emit" "diag")))
       (loop (cdr args) (string->symbol (car args)) target out-dir strip? items)]
      [(equal? (car args) "--strip-srcloc")
       (loop (cdr args) mode target out-dir #t items)]
      [(equal? (car args) "--target")
       (loop (cddr args) mode (string->symbol (cadr args)) out-dir strip? items)]
      [(equal? (car args) "--out-dir")
       (loop (cddr args) mode target (cadr args) strip? items)]
      [else
       (define parts (string-split (car args) "=" #:trim? #f))
       (unless (>= (length parts) 2)
         (error 'zig-parity-oracle "expected KEY=SRC, got ~a" (car args)))
       (loop (cdr args) mode target out-dir strip?
             (cons (cons (car parts) (string-join (cdr parts) "=")) items))])))

(define-values (mode target out-dir strip? items)
  (parse-args (vector->list (current-command-line-arguments))))

(unless (and mode out-dir)
  (eprintf "usage: zig-parity-oracle.rkt emit|diag [--strip-srcloc] [--target T] --out-dir DIR KEY=SRC ...\n")
  (exit 2))

(make-directory* out-dir)

(for ([item (in-list items)])
  (define key (car item))
  (define src (cdr item))
  (define out-path (build-path out-dir (string-append key ".out")))
  (define err-path (build-path out-dir (string-append key ".err")))
  (define-values (status payload)
    (with-handlers ([(lambda (e) #t)
                     (lambda (e)
                       (values 'fail
                               (normalize-diag
                                (if (exn? e) (exn-message e) (format "~a" e)))))])
      ;; The compiled program's own stdout/stderr noise is not the artifact.
      (parameterize ([current-output-port (open-output-string)]
                     [current-error-port (open-output-string)])
        (values 'ok (compile-src target src strip?)))))
  (case mode
    [(emit)
     (if (eq? status 'ok)
         (begin (call-with-output-file out-path #:exists 'replace
                  (lambda (p) (display payload p)))
                (printf "~a\tok\n" key))
         (begin (call-with-output-file err-path #:exists 'replace
                  (lambda (p) (display payload p)))
                (printf "~a\tfail\n" key)))]
    [(diag)
     ;; A rejection IS the artifact here: `fail` means the oracle pointedly
     ;; refused, which is what the self-host must eventually reproduce.
     (if (eq? status 'ok)
         (begin (call-with-output-file err-path #:exists 'replace
                  (lambda (p) (display "" p)))
                (printf "~a\taccepted\n" key))
         (begin (call-with-output-file err-path #:exists 'replace
                  (lambda (p) (display payload p)))
                (printf "~a\trejected\n" key)))]))
