# Beagle surface syntax — THE RULES

**This top section is authoritative and complete.** Everything below it is the
historical record: the original ruling, its successors, and the rationale for
each decision. Read below when you want to know WHY. Read here when you want to
know WHAT.

Last consolidated 2026-08-19.

## Grammar

1. **Flat pairs.** A typed binding vector alternates `binding Type`. The paren
   unit `(name Type)` is retired.
2. **Binding first, type second.** Everywhere, no exceptions.
3. **Arity is fixed by the surrounding form:**

       defn / fn parameters    binding Type
       let / loop bindings     binding Type initializer
       def / defonce           name Type initializer
       defrecord fields        field Type
       return type             bare, positional, after the vector

4. **Omitted binding types are ILLEGAL.** Every value declaration carries an
   authored type. An odd form count is a structured diagnostic naming the
   binder, never a generic malformed-list error.
5. **Return types are mandatory** — always explicit, always the slot
   immediately after `]`.
6. **Variadic** is `&` followed by exactly one ordinary pair:
   `& values (Vec Int)`.
7. **A destructuring form is ONE binder**, so arity is unchanged:
   `{:keys [w h]} Size`. Inner names project from the type and need no
   annotation.
8. **Per-parameter constraints are refinement type expressions** occupying one
   type slot: `(Int where (> _ 0))`. `_` is the parameter.
9. **Cross-parameter constraints** go in one `(where ...)` clause, after the
   return type.
10. **`Any` is a deliberate dynamic boundary, and nothing else.** Never because
    inference failed, never to avoid writing a known type, never inserted by a
    repair tool.
11. **No `_` inference placeholder.** Deliberately not shipped.
12. **Function type is `(Fn [A B] R)`**; variadic `(Fn [A B & T] R)`. Arrow
    function types are illegal and carry a `legacy-function-type` diagnostic.
13. **The binding vector stays.** Four independent removal attempts failed; see
    the adversarial-review section below.
14. **Mixed vectors are rejected** — `[(a Int) b]` is an error naming the
    untyped binder. All-legacy vectors still parse during migration.

## Printer

15. **Structural layout, never width-driven.** One space between tokens.
    Formatting depends on syntactic structure only — no width thresholds, no
    fit tests, no alignment gutters, no rename-sensitive decisions.

16. **Binding vectors.** A vector containing zero or one binding stays inline.
    A vector containing two or more bindings breaks, exactly one complete
    binding per line. A binding is counted by the surrounding grammar — a
    parameter pair, a local-binding triple, a record-field pair.

    ```clojure
    (defn greet [name String] String
      ...)

    (let [name String (read-name input)]
      ...)

    (defn resize
      [width Int
       height Int] Shape
      ...)

    (let [width Int (read-width input)
          height Int (read-height input)]
      ...)
    ```

    **There is no refinement exception.** A single binding stays inline whether
    or not its type carries a refinement — `(defn positive [n (Int where (> _ 0))] Int`.
    The earlier exception claimed a line carrying a compound type must not also
    carry the vector's structure, which is false on its own example: `[` and `]`
    sit on that very line. No invariant stood behind it, so it was a width
    argument in disguise.

17. **Declaration and expression heads.** When a DECLARATION's binding vector
    breaks, the declaration header — operator plus declared identity — stays on
    the preceding line. EXPRESSION forms keep the opening `[` attached to the
    expression head.

    ```clojure
    (defn resize                          ; declaration → header line, vector below
      [width Int
       height Int] Shape
      ...)

    (let [width Int (read-width input)    ; expression → [ attached
          height Int (read-height input)]
      ...)
    ```

    Vector-bearing declarations: `defn`, `fn` where declaration-shaped,
    `defrecord`, `defunion`, `defmacro`, `defprotocol`. (`def`, `defonce`,
    `defalias`, `defenum`, `defscalar` carry no binding vector, so this rule
    never fires on them — `(defalias UserId String)` stays one line.)
    Expressions: `let`, `loop`, `fn`, `letfn`, `for`, `doseq`.

    The predicate is **semantic node class** — never spelling, never line width,
    never the mere presence of a name. Verified against all 16 binding forms in
    the corpus with no exceptions, including `letfn` (an expression whose vector
    holds declarations: the outer `[` attaches, inner entries follow the
    ordinary rules).

    The scan-anchor invariant is that `(defn factorial` stays intact. It does
    NOT follow that the line must END there — trailing signature information
    neither moves the name nor makes it harder to find.

