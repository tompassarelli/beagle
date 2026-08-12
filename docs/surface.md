# Surface highlights

[`CHEATSHEET.md`](CHEATSHEET.md) is the primary reference: it is generated from
`beagle-lib/private/cheatsheet.rkt` and every example in it is parse- and
type-checked by the test suite. This page lists surface features the cheatsheet
does not enumerate. When the two disagree, the cheatsheet wins.

```clojure
;; types ride on bindings; interiors inferred
(defn double [(n Int)] Int (* n 2))

;; macros + quasiquote — unquote is `~`, splice `~@` (Clojure's syntax-quote
;; unquote, NOT the Common Lisp comma; `,` is whitespace, exactly as in Clojure)
(defmacro inc1 [x] `(+ ~x 1))

;; Clojure threading family, reader conditionals, canonical keyword access
(-> 1 (+ 2) (* 3))
(def msg #?(:clj "hello" :nix "bonjour" :default "hi"))
(:name {:name "ada"})
```

- **Structural noun-then-type annotations.** Binder vectors use
  `(binding-form Type)`; `def`/`defonce` place the type after their name. A bare
  simple binder requests inference; explicit `Any` marks a deliberately dynamic
  boundary. An executable return type is the mandatory positional form after
  its parameter vector.
- **Typed destructuring:** a symbol, sequential pattern, or associative pattern
  can occupy `binding-form`. Thus `(x Int)`, `([x y] (HVec Float Float))`, and
  `({:keys [host port]} Config)` use the same annotation primitive. The nesting
  represents the binding semantics. A bare destructure in a strict typed
  signature is rejected without an aggregate type to project; bare simple
  binders still request inference. Destructure a nominal `Point` by field, as
  `({:keys [x y]} Point)`, rather than positionally. Mixed vectors are direct:
  `[([x y] (HVec Float Float)) opts]`.
- **Canonical signature layout:** keep `(defn NAME [params] Return` on one line
  when it fits in 80 columns. If only the owner makes it overflow, move the
  complete `[params] Return` unit to the next line. If that indented unit also
  exceeds the width, expand the vector to one binding form per line and put the
  mandatory return on its own line. There is no parameter-count threshold and
  no partial packing.
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

## Why width owns layout

The signature is one structural unit, so the formatter first tries it beside
its owner and then at the continuation indentation. Only a signature unit that
still does not fit expands its parameter vector. This preserves compact short
signatures regardless of parameter count and exposes genuine structure when a
signature becomes long; punctuation and arbitrary count thresholds do not
participate.

The reader accepts both layouts. `beagle fmt --write .` performs the one-time
and ongoing token-aware rewrite; CI runs `beagle fmt --check .`. The same
formatter implementation therefore owns human, agent, migration, and CI
output.
