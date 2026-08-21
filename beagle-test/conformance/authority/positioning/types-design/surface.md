# SURFACE — algebraic values at the Beagle surface

The surface should make the value being handled explicit: `defrecord` describes
a product with named fields, `defunion` describes a closed sum of named
variants, and `match` is the only general eliminator for a sum. The important
property is not nicer syntax. It is that a declared type becomes a real
compiler boundary. Today a change invalidates 102/102 facts whether it changes
core or a leaf. A declared record or union interface gives the Store a stable
dependency key, while a changed variant set or field type becomes an explicit,
actionable interface break.

This proposal extends the typed Clojure-family surface already visible in
Beagle. Existing records such as `Position`, `Command`, `World`, and
`WindowSamples` in `greywrought:src/native/simulation.bgl` and
`greywrought:src/native/mesher.bgl` are the migration anchors; the proposal
does not require a second object model.

## 1. Surface forms

### Records

`defrecord` remains a nominal immutable product. Every field declaration is a
single `(name Type)` entry, with the same binding grammar used by `def`,
`defn`, and destructuring:

```clojure
(defrecord Position [(x I32) (y I32) (z I32)])
(defrecord Player
  [(id U32)
   (pos Position)
   (vel Velocity)
   (health I32)])
```

The declaration publishes, as one interface, the nominal type identity, field
order, field names, field types, nullability (none unless the type says so),
and generated constructor/accessor names. The current generated style,
`(position-x p)` and `(mesher/->WindowSamples phi materials)`, remains valid.
The compiler additionally generates `Position?` and a typed update operation;
ordinary map operations do not turn a record into an untyped map. Record field
order is semantic for Store encoding, even though source access is by name.

Records are closed products: no undeclared fields, no implicit `nil`, no
structural equivalence with a map, and no record subtyping by accidental field
overlap. A record can contain a union and a union variant can contain a
record. Recursive records require an explicit indirection type rather than
inventing an infinite value layout.

### Unions

The new form is deliberately constructor-shaped and Clojure-like:

```clojure
(defunion GroundMaterial
  (Air)
  (Soil [(hardness U8)])
  (Stone [(hardness U8)]))

(defunion DecodeError
  (BadTag [(tag String)])
  (BadField [(path String)]))

(defunion DecodeResult
  (Decoded [(value GroundMaterial)])
  (Rejected [(reason DecodeError)]))
```

Each variant is nominally owned by exactly one union. A zero-field variant is
written `(Air)`, not `Air` or `nil`; a field-bearing variant uses the same
field declaration grammar as a record. The compiler generates constructors
`(Air)`, `(Soil hardness)`, and `(Stone hardness)`, variant predicates such as
`GroundMaterial?` and `Soil?`, and typed accessors where useful. A constructor
cannot be called as a value of another union merely because its fields happen
to line up.

The union is closed in the declaring module's interface. Adding a variant,
renaming a variant, changing payload fields, or changing a payload type is an
interface change. Reordering source declarations is not. The compiler assigns
stable variant identities from the fully qualified union and variant names,
not from declaration position, so harmless source movement does not churn
FACT-ID. A renamed or deliberately retired variant is a migration, not a
decoder fallback.

For recursive syntax, the union name is in scope in its own payloads:

```clojure
(defunion Expr
  (Literal [(value Int)])
  (Add [(left Expr) (right Expr)])
  (IfZero [(test Expr) (when-zero Expr) (otherwise Expr)]))
```

The compiler must reject recursive definitions whose representation has no
finite indirection point. This is a declaration error, not a runtime stack
overflow.

### Matching

`match` evaluates its scrutinee once, then tries arms in source order. A
variant pattern binds payload fields positionally or by an explicit field
pattern; `_` is the catch-all. Examples:

```clojure
(defn material-hardness [(material GroundMaterial)] U8
  (match material
    (Air) 0
    (Soil hardness) hardness
    (Stone hardness) hardness))

(defn point-length [(point Position)] I32
  (match point
    (Position {:x x :y y :z z})
    (integer-sqrt (+ (* x x) (+ (* y y) (* z z)))))))

(defn describe [(result DecodeResult)] String
  (match result
    (Decoded value) "decoded"
    (Rejected reason) (decode-error-message reason)))
```

Record patterns are nominal checks followed by field projections. A record
pattern may bind only a subset of fields, but a typed pattern cannot introduce
an unknown field. Nested patterns compose:

```clojure
(defn player-health [(world World)] I32
  (match world
    (World {:player (Player {:health health})}) health)))
```

The exact initial pattern language is intentionally small: constructor
patterns, nominal record patterns, literal scalar patterns, variable patterns,
and `_`. Guards are permitted as `:when` after a pattern, but a guard never
counts as proof of exhaustiveness or makes a later arm unreachable. This keeps
exhaustiveness decidable and prevents a host predicate from becoming a hidden
type checker:

```clojure
(match material
  (Soil hardness :when (> hardness 0)) :usable
  (Soil _) :empty
  (Air) :empty
  (Stone _) :solid)
```

The scrutinee and every arm expression follow ordinary Beagle evaluation
rules: the scrutinee is strict and left-to-right, bindings are immutable,
guards run only after their pattern matches, and the result type is the join
of all arm result types. A match has no implicit fall-through and no host
exception escape.

## 2. Exhaustiveness and useful errors

For a closed union, the checker computes coverage by variant identity,
recursively through payload patterns. A bare variable or `_` covers the
remaining domain. Duplicate arms and arms made unreachable by a preceding
unconditional arm are errors in strict typed code; an unreachable guarded arm
is at least a warning until guard-effect and refinement rules are specified.
For `Bool`, `nil`, and finite literal unions the checker also knows the finite
domain. `Int`, `Float`, `String`, and an open `Any` domain require `_` unless
the match is itself a partial operation returning an explicit option/result
type. Arithmetic ranges and arbitrary predicates are not theorem-proved by
the first implementation.

Missing a case is a compile error at the `match`, not a runtime default. The
stable identifier and the repair-oriented text are part of the diagnostic
contract:

```text
BEAGLE-MATCH-NONEXHAUSTIVE at greywrought:src/testing/native/mesher_fixtures.bgl:24:3
match scrutinee has closed type GroundMaterial; missing variant: Stone
covered variants: Air, Soil
add an arm `(Stone ...)` or a final `_` arm
```

The location points to the match form, and the message names the missing
constructor rather than exposing a Racket, Clojure, or JavaScript exception.
For nested coverage, the diagnostic reports the path, for example
`TerrainResult.Accepted.reply-batch`. For duplicate or unreachable patterns:
`BEAGLE-MATCH-UNREACHABLE` names the arm index and the earlier covering arm.
These messages are deliberately written as repair prompts: an AI agent can
make the smallest edit from the missing variant list and immediately rerun
`beagle check --agent`.

Exhaustiveness is a FREEZE obligation. Lowering may use a jump table, tag
switch, or branch chain, but FREEZE must prove that every reachable union tag
has exactly one selected arm and that no arm reads a payload from a different
variant. A corrupted or foreign tag is not silently sent to `_`: it is a
runtime `BEAGLE-INVALID-VARIANT` failure at a checked boundary.

## 3. The `Any` boundary

`Any` is an explicit loss of static knowledge, not an open parent of every
record and union. Typed-to-`Any` passage erases static checking but preserves
the runtime nominal descriptor and union tag. `Any`-to-typed passage requires
an explicit checked decoder or validator:

```clojure
(defn decode-material [(wire Any)] DecodeResult
  (decode wire GroundMaterial))

(defn use-material [(wire Any)] String
  (match (decode-material wire)
    (Decoded material)
    (match material
      (Air) "air"
      (Soil _) "soil"
      (Stone _) "stone")
    (Rejected error) (decode-error-message error)))
```