18. **Function signatures stay contiguous.** In `defn` and `fn` the parameter
    vector and return type are ONE signature, `[parameters] Return`. The return
    type is always printed on the same line as the vector's closing `]`, whether
    the vector is inline or broken.

    ```clojure
    (defn factorial [n Int] Int
      ...)

    (defn transform
      [input Document
       options TransformOptions] (Result Document TransformError)
      ...)

    (fn [x Int
         y Int] Int
      ...)
    ```

    The reason is the mirror in rule 12: `[params] Return` renders
    `(Fn [A B] R)` — domain fenced, codomain immediately after. Splitting them
    breaks one grammatical object into two visual ones. It is worst with a
    compound return type, where a standalone `(Result AST ParseError)` becomes a
    parenthesized sibling of the first body form at the same indentation,
    distinguishable only by knowing the positional grammar.

    No width threshold, and no atomic-versus-compound exception.

    *Recorded cost:* with two or more bindings the last binding line carries a
    binding AND the codomain, where the other lines carry only a binding. This
    is real, and it is the same heterogeneity that argued against dangling
    delimiters. It is accepted because `]` is an unmissable boundary and the
    compound-return confusion above is the worse failure.

19. **Cross-parameter `where` clauses always break.** The single optional
    `(where ...)` clause occupies its own line immediately after the
    `[parameters] Return` signature and before the body. It never shares the
    return-type line, regardless of size. A multiline predicate uses ordinary
    expression indentation inside the clause.

    ```clojure
    (defn resize
      [shape Shape
       width Int
       height Int] Shape
      (where (fits shape width height))
      ...)

    (defn slice
      [buffer Buffer
       start Int
       end Int] Buffer
      (where
        (and (<= 0 start)
             (<= start end)
             (<= end (length buffer))))
      ...)
    ```

    Structural, not width-driven: `[params] Return` is the core function type;
    the `where` clause is an optional QUALIFICATION of that signature, not one
    of its two type components. The hierarchy is identity → signature →
    optional constraint → body. No short-`where` inline exception, because that
    reintroduces measured-fit formatting.

    The clause shares indentation with the first body form. That is correct:
    `where` has a reserved positional role, and the grammar already
    distinguishes the signature clause `(where pred)` from the refinement type
    `(Int where pred)` by shape. Deeper indentation would imply a nesting that
    does not exist.

20. **Ordinary applications do not break.** Operand lists are not vertically
    broken by this law:

    ```clojure
    (+ dx dy)
    (get m :key)
    ```

    Binding vectors belonging to expression forms — `let`, `loop`, `fn`,
    `letfn`, `for`, `doseq` — remain governed by rule 16. (An earlier draft said
    "expressions never break," which was literally false against those forms.)

21. **No dangling delimiters. No block vectors.** Closing parens and brackets
    collect on the last content line, as in every Lisp. The logic behind
    dangling delimiters does not stop at the vector — it forces `(defn` onto its
    own line, which costs the scan anchor in rule 17. There is no coherent
    stopping point between collected parens and every delimiter on its own line.

**Note on rules 16–21:** these do NOT all descend from one principle. Rule 16
comes from "position can be miscounted"; rule 17 from the declaration header
being a scan anchor; rule 18 from the `Fn` mirror; rule 19 from the signature /
qualification hierarchy. An earlier draft claimed 17–19 followed from 16, which
overstated the unity. They are independent laws that happen not to conflict.

