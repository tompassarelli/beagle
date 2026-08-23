#lang racket/base

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/system
         beagle/private/parse
         (only-in beagle/private/check type-check! current-check-profile)
         beagle/private/emit-dispatch
         beagle/private/emit-nix
         beagle/private/stdlib-types
         beagle/private/types
         (only-in beagle/lang/reader-impl beagle-readtable))

(define (emit-program prog)
  ((emitter-backend-emit-program (resolve-backend 'nix)) prog))

(define (substring-index text needle)
  (define matches
    (regexp-match-positions (regexp (regexp-quote needle)) text))
  (and matches (caar matches)))

(define (mt . xs) (cons MAP-TAG xs))
(define (br . xs) (cons '#%brackets xs))

(define FOO-VALIDATOR-NIX-NAME
  "bgl____24626561676c65247265636f726424466f6f2476616c6964617465")

;; The real Beagle readtable keeps reader tags and container forms identical to
;; source compilation; a bracket-tag approximation would lose that fidelity.
(define (nix-emit src)
  (define stxs
    (parameterize ([current-readtable beagle-readtable])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

(define (nix-emit-forms . forms)
  (define stxs (map (lambda (f) (datum->syntax #f f)) forms))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

(define (nix-check-and-emit src)
  (define stxs
    (parameterize ([current-readtable beagle-readtable])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog (parse-program stxs))
  (parameterize ([current-check-profile 2])
    (type-check! prog))
  (string-trim (emit-program prog)))

;; A binding constraint is executable compiler output gated on the checker's
;; positive synchronization proof, so a constrained program must be type-checked
;; before it may be emitted at all — parser-only emission fails closed. These
;; predicates are what supplies that proof.
(define CONSTRAINT-PRELUDE
  (string-append
   "(define-target nix) "
   "(defn positive? [(v Int)] Bool (> v 0)) "
   "(defn nonnegative? [(v Int)] Bool (>= v 0)) "
   "(defn valid-more? [(v (Vec Int))] Bool (> (count v) 0)) "
   "(defn greater-than-x? [(v Int)] Bool (> v 0)) "
   "(defn global-predicate [(v Int)] Bool (> v 0)) "))

(define (constrained-emit src)
  (nix-check-and-emit (string-append CONSTRAINT-PRELUDE src)))

(define (nix-eval emitted)
  (define nix (find-executable-path "nix-instantiate"))
  (and
   nix
   (let ([source (make-temporary-file "beagle-emit-nix-eval-~a.nix")]
         [stdout (open-output-string)]
         [stderr (open-output-string)])
     (dynamic-wind
       void
       (lambda ()
         (call-with-output-file
          source
          (lambda (out) (display emitted out))
          #:exists 'truncate/replace)
         (define ok?
           (parameterize ([current-output-port stdout]
                          [current-error-port stderr])
             (system* nix "--eval" "--strict" source)))
         (values ok? (string-trim (get-output-string stdout))
                 (get-output-string stderr)))
       (lambda () (delete-file source))))))

(test-case "unchecked constraint emission fails closed without a sync proof"
  (define out
    (nix-emit
     "(define-target nix) (defn accept [(value Int positive?)] Int value)"))
  (check-true
   (string-contains?
    out
    "binding constraint for value lacks the compiler's positive synchronization proof")))

;; --- basic forms -----------------------------------------------------------

(test-case "def emits let binding"
  ;; Inline `: Int` removed — bare form still emits the same let binding.
  (define out (nix-emit "(define-target nix) (def x 42)"))
  (check-true (string-contains? out "x = 42;"))
  (check-true (string-contains? out "let")))

(test-case "defn emits curried function"
  (define out (nix-emit "(define-target nix) (defn add [(a Int) (b Int)] Int (+ a b))"))
  (check-true (string-contains? out "add = a: b:"))
  (check-false (string-contains? out "builtins.deepSeq a"))
  (check-false (string-contains? out "builtins.deepSeq b"))
  (check-true (string-contains? out "a + b")))

(test-case "nullary source functions retain a unit call boundary"
  (define out
    (nix-emit
     "(define-target nix) (defn answer [] Int 42) (answer)"))
  (check-true (string-contains? out "answer = _: 42;"))
  (check-true (string-contains? out "answer null")))

(test-case "fn emits lambda"
  (define out (nix-emit "(define-target nix) (def f (fn [(x Int)] Int (+ x 1)))"))
  (check-true (string-contains? out "x:"))
  (check-true (string-contains? out "x + 1")))

(test-case "negative numeric function arguments are atomic"
  (define out
    (nix-emit
     "(define-target nix) (defn identity [(x Int)] Int x) (identity -1)"))
  (check-true (string-contains? out "identity (-1)")))

(test-case "if emits if/then/else"
  (define out (nix-emit "(define-target nix) (if true 1 0)"))
  (check-true (string-contains? out "if true then 1 else 0")))

(test-case "let emits sequential non-recursive binding applications"
  (define out (nix-emit "(define-target nix) (let [x Int 1 y Int 2] (+ x y))"))
  (check-false (string-contains? out "builtins.deepSeq x"))
  (check-false (string-contains? out "builtins.deepSeq y"))
  (check-true (string-contains? out "x + y")))

(test-case "unconstrained let RHS stays outside its own binder and lazy"
  (define out
    (constrained-emit
     (string-append
      "(def x 7) "
      "(let [x Int x ignored Any (let [(bad Int positive?) -1] 0)] x)")))
  (check-true (string-contains? out "((x:"))
  ;; The source `x` is the application argument, not a recursive `x = x`.
  (check-false (string-contains? out "x = x;"))
  (check-false (string-contains? out "ignored: builtins.deepSeq ignored"))
  (check-true (string-contains? out "Binding constraint failed: bad")))

;; --- data structures -------------------------------------------------------

(test-case "vector emits nix list"
  (define out (nix-emit "(define-target nix) [1 2 3]"))
  (check-true (string-contains? out "[ 1 2 3 ]")))

(test-case "long list breaks to multi-line"
  (define out (nix-emit "(define-target nix) [\"local-fs.target\" \"suspend.target\" \"suspend-then-hibernate.target\" \"hibernate.target\"]"))
  (check-true (and out (string-contains? out "[\n")))
  (check-true (and out (string-contains? out "\"local-fs.target\""))))

(test-case "map emits nix attrset"
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':a 1 ':b 2))))
  (check-true (string-contains? out "a = 1;"))
  (check-true (string-contains? out "b = 2;"))
  (check-true (string-contains? out "{")))

(test-case "nested attrset"
  (define inner (mt ':inner 42))
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':outer inner))))
  (check-true (and out (string-contains? out "outer ="))))

;; --- records ---------------------------------------------------------------

(test-case "defrecord emits constructor + accessors"
  (define out (nix-emit "(define-target nix) (defrecord Point [(x Int) (y Int)])"))
  (check-true (string-contains? out "mkPoint = x: y:"))
  (check-false (string-contains? out "builtins.deepSeq x"))
  (check-false (string-contains? out "builtins.deepSeq y"))
  (check-true (string-contains? out "_tag = \"point\""))
  (check-true (string-contains? out "point-x = r: r.x;"))
  (check-true (string-contains? out "point-y = r: r.y;")))

(test-case "nullary record constructors retain a unit call boundary"
  (define out
    (nix-emit
     "(define-target nix) (defunion :throwable Failure Timeout) (->Timeout)"))
  (check-true (string-contains? out "mkTimeout = _:"))
  (check-true (string-contains? out "mkTimeout null")))

;; --- semantic binding constraints -----------------------------------------

(test-case "constrained parameter guards its raw value with a stable failure"
  (define out
    (constrained-emit "(defn accept [(x Int positive?)] Int x)"))
  (check-true (string-contains? out "bgl____binding__0:"))
  (check-true
   (string-contains?
    out
    "bgl____constraint__thunk__0 = _: positive_p"))
  (check-true
   (string-contains?
    out
    "bgl____constraint__0 = bgl____constraint__thunk__0 null"))
  (check-true
   (string-contains? out "builtins.deepSeq bgl____binding__0"))
  (check-true
   (string-contains?
    out
    "Binding constraint failed: x")))

(test-case "parameter predicates are captured before every authored parameter"
  (define out
    (constrained-emit
     "(defn guarded [(x Int global-predicate) (global-predicate Int)] Int x)"))
  (define predicate-pos
    (substring-index out
                     "bgl____constraint__thunk__0 = _: global-predicate"))
  (define binder-pos
    (substring-index out "x: global-predicate:"))
  (check-not-false predicate-pos)
  (check-not-false binder-pos)
  (check-true (< predicate-pos binder-pos)))

(test-case "constrained rest parameter is guarded as its aggregate argument"
  (define out
    (constrained-emit
     "(defn collect [(x Int) & (more (Vec Int) valid-more?)] Int x)"))
  (check-true (string-contains? out "bgl____binding__1:"))
  (check-true
   (string-contains?
    out
    "bgl____constraint__thunk__1 = _: valid-more_p"))
  (check-true (string-contains? out "Binding constraint failed: more")))

(test-case "constrained let binding is a single guarded application"
  (define out
    (constrained-emit
     (string-append
      "(declare-extern expensive (Fn [] Int)) "
      "(let [(x Int positive?) (expensive)] x)")))
  (check-true (string-contains? out "bgl____constraint__0 = positive_p"))
  (check-equal? (length (regexp-match* #rx"expensive" out)) 1)
  (check-true
   (string-contains? out "bgl____binding__0: builtins.deepSeq bgl____binding__0"))
  (check-true (string-contains? out "Binding constraint failed: x")))

(test-case "non-final constrained forms are forced in eager body order"
  (define out
    (constrained-emit "(do (let [(x Int positive?) -1] x) 42)"))
  (check-true (string-contains? out "builtins.deepSeq"))
  (check-true (string-contains? out "Binding constraint failed: x")))

(test-case "top-level body expressions are sequenced instead of dropped"
  (define out
    (nix-emit
     "(define-target nix) (println \"first\") 42"))
  (check-true
   (string-contains? out "builtins.deepSeq (builtins.trace \"first\" null) (42)")))

(test-case "constrained loop guard lives in the recursive function"
  (define out
    (constrained-emit
     "(loop [(n Int nonnegative?) 2] (if (= n 0) n (recur (- n 1))))"))
  (check-true (string-contains? out "bgl____loop = bgl____binding__0:"))
  (check-true (string-contains? out "bgl____constraint__0 = nonnegative_p"))
  (check-true (string-contains? out "Binding constraint failed: n")))

(test-case "loop initializers are sequential without double-running constraints"
  (define out
    (constrained-emit "(loop [(x Int positive?) 1 (y Int greater-than-x?) x] y)"))
  (check-true
   (string-contains? out "bgl____loop__body = x: y:"))
  (check-true (string-contains? out "bgl____loop = bgl____binding__0:"))
  (check-true
   (string-contains?
    out
    (string-append
     "builtins.deepSeq bgl____binding__1 "
     "(if bgl____constraint__1 bgl____binding__1 then")))
  ;; One guard is on the initial let path and one is in the recur function.
  (check-equal?
   (length (regexp-match* #rx"Binding constraint failed: x" out))
   2))

(test-case "constrained for binding guards each callback value"
  (define out
    (constrained-emit "(for [(x Int positive?) [1 2]] x)"))
  (check-true (string-contains? out "builtins.concatMap"))
  (check-true
   (string-contains?
    out
    "bgl____constraint__thunk__0 = _: positive_p"))
  (check-true (string-contains? out "Binding constraint failed: x")))

(test-case "record constraint emits provider validator and constructor route"
  (define out
    (constrained-emit
     (string-append
      "(defrecord Point [(x Int positive?) (y Int)]) "
      "(->Point 1 2)")))
  (check-true
   (string-contains?
    out
    "bgl____24626561676c65247265636f726424506f696e742476616c6964617465 ="))
  (check-true
   (string-contains?
    out
    "mkPoint = let bgl____constraint__thunk__0 = _: positive_p;"))
  (check-true
   (string-contains?
    out
    "x: y:"))
  (check-false (string-contains? out "builtins.deepSeq x"))
  (check-false (string-contains? out "builtins.deepSeq y"))
  (check-true
   (string-contains?
    out
    "bgl____24626561676c65247265636f726424506f696e742476616c6964617465"))
  (check-true (string-contains? out "Binding constraint failed: x")))

(test-case "union and throwable variants use constrained tagged validators"
  (define union-out
    (constrained-emit
     (string-append
      "(defunion Shape (Circle [(radius Int positive?)])) "
      "(->Circle 1)")))
  (check-true
   (string-contains?
    union-out
    "bgl____24626561676c65247265636f726424436972636c652476616c6964617465 ="))
  (check-true (string-contains? union-out "radius:"))
  (check-false (string-contains? union-out "builtins.deepSeq radius"))
  (check-true (string-contains? union-out "_tag = \"circle\""))
  (check-true (string-contains? union-out "circle-radius = r: r.radius"))
  (define error-out
    (constrained-emit
     (string-append
      "(defunion :throwable Failure (Bad [(code Int positive?)])) "
      "(->Bad 1)")))
  (check-true
   (string-contains?
    error-out
    "bgl____24626561676c65247265636f7264244261642476616c6964617465 ="))
  (check-true (string-contains? error-out "code:"))
  (check-false (string-contains? error-out "builtins.deepSeq code"))
  (check-true (string-contains? error-out "_tag = \"bad\"")))

(test-case "unsupported protocol declarations fail instead of disappearing"
  (define protocol-out
    (nix-emit
     (string-append
      "(define-target nix) "
      "(defprotocol Sized (size [(self Any)] Int)) "
      "42")))
  (check-true
   (string-contains?
    protocol-out
    "protocol declarations are not supported by the nix backend"))
  (define implementation-out
    (nix-emit
     (string-append
      "(define-target nix) "
      "(extend-type String Sized (size [(self String)] Int 1)) "
      "42")))
  (check-true
   (string-contains?
    implementation-out
    "protocol implementations are not supported by the nix backend")))

;; --- nix builtins ----------------------------------------------------------

(test-case "standard Nix infix operators all have semantic contracts"
  (define contracts (stdlib-for-target 'nix))
  (for ([operator (in-list '(+ - * / < > <= >= = == not= != and or ++ // ->))])
    (check-true (hash-has-key? contracts operator)
                (format "missing Nix operator contract: ~a" operator)))
  (for ([operator (in-list '(!= ++ // ->))])
    (check-false (hash-has-key? (stdlib-for-target 'clj) operator)
                 (format "Nix-only operator leaked to Clojure: ~a" operator))))

(test-case "Nix-only list concatenation and inequality check without externs"
  (define out
    (nix-check-and-emit
     (string-append
      "(define-target nix) "
      "[(++ [1] [2] [3]) (!= 1 2)]")))
  (check-true (string-contains? out "[ 1 ] ++ [ 2 ] ++ [ 3 ]"))
  (check-true (string-contains? out "1 != 2")))

(test-case "builtins/ calls emit as builtins.*"
  (define out (nix-emit "(define-target nix) (builtins/length [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "lib/ calls emit as lib.*"
  (define out (nix-emit-forms '(define-target nix)
    `(lib/mkIf true ,(mt ':enable #t))))
  (check-true (string-contains? out "lib.mkIf true")))

;; --- stdlib fns ------------------------------------------------------------

(test-case "map fn emits builtins.map"
  (define out (nix-emit-forms '(define-target nix)
    `(map (fn ,(br (list 'x 'Int)) Int (+ x 1)) ,(br 1 2 3))))
  (check-true (string-contains? out "builtins.map")))

(test-case "filter fn emits builtins.filter"
  (define out (nix-emit-forms '(define-target nix)
    `(filter (fn ,(br (list 'x 'Int)) Bool (> x 0)) ,(br 1 -1 2))))
  (check-true (string-contains? out "builtins.filter")))

(test-case "nil? emits null check"
  (define out (nix-emit "(define-target nix) (nil? x)"))
  (check-true (string-contains? out "== null")))

(test-case "count emits builtins.length"
  (define out (nix-emit "(define-target nix) (count [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "merge emits //"
  (define out (nix-emit-forms '(define-target nix)
    `(merge ,(mt ':a 1) ,(mt ':b 2))))
  (check-true (string-contains? out "//")))

(test-case "concat emits ++"
  (define out (nix-emit "(define-target nix) (concat [1] [2])"))
  (check-true (string-contains? out "++")))

;; --- attrset field access via get -----------------------------------------
;; (:keyword target) call-form removed — use (get m :key); emit-nix lowers
;; literal-keyword get to unquoted attrset access (person.name).

(test-case "get with literal keyword emits unquoted attrset access"
  (define out (nix-emit "(define-target nix) (get person :name)"))
  (check-true (string-contains? out "person.name")))

(test-case "round-trip identity at Nix emit: (:k target) == (get target :k)"
  ;; Both forms canonicalize to kw-access; emit produces identical Nix.
  (define a (nix-emit "(define-target nix) (:name person)"))
  (define b (nix-emit "(define-target nix) (get person :name)"))
  (check-equal? a b))

(test-case "(get target :kw default) emits `target.kw or default`"
  ;; 3-arity literal-key kw-access lowers to Nix's `or` suffix — same
  ;; emit as the explicit (get-or target kw default) form, modulo the
  ;; identifier-vs-path key (kw-access requires keyword, get-or any path).
  (define out (nix-emit "(define-target nix) (get config :timeout 30)"))
  (check-true (string-contains? out "config.timeout or 30")))

;; --- dotted option paths ---------------------------------------------------

(test-case "dotted keyword keys become Nix option paths"
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':services.openssh.enable #t))))
  (check-true (string-contains? out "services.openssh.enable = true;")))

;; --- cond ------------------------------------------------------------------

(test-case "cond emits nested if/then/else"
  (define out (nix-emit "(define-target nix) (cond [true 1] [false 2])"))
  (check-true (string-contains? out "if true then 1 else"))
  (check-true (string-contains? out "if false then 2")))

;; Clojure-shaped flat-pair cond is accepted and canonicalizes to the same
;; AST as the bracketed form — the emitted Nix is byte-identical.
(test-case "cond: flat-pair Clojure form == bracketed form (with :else)"
  (define flat (nix-emit "(define-target nix) (cond (= x 1) :a (= x 2) :b :else :c)"))
  (define brk  (nix-emit "(define-target nix) (cond [(= x 1) :a] [(= x 2) :b] [:else :c])"))
  (check-equal? flat brk)
  ;; sanity: :else collapses to the bare else-body, not a literal "else" test
  (check-false (string-contains? flat "if \"else\"")))

(test-case "cond: flat-pair without :else falls through to null"
  (define out (nix-emit "(define-target nix) (cond (= x 1) :a (= x 2) :b)"))
  (check-true (string-contains? out "if (x == 1) then \"a\""))
  (check-true (string-contains? out "if (x == 2) then \"b\""))
  (check-true (string-contains? out "else null")))

(test-case "cond: bare `else` in bracketed clause works (same as :else)"
  (define a (nix-emit "(define-target nix) (cond [(= x 1) :a] [else :b])"))
  (define b (nix-emit "(define-target nix) (cond [(= x 1) :a] [:else :b])"))
  (check-equal? a b))

(test-case "cond: mixed bracketed + flat clauses is rejected"
  ;; nix-emit returns #f on parse failure (its handler swallows the error)
  ;; — so a #f result indicates the mixed form was refused.
  (define out (nix-emit "(define-target nix) (cond [(= x 1) :a] (= x 2) :b)"))
  (check-false out))

;; --- with (record update) --------------------------------------------------

(test-case "with emits attrset merge"
  (define out (nix-emit "(define-target nix) (defrecord Foo [(a Int)]) (with (->Foo 1) [:a 2])"))
  (check-true (string-contains? out "//")))

(test-case "dynamic Map with updates preserve keyword attribute spelling"
  (define out
    (nix-emit
     "(define-target nix) (with {:ready? 1} [:ready? 2])"))
  (check-true (string-contains? out "\"ready?\" = 1;"))
  (check-true
   (string-contains? out "// { \"ready?\" = bgl____update__value__0; }"))
  (check-false (string-contains? out "ready_p = 2;")))

(test-case "dynamic Map with updates preserve keyword attribute spelling"
  (define out
    (nix-emit
     "(define-target nix) (with {:ready? 1} [:ready? 2])"))
  (check-true (string-contains? out "\"ready?\" = 1;"))
  (check-true
   (string-contains? out "// { \"ready?\" = bgl____update__value__0; }"))
  (check-false (string-contains? out "ready_p = 2;")))

(test-case "with update fields use the same Nix property spelling as records"
  (define out
    (nix-emit
     (string-append
      "(define-target nix) "
      "(defrecord Flags [(ready? Bool) (if Int)]) "
      "(with (->Flags false 1) [:ready? true] [:if 2])")))
  (check-true
   (string-contains? out "ready_p = bgl____update__value__0;"))
  (check-true (string-contains? out "if' = bgl____update__value__1;")))

(test-case "checked record keyword reads use the generated field spelling"
  (define out
    (nix-check-and-emit
     (string-append
      "(define-target nix) "
      "(defrecord Flags [(ready? Bool)]) "
      "(:ready? (->Flags true))")))
  (check-true (string-contains? out ").ready_p")))

(test-case "Map keyword labels preserve punctuation as quoted attributes"
  (define out
    (nix-emit
     "(define-target nix) (:ready? {:ready? true})"))
  (check-true (string-contains? out "\"ready?\" = true;"))
  (check-true (string-contains? out ".\"ready?\"")))

(test-case "typed constrained record update routes through its checked validator"
  (define out
    (nix-check-and-emit
     (string-append
      "(define-target nix) "
      "(defn positive? [(value Int)] Bool (> value 0)) "
      "(defrecord Foo [(a Int positive?)]) "
      "(with (->Foo 1) [:a 2])")))
  ;; Defined once, called once on the update candidate.
  (check-equal?
   (length (regexp-match* (regexp FOO-VALIDATOR-NIX-NAME) out))
   2)
  ;; The target and every update value are bound and forced before the merge,
  ;; so a constrained field cannot slip past the validator under Nix laziness.
  (check-true
   (string-contains?
    out
    "bgl____update__candidate = (bgl____update__target // { a = bgl____update__value__0; })"))
  (check-true
   (string-contains?
    out
    (format "(~a bgl____update__candidate)" FOO-VALIDATOR-NIX-NAME))))

(test-case "qualified validator ABI is mangled as a Nix attr selection"
  (define stxs
    (parameterize ([current-readtable beagle-readtable])
      (with-input-from-string
          "(define-target nix) (with base [:a 2])"
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog (parse-program stxs))
  (define update (car (program-forms prog)))
  (hash-set!
   (program-semantic-contracts prog)
   update
   (record-update-contract
    'Foo 'provider/$beagle$record$Foo$validate '(:a)))
  (define out (string-trim (emit-program prog)))
  (check-true
   (string-contains?
    out
    (format
     "(provider.~a bgl____update__candidate)"
     FOO-VALIDATOR-NIX-NAME))))

;; --- string ops ------------------------------------------------------------

(test-case "str emits string concatenation"
  (define out (nix-emit "(define-target nix) (str \"hello\" \" \" \"world\")"))
  (check-true (string-contains? out "\"hello\" + \" \" + \"world\"")))

;; --- comparison operators --------------------------------------------------

(test-case "comparison operators"
  (define out (nix-emit "(define-target nix) (< 1 2)"))
  (check-true (string-contains? out "1 < 2"))
  (define out2 (nix-emit "(define-target nix) (= 1 1)"))
  (check-true (string-contains? out2 "1 == 1")))

;; === Nix-specific forms (Nisp parity) ======================================

;; --- Phase 1: Module-writing core ------------------------------------------

(test-case "fn-set emits attrset-pattern lambda"
  (define out (nix-emit "(define-target nix) (nix/fn-set (a b) (+ a b))"))
  (check-true (and out (string-contains? out "{ a, b }:")))
  (check-true (and out (string-contains? out "a + b"))))

(test-case "fn-set with defaults"
  (define out (nix-emit "(define-target nix) (nix/fn-set (a (b 5)) (+ a b))"))
  (check-true (and out (string-contains? out "b ? 5")))
  (check-true (and out (string-contains? out "{ a, b ? 5 }:"))))

(test-case "module emits ... in formals"
  (define out (nix-emit "(define-target nix) (nix/module [config lib pkgs] config)"))
  (check-true (and out (string-contains? out "...")))
  (check-true (and out (string-contains? out "{ config, lib, pkgs, ... }:"))))

(test-case "project module policy omits only declared outer authoring attrs"
  (define source
    (string-append
     "(define-target nix) "
     "(nix/module [config lib] "
     "  (let [enabled Bool true] "
     "    {:tags [desktop] "
     "     :tags-opt-in [experimental] "
     "     :tag-overrides {:desktop {:demo true}} "
     "     :flake-inputs {:demo {:url \"github:example/demo\"}} "
     "     :config {:tags [runtime] :enabled enabled}}))"))
  (define ordinary (nix-emit source))
  (check-true (string-contains? ordinary "tags ="))
  (define project-emitted
    (parameterize
        ([current-nix-module-omit-attrs
          '(:tags :tags-opt-in :tag-overrides :flake-inputs)])
      (nix-emit source)))
  (check-false (string-contains? project-emitted "tags-opt-in ="))
  (check-false (string-contains? project-emitted "tag-overrides ="))
  (check-false (string-contains? project-emitted "flake-inputs ="))
  (check-equal? (length (regexp-match* #rx"tags =" project-emitted)) 1))

(test-case "overlay emits curried (final: prev: body)"
  (define out (nix-emit-forms '(define-target nix)
    `(nix/overlay ,(br 'final 'prev) ,(mt ':foo 1))))
  (check-true
   (and out
        (string-contains? out "final: prev:")))
  (check-false (and out (string-contains? out "builtins.deepSeq final")))
  (check-false (and out (string-contains? out "{ final, prev"))))

(test-case "overlay parameters stay lazy across a recursive Nix fixed point"
  (define overlay
    (nix-emit-forms '(define-target nix)
      `(nix/overlay ,(br 'final 'prev) final.pkgs)))
  (when (find-executable-path "nix-instantiate")
    (define-values (ok? stdout stderr)
      (nix-eval
       (format
        "let overlay = ~a; final = { pkgs = 42; self = final; }; in overlay final {}"
        overlay)))
    (check-true ok? stderr)
    (check-equal? stdout "42")))

(test-case "inherit emits inherit"
  (define out (nix-emit "(define-target nix) (inherit a b c)"))
  (check-true (and out (string-contains? out "inherit a b c;"))))

(test-case "inherit-from emits inherit (ns)"
  (define out (nix-emit "(define-target nix) (inherit-from pkgs vim git)"))
  (check-true (and out (string-contains? out "inherit (pkgs) vim git;"))))

(test-case "nix/with emits with"
  (define out (nix-emit "(define-target nix) (nix/with lib [1 2 3])"))
  (check-true (and out (string-contains? out "with lib;")))
  (check-true (and out (string-contains? out "[ 1 2 3 ]"))))

(test-case "s emits interpolated string"
  (define out (nix-emit "(define-target nix) (s \"hello \" name \"!\")"))
  (check-true (and out (string-contains? out "\"hello ${name}!\""))))

(test-case "s with only literals"
  (define out (nix-emit "(define-target nix) (s \"hello\" \" world\")"))
  (check-true (and out (string-contains? out "\"hello world\""))))

(test-case "p emits path literal"
  (define out (nix-emit "(define-target nix) (p \"./foo/bar.nix\")"))
  (check-true (and out (string-contains? out "./foo/bar.nix"))))

;; --- Phase 2: Nix semantic essentials --------------------------------------

(test-case "rec-attrs emits recursive attrset"
  (define out (nix-emit "(define-target nix) (rec-attrs x 1 y x)"))
  (check-true (and out (string-contains? out "rec {")))
  (check-true (and out (string-contains? out "x = 1;")))
  (check-true (and out (string-contains? out "y = x;"))))

(test-case "nix/assert emits assert"
  (define out (nix-emit "(define-target nix) (nix/assert true 42)"))
  (check-true (and out (string-contains? out "assert true; 42"))))

(test-case "get-or emits select with or-default"
  (define out (nix-emit "(define-target nix) (get-or config a.b.c \"fallback\")"))
  (check-true (and out (string-contains? out "config.a.b.c or \"fallback\""))))

(test-case "has is removed; rejection names contains?"
  ;; `has` removed 2026-06-12 (zero corpus hits; contains? is the Clojure
  ;; spelling). nix-emit returns #f when parse rejects.
  (check-false (nix-emit "(define-target nix) (has config a.b)")))

(test-case "contains? emits hasAttr (the has replacement)"
  (define out (nix-emit "(define-target nix) (contains? config :services)"))
  (check-true (and out (string-contains? out "builtins.hasAttr"))))

(test-case "ms emits multiline string"
  (define out (nix-emit "(define-target nix) (ms \"line one\" \"line two\")"))
  (check-true (and out (string-contains? out "''")))
  (check-true (and out (string-contains? out "line one")))
  (check-true (and out (string-contains? out "line two"))))

(test-case "search-path emits search path"
  (define out (nix-emit "(define-target nix) (search-path nixpkgs)"))
  (check-true (and out (string-contains? out "<nixpkgs>"))))

;; --- escape hatch removed --------------------------------------------------

(test-case "unsafe-nix is rejected at parse time"
  ;; nix-emit swallows the parse error and returns #f when the program fails.
  (check-false (nix-emit "(def x (unsafe-nix \"hello\"))")))

;; --- qualified calls: / -> . --------------------------------------------------

(test-case "pkgs/ call emits as pkgs.fn"
  (define out (nix-emit "(define-target nix) (pkgs/writeScriptBin \"hello\" \"body\")"))
  (check-true (and out (string-contains? out "pkgs.writeScriptBin")))
  (check-false (string-contains? out "pkgs/writeScriptBin")))

(test-case "arbitrary ns/ call emits as ns.fn"
  (define out (nix-emit "(define-target nix) (config/boot.kernelPackages.kernel)"))
  (check-true (and out (string-contains? out "config.boot.kernelPackages.kernel"))))

(test-case "ns/ symbol in non-call position emits as ns.sym"
  (define out (nix-emit "(define-target nix) (def x pkgs/hello)"))
  (check-true (and out (string-contains? out "pkgs.hello")))
  (check-false (string-contains? out "pkgs/hello")))

(test-case "qualified record pattern matches the provider's leaf tag"
  (define out
    (nix-emit-forms
     '(define-target nix)
     `(match value
        ,(br '(models/Widget) 'value)
        ,(br '_ 'nil))))
  (check-true (and out (string-contains? out "_tag == \"widget\"")))
  (check-false (string-contains? out "models/widget")))

(test-case "bgl/promote remains an erased Nix operation"
  (define out (nix-emit "(define-target nix) (bgl/promote value)"))
  (check-equal? out "value"))

;; --- not -> ! -----------------------------------------------------------------

(test-case "not emits ! prefix operator"
  (define out (nix-emit "(define-target nix) (not true)"))
  (check-true (and out (string-contains? out "!true")))
  (check-false (string-contains? out "not true")))

(test-case "not with complex expr wraps inner in parens"
  (define out (nix-emit "(define-target nix) (not (= x 1))"))
  (check-true (and out (string-contains? out "!(")))
  (check-true (and out (string-contains? out "==")))
  (check-false (string-contains? out "((!")))

;; --- quoted containers (Clojure-shaped data literals) -----------------------
;; '[…] / '{…} / '#{…} parse as the container itself. Containers always
;; evaluate in beagle; the quote is identity (meaning-preserving). Lets
;; agents author Clojure-shaped data literals without learning beagle's
;; "quote only on lists" discipline.
;;
;; The plain `read-syntax` used by `nix-emit` doesn't have the beagle
;; readtable, so we construct quoted-container datums by hand via
;; `nix-emit-forms` to exercise the parse layer directly.

(test-case "quoted vector '[…] parses as vec-form (matches bare [..])"
  (define out (nix-emit-forms
               '(define-target nix)
               `(def xs (quote ,(br 1 2 3)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def xs ,(br 1 2 3))))
  (check-true (and out (string-contains? out "[ 1 2 3 ]")))
  (check-equal? out ref))

(test-case "quoted map '{…} parses as map-form (matches bare {..})"
  (define out (nix-emit-forms
               '(define-target nix)
               `(def m (quote ,(mt ':a 1 ':b 2)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def m ,(mt ':a 1 ':b 2))))
  (check-true (and out (string-contains? out "a = 1")))
  (check-true (and out (string-contains? out "b = 2")))
  (check-equal? out ref))

(test-case "quoted set '#{…} parses as set-form (matches bare #{..})"
  (define st (lambda xs (cons SET-TAG xs)))
  (define out (nix-emit-forms
               '(define-target nix)
               `(def s (quote ,(st 1 2 3)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def s ,(st 1 2 3))))
  (check-equal? out ref))

(test-case "quoted symbol still produces a quoted AST node (unchanged)"
  ;; Regression: only containers get the strip-quote treatment.
  ;; '(a b c) and 'symbol must continue to parse as `quoted`.
  (define out (nix-emit "(define-target nix) (def s 'hello)"))
  (check-true (and out (string-contains? out "\"hello\""))))

;; --- nix/-prefixed canonical Nix-namespaced forms ---------------------------
;; Per the prefix rule in beagle:AGENTS.md,
;; Nix-specific forms whose Clojure namesake means something different get the
;; nix/ prefix. `nix/assert` / `nix/with` / `nix/with-cfg` are the ONLY accepted
;; spellings; bare `assert` / `with-cfg` / Nix-scope `with` are HARD-REJECTED at
;; parse time (see beagle-test/tests/parse.rkt regression tests).

(test-case "nix/assert emits Nix assert form"
  (define out (nix-emit "(define-target nix) (def x (nix/assert true 42))"))
  (check-true (and out (string-contains? out "assert true"))))

(test-case "nix/with emits Nix scope form"
  (define out (nix-emit "(define-target nix) (def x (nix/with pkgs 42))"))
  (check-true (and out (string-contains? out "with pkgs;"))))

(test-case "nix/with-cfg emits cfg-let binding"
  (define out (nix-emit
               "(define-target nix) (def x (nix/with-cfg config.myConfig.x 42))"))
  (check-true (and out (string-contains? out "cfg = config.myConfig.x"))))

(test-case "bare (with target [:k v] ...) record-update still works — not renamed"
  ;; (with …) is overloaded — only the Nix-scope shape is the §C-silent
  ;; collision. Record-update form stays bare; it's not a Clojure collision.
  (define out (nix-emit
               "(define-target nix) (def x (with base [:k 1] [:j 2]))"))
  (check-true (and out (string-contains? out "//"))))

;; --- ms + s inline interpolation ---------------------------------------------

(test-case "ms with s inlines interpolation without double-wrapping"
  (define out (nix-emit "(define-target nix) (ms (s \"#!\" pkgs.bash \"/bin/bash\") \"echo hi\")"))
  (check-true (and out (string-contains? out "#!${pkgs.bash}/bin/bash")))
  (check-false (string-contains? out "${\"")))

;; Multi-operand (ms …) is the canonical form (one operand per physical
;; line). Each operand must land on its own output line — concatenation
;; without \n is the bug we fixed for both legacy and operative emitters.
(test-case "ms multi-operand emits one physical line per operand"
  (define out (nix-emit "(define-target nix) (ms \"first line\" \"second line\" \"third\")"))
  (check-true (and out (regexp-match? #rx"first line[\n\r]" out)))
  (check-true (and out (regexp-match? #rx"second line[\n\r]" out)))
  ;; No "lineSecond" concatenation regression
  (check-false (and out (regexp-match? #rx"first linesecond" out))))

(test-case "ms with multiple s operands keeps each on its own line"
  (define out (nix-emit
               "(define-target nix) (ms (s \"#!\" pkgs.bash) \"set -e\" (s \"echo \" name))"))
  (check-true (and out (string-contains? out "#!${pkgs.bash}")))
  (check-true (and out (regexp-match? #rx"\\$\\{pkgs.bash\\}[\n\r]" out)))
  (check-true (and out (regexp-match? #rx"set -e[\n\r]" out)))
  (check-true (and out (string-contains? out "echo ${name}"))))

;; ~''…'' reader-level tests live in tests/nix-roundtrip.rkt — they
;; need the beagle/nix #lang reader which nix-emit (plain read-syntax)
;; doesn't invoke.

;; Plain Racket strings have no interpolation semantics in bnix, so literal
;; `${X}` in an (ms …) / (s …) chunk must be escaped as `''${X}` / `\${X}`
;; in the emitted Nix string. Otherwise bash array-expansion syntax like
;; `${THEMES[@]}` lands in the output as a malformed Nix interp.
(test-case "ms escapes bare ${ in plain string chunks (multiline)"
  (define out (nix-emit
               "(define-target nix) (ms \"printf '%s\\\\n' \\\"${THEMES[@]}\\\"\")"))
  (check-true (and out (string-contains? out "''${THEMES[@]}")))
  (check-false (and out (regexp-match? #rx"[^'\\\\]\\$\\{THEMES" out))))

(test-case "ms preserves $${ literal-dollar marker (multiline)"
  (define out (nix-emit "(define-target nix) (ms \"hello $${X} world\")"))
  (check-true (and out (string-contains? out "''${X}"))))

(test-case "s escapes bare ${ in plain string chunks (single-line)"
  (define out (nix-emit
               "(define-target nix) (s \"prefix ${VAR} suffix\")"))
  (check-true (and out (string-contains? out "\\${VAR}")))
  (check-false (and out (regexp-match? #rx"[^\\\\]\\$\\{VAR" out))))

;; --- flake-input emission ----------------------------------------------------

(test-case "flake-input emits canonical inputs.X.Y.${system}.Z path"
  (define out (nix-emit "(define-target nix) (def pkg (flake-input :quickshell :packages :default))"))
  (check-true (and out (string-contains? out "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default"))))

(test-case "flake-input with multi-segment path"
  (define out (nix-emit "(define-target nix) (def pkg (flake-input :nur :legacyPackages :repos :rycee :firefox-addons :sidebery))"))
  (check-true (and out (string-contains? out "inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system}.repos.rycee.firefox-addons.sidebery"))))

(test-case "flake-input inside string concat composes cleanly"
  (define out (nix-emit "(define-target nix) (def exec (s (flake-input :quickshell :packages :default) \"/bin/qs\"))"))
  ;; Should produce a string with the flake-input path interpolated, then "/bin/qs" appended
  (check-true (and out (string-contains? out "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default")))
  (check-true (and out (string-contains? out "/bin/qs"))))

;; --- nix-ident migration error (emit-side; parse-side covered in nix-parse) ---

(test-case "nix-ident fails at parse — nix-emit returns #f"
  ;; nix-emit's parse-program is wrapped in with-handlers that returns #f
  ;; on parse failure. The migration-error message itself is tested in
  ;; nix-parse.rkt; here we just confirm the form doesn't reach emit.
  (define out (nix-emit "(define-target nix) (def x (nix-ident \"inputs.foo\"))"))
  (check-false out))

;; --- Clojure conditional sugar: accept-and-canonicalize ---------------------
;;
;; (when c body…)      → (if c (do body…))
;; (when-not c body…)  → (if (not c) (do body…))
;; (if-not c t e)      → (if c e t)
;; (unless c body…)    → (if c nil (do body…))
;;
;; Each test parses both the surface form and the lowered form and asserts
;; the emitted Nix is byte-equal. Pre-condition: parse-side coverage lives in
;; tests/parse.rkt (AST shape) and tests/diagnostic-kind.rkt (the no-body
;; rejection-form tag).

(test-case "when emits same Nix as if + do (multi body)"
  (define a (nix-emit "(define-target nix) (when (> x 0) (println x) x)"))
  (define b (nix-emit "(define-target nix) (if (> x 0) (do (println x) x))"))
  (check-equal? a b))

(test-case "when-not emits same Nix as if (not c) + body (single body)"
  (define a (nix-emit "(define-target nix) (when-not (> x 0) (println x))"))
  (define b (nix-emit "(define-target nix) (if (not (> x 0)) (println x))"))
  (check-equal? a b))

(test-case "if-not emits same Nix as if with branches swapped"
  (define a (nix-emit "(define-target nix) (if-not (> x 0) \"neg\" \"pos\")"))
  ;; Source swap: (if-not c t e) → (if c e t)
  (define b (nix-emit "(define-target nix) (if (> x 0) \"pos\" \"neg\")"))
  (check-equal? a b))

(test-case "unless is removed; when-not is the Clojure spelling"
  ;; `unless` removed 2026-06-12 — not a Clojure form; zero corpus hits.
  (check-false (nix-emit "(define-target nix) (unless (> x 0) (println x))"))
  ;; when-not lowers to (if (not c) (do body…)) and emits fine.
  (define out (nix-emit "(define-target nix) (when-not (> x 0) (println x))"))
  (check-true (and out (string-contains? out "if"))))
