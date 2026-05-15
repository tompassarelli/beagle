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

(define (beagle-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets])
    (read in)))

(define (beagle-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets])
    (read-syntax src in)))