## The admissibility filter for any future formatting rule

A formatting rule needs **either a positive reading or structural purpose, or a
concrete invariant it protects.** Hypothetical defensive benefits do not justify
permanent syntax on their own.

The distinction is *concrete invariant* versus *hypothetical anxiety*, NOT
positive versus defensive. Purely defensive reasoning produced the strongest
rule here — the binding vector survives because without it two grammatical
productions are indistinguishable. What failed were anxieties, not defences:
reflow on rename (the printer absorbs it; second-order, does not decide when
readability gives a clear answer) and diff size (optimizes a tooling artifact,
not readability).

## Migration

22. **Order:** land the dual-read reader → build the `let`/`loop`/`def` triple
    grammar → convert file by file in parallel lanes → flip legacy off last, as
    a single final commit.
23. **Migration AUTHORS types, it does not reshape them.** 12,017 sites need a
    type written; roughly 3,600 are machine-derivable for review. A further
    43,526 sites are pure mechanical reshape.

---

# Historical record and rationale

# Beagle surface syntax ruling — typed bindings (2026-08-18)

Ruled in operator session 2026-08-18 (operator taste decisions + commander
judgment). Supersedes the grouped `(name Type)` annotation unit everywhere.
Migration is queued for immediately after the native compiler binary exists —
byte-parity baselines freeze surface churn during the self-compiler campaign.

## The rules

1. **Flat pairs.** A typed binding vector alternates `binding-form Type`.
   The paren unit `(name Type)` is retired: in a Lisp, parens mean a form with
   an operator head, and `(name String)` reads as application — a lie about
   structure.

2. **Order law.** Binding first, type second, everywhere — `defn`, `fn`, and
   every future binding site. No exceptions, no mixed order.

3. **Constraints are never a third slot.** A per-parameter constraint is a
   refinement *type expression* — `(Int where (> _ 0))` — whose parens are
   honest (it is a form, `where` in operator position). Cross-parameter
   constraints go in one `(where ...)` clause after the return type; a
   per-param slot could never express `(<= lo hi)`. Named refinements via
   `defcontract` (`PosInt`, `NonEmptyString`) are the everyday texture; inline
   `where` is the exception.

4. **Return type** is bare, after the binding vector.

4a. **Strict pairs — no mixing.** A typed binding vector is pairs all the way
   through: every binder gets exactly one following type expression. Mixed
   vectors (`[x Int y z String]` with `y` inferred) are banned — one bare
   binder destroys the parseability of everything after it. An odd form count
   is a structured diagnostic naming the binder: `parameter age has no
   following type`, never a generic malformed-list error.

4b. **Variadic**: `&` is a marker followed by exactly one ordinary pair —
   `& values (Vec Int)`.

4c. **Uniform declaration sites.** `defrecord` fields take the same pair law
   and the same breaking law:

   ```clojure
   (defrecord Point
     [x Float
      y Float])
   ```

   `def` needs no new grammar: ascription covers it —
   `(def answer (: 42 Int))`; `def` stays name + value.

5. **`let` stays binding/init.** Local types by inference; explicit ascription
   is `(: expr Type)` on the expression. Binding vectors never grow triples.

6. **Printer law** (enforced by the canonical printer — there is exactly one
   rendering of a definition, never a convention humans maintain):
   - One space between tokens, everywhere. No column alignment, no gutter
     wider than the token separator, no thresholds.
   - Breaking law: any typed binding vector (`defn`, `fn`, `defrecord`, every
     future site) with more than one pair, or any refinement, breaks one pair
     per line — return type on its own line for `defn`. A single unrefined
     pair may stay inline.

## Canonical examples

