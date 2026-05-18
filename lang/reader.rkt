#lang s-exp syntax/module-reader
beagle/main
#:read         beagle-read
#:read-syntax  beagle-read-syntax

;; Beagle preserves the distinction between [...] and (...). This matters
;; because Clojure cares (vectors vs lists) and beagle needs to know which
;; was written. Setting `read-square-bracket-with-tag` makes the reader
;; produce `(#%brackets a b c)` for source `[a b c]`. Plain `(a b c)` stays
;; as-is. The parser pattern-matches on `#%brackets` to recognize the
;; bracketed forms.
;;
;; The readtable also intercepts:
;;   - `#"..."` — Clojure regex literals (produce `(#%regex "pattern")`)
;;   - `{...}` — map literals (produce `(MAP-TAG k1 v1 k2 v2 ...)`)
;;   - `#{...}` — set literals (produce `(SET-TAG e1 e2 ...)`)
;;
;; Racket normally reads `#"..."` as byte strings; we override to read
;; the pattern verbatim. `{` and `#{` are intercepted via readtable entries.

(require beagle/private/types)

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

;; Read forms from `port` until a closing `}` is encountered.
;; Uses the current readtable so nested structures are handled correctly.
(define (read-until-close-brace port)
  (let loop ([acc '()])
    (skip-whitespace port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated map/set literal (missing `}`)")]
      [(char=? c #\})
       (read-char port)  ; consume the }
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

;; Readtable handler for `{` — map literals.
;; Produces `(MAP-TAG k1 v1 k2 v2 ...)`.
(define (curly-reader ch port src line col pos)
  (define items (read-until-close-brace port))
  (define result (cons MAP-TAG items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

;; Dispatch-macro handler for `#` — set literals and regex.
;; `#` already consumed by dispatch; peeks at next char to decide.
(define (hash-dispatch ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\{))
     (read-char port)  ; consume the {
     (define items (read-until-close-brace port))
     (define result (cons SET-TAG items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [(and (char? next) (char=? next #\"))
     (read-char port)  ; consume the "
     (define pattern (read-regex-pattern port))
     (define result (list '#%regex pattern))
     (if src
       (datum->syntax #f result (vector src line col pos
                                        (+ 3 (string-length pattern))))
       result)]
    [else
     (error 'beagle "unexpected dispatch sequence: #~a" next)]))

;; `@expr` → `(deref expr)` (Clojure deref sugar)
(define (at-reader ch port src line col pos)
  (define expr (read-syntax src port))
  (define result (list 'deref expr))
  (datum->syntax #f result (vector src line col pos #f)))

;; `^{:key val} form` → `(#%meta (#%map :key val) form)` (Clojure metadata)
;; `^:keyword form` → `(#%meta (#%map :keyword true) form)` (shorthand)
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
