#lang racket/base

;; Reader compatibility diagnostics for retired annotation punctuation.
;;
;; `:` remains a TERMINATING macro inside beagle-readtable so the parser can
;; recognize an old spelling and issue a pointed structural replacement. This
;; is lexical diagnostic machinery, not accepted or canonical Beagle syntax.
;; It must live in the readtable itself: the bracket/quasiquote/unquote/meta
;; readers re-parameterize to beagle-readtable, so a layered entry would vanish
;; inside containers and templates. Split by the next character:
;;   `:` + delimiter/whitespace/EOF → ANN-MARKER (`#%:`)
;;   `:` + anything else            → today's keyword symbol, byte-identical
;;
;; The retired flat spelling `a: Int` intentionally reads as the three datums
;; `a` `#%:` `Int`. The parser then rejects it and points to `(a Int)`.

(require rackunit
         racket/file
         beagle/lang/reader-impl
         (only-in beagle/private/parse read-beagle-syntax))

(define (rd s) (beagle-read (open-input-string s)))

(define A (string->symbol "#%:"))

(test-case "retired colon spelling produces the interned diagnostic marker #%:"
  (check-eq? ANN-MARKER A)
  (check-eq? (rd ":") ANN-MARKER))

;; --- lexical compatibility observations ------------------------------------

(define TABLE
  (list
   (cons "(a: Int)"                  (list 'a A 'Int))
   (cons "[a: Int b: String]"        (list '#%brackets 'a A 'Int 'b A 'String))
   (cons "(defn f [a: Int] -> Int a)"
         (list 'defn 'f (list '#%brackets 'a A 'Int) '-> 'Int 'a))
   (cons ":foo"                      ':foo)
   (cons ":foo/bar"                  ':foo/bar)
   (cons "::kw"                      '::kw)
   (cons "{:k 1 :j 2}"               (list '#%map ':k 1 ':j 2))
   ;; spacing does not hide the retired marker; the parser rejects either form
   (cons "(a : Int)"                 (list 'a A 'Int))
   ;; colon glued to the TYPE is a keyword, not the marker (parser rejects it)
   (cons "(a :Int)"                  (list 'a ':Int))
   ;; dangling marker survives the reader; the parser gives the pointed error
   (cons "[: Int]"                   (list '#%brackets A 'Int))
   ;; the older marker stays visible so the parser can issue a pointed rejection
   (cons ":-"                        ':-)
   (cons "\"a: not syntax\""         "a: not syntax")
   (cons "`[~name: ~type]"
         (list 'quasiquote (list '#%brackets (list 'unquote 'name) A (list 'unquote 'type))))
   (cons "`[~@fields active: Bool]"
         (list 'quasiquote (list '#%brackets (list 'unquote-splicing 'fields) 'active A 'Bool)))))

(for ([row (in-list TABLE)])
  (test-case (format "reader: ~a" (car row))
    (check-equal? (rd (car row)) (cdr row))))

(test-case "reader: a `;` comment containing a colon is untouched"
  (check-equal? (beagle-read (open-input-string ";; a: comment\n(ok)")) '(ok)))

;; --- containers + reader macros preserve diagnostic visibility --------------

(test-case "retired marker remains visible to rejection diagnostics in containers"
  (check-equal? (rd "#{a: Int}")        (list '#%set 'a A 'Int))
  (check-equal? (rd "{k: Int 1}")       (list '#%map 'k A 'Int 1))
  (check-equal? (rd "#(f %: Int)")      (list 'fn (list '#%brackets '%1) (list 'f '%1 A 'Int)))
  (check-equal? (rd "#?(:clj a: Int :nix b)")
                (list 'reader-conditional ':clj 'a A 'Int ':nix 'b))
  (check-equal? (rd "^:private x: Int")
                (list '#%meta ':private 'x))   ; meta binds ONE datum; marker follows
  (check-equal? (rd "'[a: Int]")
                (list 'quote (list '#%brackets 'a A 'Int))))

(test-case "char literal \\: is a char, not the marker"
  (check-equal? (rd "(f \\:)") (list 'f #\:)))

(test-case "keyword forms the marker must not eat"
  (check-equal? (rd "(m :a/b ::c :d :-)") '(m :a/b ::c :d :-))
  (check-equal? (rd "(get m :Some-Key)")  '(get m :Some-Key)))

(test-case "mid-token `:` splits: `x:y` is `x` + the keyword `:y`"
  (check-equal? (rd "(x:y)") '(x :y)))

;; `<:` is ONE symbol (forall subtype bound) — the colon reader must not split it.
(test-case "<: stays a single symbol; other <-tokens are unaffected"
  (check-equal? (rd "(forall [(T <: String)] T)")
                (list 'forall (list '#%brackets (list 'T '<: 'String)) 'T))
  (check-equal? (rd "(< a b)")  '(< a b))
  (check-equal? (rd "(<= a b)") '(<= a b))
  (check-equal? (rd "(<- a)")   '(<- a)))

;; `.foo:` must split the same way on both the dot path and the plain path.
(test-case "dot-token reader terminates on `:`"
  (check-equal? (rd "(.foo: Int)") (list '.foo A 'Int)))

;; --- lexical diagnostic parity through the source reader (#19) -------------

(define (parse-path form-str)
  (define tmp (make-temporary-file "pa-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o) (display (string-append "#lang beagle/clj\n" form-str "\n") o))
       #:exists 'truncate/replace)
     (define stxs (read-beagle-syntax tmp))
     (syntax->datum (cadr stxs)))
   (lambda () (delete-file tmp))))

(for ([s (in-list '("(def x: Int 42)"
                    "(defn f [a: Int b: (Vec Int)] -> Int a)"
                    "(defrecord P [x: Int y: Int])"
                    "(defn g [cb: (Fn [Int] String)] -> String (cb 1))"
                    "(let [v: Int 1] v)"))])
  (test-case (format "retired-spelling reader-path parity: ~a" s)
    (check-equal? (parse-path s) (rd s))))
