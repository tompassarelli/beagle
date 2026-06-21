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
         ;; THE single beagle readtable — no bespoke subset reader to drift
         ;; (#19/#32). Datum mode (plain read) gives container/reader tags as data.
         (only-in "../lang/reader-impl.rkt" beagle-readtable))

;; --- entry ----------------------------------------------------------------

(define (expand-file path)
  (define datums (read-file-datums path))
  (define registry (make-macro-registry))
  ;; First pass: register macros (template + proc + beagle)
  (for ([d (in-list datums)])
    (match d
      [(list 'define-macro (or 'proc 'beagle) (? symbol? name) typed-params ': ret-type body)
       (define macro-kind (cadr d))
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
       (if (eq? macro-kind 'beagle)
           (register-beagle-macro! registry name param-names input-contracts ret-type body)
           (register-proc-macro! registry name param-names input-contracts ret-type body))]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name kind ps template)]
      [(list 'defmacro (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name 'defmacro ps template)]
      [_ (void)]))
  ;; Second pass: expand each non-meta form, splice (Vec Form) output
  (for ([d (in-list datums)])
    (unless (and (pair? d) (memq (car d) '(define-macro defmacro import)))
      (define expanded (expand-fully registry d))
      (cond
        [(and (pair? expanded) (eq? (car expanded) '#%splice-forms))
         (for ([form (in-list (cdr expanded))])
           (displayln (datum->beagle-src form))
           (newline))]
        [else
         (displayln (datum->beagle-src expanded))
         (newline)]))))

(define (read-file-datums path)
  ;; Read with THE canonical beagle readtable (datum mode) so the full surface
  ;; — [..] {..} #{..} #"re" #(..) ^meta #?(..) #?@(..) ' ` ~ ~@ #r"" — is read
  ;; exactly as the compiler reads it. No bespoke subset reader to drift (#32).
  (with-input-from-file path
    (lambda ()
      (parameterize ([current-readtable beagle-readtable])
        ;; Skip the #lang line.
        (read-line)
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

;; --- rendering ------------------------------------------------------------

;; A 2-element tagged list (head x) — the shape of quote/unquote reader output.
(define (tagged1? d tag)
  (and (pair? d) (eq? (car d) tag) (pair? (cdr d)) (null? (cddr d))))

;; Render a datum back into beagle-equivalent source. The reader's tagged forms
;; round-trip to their surface syntax: #%brackets→[..], #%map→{..}, #%set→#{..},
;; #%regex→#"..", #%meta→^m f, reader-conditional(-splice)→#?(..)/#?@(..), and
;; the quote family quote/quasiquote/unquote/unquote-splicing→' ` ~ ~@. Anything
;; else is a plain list → (..). Booleans are beagle `true`/`false` (not #t/#f).
(define (datum->beagle-src d)
  (cond
    [(string? d) (~v d)]
    [(boolean? d) (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d) (number->string d)]
    [(symbol? d) (symbol->string d)]
    [(null? d) "()"]
    [(bracketed? d)
     (format "[~a]" (render-list-body (bracket-body d)))]
    [(map-tagged? d)
     (format "{~a}" (render-list-body (map-body d)))]
    [(set-tagged? d)
     (format "#{~a}" (render-list-body (set-body d)))]
    ;; #"regex" — pattern stored verbatim (escapes preserved by the reader)
    [(and (tagged1? d '#%regex) (string? (cadr d)))
     (format "#\"~a\"" (cadr d))]
    ;; ^meta form  (privacy / dynamic / metadata)
    [(and (pair? d) (eq? (car d) '#%meta) (= (length d) 3))
     (format "^~a ~a" (datum->beagle-src (cadr d)) (datum->beagle-src (caddr d)))]
    ;; #?(:tag form ...) / #?@(:tag form ...) — reader conditionals (unresolved:
    ;; expand-tool shows surface, target selection is parse-time)
    [(and (pair? d) (eq? (car d) 'reader-conditional))
     (format "#?(~a)" (render-list-body (cdr d)))]
    [(and (pair? d) (eq? (car d) 'reader-conditional-splice))
     (format "#?@(~a)" (render-list-body (cdr d)))]
    ;; quote family → ' ` ~ ~@
    [(tagged1? d 'quote)            (string-append "'"  (datum->beagle-src (cadr d)))]
    [(tagged1? d 'quasiquote)       (string-append "`"  (datum->beagle-src (cadr d)))]
    [(tagged1? d 'unquote)          (string-append "~"  (datum->beagle-src (cadr d)))]
    [(tagged1? d 'unquote-splicing) (string-append "~@" (datum->beagle-src (cadr d)))]
    [(pair? d)
     (format "(~a)" (render-list-body d))]
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

(define (expand-datums path)
  (define datums (read-file-datums path))
  (define registry (make-macro-registry))
  (for ([d (in-list datums)])
    (match d
      [(list 'define-macro (or 'proc 'beagle) (? symbol? name) typed-params ': ret-type body)
       (define macro-kind (cadr d))
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
       (if (eq? macro-kind 'beagle)
           (register-beagle-macro! registry name param-names input-contracts ret-type body)
           (register-proc-macro! registry name param-names input-contracts ret-type body))]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name kind ps template)]
      [(list 'defmacro (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry name 'defmacro ps template)]
      [_ (void)]))
  (apply append
    (for/list ([d (in-list datums)])
      (if (and (pair? d) (memq (car d) '(define-macro defmacro import)))
        '()
        (let ([expanded (expand-fully registry d)])
          (if (and (pair? expanded) (eq? (car expanded) '#%splice-forms))
            (cdr expanded)
            (list expanded)))))))

;; --- traced expansion -------------------------------------------------------

(define (make-trace-handler)
  (lambda (phase macro-name datum depth)
    (define indent (make-string (* depth 2) #\space))
    (case phase
      [(before)
       (fprintf (current-error-port) "~a--- expand: ~a ---\n" indent macro-name)
       (fprintf (current-error-port) "~a  input:  ~a\n" indent (datum->beagle-src datum))]
      [(after)
       (fprintf (current-error-port) "~a  output: ~a\n\n" indent (datum->beagle-src datum))])))

(define (expand-file-traced path)
  (parameterize ([current-trace-handler (make-trace-handler)])
    (expand-file path)))

(provide expand-file expand-file-traced expand-datums
         ;; exported for tests: the reader + the surface renderer
         read-file-datums datum->beagle-src)
