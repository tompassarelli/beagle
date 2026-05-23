#lang racket/base

;; Nix-specific reader extensions.
;; Adds ''...'' indented string syntax (Nix-native) on top of the base
;; beagle readtable.

(require beagle/lang/reader-impl
         racket/string
         racket/list)

;; Nix ''...'' string reader.
;; '' opens, '' closes.  Triple ''' embeds a literal ''.
;; ''${ escapes interpolation (literal ${).
;; Produces (#%nix-string <raw-text>) to preserve provenance through the AST.

(define (read-nix-indented-string port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c)
       (error 'beagle "unterminated '' string")]
      [(char=? c #\')
       (define c2 (peek-char port))
       (cond
         [(and (char? c2) (char=? c2 #\'))
          (define c3 (peek-char port 1))
          (cond
            [(and (char? c3) (char=? c3 #\'))
             ;; ''': preserve as ''' in text (Nix escape for literal '')
             (read-char port) (read-char port)
             (loop (cons #\' (cons #\' (cons #\' acc))))]
            [(and (char? c3) (char=? c3 #\$))
             ;; ''${: preserve as ''${ in text (Nix escape for literal ${)
             (read-char port) (read-char port)
             (loop (cons #\$ (cons #\' (cons #\' acc))))]
            [(and (char? c3) (char=? c3 #\\))
             ;; ''\X: preserve as ''\X in text (Nix escape sequence)
             (read-char port) (read-char port)
             (define esc (read-char port))
             (loop (cons esc (cons #\\ (cons #\' (cons #\' acc)))))]
            [else
             ;; Closing ''
             (read-char port)
             (nix-dedent (list->string (reverse acc)))])]
         [else
          ;; Single ' inside string — literal
          (loop (cons c acc))])]
      [else (loop (cons c acc))])))

(define (nix-dedent str)
  (define lines (string-split str "\n" #:trim? #f))
  (define non-empty
    (filter (lambda (l) (not (regexp-match? #rx"^[ \t]*$" l)))
            (if (and (pair? lines) (string=? (car lines) ""))
                (cdr lines) lines)))
  (define min-indent
    (if (null? non-empty) 0
        (apply min
          (map (lambda (l)
                 (string-length (cadr (regexp-match #rx"^([ \t]*)" l))))
               non-empty))))
  (define stripped
    (map (lambda (l)
           (if (>= (string-length l) min-indent)
               (substring l min-indent) l))
         lines))
  ;; Strip leading empty line and trailing whitespace-only line (Nix '' semantics)
  (define trimmed
    (let* ([s stripped]
           [s (if (and (pair? s) (string=? (car s) "")) (cdr s) s)]
           [s (if (and (pair? s) (regexp-match? #rx"^[ \t]*$" (last s))) (drop-right s 1) s)])
      s))
  (string-join trimmed "\n"))

(define (nix-sq-reader ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\'))
     ;; Two single quotes: nix indented string
     (read-char port)
     (define text (read-nix-indented-string port))
     (define result (list '#%nix-string text))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [else
     ;; Single quote: standard Racket quote
     (define expr (if src (read-syntax src port) (read port)))
     (define result (list 'quote expr))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]))

;; ~"text ${expr} text" → (s "text " expr " text")
;; Lexes the interp-string body, splits on ${...} segments,
;; parses each segment as a beagle datum and emits an (s ...) form.
(define (read-interp-string port src line col pos)
  ;; Consume the opening "
  (define opening (read-char port))
  (unless (and (char? opening) (char=? opening #\"))
    (error 'beagle "~~ must be followed by \" to open an interpolated string"))
  (let loop ([parts '()] [literal '()])
    (define c (read-char port))
    (cond
      [(eof-object? c)
       (error 'beagle "unterminated ~~\"...\" string")]
      [(char=? c #\")
       (define final-parts
         (if (null? literal) parts (cons (list->string (reverse literal)) parts)))
       (define result (cons 's (reverse final-parts)))
       (if src
         (datum->syntax #f result (vector src line col pos #f))
         result)]
      [(char=? c #\\)
       ;; Escape: \", \\, \$, \n, \t
       (define esc (read-char port))
       (cond
         [(eof-object? esc) (error 'beagle "unterminated escape in ~~\"...\"")]
         [(char=? esc #\n) (loop parts (cons #\newline literal))]
         [(char=? esc #\t) (loop parts (cons #\tab literal))]
         [else (loop parts (cons esc literal))])]
      [(and (char=? c #\$)
            (let ([n (peek-char port)]) (and (char? n) (char=? n #\{))))
       (read-char port) ; consume {
       ;; Read a balanced expression up to matching }
       (define expr-str (read-until-matching-brace port))
       (define expr-port (open-input-string expr-str))
       (define expr-datum
         (parameterize ([read-square-bracket-with-tag '#%brackets]
                        [current-readtable beagle-nix-readtable])
           (read expr-port)))
       (define new-parts
         (if (null? literal)
           (cons expr-datum parts)
           (cons expr-datum (cons (list->string (reverse literal)) parts))))
       (loop new-parts '())]
      [else (loop parts (cons c literal))])))

(define (read-until-matching-brace port)
  (let loop ([depth 1] [acc '()] [in-str? #f])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unmatched { in ~~\"${...}\"")]
      [(and (not in-str?) (char=? c #\{))
       (loop (+ depth 1) (cons c acc) #f)]
      [(and (not in-str?) (char=? c #\}))
       (if (= depth 1)
         (list->string (reverse acc))
         (loop (- depth 1) (cons c acc) #f))]
      [(and (not in-str?) (char=? c #\"))
       (loop depth (cons c acc) #t)]
      [(and in-str? (char=? c #\\))
       (define n (read-char port))
       (loop depth (cons n (cons c acc)) in-str?)]
      [(and in-str? (char=? c #\"))
       (loop depth (cons c acc) #f)]
      [else
       (loop depth (cons c acc) in-str?)])))

(define (nix-tilde-reader ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\"))
     (read-interp-string port src line col pos)]
    [else
     ;; ~ followed by non-quote: treat as a symbol char (allow ~foo names)
     (define rest
       (let loop ([acc (list ch)])
         (define n (peek-char port))
         (cond
           [(or (eof-object? n) (memv n '(#\space #\newline #\tab #\) #\] #\} #\( #\[ #\{ #\;)))
            (list->string (reverse acc))]
           [else (read-char port) (loop (cons n acc))])))
     (string->symbol rest)]))

(define beagle-nix-readtable
  (make-readtable beagle-readtable
    #\' 'terminating-macro nix-sq-reader
    #\~ 'non-terminating-macro nix-tilde-reader))

(define (beagle-nix-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read in)))

(define (beagle-nix-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read-syntax src in)))

(provide beagle-nix-read beagle-nix-read-syntax)
