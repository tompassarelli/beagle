#lang racket/base

;; Shared reader logic for all #lang beagle/* variants — turtles surface.
;;
;; Reader rule: parentheses only for structure. No [], no {}, no #{}.
;; Atom literals at the reader level: numbers, strings, symbols, keywords,
;; characters, booleans, regex (#"..."), raw strings (#r"..."), heredocs
;; (#<<TAG ... TAG).
;;
;; The turtles surface (plan 20260528021255) eliminated reader-level
;; bracket distinctions. Pre-turtles brackets [], {}, #{} now raise reader
;; errors with migration hints pointing at `bin/beagle-migrate-turtles`.

(require racket/port
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
     (error 'beagle
            "`#{` set literal removed in turtles surface (use `(hash-set ...)`); run bin/beagle-migrate-turtles to migrate v0.15 source")]
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

;; Note: there is NO apostrophe reader macro in the quote-operator surface.
;; `'` is just an ordinary identifier character. Data quoting uses
;; `(' OPERAND)` with `'` in head position; there is no `'x` prefix sugar.
;; See plan 20260528220000-beagle_quote_operator_clarification.

(define (pipe-reader ch port src line col pos)
  ;; Treat `|` as an ordinary identifier character so `|>` and `|>>`
  ;; read as bare symbols. The default Racket reader uses `|...|` to
  ;; delimit a quoted identifier, which interferes with the threading
  ;; symbols. We override by reading until a non-symbol-char and
  ;; returning a symbol.
  (let loop ([acc (list #\|)])
    (define c (peek-char port))
    (cond
      [(or (eof-object? c)
           (char-whitespace? c)
           (memq c '(#\( #\) #\[ #\] #\{ #\} #\" #\; #\, #\` #\')))
       (define sym (string->symbol (list->string (reverse acc))))
       (if src
         (datum->syntax #f sym (vector src line col pos (length acc)))
         sym)]
      [else
       (read-char port)
       (loop (cons c acc))])))

(define (bracket-error ch port src line col pos)
  (error 'beagle
         "`~a` removed in turtles surface (use `(vector ...)`, `(hash-map ...)`, params/body sub-forms, etc.); run bin/beagle-migrate-turtles to migrate v0.15 source"
         ch))

(define (curly-error ch port src line col pos)
  (error 'beagle
         "`{...}` map literal removed in turtles surface (use `(hash-map :k v ...)`); run bin/beagle-migrate-turtles to migrate v0.15 source"))

(define beagle-readtable
  (make-readtable #f
    #\[ 'terminating-macro bracket-error
    #\] 'terminating-macro bracket-error
    #\{ 'terminating-macro curly-error
    #\} 'terminating-macro
                            (lambda (ch port src line col pos)
                              (error 'beagle "unexpected `}`"))
    #\| 'non-terminating-macro pipe-reader
    ;; `'` is treated as ordinary so it can appear as a bare symbol in
    ;; head position; we override Racket's default `'x` ≡ (quote x) macro
    ;; by aliasing `'` to the ordinary character `a`.
    #\' #\a #f
    #\# 'non-terminating-macro hash-dispatch))

(define (beagle-read in)
  (parameterize ([current-readtable beagle-readtable])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([current-readtable beagle-readtable])
    (read-syntax src in)))

(provide beagle-read beagle-read-syntax beagle-readtable)
