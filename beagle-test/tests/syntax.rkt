#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/list
         racket/string
         racket/port
         beagle/private/syntax)

;; ============================================================================
;; 1. Golden valid files — valid input passes unchanged
;; ============================================================================

(define golden-suite
  (test-suite "golden: valid input unchanged"
    (test-case "empty string"
      (define r (repair-structure ""))
      (check-false (repair-result-changed? r))
      (check-equal? (repair-result-confidence r) 'high))

    (test-case "simple call"
      (define r (repair-structure "(foo 1 2 3)"))
      (check-false (repair-result-changed? r)))

    (test-case "nested forms"
      (define r (repair-structure "(define (foo x)\n  (+ x 1))"))
      (check-false (repair-result-changed? r)))

    (test-case "all delimiter types"
      (define r (repair-structure "(defn bar [x y]\n  {:a x\n   :b #{:c :d}})"))
      (check-false (repair-result-changed? r)))

    (test-case "strings with parens inside"
      (define r (repair-structure "(println \"hello (world) [test]\")"))
      (check-false (repair-result-changed? r)))

    (test-case "line comments"
      (define r (repair-structure ";; (unclosed\n(foo)"))
      (check-false (repair-result-changed? r)))

    (test-case "block comments"
      (define r (repair-structure "#| (unclosed |# (foo)"))
      (check-false (repair-result-changed? r)))

    (test-case "nested block comments"
      (define r (repair-structure "#| outer #| inner |# still |# (foo)"))
      (check-false (repair-result-changed? r)))

    (test-case "char literals of delimiters"
      (define r (repair-structure "(list #\\( #\\) #\\[ #\\])"))
      (check-false (repair-result-changed? r)))

    (test-case "regex literal"
      (define r (repair-structure "(re-match #\"[()]+\" s)"))
      (check-false (repair-result-changed? r)))

    (test-case "hash-set literal"
      (define r (repair-structure "#{:a :b :c}"))
      (check-false (repair-result-changed? r)))

    (test-case "multiline let"
      (define r (repair-structure "(let ([a 1]\n      [b 2])\n  (+ a b))"))
      (check-false (repair-result-changed? r)))

    (test-case "real beagle defn"
      (define r (repair-structure
        "(defn process-item [(item : Item)] : Result\n  (let ([id (item-id item)]\n        [val (item-value item)])\n    (if (> val 0)\n      {:status :ok :id id}\n      {:status :error :reason \"negative\"})))"))
      (check-false (repair-result-changed? r)))))

;; ============================================================================
;; 2. Mutation tests — delete/add/swap closers
;; ============================================================================

(define mutation-suite
  (test-suite "mutation: recover from common agent errors"
    (test-case "missing 1 closer at EOF"
      (define r (repair-structure "(foo 1 2"))
      (check-true (repair-result-changed? r))
      (check-equal? (repair-result-confidence r) 'high)
      (check-equal? (repair-result-output r) "(foo 1 2)"))

    (test-case "missing 2 closers at EOF"
      (define r (repair-structure "(define (foo x)\n  (+ x 1"))
      (check-true (repair-result-changed? r))
      (check-equal? (repair-result-output r) "(define (foo x)\n  (+ x 1))"))

    (test-case "missing 3 closers — deeply nested"
      (define r (repair-structure "(a (b (c d"))
      (check-equal? (repair-result-output r) "(a (b (c d)))"))

    (test-case "missing bracket closer"
      (define r (repair-structure "[1 2 3"))
      (check-equal? (repair-result-output r) "[1 2 3]"))

    (test-case "missing brace closer"
      (define r (repair-structure "{:a 1 :b 2"))
      (check-equal? (repair-result-output r) "{:a 1 :b 2}"))

    (test-case "missing hash-brace closer"
      (define r (repair-structure "#{:a :b"))
      (check-equal? (repair-result-output r) "#{:a :b}"))

    (test-case "extra closer at end"
      (define r (repair-structure "(foo))"))
      (check-true (repair-result-changed? r))
      (check-equal? (repair-result-output r) "(foo)"))

    (test-case "extra closer mid-file"
      (define r (repair-structure "(foo) )\n(bar)"))
      (check-equal? (repair-result-output r) "(foo)\n(bar)"))

    (test-case "wrong closer: ) instead of ]"
      (define r (repair-structure "(foo [bar)"))
      (check-true (repair-result-changed? r))
      (define out (repair-result-output r))
      (check-true (check-result-valid? (check-structure out))))

    (test-case "wrong closer: ] instead of )"
      (define r (repair-structure "(foo bar]"))
      (check-true (repair-result-changed? r))
      (define out (repair-result-output r))
      (check-true (check-result-valid? (check-structure out))))

    (test-case "wrong closer: } instead of )"
      (define r (repair-structure "(foo bar}"))
      (check-true (repair-result-changed? r))
      (define out (repair-result-output r))
      (check-true (check-result-valid? (check-structure out))))

    (test-case "truncated in let bindings"
      (define r (repair-structure "(let ([a 1]\n      [b 2"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "truncated in map literal"
      (define r (repair-structure "{:a 1\n :b {:c 3"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "multiple missing closers across forms"
      (define r (repair-structure "(foo\n(bar\n(baz 1"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))))

;; ============================================================================
;; 3. Idempotence tests
;; ============================================================================

(define idempotence-suite
  (test-suite "idempotence: repair(repair(x)) == repair(x)"
    (test-case "idempotent on valid"
      (define src "(defn foo [x] (+ x 1))")
      (define r1 (repair-result-output (repair-structure src)))
      (define r2 (repair-result-output (repair-structure r1)))
      (check-equal? r1 r2))

    (test-case "idempotent after repair"
      (define src "(defn foo [x]\n  (+ x 1")
      (define r1 (repair-result-output (repair-structure src)))
      (define r2 (repair-result-output (repair-structure r1)))
      (check-equal? r1 r2))

    (test-case "idempotent after wrong closer"
      (define src "(foo [bar)")
      (define r1 (repair-result-output (repair-structure src)))
      (define r2 (repair-result-output (repair-structure r1)))
      (check-equal? r1 r2))

    (test-case "idempotent after extra closer"
      (define src "(foo))")
      (define r1 (repair-result-output (repair-structure src)))
      (define r2 (repair-result-output (repair-structure r1)))
      (check-equal? r1 r2))

    (test-case "idempotent on complex multi-error"
      (define src "(let ([a 1]\n      [b 2)\n  (+ a b")
      (define r1 (repair-result-output (repair-structure src)))
      (define r2 (repair-result-output (repair-structure r1)))
      (check-equal? r1 r2))))

;; ============================================================================
;; 4. Parser confirmation — repaired output must parse via CST
;; ============================================================================

(define parser-suite
  (test-suite "parser: repaired output roundtrips through CST"
    (test-case "repaired EOF closers roundtrip"
      (define src "(foo (bar (baz")
      (define fixed (repair-result-output (repair-structure src)))
      (define cst (parse-cst fixed))
      (check-equal? (cst->string cst) fixed))

    (test-case "repaired mismatch roundtrip"
      (define src "(foo [bar)")
      (define fixed (repair-result-output (repair-structure src)))
      (define cst (parse-cst fixed))
      (check-equal? (cst->string cst) fixed))

    (test-case "repaired complex form roundtrip"
      (define src "(defn foo [x y]\n  (let ([a (+ x 1)]\n        [b (* y 2)]\n    {:sum (+ a b)\n     :diff (- a b")
      (define fixed (repair-result-output (repair-structure src)))
      (define cst (parse-cst fixed))
      (check-equal? (cst->string cst) fixed))))

;; ============================================================================
;; 5. Safety tests — delimiters inside strings/comments are ignored
;; ============================================================================

(define safety-suite
  (test-suite "safety: opaque regions are untouched"
    (test-case "parens in string preserved"
      (define src "(define msg \"missing ) here\")")
      (define r (repair-structure src))
      (check-false (repair-result-changed? r)))

    (test-case "brackets in string preserved"
      (define r (repair-structure "(define msg \"[unclosed\")"))
      (check-false (repair-result-changed? r)))

    (test-case "parens in line comment ignored"
      (define r (repair-structure "(foo ;; (unclosed paren\n  bar)"))
      (check-false (repair-result-changed? r)))

    (test-case "parens in block comment ignored"
      (define r (repair-structure "(foo #| (unclosed |# bar)"))
      (check-false (repair-result-changed? r)))

    (test-case "char literal of paren"
      (define r (repair-structure "(list #\\( #\\))"))
      (check-false (repair-result-changed? r)))

    (test-case "escaped quote in string"
      (define r (repair-structure "(define s \"he said \\\"hello\\\" to me\")"))
      (check-false (repair-result-changed? r)))

    (test-case "regex with parens"
      (define r (repair-structure "(re-find #\"(\\\\d+)\" s)"))
      (check-false (repair-result-changed? r)))))

;; ============================================================================
;; 6. CST roundtrip tests
;; ============================================================================

(define cst-suite
  (test-suite "cst: roundtrip identity"
    (test-case "empty"
      (check-equal? (cst->string (parse-cst "")) ""))

    (test-case "atoms only"
      (check-equal? (cst->string (parse-cst "foo bar")) "foo bar"))

    (test-case "nested forms"
      (define src "(define (foo [x : Int]) (+ x 1))")
      (check-equal? (cst->string (parse-cst src)) src))

    (test-case "comments preserved"
      (define src ";; header\n(foo) ;; inline\n#| block |#")
      (check-equal? (cst->string (parse-cst src)) src))

    (test-case "whitespace preserved"
      (define src "(foo\n  bar\n    baz)")
      (check-equal? (cst->string (parse-cst src)) src))

    (test-case "all delimiter types"
      (define src "(defn f [x] {:a #{:b :c}} (list x))")
      (check-equal? (cst->string (parse-cst src)) src))))

;; ============================================================================
;; 7. Structural patch tests
;; ============================================================================

(define patch-suite
  (test-suite "patch: structural editing operations"
    (test-case "rename-symbol"
      (define tree (parse-cst "(defn foo [x] (+ x 1))"))
      (define out (cst->string (cst-rename-symbol tree "x" "y")))
      (check-equal? out "(defn foo [y] (+ y 1))"))

    (test-case "replace-form"
      (define tree (parse-cst "(def x 42)"))
      (define out (cst->string (cst-replace-form tree '(0 2) "99")))
      (check-equal? out "(def x 99)"))

    (test-case "delete-form"
      (define tree (parse-cst "(a)\n(b)\n(c)"))
      (define out (cst->string (cst-delete-form tree '(1))))
      (check-true (string-contains? out "(a)"))
      (check-true (string-contains? out "(c)"))
      (check-false (string-contains? out "(b)")))

    (test-case "insert-form-after"
      (define tree (parse-cst "(a)\n(b)"))
      (define out (cst->string (cst-insert-form-after tree '(0) "(new)")))
      (check-true (string-contains? out "(new)"))
      (define cst2 (parse-cst out))
      (check-equal? (length (cst-content-children cst2)) 3))

    (test-case "wrap-form"
      (define tree (parse-cst "(foo x)"))
      (define out (cst->string (cst-wrap-form tree '(0 1) "(" ")")))
      (check-equal? out "(foo (x))"))

    (test-case "find-defn"
      (define tree (parse-cst "(defn foo [] 1)\n(def bar 2)\n(defn baz [x] x)"))
      (check-true (and (cst-find-defn tree "foo") #t))
      (check-true (and (cst-find-defn tree "bar") #t))
      (check-true (and (cst-find-defn tree "baz") #t))
      (check-false (cst-find-defn tree "qux")))

    (test-case "find-by-line"
      (define tree (parse-cst "(defn foo []\n  (+ 1 2))\n\n(def bar 42)"))
      (define found (cst-find-by-line tree 2))
      (check-true (and found #t))
      (check-true (string-contains? (cst->string found) "+ 1 2")))

    (test-case "chained operations"
      (define tree (parse-cst "(defn calc [x y]\n  (+ x y))"))
      (define r1 (cst-rename-symbol tree "x" "a"))
      (define r2 (cst-rename-symbol r1 "y" "b"))
      (define out (cst->string r2))
      (check-equal? out "(defn calc [a b]\n  (+ a b))"))))

;; ============================================================================
;; 8. check-structure diagnostic tests
;; ============================================================================

(define check-suite
  (test-suite "check-structure diagnostics"
    (test-case "valid input"
      (check-true (check-result-valid? (check-structure "(foo)"))))

    (test-case "unclosed reported"
      (define r (check-structure "(foo"))
      (check-false (check-result-valid? r))
      (check-equal? (length (check-result-diagnostics r)) 1)
      (check-true (string-contains?
        (structural-diagnostic-message (car (check-result-diagnostics r)))
        "unclosed")))

    (test-case "mismatch reported"
      (define r (check-structure "(foo]"))
      (check-false (check-result-valid? r)))

    (test-case "extra closer reported"
      (define r (check-structure "(foo))"))
      (check-false (check-result-valid? r))
      (check-true (string-contains?
        (structural-diagnostic-message (car (check-result-diagnostics r)))
        "unmatched")))))

;; ============================================================================
;; 9. Parinfer indent mode parity tests
;; ============================================================================

(define parinfer-suite
  (test-suite "parinfer: indent mode parity with parinfer-rust"
    (test-case "basic indent — single opener"
      (define r (repair-structure "(defn foo\n  [arg\n  ret"))
      (check-equal? (repair-result-output r) "(defn foo\n  [arg]\n  ret)"))

    (test-case "deeper indent — opener stays open"
      (define r (repair-structure "(defn foo\n  [arg\n   ret"))
      (check-equal? (repair-result-output r) "(defn foo\n  [arg\n   ret])"))

    (test-case "dedent to col 0 closes outer"
      (define r (repair-structure "(defn foo\n[arg\n   ret"))
      (check-equal? (repair-result-output r) "(defn foo)\n[arg\n   ret]"))

    (test-case "full dedent closes all"
      (define r (repair-structure "(defn foo\n[arg\nret"))
      (check-equal? (repair-result-output r) "(defn foo)\n[arg]\nret"))

    (test-case "two top-level forms separated by blank line"
      (define r (repair-structure "(defn foo\n  [arg\n  ret\n\n(defn foo\n  [arg\n  ret"))
      (check-equal? (repair-result-output r)
        "(defn foo\n  [arg]\n  ret)\n\n(defn foo\n  [arg]\n  ret)"))

    (test-case "string with unbalanced parens"
      (define r (repair-structure "(defn foo [a b]\n  (str \"a)b\"\n  ret"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "multiline string"
      (define r (repair-structure "(defn foo\n  \"multi\n  line\"\n  ret"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "indented closer on its own line"
      (define r (repair-structure "(def foo\n  bar\n  )"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "multiple indent levels"
      (define r (repair-structure "(a\n  (b\n    c\n  d\ne"))
      (define out (repair-result-output r))
      (check-true (check-result-valid? (check-structure out))))

    (test-case "hash-set opener"
      (define r (repair-structure "#{:a :b\n  :c"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "mixed delimiter types"
      (define r (repair-structure "(let [a {:x 1\n         :y 2\n  b"))
      (define out (repair-result-output r))
      (check-true (check-result-valid? (check-structure out))))

    (test-case "comment-only lines — closers placed correctly"
      (define r (repair-structure "(let [a 1\n      b 2\n      c {:foo 1\n         ;; :bar 2}]\n  ret)"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "tab indentation"
      (define r (repair-structure "(def foo\n\tbar\n\tbaz"))
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))))

;; ============================================================================
;; 10. Safe auto-apply gate — the contract `beagle-syntax --repair --write` and
;; the PostToolUse hook rely on: high-confidence + re-verifies => auto-apply;
;; low-confidence (e.g. unclosed string) => refuse, never write a guess.
;; ============================================================================

(define safe-write-gate-suite
  (test-suite "safe auto-apply gate"
    (test-case "paren imbalance: high-confidence + re-verifies (auto-applies)"
      (define r (repair-structure "(defn outer []\n  (let [x 1]\n    (when x\n      (g x)))\n\n(defn next-fn [] 1)"))
      (check-true (repair-result-changed? r))
      (check-equal? (repair-result-confidence r) 'high)
      (check-true (check-result-valid? (check-structure (repair-result-output r)))))

    (test-case "defn-swallow (vim.bjs class): close lands before the next top-level defn"
      (define out (repair-result-output
                   (repair-structure "(defn a [x]\n  (foo\n    (bar x)\n\n(defn b [] 2)")))
      (check-true (check-result-valid? (check-structure out)))
      ;; `b` survives as its own top-level form — not swallowed into `a`
      (check-true (regexp-match? #rx"\n\\(defn b" out)))

    (test-case "unclosed string: low confidence => --write refuses (no guess)"
      (check-equal? (repair-result-confidence (repair-structure "(f \"oops)\n")) 'low))))

;; ============================================================================
;; Run
;; ============================================================================

(run-tests golden-suite)
(run-tests mutation-suite)
(run-tests idempotence-suite)
(run-tests parser-suite)
(run-tests safety-suite)
(run-tests cst-suite)
(run-tests patch-suite)
(run-tests check-suite)
(run-tests parinfer-suite)
(run-tests safe-write-gate-suite)