`decode` is generated from the declared type descriptor. It validates the
nominal union identity, tag, field count, field types, collection bounds, and
recursive depth budget. It returns a typed failure value; it does not throw a
host cast exception or accept a map whose keys merely resemble record fields.
For an untrusted wire or Store payload, this is the only route into a typed
union.

Matching an `Any` directly is allowed only with a final `_` arm. Constructor and
record arms then perform checked runtime tests, and a failed test proceeds to
the next arm. There is no static claim that the listed arms cover all possible
host values. A missing `_` is `BEAGLE-MATCH-ANY-NONEXHAUSTIVE`, even if the
author believes the value is always a particular union. The repair is to
decode first or state the dynamic fallback explicitly:

```clojure
(match value
  (Soil hardness) hardness
  _ 0)                         ; dynamic fallback is visible
```

At an exported function boundary, a declared union parameter is a runtime
validation boundary in hosted profiles and a tag/layout validation boundary in
Native Core. A declared `Any` parameter accepts anything and therefore cannot
provide the interface cutoff needed by Store facts. Migrating a boundary from
`Any` to a union is intentionally a fact dependency change; it should be
recorded as such rather than hidden behind an adapter.

## 4. Representation in all profiles

The representation is profile-specific, but the semantic value is not. The
portable contract is: nominal union identity, stable variant identity,
immutable payload fields, canonical equality/hash behavior, no observable
allocation identity, and the same decode failures. The allocation and wire
dimensions must be represented in the 263-case conformance corpus; in
particular, no profile may inherit a host's map/object equality or lazy
payload behavior.

### Native Core (`core`)

Native lowering uses a tagged closed layout. A union value contains a stable
type/variant tag and either inline fixed-width payload slots or a traced boxed
payload for recursive/variable-size fields. Records use a nominal layout with
field offsets known after lowering. Pattern matching lowers to a tag test and
payload projections; a constructor arm cannot inspect fields before its tag
test. All representations are immutable from surface code, and GC or scalar
replacement may move them without changing Beagle semantics.

The tag is not an `Int` available to the program. Serialization uses the
canonical descriptor, not native padding, pointer values, or field offsets.
This is essential for facts to survive a Native compiler change.

### Hosted Clojure (`hosted-clj`)

The compiler emits private immutable implementation objects carrying the same
descriptor and tag. It may use generated `deftype`, a private record-like
wrapper, or a persistent vector internally, but Beagle code sees only the
generated constructors, predicates, accessors, and match operation. It must
not expose Clojure's map/record equality, Java class identity, lazy sequences,
or host exceptions as Beagle behavior. Constructor application is eager and
payloads are fully validated before the value is returned.

### Hosted JavaScript (`hosted-js`)

The compiler emits frozen immutable values with a private brand and stable
variant tag. A generated implementation may use a frozen object for named
fields and a non-enumerable/private tag, or a generated class, provided the
Beagle-visible behavior is identical. It must not use ordinary JSON objects as
unbranded records: `{x: 1, y: 2}` is not a `Position`. JSON and JS interop
crossings use the generated encoder/decoder and never infer a union from a
truthy property.

Raw `js/*` interop is an explicit host boundary. It may observe or construct
host representatives only through declared `Any`; it cannot claim that an
arbitrary JS object is a typed Beagle union. A JS value coming back from that
boundary must be decoded, and a bad brand/tag/field shape returns the same
`DecodeError` as Native Core and hosted Clojure. `Object.freeze` is an
implementation safety measure, not the semantic definition.

### Store and cross-profile materialization

The canonical value encoding is:

```text
type-id | variant-id | arity | field-1 ... field-n
```

Records encode `type-id | field-schema-version | fields-in-declaration-order`;
unions encode both union and variant identity even when a variant has no
payload. Nested values recursively use the same encoding. Hashes and FACT-ID
therefore do not depend on a host class name, object key order, pointer, or
padding. A materializer for any profile reconstructs the declared value and
rejects an unknown variant, wrong schema version, or invalid payload instead
of defaulting to a nearby case.

