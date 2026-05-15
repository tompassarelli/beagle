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
;; The readtable also intercepts `#"..."` — Clojure regex literals. Racket
;; normally reads these as byte strings (with different escape rules), so we
;; override to read the pattern verbatim and produce `(#%regex "pattern")`.

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

(define beagle-readtable
  (make-readtable #f
    #\" 'dispatch-macro regex-dispatch))

(define (beagle-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-readtable])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-readtable])
    (read-syntax src in)))
