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

- **Structural noun-then-type annotations.** The outer binder vector is only a
  collection. Each entry is a bare symbol or one complete
  `(binding-form Type [constraint])` form; typed and bare entries may mix as
  `[a (b Point)]`. `def`/`defonce` place the type after their name. A bare symbol
  requests inference; explicit `Any` marks a deliberately dynamic boundary. An
  executable return type is the mandatory positional form after its parameter
  vector.
- **Typed destructuring:** a symbol, sequential pattern, or associative pattern
  can occupy `binding-form`. Thus `(x Int)`, `([x y] (HVec Float Float))`, and
  `({:keys [host port]} Config)` use the same structural declaration. The
  nesting represents the binding semantics. A bare destructure in a strict
  typed signature is rejected without an aggregate type to project; bare
  symbols still request inference. Destructure a nominal `Point` by field, as
  `({:keys [x y]} Point)`, rather than positionally. Mixed vectors are direct:
  `[([x y] (HVec Float Float)) opts]`.
- **Binding constraints:** the optional third element in
  `(binding-form Type constraint)` must be a statically known synchronous unary
  predicate `[Type -> Bool]`. The target calls it on the complete incoming value
  before installing the binder or projecting a destructure. False raises a
  runtime binding-constraint error and prevents the binding body from running.
  Constraint signatures containing `Any`, extra arguments, non-`Bool` returns,
  or asynchronous work are rejected rather than compiled as guards.
  Call-produced predicates are accepted only when the callee publishes an
  explicit positive returned-callable synchronization proof; executing the
  factory synchronously is not sufficient.
- **Complete field declarations:** a field owns all its local metadata. Write
  `[(id String id-valid?) (name String name-valid?)]`, never the flattened
  `[(id String) id-valid? (name String) name-valid?]`. Macro-owned DSLs with
  additional validators, encoders, or decoders keep those values in the same
  declaration form and validate that form's exact shape; adjacent entries are
  never repartitioned.
- **Canonical signature layout:** keep `(defn NAME [params] Return` on one line
  when it fits in 80 columns. If only the owner makes it overflow, move the
  complete `[params] Return` unit to the next line. If that indented unit also
  exceeds the width, expand the vector to one binding form per line and put the
  mandatory return on its own line. If one declaration still exceeds the width,
  expand its binding form, type, and constraint inside that declaration. There
  is no parameter-count threshold, partial packing, or alignment whitespace
  that simulates grouping.
- **`defmacro` + quasiquote / unquote / unquote-splicing.** Quasiquote is
  `` ` ``, unquote `~`, splice `~@`. Beagle deliberately dropped the CL-style
  `,`-as-unquote: `,` is whitespace, as in Clojure. Free references resolve at
  the macro's definition site (mode-2 hygiene). Structural declaration macros
  use `(syntax-error-at input-collection zero-based-index message ...)` from a
  `map-indexed` pass to reject and point at one exact caller form; the original
  input collection identity must be preserved.
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
