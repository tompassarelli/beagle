# Surface highlights

[`CHEATSHEET.md`](CHEATSHEET.md) is the primary reference: it is generated from
`beagle-lib/private/cheatsheet.rkt` and every example in it is parse- and
type-checked by the test suite. This page lists surface features the cheatsheet
does not enumerate. When the two disagree, the cheatsheet wins.

```clojure
;; types ride on bindings; interiors inferred
(defn double [n: Int] -> Int (* n 2))

;; macros + quasiquote — unquote is `~`, splice `~@` (Clojure's syntax-quote
;; unquote, NOT the Common Lisp comma; `,` is whitespace, exactly as in Clojure)
(defmacro inc1 [x] `(+ ~x 1))

;; Clojure threading family, reader conditionals, canonical keyword access
(-> 1 (+ 2) (* 3))
(def msg #?(:clj "hello" :nix "bonjour" :default "hi"))
(:name {:name "ada"})
```

- **Inline postfix `NAME: TYPE` / `[params] -> RET` annotations** on the typed
  boundaries `def` / `defn` / `defonce` / `defrecord`; interiors and
  `let`-locals are inferred.
- **Canonical boundary-vector layout:** zero to two logical parameters or typed
  fields stay inline when the complete signature through any `-> RET` fits in
  80 columns. Three or more, or any over-width signature, put the vector on the
  following line exactly two columns past the owning form's opening
  parenthesis. A vertical vector has one aligned logical entry per line and is
  never partially packed. `]` has exactly one space before any `-> RET`.
  Binding names are left-aligned; `:` attaches to its name and has exactly one
  following space. Names, colons, and types are never padded into columns.
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

## Why two stays compact

The count-plus-width threshold follows established formatter practice rather
than making whitespace part of Beagle's grammar. Clojure formatter zprint's
[`gt2-force-nl`](https://cljdoc.org/d/zprint/zprint/1.3.0/doc/zprint-reference#gt2-force-nl-and-gt3-force-nl)
keeps a form on one line when it fits unless it has more than two arguments.
clang-format's
[`PackParameters: {BinPack: UseBreakAfter, BreakAfter: 2}`](https://clang.llvm.org/docs/ClangFormatStyleOptions.html#packparameters)
combines the same parameter-count threshold with ordinary width wrapping.
Google's [Swift line-wrapping rules](https://google.github.io/swift/#line-wrapping)
provide the complementary invariant: a delimited list is entirely horizontal
or entirely vertical, with one element per line after wrapping. Beagle applies
those priors narrowly to grammar-owned parameter and typed-field vectors.

The reader accepts both layouts. `beagle fmt --write .` performs the one-time
and ongoing token-aware rewrite; CI runs `beagle fmt --check .`. The same
formatter implementation therefore owns human, agent, migration, and CI
output.