The interface digest includes the union's complete closed variant set and the
record's field schema. A body-only implementation change can reuse dependent
facts when its published type/effect contract is unchanged. Adding a union
variant correctly invalidates exhaustive consumers, while changing a leaf
implementation need not invalidate every Store fact. This is the missing
cutoff, not an assertion that every semantic change is cheap: conformance
contract changes, compiler epoch changes, and re-attestation still invalidate
where required.

## 5. Migration from current Greywrought code

The current code already has good product types. For example,
`greywrought:src/native/simulation.bgl:40` declares `Position`, `Command`,
`Player`, and `World`, and `greywrought:src/testing/native/mesher_fixtures.bgl:19`
contains this open-ended classification:

```clojure
(defn seed-material-for [(phi Int)] Int
  (cond
    (> phi 0) 0
    (>= phi (- 0 soil-depth)) 2
    :else 1))
```

The first migration gives the domain a name while retaining the integer
fixture and codec contract at the edge:

```clojure
(defunion SeedMaterial
  (Air)
  (Soil)
  (Stone))

(defn seed-material [(phi Int)] SeedMaterial
  (cond
    (> phi 0) (Air)
    (>= phi (- 0 soil-depth)) (Soil)
    :else (Stone)))

(defn seed-material-code [(material SeedMaterial)] Int
  (match material
    (Air) 0
    (Soil) 2
    (Stone) 1))

;; Compatibility with the existing Vec Int fixture/hash boundary.
(defn seed-material-for [(phi Int)] Int
  (seed-material-code (seed-material phi)))
```

The adapter is temporary only at the declared integer boundary. New code
should carry `SeedMaterial` through meshing and convert once in the canonical
codec. If a fourth material is added, every typed `match` receives the exact
missing-case diagnostic; the compatibility adapter does not silently map it
to a made-up integer.

The same migration applies to the `Any`-heavy hosted authority records in
`greywrought:src/authority/terrain-policy.bjs`. Its current `TerrainResult`
record has `accepted? Bool`, `reason String`, and two `Any` batches. A target
shape is a sum, not a Boolean protocol:

```clojure
(defunion TerrainResult
  (Accepted [(reply-batch TerrainBatch)
             (broadcast-batch TerrainBatch)])
  (Rejected [(reason TerrainRejection)]))

(defunion TerrainRejection
  (InvalidRequest)
  (Conflict [(expected Int) (actual Int)])
  (DurableMismatch [(digest String)]))

(defn result-reason [(result TerrainResult)] String
  (match result
    (Accepted _ _) "accepted"
    (Rejected (InvalidRequest)) "invalid-request"
    (Rejected (Conflict _ _)) "conflict"
    (Rejected (DurableMismatch _)) "durable-mismatch"))
```

The ingress decoder remains `Any` because the browser is hostile; it should
decode into `TerrainResult` or a typed request/error union immediately. Store
materialization then stores the union value, not a map with an `accepted?`
flag. This makes conflicts, writer admission failures, and replay outcomes
visible to exhaustive callers and gives the compiler a stable shape to attach
to a fact.

Migration order is boundary-first: define the union and decoder, change the
producer's declared return type, update each consumer's match, then remove
the Boolean/`Any` adapter. Do not add a permanent `Any` field to avoid a
variant decision. Existing `defrecord` field access remains a low-risk first
step, but any record with a Boolean discriminator plus nullable or `Any`
payloads should be reviewed for conversion to a union.

## 6. Hard problems that must be solved

* **Schema evolution.** A closed union makes variant addition intentionally
  breaking. The compiler and Store need interface digests, migration tools,
  and readable receipts that identify affected match sites. Unknown persisted
  variants need a durable quarantine/error path, not a default arm.
* **Recursive and large values.** Recursive unions need boxed cycles or a
  finite-depth value discipline; Store encoding needs cycle rejection or an
  explicit identity-bearing reference type. Payload limits must be enforced
  before allocation in all profiles.
