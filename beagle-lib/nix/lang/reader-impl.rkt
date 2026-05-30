#lang racket/base

;; Nix-specific reader extensions.
;;
;; Adds two interpolated-string reader macros on top of the base beagle
;; readtable:
;;
;;   ~"text ${expr} more"   — single-line beagle interp (lowers to (s ...))
;;   ~''multi               — multi-line beagle interp (lowers to (ms ...))
;;   line ${expr}''
;;
;; There is intentionally no bare ''...'' Nix-passthrough reader and no
;; (unsafe-nix "...") escape hatch. If you need verbatim Nix text, either
;; (a) add the missing function to beagle-lib/private/stdlib-nix.rkt or
;; (b) write the snippet as a .nix file alongside the .bnix and import it.

(require beagle/lang/reader-impl
         racket/string
         racket/list)

;; Read a balanced ${...} expression body. Returns the raw text inside.
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

(define (parse-interp-expr expr-str)
  (define expr-port (open-input-string expr-str))
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read expr-port)))

;; ~"text ${expr} text" → (s "text " expr " text")
(define (read-single-line-interp port src line col pos)
  (define opening (read-char port))
  (unless (and (char? opening) (char=? opening #\"))
    (error 'beagle "expected \" after ~~ for single-line interpolation"))
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
       (define esc (read-char port))
       (cond
         [(eof-object? esc) (error 'beagle "unterminated escape in ~~\"...\"")]
         [(char=? esc #\n) (loop parts (cons #\newline literal))]
         [(char=? esc #\t) (loop parts (cons #\tab literal))]
         [else (loop parts (cons esc literal))])]
      [(and (char=? c #\$)
            (let ([n (peek-char port)]) (and (char? n) (char=? n #\{))))
       (read-char port)
       (define expr-str (read-until-matching-brace port))
       (define expr-datum (parse-interp-expr expr-str))
       (define new-parts
         (if (null? literal)
           (cons expr-datum parts)
           (cons expr-datum (cons (list->string (reverse literal)) parts))))
       (loop new-parts '())]
      [else (loop parts (cons c literal))])))

;; Out-of-band marker emitted by read-multi-line-body's `''$` escape.
;; split-line-interp recognises it and treats the following `$` as a
;; literal chunk character rather than starting an interp parse. U+0001
;; is reserved for this purpose — it cannot appear in user-authored Nix
;; source (where the body is text content) without explicit unicode
;; escapes that this reader doesn't honour.
(define LITERAL-DOLLAR-SENTINEL #\u0001)

;; Read raw text between ~'' and ''. Handles Nix-style escapes:
;;   '''     → ''       in result (literal '')
;;   ''${    → \1${     literal ${, sentinel-prefixed so the later
;;                      split-line-interp pass leaves it alone
;;   ''\X    → \X       in result (Nix escape passthrough)
(define (read-multi-line-body port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated ~~''...'' string")]
      [(char=? c #\')
       (define c2 (peek-char port))
       (cond
         [(and (char? c2) (char=? c2 #\'))
          (define c3 (peek-char port 1))
          (cond
            [(and (char? c3) (char=? c3 #\'))
             ;; '''   → literal ''
             (read-char port) (read-char port)
             (loop (cons #\' (cons #\' acc)))]
            [(and (char? c3) (char=? c3 #\$))
             ;; ''$ → literal $ (disables Nix interp). Two-pass concern:
             ;; read-multi-line-body produces a raw text that later flows
             ;; through nix-dedent + split-line-interp. By the time
             ;; split-line-interp scans, a bare `$` + `{` looks identical
             ;; whether it came from `${` (real interp) or `''${` (literal).
             ;; To distinguish, we emit U+0001 as a sentinel before the
             ;; literal $; split-line-interp strips the sentinel and
             ;; passes through the following $ as a chunk character
             ;; without attempting interp parsing.
             (read-char port) (read-char port)
             (loop (cons #\$ (cons LITERAL-DOLLAR-SENTINEL acc)))]
            [(and (char? c3) (char=? c3 #\\))
             ;; ''\X → literal \X
             (read-char port) (read-char port)
             (define esc (read-char port))
             (loop (cons esc (cons #\\ acc)))]
            [else
             ;; closing ''
             (read-char port)
             (list->string (reverse acc))])]
         [else (loop (cons c acc))])]
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
  (define trimmed
    (let* ([s stripped]
           [s (if (and (pair? s) (string=? (car s) "")) (cdr s) s)]
           [s (if (and (pair? s) (regexp-match? #rx"^[ \t]*$" (last s))) (drop-right s 1) s)])
      s))
  trimmed)

;; Split one line on ${expr} boundaries, return list of datums.
;;
;; U+0001 sentinels are emitted by read-multi-line-body's `''$` literal-
;; dollar escape. When we encounter one, the following char (a `$`) must
;; be passed through as a chunk character WITHOUT triggering interp
;; parsing — the sentinel is dropped from the output text.
(define (split-line-interp line)
  (let loop ([i 0] [acc '()] [chunk '()])
    (cond
      [(>= i (string-length line))
       (define final
         (if (null? chunk) acc (cons (list->string (reverse chunk)) acc)))
       (reverse final)]
      [(char=? (string-ref line i) LITERAL-DOLLAR-SENTINEL)
       (cond
         [(< (+ i 1) (string-length line))
          (loop (+ i 2) acc (cons (string-ref line (+ i 1)) chunk))]
         [else (loop (+ i 1) acc chunk)])]
      [(and (char=? (string-ref line i) #\$)
            (< (+ i 1) (string-length line))
            (char=? (string-ref line (+ i 1)) #\{))
       ;; find matching }
       (define depth 1)
       (define j (+ i 2))
       (define-values (expr-end final-depth)
         (let scan ([k j] [d depth] [in-str? #f])
           (cond
             [(>= k (string-length line)) (values k d)]
             [(and (not in-str?) (char=? (string-ref line k) #\{))
              (scan (+ k 1) (+ d 1) #f)]
             [(and (not in-str?) (char=? (string-ref line k) #\}))
              (if (= d 1) (values k 0) (scan (+ k 1) (- d 1) #f))]
             [(and (not in-str?) (char=? (string-ref line k) #\"))
              (scan (+ k 1) d #t)]
             [(and in-str? (char=? (string-ref line k) #\\))
              (scan (+ k 2) d in-str?)]
             [(and in-str? (char=? (string-ref line k) #\"))
              (scan (+ k 1) d #f)]
             [else (scan (+ k 1) d in-str?)])))
       (when (not (zero? final-depth))
         (error 'beagle "unmatched { in ~~''${...}''"))
       (define expr-str (substring line j expr-end))
       (define expr-datum (parse-interp-expr expr-str))
       (define new-acc
         (if (null? chunk)
           (cons expr-datum acc)
           (cons expr-datum (cons (list->string (reverse chunk)) acc))))
       (loop (+ expr-end 1) new-acc '())]
      [else
       (loop (+ i 1) acc (cons (string-ref line i) chunk))])))

;; ~''...'' → (ms LINE ...) where each LINE is either a string or, if it
;; contains ${expr}, an (s ...) form.
(define (read-multi-line-interp port src line col pos)
  ;; Two leading '' have already been consumed.
  (define raw (read-multi-line-body port))
  (define lines (nix-dedent raw))
  (define ms-args
    (for/list ([l (in-list lines)])
      (define parts (split-line-interp l))
      (cond
        [(null? parts) ""]
        [(and (= (length parts) 1) (string? (car parts))) (car parts)]
        [else (cons 's parts)])))
  (define result (cons 'ms ms-args))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (nix-tilde-reader ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\"))
     (read-single-line-interp port src line col pos)]
    [(and (char? next) (char=? next #\'))
     (read-char port)
     (define n2 (peek-char port))
     (cond
       [(and (char? n2) (char=? n2 #\'))
        (read-char port)
        (read-multi-line-interp port src line col pos)]
       [else
        (error 'beagle "expected '' after ~~' for multi-line interpolation; got ~a"
               (if (char? n2) n2 'eof))])]
    [else
     ;; ~ followed by non-quote: allow as a symbol-character prefix (~foo)
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
    #\~ 'non-terminating-macro nix-tilde-reader))

(define (beagle-nix-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read in)))

(define (beagle-nix-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read-syntax src in)))

(provide beagle-nix-read beagle-nix-read-syntax beagle-nix-readtable)
