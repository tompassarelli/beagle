#lang racket/base

;; Shared utilities for JS emission.

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

(define (mangle-name sym)
  (mangle-str (symbol->string sym)))

;; ESM code is ALWAYS strict mode, so a beagle identifier that mangles to a JS
;; reserved word — or to strict-mode-restricted `eval`/`arguments` — is a
;; SyntaxError at its declaration / param / binding site (`function f(private)`,
;; `let default = …`). Suffix such a name with `$`: a character mangle-str never
;; otherwise emits, so the `<word>$` namespace can never collide with a
;; normally-mangled identifier, and because every identifier reference funnels
;; through mangle-str the rename stays consistent across declaration and use.
;; Property names go through mangle-prop / kw->prop, NOT here, so a legal member
;; access like `obj.private` or an object key `{ default: … }` is untouched.
;;
;; DELIBERATELY EXCLUDED: `true` `false` `this` `super`. beagle carries these as
;; literal / keyword SYMBOLS that the emitter routes through mangle-name to emit
;; as the bare JS keyword. Mangling them would corrupt those intentional
;; emissions into `true$` / `this$`. (`nil` never reaches here — emit-js lowers
;; it to `null` directly — so `null` in this set only ever guards a real
;; user-authored identifier.)
(define JS-RESERVED-WORDS
  (for/hash ([w (in-list '("break" "case" "catch" "class" "const" "continue"
                           "debugger" "default" "delete" "do" "else" "enum"
                           "export" "extends" "finally" "for" "function"
                           "if" "implements" "import" "in" "instanceof"
                           "interface" "let" "new" "null" "package" "private"
                           "protected" "public" "return" "static"
                           "switch" "throw" "try" "typeof" "var"
                           "void" "while" "with" "yield" "await" "eval"
                           "arguments"))])
    (values w #t)))

(define (js-reserved-word? s) (hash-ref JS-RESERVED-WORDS s #f))

;; Punctuation shared by binding and property names. Binding names first escape
;; authored `_` so `a_b` cannot collide with `a-b`; property names preserve it
;; because an authored JS label such as `wall_s` must remain exactly `wall_s`.
(define (mangle-punctuation s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace
      (string-replace
       (string-replace
        (string-replace
         (string-replace
          (string-replace s "-" "_")
          "?" "_p")
         "!" "_bang")
        "=" "_eq")
       ">" "_gt")
      "<" "_lt")
     "%" "_pct")
    "*" "_star")
   "+" "_plus"))

(define (mangle-chars s)
  (mangle-punctuation (string-replace s "_" "__")))

(define (mangle-str s)
  (define mangled (mangle-chars s))
  (if (js-reserved-word? mangled) (string-append mangled "$") mangled))

(define (mangle-prop s)
  (mangle-punctuation s))

;; Foreign selector literals name JavaScript members exactly.  Dot notation is
;; available only for the conservative ASCII identifier subset; every other
;; spelling stays byte-for-byte visible through a quoted bracket key.
(define (js-member-identifier? s)
  (and (string? s)
       (regexp-match? #px"^[A-Za-z_$][A-Za-z0-9_$]*$" s)))

(define (js-selector-suffix name)
  (unless (string? name)
    (raise-argument-error 'js-selector-suffix "string?" name))
  (if (js-member-identifier? name)
      (string-append "." name)
      (string-append "[" (js-string-lit name) "]")))

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
 escape-js-regex-slash
 js-string-lit
 mangle-name mangle-str mangle-prop mangle-chars
 js-member-identifier? js-selector-suffix
 current-emit-expr)
