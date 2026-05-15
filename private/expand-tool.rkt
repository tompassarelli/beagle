#lang racket/base

;; Implementation of `beagle expand`: read a beagle source file, parse +
;; expand macros, and print the result in beagle-source-equivalent form.
;;
;; This is the "no magic" knob — LLMs (and humans) can audit what their
;; macros do before compilation. Macro hallucinations are a real failure
;; mode; making expansions inspectable fixes the feedback loop.

(require racket/match
         racket/format
         "parse.rkt"
         "macros.rkt"
         "types.rkt")

(define BT BRACKET-TAG)

;; --- entry ----------------------------------------------------------------

(define (expand-file path)
  (define datums (read-file-datums path))
  (define registry (make-macro-registry))
  ;; First pass: register macros
  (for ([d (in-list datums)])
    (match d
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(and (pair? params) (eq? (car params) BT)) (cdr params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name kind ps template)]
      [_ (void)]))
  ;; Second pass: expand each non-meta form
  (for ([d (in-list datums)])
    (unless (and (pair? d) (memq (car d) '(define-macro)))
      (define expanded (expand-fully registry d))
      (displayln (datum->beagle-src expanded))
      (newline))))

(define (read-file-datums path)
  ;; Use beagle's reader to preserve [...] vs (...) distinction.
  (with-input-from-file path
    (lambda ()
      (parameterize ([read-square-bracket-with-tag BT])
        ;; Skip the #lang line.
        (read-line)
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

;; --- rendering ------------------------------------------------------------

;; Render a datum back into beagle-equivalent source. Bracketed lists
;; (from #%brackets) render with `[...]`; other lists with `(...)`.
(define (datum->beagle-src d)
  (cond
    [(string? d) (~v d)]
    [(boolean? d) (if d "#t" "#f")]
    [(exact-integer? d) (number->string d)]
    [(real? d) (number->string d)]
    [(symbol? d) (symbol->string d)]
    [(null? d) "()"]
    [(and (pair? d) (eq? (car d) BT))
     ;; bracketed form
     (format "[~a]"
             (render-list-body (cdr d)))]
    [(pair? d)
     (format "(~a)"
             (render-list-body d))]
    [else (~v d)]))

(define (render-list-body items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (string-join (reverse acc) " ")]
      [(pair? rest)
       (loop (cdr rest) (cons (datum->beagle-src (car rest)) acc))]
      [else
       ;; improper tail
       (string-join (reverse (cons (string-append ". " (datum->beagle-src rest)) acc)) " ")])))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

(provide expand-file)
