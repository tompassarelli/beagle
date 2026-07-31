# Surface highlights

[`CHEATSHEET.md`](CHEATSHEET.md) is the primary reference: it is generated from
`beagle-lib/private/cheatsheet.rkt` and every example in it is parse- and
type-checked by the test suite. This page lists surface features the cheatsheet
does not enumerate. When the two disagree, the cheatsheet wins.

```clojure
;; types ride on bindings; interiors inferred
(defn double [n :- Int] :- Int (* n 2))

;; macros + quasiquote — unquote is `~`, splice `~@` (Clojure's syntax-quote
;; unquote, NOT the Common Lisp comma; `,` is whitespace, exactly as in Clojure)
(defmacro inc1 [x] `(+ ~x 1))

;; Clojure threading family, reader conditionals, canonical keyword access
(-> 1 (+ 2) (* 3))
(def msg #?(:clj "hello" :nix "bonjour" :default "hi"))
(:name {:name "ada"})
```

- **Inline `:-` annotations** on the typed boundaries `def` / `defn` / `defonce`
  / `defrecord`; interiors and `let`-locals are inferred.
- **`defmacro` + quasiquote / unquote / unquote-splicing.** Quasiquote is
  `` ` ``, unquote `~`, splice `~@`. Beagle deliberately dropped the CL-style
  `,`-as-unquote: `,` is whitespace, as in Clojure. Free references resolve at
  the macro's definition site (mode-2 hygiene).
- **Clojure threading family:** `->`, `->>`, `as->`, `cond->`, `cond->>`,
  `some->`, `some->>`.
- **Reader conditionals** `#?(:clj … :nix … :default …)` and `#?@(…)`.
- **Quoted containers** `'[…]`, `'{…}`, `'#{…}` self-evaluate.
- **Sourcemap fidelity:** the author's position survives every canonicalization,
  guarded by `beagle-test/tests/sourcemap-fidelity.rkt`, which asserts
  diagnostic-position accuracy.
- **Typo suggestions** for mistyped NixOS options: segment-aware Levenshtein
  against the option schema, with a Top-1 accuracy floor asserted by
  `beagle-test/tests/levenshtein-benchmark.rkt`.
- **Per-target prefixes** (`nix/`, `js/`, …) for forms whose meaning genuinely
  diverges per backend.

Check any snippet with `bin/beagle syntax FILE` (parse) and `bin/beagle check
FILE` (types) rather than trusting a doc.