```clojure
(defn greet [name String] String
  (str "hello " name))

(defn resize
  [shape Shape
   width (Int where (> _ 0))
   height (Int where (> _ 0))]
  Shape
  (where (fits shape width height))
  ...)

(defn place
  [{:keys [w h]} Size
   label String]
  Point
  ...)

(let [x (: (parse s) Int)]
  ...)
```

## Rationale digest

- Name-then-type matches the dominant pretraining prior (TypeScript, Python,
  Kotlin, ML, Typed Racket) — agents emit it at near-zero error rate.
- The pair needs no delimiter because alternation is the grammar — the same
  visual grammar as `let`, which every reader already parses on sight.
- Column alignment rejected: wide space-only gaps break row tracking (tables
  that wide need dot leaders); alignment produces output identical to fixed
  spacing except exactly where name lengths vary, which is where it degrades
  (dead air, exemption cliffs, whole-vector reflows). rustfmt/prettier/black
  all shipped and then killed alignment for the same reasons.
- Two-space gutter rejected: the single-line form `[name String]` is one
  space; the same pair must not print differently by breaking. One space
  between tokens is the whole spacing spec.
- Metadata annotation (`^String name`) disqualified on principle: Beagle types
  are semantic and participate in canonical identity; a side-channel invisible
  to equality is the wrong home for a load-bearing type.
- **The return type is bare because the declaration mirrors its own type.**
  `(defn move [p Point dx Float] Point ...)` has type `(Fn [Point Float] Point)`
  — domain fenced, codomain after it, same shape in both. The apparent
  asymmetry (inputs packaged, output loose) is not a wart; it is the honest
  rendering of a real asymmetry, N inputs and 1 output. `Fn` is also uniform as
  a constructor this way: exactly two arguments, always.
- Formatting churn is structurally absorbed: identity is AST-keyed, and the
  shadow-parity gate proved whitespace edits perturb only the exact-text facet
  and spans — zero fact invalidation.

## Refinement semantics (ruled)

A `where` refinement is a **fact**, and its enforcement placement is also a
fact. The checker discharges the predicate statically wherever provable;
it materializes as a runtime guard exactly where the trust domain changes
(host boundaries, untyped edges) per the ruled trust-domain erasure. The base
type erases as usual; the predicate is authored executable logic and is
preserved. Where each predicate was proven versus guarded is recorded and
queryable — refinement behavior is never implicit.

Shape disambiguation is deliberate: refinement is infix — `(Int where pred)` —
and the signature clause is head-led — `(where pred)`. If refinement were
head-led too, the two constructs would differ only by arity and a malformed
one-argument refinement would silently parse as a constraint clause. Distinct
shapes are the stronger property; the infix form is documented honestly as a
type-grammar production, not an expression form.

Rejected: `⟨ ⟩` declaration brackets (non-ASCII, tool-hostile, and adjacency
in a known context already gives the parser its declaration node — `let` has
proven this for decades); `(where Type pred)` head-led refinement (arity-only
disambiguation, above).

## Migration scope (post-campaign seam)

Reader, canonical printer, corpus, self-host bundle, oracle grammar, docs.

---

# Ruling 2 — fixed arity, no omitted types (2026-08-19)

