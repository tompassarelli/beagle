#lang racket/base

;; Implementation of `beagle expand`: read a beagle source file, parse +
;; expand macros, and print the result in beagle-source-equivalent form.
;;
;; This is the "no magic" knob — LLMs (and humans) can audit what their
;; macros do before compilation. Macro hallucinations are a real failure
;; mode; making expansions inspectable fixes the feedback loop.

(require racket/match
         racket/format
         racket/list
         "parse.rkt"
         "macros.rkt"
         "types.rkt"
         "tags.rkt")

;; --- entry ----------------------------------------------------------------

(define (expand-file path)
  (define datums (read-file-datums path))
  (define registry (make-macro-registry))
  ;; First pass: register macros (template + proc)
  (for ([d (in-list datums)])
    (match d
      [(list 'define-macro 'proc (? symbol? name) typed-params ': ret-type body)
       (define raw-params
         (cond
           [(bracketed? typed-params) (bracket-body typed-params)]
           [(list? typed-params)      typed-params]
           [else '()]))
       (define-values (param-names input-contracts)
         (for/lists (names contracts)
                    ([p (in-list raw-params)])
           (cond
             [(and (list? p) (= (length p) 3) (symbol? (car p)) (eq? (cadr p) ':))
              (values (car p) (caddr p))]
             [(symbol? p)
              (values p 'Syntax)]
             [else (values (gensym) 'Syntax)])))
       (register-proc-macro! registry name param-names input-contracts ret-type body)]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name kind ps template)]
      [_ (void)]))
  ;; Second pass: expand each non-meta form, splice (Vec Form) output
  (for ([d (in-list datums)])
    (unless (and (pair? d) (memq (car d) '(define-macro import)))
      (define expanded (expand-fully registry d))
      (cond
        [(and (pair? expanded) (eq? (car expanded) '#%splice-forms))
         (for ([form (in-list (cdr expanded))])
           (displayln (datum->beagle-src form))
           (newline))]
        [else
         (displayln (datum->beagle-src expanded))
         (newline)]))))

;; Minimal readtable for expand-tool: handles #"...", {...}, and #{...}.
(define (read-regex port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated regex literal")]
      [(char=? c #\")  (list->string (reverse acc))]
      [(char=? c #\\)
       (define next (read-char port))
       (cond
         [(eof-object? next) (error 'beagle "unterminated regex literal")]
         [else (loop (cons next (cons #\\ acc)))])]
      [else (loop (cons c acc))])))

(define (skip-ws-expand port)
  (let loop ()
    (define c (peek-char port))
    (when (and (char? c) (char-whitespace? c))
      (read-char port)
      (loop))))

(define (read-until-brace-expand port)
  (let loop ([acc '()])
    (skip-ws-expand port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated map/set literal")]
      [(char=? c #\})
       (read-char port)
       (reverse acc)]
      [else
       (define val (read port))
       (loop (cons val acc))])))

(define expand-readtable
  (make-readtable #f
    #\{ 'terminating-macro
         (lambda (ch port src line col pos)
           (define items (read-until-brace-expand port))
           (define result (cons MAP-TAG items))
           (if src (datum->syntax #f result (vector src line col pos #f)) result))
    #\} 'terminating-macro
         (lambda (ch port src line col pos) (error 'beagle "unexpected `}`"))
    #\# 'non-terminating-macro
         (lambda (ch port src line col pos)
           (define next (peek-char port))
           (cond
             [(and (char? next) (char=? next #\{))
              (read-char port)
              (define items (read-until-brace-expand port))
              (define result (cons SET-TAG items))
              (if src (datum->syntax #f result (vector src line col pos #f)) result)]
             [(and (char? next) (char=? next #\"))
              (read-char port)
              (define pattern (read-regex port))
              (define result (list '#%regex pattern))
              (if src
                (datum->syntax #f result (vector src line col pos (+ 3 (string-length pattern))))
                result)]
             [else
              (define sym-str
                (let loop ([acc '()])
                  (define c (peek-char port))
                  (if (and (char? c)
                           (not (char-whitespace? c))
                           (not (memq c '(#\( #\) #\[ #\] #\{ #\} #\" #\; #\' #\`))))
                    (begin (read-char port) (loop (cons c acc)))
                    (list->string (reverse acc)))))
              (string->symbol (string-append "#" sym-str))]))))

(define (read-file-datums path)
  ;; Use beagle's reader to preserve [...] vs (...), {...}, and #{...}.
  (with-input-from-file path
    (lambda ()
      (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                     [current-readtable expand-readtable])
        ;; Skip the #lang line.
        (read-line)
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

;; --- rendering ------------------------------------------------------------

;; Render a datum back into beagle-equivalent source. Bracketed lists
;; (from #%brackets) render with `[...]`; other lists with `(...)`.
;; Map-tagged render as `{...}`; set-tagged render as `#{...}`.
(define (datum->beagle-src d)
  (cond
    [(string? d) (~v d)]
    [(boolean? d) (if d "#t" "#f")]
    [(exact-integer? d) (number->string d)]
    [(real? d) (number->string d)]
    [(symbol? d) (symbol->string d)]
    [(null? d) "()"]
    [(bracketed? d)
     (format "[~a]"
             (render-list-body (bracket-body d)))]
    [(map-tagged? d)
     (format "{~a}"
             (render-list-body (map-body d)))]
    [(set-tagged? d)
     (format "#{~a}"
             (render-list-body (set-body d)))]
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
