#lang racket/base

;; Shared reader logic for all #lang beagle/* variants.
;; Provides the readtable that preserves [...], {...}, #{...}, #"...", @, ^{}.

(require beagle/private/types
         racket/port
         racket/string
         racket/list)

(define (read-regex-pattern port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated regex literal")]
      [(char=? c #\")
       (list->string (reverse acc))]
      [(char=? c #\\)
       (define next (read-char port))
       (cond
         [(eof-object? next) (error 'beagle "unterminated regex literal")]
         [else (loop (cons next (cons #\\ acc)))])]
      [else (loop (cons c acc))])))

(define (regex-dispatch ch port src line col pos)
  (define pattern (read-regex-pattern port))
  (define result (list '#%regex pattern))
  (if src
    (datum->syntax #f result (vector src line col pos
                                     (+ 3 (string-length pattern))))
    result))

(define (read-until-close-brace port)
  (let loop ([acc '()])
    (skip-whitespace port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated map/set literal (missing `}`)")]
      [(char=? c #\})
       (read-char port)
       (reverse acc)]
      [else
       (define val (read port))
       (loop (cons val acc))])))

(define (skip-whitespace port)
  (let loop ()
    (define c (peek-char port))
    (when (and (char? c) (char-whitespace? c))
      (read-char port)
      (loop))))

(define (curly-reader ch port src line col pos)
  (define items (read-until-close-brace port))
  (define result (cons MAP-TAG items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (read-heredoc-tag port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated #<< tag")]
      [(char=? c #\newline) (list->string (reverse acc))]
      [(char-whitespace? c) (loop acc)]
      [else (loop (cons c acc))])))

(define (read-heredoc-body port tag)
  (let loop ([lines '()] [current '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated #<<~a heredoc" tag)]
      [(char=? c #\newline)
       (define line (list->string (reverse current)))
       (define stripped (string-trim line))
       (if (string=? stripped tag)
         (values (reverse lines) line)
         (loop (cons line lines) '()))]
      [else (loop lines (cons c current))])))

(define (heredoc-dedent lines closing-line)
  (define baseline
    (string-length
      (car (regexp-match #rx"^([ \t]*)" closing-line))))
  (define stripped
    (map (lambda (l)
           (if (regexp-match? #rx"^[ \t]*$" l) ""
             (if (>= (string-length l) baseline)
               (substring l baseline) l)))
         lines))
  (define trimmed
    (let* ([s stripped]
           [s (if (and (pair? s) (string=? (car s) "")) (cdr s) s)]
           [s (if (and (pair? s) (string=? (last s) "")) (drop-right s 1) s)])
      s))
  (string-join trimmed "\n"))

(define (read-raw-string port src line col pos)
  (define hash-count
    (let loop ([n 0])
      (define c (peek-char port))
      (if (and (char? c) (char=? c #\#))
        (begin (read-char port) (loop (add1 n)))
        n)))
  (define open (read-char port))
  (unless (and (char? open) (char=? open #\"))
    (error 'beagle "expected '\"' after #r~a, got: ~a"
           (make-string hash-count #\#) open))
  (define content
    (let loop ([acc '()])
      (define c (read-char port))
      (cond
        [(eof-object? c)
         (error 'beagle "unterminated raw string literal")]
        [(char=? c #\")
         (define hashes
           (let hloop ([n 0])
             (if (and (< n hash-count)
                      (char? (peek-char port))
                      (char=? (peek-char port) #\#))
               (begin (read-char port) (hloop (add1 n)))
               n)))
         (if (= hashes hash-count)
           (list->string (reverse acc))
           (loop (foldl cons acc
                        (cons #\" (build-list hashes (lambda (_) #\#))))))]
        [else (loop (cons c acc))])))
  (if src
    (datum->syntax #f content (vector src line col pos #f))
    content))

(define (hash-dispatch ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\<))
     (read-char port)
     (define next2 (peek-char port))
     (cond
       [(and (char? next2) (char=? next2 #\<))
        (read-char port)
        (define tag (read-heredoc-tag port))
        (define-values (lines closing-line) (read-heredoc-body port tag))
        (define text (heredoc-dedent lines closing-line))
        (define result (list '#%block-string tag text))
        (if src
          (datum->syntax #f result (vector src line col pos #f))
          result)]
       [else
        (define combined (input-port-append #f (open-input-string "#<") port))
        (parameterize ([current-readtable (make-readtable #f)])
          (if src (read-syntax src combined) (read combined)))])]
    [(and (char? next) (char=? next #\{))
     (read-char port)
     (define items (read-until-close-brace port))
     (define result (cons SET-TAG items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [(and (char? next) (char=? next #\"))
     (read-char port)
     (define pattern (read-regex-pattern port))
     (define result (list '#%regex pattern))
     (if src
       (datum->syntax #f result (vector src line col pos
                                        (+ 3 (string-length pattern))))
       result)]
    [(and (char? next) (char=? next #\r))
     (read-char port)
     (read-raw-string port src line col pos)]
    [else
     (define combined (input-port-append #f (open-input-string "#") port))
     (parameterize ([current-readtable (make-readtable #f)])
       (if src
         (read-syntax src combined)
         (read combined)))]))

(define (at-reader ch port src line col pos)
  (define expr (read-syntax src port))
  (define result (list 'deref expr))
  (datum->syntax #f result (vector src line col pos #f)))

(define (caret-reader ch port src line col pos)
  (skip-whitespace port)
  (define next (peek-char port))
  (define meta-map
    (cond
      [(and (char? next) (char=? next #\{))
       (read port)]
      [(and (char? next) (char=? next #\:))
       (define kw (read port))
       (list MAP-TAG kw #t)]
      [else
       (error 'beagle "^ must be followed by {:map} or :keyword, got: ~a" next)]))
  (define target (read port))
  (define result (list '#%meta meta-map target))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define beagle-readtable
  (make-readtable #f
    #\{ 'terminating-macro curly-reader
    #\} 'terminating-macro (lambda (ch port src line col pos)
                             (error 'beagle "unexpected `}`"))
    #\@ 'non-terminating-macro at-reader
    #\^ 'non-terminating-macro caret-reader
    #\# 'non-terminating-macro hash-dispatch))

(define (beagle-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-readtable])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-readtable])
    (read-syntax src in)))

(provide beagle-read beagle-read-syntax beagle-readtable)