**Supersedes rule 5 of the original ruling above** ("`let` stays binding/init.
Local types by inference"). That was written before the consequence of removing
the paren entry-boundary was worked through. It is wrong and is replaced.

## The forcing argument

The old permissive grammar — a bare symbol requests inference, `(binding Type)`
is one typed entry — was parseable ONLY because the parentheses supplied an
entry boundary. `[a (b Point)]` mixes an inferred and a typed binding
unambiguously because the parens say where each entry starts and ends.

Remove the parens and that permissiveness has no principled meaning:

    [a b c d]          ; two typed pairs, or four inferred parameters?
    (let [x T y z U w]) ; two typed triples, or three inferred pairs?

Parsing must never depend on resolving which symbols happen to name types. So
adopting the flat surface REQUIRES the stronger fixed-arity rule. The rule is
better for Beagle independently, but it is not optional.

## The law

Every root value declaration carries an authored type slot. Arity is fixed by
the surrounding form:

    defn parameters       binding Type
    let / loop bindings   binding Type initializer
    def / defonce         name Type initializer
    record fields         field Type
    return types          always explicit, positional after the parameter vector

    omitted binding types ILLEGAL

Examples:

```clojure
(defn greet
  [name String
   age Int]
  String
  ...)

(let
  [name String (read-name input)
   age Int (read-age input)]
  ...)

(loop
  [i Int 0
   total Int 0]
  ...)

(defrecord Person
  [name String
   age Int])

(def answer Int 42)
```

The visual law is identical everywhere: **noun, then type**. The initializer is
simply the third component a local declaration requires.

## Types ride on bindings; expressions infer

Mandatory declaration types are NOT the removal of inference. In

```clojure
(let [name String (read-name input)]
  (str "hello " name))
```

the compiler still infers the type of `(read-name input)` and checks it is
admissible as `String`, infers `(str "hello " name)`, checks the body against
the declared return, and infers every intermediate expression. Explicit types
live on binding declarations; expression interiors stay inferred.

## `Any` is a boundary, never inference

`Any` remains legal and means exactly one thing: deliberately discard any
stronger static fact and bind at an open dynamic type. If `read-name` produces
`String`, annotating it `Any` is a semantic DOWNGRADE and should be unusual and
conspicuous.

```clojure
(let [payload Any (read-host-value)]   ; legitimate: a real dynamic boundary
  ...)
```

`Any` must never be: inserted because inference failed; used to avoid writing a
known type; read as "compiler, work this out"; silently selected by a repair
tool; or permitted where a native representation or proof is required. The
checker already refuses `Any` inside binding constraints, which is the same
principle — it is not a harmless wildcard.

    omitted type              no
    Any as inference          no
    Any as dynamic boundary   yes

## Destructuring and refinements need no special case

The whole destructuring form is ONE binder, so the arity is unchanged:

```clojure
(let [{:keys [w h]} Size (measure input)] ...)   ; binder / type / initializer
(defn area [{:keys [w h]} Size] Int (* w h))     ; binder / type
```

`w` and `h` need no annotations; their types project from `Size`. Refinements
are ordinary type expressions and likewise occupy exactly one slot:

```clojure
(let [width (Int where (> _ 0)) (read-width input)] ...)
```

## No inference placeholder yet

`_` as "infer this type" is deliberately NOT shipped. It reintroduces a weaker
declaration mode before mandatory local types have been shown to be burdensome,
and in an agent-authored language the usual objection to annotations — the
effort of typing them — is largely absent. Start with the stronger invariant:
every value declaration has an authored type slot. An inference hole can be
added later without changing the grammar; omission cannot be added back cleanly
once removed, because it is what destroys the grammar.

## Migration consequence

The current bare-symbol inference policy is REMOVED as part of adopting the flat
syntax. It was coherent only while `(binding Type)` supplied an entry boundary.
Every migration seam must therefore also convert inferred bindings to authored
types rather than only reshaping existing annotations — this is strictly more
work than a mechanical reprint, and any bare binder the printer meets is a site
needing an authored type, not a form to pass through.

## Breaking law, restated absolutely (operator, 2026-08-19)

Supersedes the wording in rule 6, which said "more than one pair". Under Ruling
2 a binding is a pair in some forms and a triple in others, so the rule is
stated in BINDINGS, not slots:

**More than one binding in a vector ALWAYS breaks, one binding per line. No
exceptions, no width threshold, no "it fits" case.**

This is forbidden and the printer must never emit it:

```clojure
(defn greet [a String b Int] String ...)     ; ILLEGAL
```

It is written:

```clojure
(defn greet
  [a String
   b Int]
  String
  ...)
```

Inline is permitted in exactly one case: a vector containing a SINGLE binding
with no refinement.

```clojure
(defn greet [name String] String ...)        ; legal — one binding
(def answer Int 42)                          ; legal — one binding
```

Any refinement forces the break even for a single binding, because a refinement
is a compound type expression and a line carrying one must not also carry the
vector's structure.

The rule is per-VECTOR, not per-form: it holds identically for `defn`, `fn`,
`let`, `loop`, `defrecord`, and every future binding site. A `let` with two
bindings breaks exactly as a `defn` with two parameters does. There is no form
in the language where two bindings share a line.

---

# Ruling 3 — mixed legacy vectors are a REJECTION, not a regression (2026-08-19)

The flat-binding reader rejects a vector that mixes a grouped declaration with a
bare inferred binder — `[(a Int) b]`, `[x ({:keys [y]} Config) & rest]`. Seven
suite tests assert those parse. **The tests are wrong and the reader is right.**

Ruling 2 states the law: `omitted binding types ILLEGAL`. A bare binder inside a
declaration vector is precisely the construct Ruling 2 deleted, and the forcing
argument there shows the old permissiveness was parseable only because the
parens supplied an entry boundary. Removing the paren removes the permission.
A test asserting that a bare binder still parses is asserting a policy the
language no longer has.

The compliant fix is therefore NOT to restore permissiveness. Restoring it is
also unsound: `structured-binding?` matches any 2–3 element list with a symbol
head, so a flat type expression `(Vec Int)` is shape-indistinguishable from a
legacy `(name Type)`, and an "if any item is grouped, use legacy mode" rule
would misparse `[a (Vec Int) b String]`.

Those tests are rewritten to assert the DIAGNOSTIC — the structured error naming
the untyped binder, per rule 4a — instead of the parse. The corpus is already
clean: all 492 tracked Beagle sources parse byte-identically before and after,
so no real program depends on the removed permission.

What is NOT waived by this ruling: the `defrecord` field diagnostic regression
(hints like `Did you mean: (id String (wire-validator id))` degrading to
`unknown type: id`) is a genuine defect and must be repaired, because the repair
hints feed the automated repair loop; and the printer's failure to break `let`
and `loop` bindings one-per-line violates the absolute breaking law above.

---

# Ruling 4 — migration is incremental behind the dual-read reader (operator, 2026-08-19)

The corpus is NOT converted before the reader lands. Ordered:

1. **Land the dual-read reader.** It accepts legacy `(name Type)` AND flat
   `name Type`. Landing it changes no existing program — proven: all 492
   tracked Beagle sources parse byte-identically before and after, and 5.09 MB
   of emitted output is byte-identical.
2. **Build the Ruling 2 declaration grammar** — `let` / `loop` / `def` /
   `defonce` as `binding Type initializer` — alongside the existing ascription
   form, again dual-read. This does not exist yet; the landed reader implements
   Ruling 1 only.
3. **Convert the corpus file by file, in parallel lanes.** Legacy keeps
   working throughout, so no lane blocks another and no landing is atomic.
4. **Flip legacy off last.** The bare-binder rejection and the removal of the
   `(name Type)` reader become a single final commit, once no tracked source
   depends on either.

Rejected: authoring all sites before landing (blocks the whole thread for days
and serializes work that has no reason to serialize); flat-for-new-code-only
(two permanent dialects, and Ruling 2's grammar argument dies).

The dual-read capability exists precisely so the migration need not be atomic.

---

# The binding vector survived adversarial review (2026-08-19)

Four independent attempts to DELETE the binding vector were run and all four
failed. Do not re-run these cold; the arguments are recorded here.

1. **Flat parameters** — `(defn add x Int y Int Int (+ x y))`. Fails: the
   parser cannot tell where parameters stop. `(defn f x Int y Int x)` is
   genuinely ambiguous between two params with no body, and one param with `y`
   as the return type and `Int x` as a two-form body. Nothing in the grammar
   decides it.

2. **Positional rule "return type follows the last typed input."** Same failure
   one level deeper: it requires knowing which symbols name types, at parse
   time. Ruling 2's forcing argument already forbids that — "parsing must never
   depend on resolving which symbols happen to name types."

3. **Capitalization as law** — types Capitalized, binders lowercase, enforced,
   so the parser can distinguish them lexically. Fails three ways: renaming
   `Point` to `point` becomes a parse error rather than a style change;
   `forall` variables (`A`, `B` in `(Fn [A B] R)`) are capitalized but are
   variables, not types; and destructuring binders (`{:keys [w h]}`) and
   refinements (`(Int where (> _ 0))`) are forms rather than symbols, so they
   need shape-based handling regardless. Today capitalization is only a
   WARNING — `note-capitalized-binding!` at `beagle:beagle-lib/private/parse.rkt`
   — never a rule.

4. **Flat `Fn`** — `(Fn A B R)` with "last argument is the codomain." Works for
   `Fn` alone, since a type form has no body. But `defn` and `fn` DO have
   bodies, so the same rule is unavailable to them and they would keep the
   bracket — breaking the declaration/type mirror above. Also `(Fn [A B & T] R)`
   loses the boundary that scopes `&`, and `(Fn [] R)` degrades from an explicit
   empty node to an absence.

**One constraint kills all four: the parser must find the structure before
anything knows what a type is.** Every removal path ends up needing type
knowledge at parse time. The bracket supplies the boundary while asking no
question about meaning.

## Dangling delimiters and block vectors — considered, REJECTED (2026-08-19)

Proposed: give closing brackets their own line so appending a binding is a
one-line diff, then — for consistency — give opening brackets their own line
too, making every broken vector a block:

```clojure
[
  width Int
  height Int
]
```

The motivating defect is real: in `[width Int` / `height Int]` the first element
shares a line with `[` and the last shares one with `]`, so three structurally
identical elements get three different renderings.

**It was rejected because the logic does not stop at the vector.** If elements
must not share lines with delimiters, the same argument applies to the enclosing
form, which lands on:

```clojure
(
  defn
  resize
  [
    width Int
    height Int
  ]
  Shape
  (make-shape width height)
)
```

Ten lines for a two-parameter function, and `(defn resize` is gone as a scan
anchor — a file becomes a column of bare symbols in which a function name is
indistinguishable from a parameter name. There is no coherent stopping point
between "collect the parens" and "every delimiter on its own line"; a half
commitment is arbitrary.

The scan anchor is worth more than delimiter uniformity, so the first/last
asymmetry is accepted as the price of collected parens. Collected parens are
what make a Lisp scannable.

The git-diff argument (one-line append instead of two) was raised and is weak:
it optimizes a tooling artifact rather than readability, and readability is the
criterion.

Also considered and rejected as UNNECESSARY rather than unsound: an explicit
return marker, `(defn slice [...] -> Buffer ...)`. Since Ruling 2 makes return
types mandatory, the slot immediately after `]` always holds exactly one item
and it is always the return type. Position already disambiguates it, so the
marker buys nothing — and `->` additionally collides with the threading macro
and with the retired arrow function types that `beagle:beagle-lib/private/types.rkt`
diagnoses as `legacy-function-type`.

## Machine-assisted authoring is the lever

Ruling 2 removes bare-binder inference, so migration must AUTHOR types rather
than reshape existing ones. But the compiler already infers a type for every one
of those bindings — that is what it does today. Where inference yields a
concrete type, the authored annotation is mechanically derivable and needs
review, not invention. Human judgment is required only where inference yields
`Any`, is ambiguous, or where the inferred type is not the type the author
means. Sizing the migration therefore means splitting the sites into
machine-derivable and judgment-required, not counting them.