* **Refinement through guards.** Guards are useful for value constraints but
  are effectful-looking arbitrary code and cannot drive coverage initially.
  A future refinement system must specify purity, termination, solver trust,
  and cross-profile agreement before guards can narrow types.
* **`Any` and hostile input.** Dynamic values can carry malicious tags, deep
  nesting, oversized collections, or JS objects with surprising prototypes.
  Decoders need bounded work, canonical error paths, and no partial Store
  admission. A runtime tag check is not a proof of payload validity.
* **Representation and ABI.** Native inline layouts, Clojure objects, and JS
  frozen objects have different costs and alignment. The semantic contract
  must not accidentally promise layout, but Native FFI and Store codecs need
  explicit versioned ABI descriptors.
* **Effects and evaluation.** Pattern matching must not evaluate payloads,
  guards, or constructor arguments more than once. Lazy host sequences and JS
  getters must never leak into a strict Beagle match.
* **Pattern language growth.** Or-patterns, map patterns, ranges, aliases,
  and user-defined view patterns are attractive but can make coverage
  undecidable or effectful. Ship the small constructor/record language first;
  add each extension with independent corpus cases for evaluation order,
  strictness, allocation, failure, and effects.
* **Compiler staging.** Parser, typed lowering, slice-union machinery, and
  FREEZE must agree on one nominal tag model. Union syntax that parses but
  cannot freeze is not a usable feature; each new form needs a freeze receipt,
  including invalid-tag and unknown-variant paths.
* **Corpus scale.** The existing 263-case corpus covers only 258 of 2062
  dimensions. Union and record work must add cases for all three profiles,
  especially host representation, Any seams, serialization, and missing-case
  behavior, without declaring untested dimensions decided.
* **Fact granularity.** A union variant addition should invalidate exhaustive
  matches but should not force unrelated facts to churn. The Store dependency
  graph must distinguish an interface digest from an implementation digest and
  retain epoch/re-attestation rules for compiler or semantic-contract changes.

## Open Problems

1. Choose the canonical spelling and field syntax for variant patterns: the
   proposed `(Variant payload ...)` form is compact, but record-like keyed
   patterns may be clearer for large payloads.
2. Decide whether `Result` and `Option` are compiler-predeclared unions or
   ordinary library declarations, and define their stable qualified type IDs.
3. Specify the finite indirection type for recursive unions and whether cycles
   are rejected by value construction, Store admission, or both.
4. Specify exact ABI and canonical bytes for `U64`, `F32`, foreign handles, and
   nested union values before Native Core and Store codecs are implemented.
5. Decide whether malformed runtime union tags are recoverable `DecodeError`
   values everywhere or may be fatal `BEAGLE-INVALID-VARIANT` failures after a
   trusted internal boundary.
6. Define generated update operations and whether a record update preserves
   the original nominal type when fields contain unions.
7. Add the missing conformance dimensions and receipts for `match` evaluation
   order, guard strictness, allocation representation, failure behavior, and
   `Any` decoding under `core`, `hosted-clj`, and `hosted-js`.

## Decisions Needed

- Approve closed nominal unions with stable qualified variant IDs and no
  implicit open-extension mechanism.
- Approve `match` as strict, source-ordered, single-scrutinee evaluation with
  `_` required for open domains and guards excluded from coverage.
- Approve `BEAGLE-MATCH-NONEXHAUSTIVE` and
  `BEAGLE-MATCH-ANY-NONEXHAUSTIVE` as stable repair-facing diagnostic IDs.
- Approve explicit `decode`/`Result` at every `Any`-to-typed seam; no implicit
  casts and no map-shape duck typing.
- Approve nominal immutable records and unions as canonical Store values with
  type/variant/schema identity in FACT-ID materialization.
- Approve interface-digest dependencies as the first typed cutoff experiment,
  with variant-set changes invalidating exhaustive consumers and body-only
  changes remaining eligible for reuse.
- Decide the initial recursive-value and malformed-tag policy before lowering
  implementation begins.
