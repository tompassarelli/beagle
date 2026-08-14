#lang racket/base

;; In-compiler capability cheatsheet — the single source of truth for "what
;; beagle can do". Every entry carries a RUNNABLE example, and
;; beagle-test/tests/cheatsheet.rkt parses + type-checks every one, so this
;; file physically CANNOT claim a capability that doesn't work. That is the
;; anti-rot guarantee: unlike hand-written reference (which drifted — an agent
;; once concluded beagle had no refinement types while `defscalar :where` had
;; shipped for weeks), a stale entry fails the build.
;;
;; It is generated/verified, not prose — consistent with beagle's "no static
;; reference; the compiler is the source of truth" rule. Render it with
;; `bin/beagle-cheatsheet`.
;;
;; Examples omit the file preamble for brevity. Bare `#lang beagle` selects
;; Core; hosted Clojure is explicit `#lang beagle/clj`. The test checks the
;; shared surface under the hosted Clojure profile.

(require racket/string)

(provide (struct-out cheat)
         CHEATSHEET
         cheat-categories
         render-cheatsheet)

;; form     : the surface form / capability name
;; category : grouping for display
;; summary  : one line — what it does and the gotcha worth knowing
;; example  : a runnable snippet (preamble-free) that MUST parse + type-check
(struct cheat (form category summary example) #:transparent)

(define CHEATSHEET
  (list
   ;; --- types ---------------------------------------------------------------
   (cheat "defrecord" "Types"
          "Product type with typed fields; generates a constructor and accessors."
          "(defrecord Point [(x Int) (y Int)])")

   (cheat "defunion + match" "Types"
          "Sum type over records. `match` is checked EXHAUSTIVELY — a missing constructor is a compile error (and the authoring loop can auto-fill the clauses)."
          (string-append
           "(defrecord Circle [(r Int)])\n"
           "(defrecord Square [(side Int)])\n"
           "(defunion Shape Circle Square)\n"
           "(defn area [(s Shape)] Int\n"
           "  (match s [(Circle r) r] [(Square side) side]))"))

   (cheat "defscalar :where" "Types / contracts"
          "Refinement contract: a base type narrowed by predicates. Literal violations are caught statically; non-literal values get a runtime guard emitted per target (nix `assert`, clj `:pre`, js `throw`)."
          (string-append
           "(defscalar Percentage Int :where (>= 0) (<= 100))\n"
           "(def half Percentage (->Percentage 50))"))

   (cheat "defenum" "Types"
          "Enumeration of named constants."
          "(defenum Color Red Green Blue)")

   (cheat "structural binding annotations" "Types"
          "The outer `[...]` is only a collection; each entry is `symbol`, `(binding-form Type)`, or `(binding-form Type constraint)`. Thus `[a (b Point)]` directly mixes an inferred and a typed binding. Sequential and associative destructures may occupy `binding-form`; their complete incoming aggregate is typed and, when present, passed to the constraint before any names are projected. A constraint must be a statically known synchronous unary `(Fn [Type] Bool)` predicate without `Any`; false raises a runtime binding-constraint error. Call-produced predicates require an explicit positive returned-callable synchronization proof from the callee; executing the factory synchronously is not sufficient. Every field or macro declaration likewise owns all its validators/encoders/decoders in one form; flattened adjacent metadata is rejected. Executable signatures place their mandatory return directly after the parameter vector; a type-level function signature is written `(Fn [ParamType ...] ReturnType)`."
          (string-append
           "(defn positive? [(value Int)] Bool (> value 0))\n"
           "(defn clamp [(n Int positive?)] Int (if (> n 100) 100 n))"))

   ;; --- bindings & functions ------------------------------------------------
   (cheat "def / defonce" "Bindings"
          "Typed top-level binding."
          "(def answer Int 42)")

   (cheat "defn" "Functions"
          "Function with typed params and return. Params are a bracket vector."
          (string-append
           "(defn add [(x Int) (y Int)] Int\n"
           "  (+ x y))"))

   (cheat "let / loop / recur / cond" "Control flow"
          "Standard control flow; bindings use bracket vectors."
          (string-append
           "(defn sum-to [(n Int)] Int\n"
           "  (loop [i 0 acc 0]\n"
           "    (cond [(> i n) acc]\n"
           "          [:else (recur (+ i 1) (+ acc i))])))"))

   ;; --- macros & interop ----------------------------------------------------
   (cheat "defmacro + quasiquote" "Macros"
          "Hygienic macros. Quasiquote `` ` ``, unquote `~`, splice `~@`. Free references resolve at the macro's definition site (mode-2 hygiene). Structural declaration macros use `(syntax-error-at original-input index message ...)` from `map-indexed` to point at one exact caller form; indices are zero-based over logical elements."
          "(defmacro twice [x] `(do ~x ~x))")

   (cheat "declare-extern" "Interop"
          "Declare a host function/value with a type so typed code can call into the target runtime."
          "(declare-extern host/now (Fn [] Int))")))

(define (cheat-categories)
  ;; preserve first-appearance order
  (let loop ([cs CHEATSHEET] [seen '()] [acc '()])
    (cond
      [(null? cs) (reverse acc)]
      [(member (cheat-category (car cs)) seen) (loop (cdr cs) seen acc)]
      [else (loop (cdr cs)
                  (cons (cheat-category (car cs)) seen)
                  (cons (cheat-category (car cs)) acc))])))

(define (render-cheatsheet)
  (define out (open-output-string))
  (fprintf out "# beagle cheatsheet\n\n")
  (fprintf out "What the language can do, with verified examples. Generated by\n")
  (fprintf out "`bin/beagle-cheatsheet` from beagle-lib/private/cheatsheet.rkt; every\n")
  (fprintf out "example is parse+type-checked by the test suite, so nothing here is stale.\n\n")
  (fprintf out "Native Core files use bare `#lang beagle` on `.bgl`; hosted Clojure uses\n")
  (fprintf out "`#lang beagle/clj` on `.bclj`. Then write `(ns ...)` and ordinary forms.\n")
  (fprintf out "For signatures, fields, and the full form set, query the compiler\n")
  (fprintf out "(`bin/beagle sig|fields|syntax`, or `bin/beagle` for all commands);\n")
  (fprintf out "for the target list itself, `bin/beagle langs`.\n")
  (for ([cat (in-list (cheat-categories))])
    (fprintf out "\n## ~a\n\n" cat)
    (for ([c (in-list CHEATSHEET)]
          #:when (string=? (cheat-category c) cat))
      (fprintf out "### ~a\n~a\n\n```clojure\n~a\n```\n\n"
               (cheat-form c) (cheat-summary c) (cheat-example c))))
  (string-append (string-trim (get-output-string out)) "\n"))

(module+ main
  (display (render-cheatsheet)))
