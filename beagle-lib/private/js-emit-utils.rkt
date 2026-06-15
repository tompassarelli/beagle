#lang racket/base

;; Shared utilities for JS emission — used by emit-js.rkt, emit-jst.rkt,
;; and emit-js-quote.rkt.

(require racket/string)

(define (escape-js-regex-slash pat)
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i (string-length pat))
       (list->string (reverse acc))]
      [(char=? (string-ref pat i) #\\)
       (if (< (+ i 1) (string-length pat))
         (loop (+ i 2) (cons (string-ref pat (+ i 1)) (cons #\\ acc)))
         (loop (+ i 1) (cons #\\ acc)))]
      [(char=? (string-ref pat i) #\/)
       (loop (+ i 1) (cons #\/ (cons #\\ acc)))]
      [else
       (loop (+ i 1) (cons (string-ref pat i) acc))])))

(define (escape-js-template-string s)
  (regexp-replace* #rx"\\$\\{"
    (regexp-replace* #rx"`" s "\\\\`")
    "\\\\${"))

(define (mangle-name sym)
  (mangle-str (symbol->string sym)))

(define (mangle-str s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace
      (string-replace
       (string-replace
        (string-replace
         (string-replace s "_" "__")
         "-" "_")
        "?" "_p")
       "!" "_bang")
      "=" "_eq")
     ">" "_gt")
    "<" "_lt")
   "%" "_pct"))

(define (mangle-prop s)
  (string-replace s "-" "_"))

;; --- canonical JS binary/assign operator tables -----------------------------
;; Shared by parse-js-quote (recognition during parse) and the emitters
;; (rendering during emit). Single source of truth.

(define JS-BINARY-OPS
  (hasheq '+ "+" '- "-" '* "*" '/ "/" '% "%"
          '** "**" '=== "===" '!== "!==" '== "==" '!= "!="
          '< "<" '> ">" '<= "<=" '>= ">="
          'and "&&" 'or "||" 'nullish "??"
          'bit-and "&" 'bit-or "|" 'bit-xor "^"
          '<< "<<" '>> ">>" '>>> ">>>"
          'in "in" 'instanceof "instanceof"))

(define JS-ASSIGN-OPS
  (hasheq '+= "+=" '-= "-=" '*= "*=" '/= "/="
          '%= "%=" '**= "**="
          'and= "&&=" 'or= "||=" 'nullish= "??="
          'bit-and= "&=" 'bit-or= "|=" 'bit-xor= "^="
          '<<= "<<=" '>>= ">>=" '>>>= ">>>="))

(define (js-binary-op? sym)
  (and (symbol? sym) (hash-has-key? JS-BINARY-OPS sym)))
(define (js-assign-op? sym)
  (and (symbol? sym) (hash-has-key? JS-ASSIGN-OPS sym)))

(define current-emit-expr (make-parameter #f))

;; Render a string VALUE as a valid JS double-quoted string literal. Racket's
;; ~v writes Racket escapes (e.g. \e for ESC, \a for bell) that are NOT valid
;; JS — JS drops the backslash, silently losing the control char (broke ANSI).
;; Emit JS-legal escapes instead.
(define (js-string-lit s)
  (define out (open-output-string))
  (write-char #\" out)
  (for ([c (in-string s)])
    (define n (char->integer c))
    (cond
      [(char=? c #\") (write-string "\\\"" out)]
      [(char=? c #\\) (write-string "\\\\" out)]
      [(char=? c #\newline) (write-string "\\n" out)]
      [(char=? c #\return) (write-string "\\r" out)]
      [(char=? c #\tab) (write-string "\\t" out)]
      [(= n 8)  (write-string "\\b" out)]
      [(= n 12) (write-string "\\f" out)]
      [(= n 11) (write-string "\\v" out)]
      [(or (< n 32) (= n 127))
       (let ([h (number->string n 16)])
         (write-string (string-append "\\x" (if (= (string-length h) 1)
                                                (string-append "0" h) h))
                       out))]
      [else (write-char c out)]))
  (write-char #\" out)
  (get-output-string out))

(provide
 escape-js-regex-slash escape-js-template-string
 js-string-lit
 mangle-name mangle-str mangle-prop
 JS-BINARY-OPS JS-ASSIGN-OPS
 js-binary-op? js-assign-op?
 current-emit-expr)
