# Surface highlights

[`CHEATSHEET.md`](CHEATSHEET.md) is the primary reference: it is generated from
`beagle-lib/private/cheatsheet.rkt` and every example in it is parse- and
type-checked by the test suite. This page lists surface features the cheatsheet
does not enumerate. When the two disagree, the cheatsheet wins.

```clojure
;; every value declaration carries an authored type
(defn double [n Int] Int (* n 2))

;; macros + quasiquote — unquote is `~`, splice `~@` (Clojure's syntax-quote
;; unquote, NOT the Common Lisp comma; `,` is whitespace, exactly as in Clojure)
(defmacro inc1 [x] `(+ ~x 1))

;; Clojure threading family, reader conditionals, canonical keyword access
(-> 1 (+ 2) (* 3))
(def msg #?(:clj "hello" :nix "bonjour" :default "hi"))
(:name {:name "ada"})
```

- **Flat noun-then-type pairs.** The outer vector alternates `binding Type`.
  Every value declaration carries an authored type; omitted types and mixed
  legacy/flat vectors are rejected with a diagnostic naming the binder.
  `def`/`defonce` use `name Type initializer`; `let`/`loop` use
  `binding Type initializer`; executable return types are mandatory directly
  after the parameter vector. `Any` marks only a deliberate dynamic boundary.
- **Typed destructuring:** a symbol, sequential pattern, or associative pattern
  is one binder and occupies one binding slot. Thus `[x Int]`,
  `[[x y] (HVec Float Float)]`, and `[{:keys [host port]} Config]` use the same
  flat pair grammar. Inner projected names need no annotations. Destructure a
  nominal `Point` by field rather than positionally.
- **Binding constraints:** a per-binding constraint is a refinement type in the
  type slot, such as `[n (Int where positive?)]`. `_` denotes the parameter in
  an inline predicate. A cross-parameter `(where ...)` clause occupies its own
  line immediately after the mandatory return type.
- **Complete field declarations:** a field owns all its local metadata. Write
  `[id (String where id-valid?) name (String where name-valid?)]`, never a
  validator detached from its field's type expression. Macro-owned DSLs with
  additional validators, encoders, or decoders keep those values in the same
  declaration form and validate that form's exact shape; adjacent entries are
  never repartitioned.
- **Canonical structural layout:** layout never depends on width. Zero or one
  binding stays inline; two or more bindings break one complete pair or triple
  per line. Declaration headers remain on their own line when their vector
  breaks; expression heads keep `[` attached. A function's return type stays on
  the line containing `]`, while a cross-parameter `(where ...)` clause always
  takes the following line. Delimiters never dangle.
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

## Why layout is structural

Binding count and surrounding form determine layout before names or line width
are considered. This keeps formatting stable across renames and makes the
parameter vector, return type, optional qualification, and body visually
distinct grammatical units. Use `beagle fmt --write PATH...` to apply the
canonical rewrite and `beagle fmt --check PATH...` when checking a tree.
