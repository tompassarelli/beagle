# Beagle host-leakage rules — decided on paper

## Status and authority

Overall status: **DECIDED-ON-PAPER**.

This document decides the eight original host-leakage gates named by
`beagle:beagle-test/conformance/authority/positioning/ORACLE-RETIREMENT-DESIGN.md`. It uses
the contract dimensions and anti-inheritance rule in
`beagle:beagle-test/conformance/authority/positioning/SEMANTIC-CONTRACTS-DESIGN.md`. Current
compiler and runtime behavior is evidence, not authority. “Racket does it” is
not a rule. It also incorporates all ten tranche 2 rules from
`beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DRAFT-TRANCHE2.md`,
resolved on 2026-08-18.

Every conformance case below is a **SKETCH — NOT RUN**. No rule in this
document is `PROVEN`; a rule becomes proven only when its independent corpus
case runs under every profile it claims and produces a passing receipt.

The error names below are semantic identifiers. A profile may add location and
explanation, but may not substitute a host exception class or change the
identifier. The eight original rules are immutable-value rules unless they
explicitly say otherwise: eager inputs, left-to-right evaluation, no mutation,
no hidden effects, and no author-observable allocation identity. A per-form
contract must
still fill every field required by `SemanticFormContractV1`; this document
closes the dimensions through which these eight host leaks could otherwise
enter.

`MIGRATION-REQUIRED` means the decision intentionally changes at least one
currently observable route. It is not permission to retain the old behavior as
a profile exception.

## 1. `HL-NUMBER-SEMANTICS`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The surface type table admits `Int`, `Float`, `I8`, `I16`, `I32`, `U8`,
  `U16`, `U32`, `U64`, and `F32`, and includes all of them in `Number`:
  `beagle:beagle-lib/private/types.rkt:19`.
- The parser currently accepts any Racket exact integer and real without a
  Beagle range check: `beagle:beagle-lib/private/parse.rkt:2319`.
- The portable table exposes arithmetic, conversions, non-finite codecs, and
  parsers while describing the arithmetic surface in terms of Clojure's host
  numeric tower: `beagle:beagle-lib/private/stdlib-portable.rkt:98` and
  `beagle:beagle-lib/private/stdlib-portable.rkt:111`.
- JavaScript currently uses binary64 `Number`, `Math` operations, `parseInt`,
  and `parseFloat`; the latter two accept host-specific prefixes and return
  `NaN` rather than Beagle absence: `beagle:beagle-lib/private/emit-js.rkt:210`,
  `beagle:beagle-lib/private/emit-js.rkt:490`, and
  `beagle:beagle-lib/private/emit-js.rkt:594`.
- Native Core already models checked i64 arithmetic, rejects Int `/`, defines
  Float operations explicitly, and makes Float-to-Int truncate toward zero
  while rejecting NaN and out-of-range values:
  `beagle:native-core/src/native/core.bclj:227`,
  `beagle:native-core/src/native/core.bclj:379`, and
  `beagle:native-core/src/native/lower.bclj:15699`.
- Native parsing already returns absence for malformed/overflowing i64 input
  and uses a managed binary64 grammar and exact IEEE rounding:
  `beagle:native-core/src/native/core.bclj:759`.
- Clojure and JavaScript currently print non-finite values with different host
  spellings: `beagle:beagle-lib/private/emit-clj.rkt:89` and
  `beagle:beagle-lib/private/emit-js.rkt:73`.

This is accidental host leakage. In particular, unbounded Racket integers,
JavaScript's one-number representation and prefix parsers, Clojure ratios, and
host printers cannot jointly describe one Beagle number model.

### DECIDED rule

1. `Int` is an exact signed 64-bit integer with range
   `[-9223372036854775808, 9223372036854775807]`. An out-of-range literal is a
   static `BEAGLE-NUMERIC-RANGE` error. `+`, `-`, `*`, `inc`, `dec`, unary
   negation, and every intermediate step of a variadic operation are checked;
   overflow is `BEAGLE-NUMERIC-OVERFLOW`, never wrapping, widening, or a host
   bignum. Arguments and intermediate operations are evaluated left to right.
2. `quot`, `rem`, and `mod` take two `Int` values. Division by zero is
   `BEAGLE-DIVIDE-BY-ZERO`; `quot` truncates toward zero; `rem` has the sign of
   the dividend and satisfies `a = (quot a b) * b + rem a b`; `mod` is zero or
   has the sign of the divisor. `MIN_INT / -1` is
   `BEAGLE-NUMERIC-OVERFLOW`. Int `/` is a static
   `BEAGLE-NUMERIC-DOMAIN` error: Beagle has no implicit Ratio domain.
3. `Float` is IEEE-754 binary64. Each primitive result is rounded once using
   round-to-nearest, ties-to-even. Signed zero, subnormals, and infinities are
   values. A Float divisor of either signed zero produces
   `BEAGLE-DIVIDE-BY-ZERO`; overflow of any other finite Float operation yields
   the correctly signed infinity and underflow follows IEEE gradual underflow.
   Ordered predicates involving NaN are false and Float `=` involving NaN is
   false, including NaN compared with itself. Every produced or decoded NaN is
   canonicalized to bit pattern `0x7ff8000000000000`; `float-to-bits` therefore
   has one NaN answer.
4. `long`/Float-to-Int truncates toward zero. NaN, infinity, or an out-of-range
   result is `BEAGLE-NUMERIC-RANGE`. Int-to-Float performs one correctly rounded
   binary64 conversion. There is no implicit conversion from String or Bool.
5. The fixed-width types are semantic storage/ABI domains, not aliases for host
   numbers. `I8`, `I16`, and `I32` use two's-complement signed ranges; `U8`,
   `U16`, `U32`, and `U64` use their full unsigned ranges; `F32` is IEEE-754
   binary32 and canonicalizes NaN to `0x7fc00000`. Construction or explicit
   narrowing outside the destination range is `BEAGLE-NUMERIC-RANGE`, never
   truncation. Generic arithmetic exactly widens signed narrow integers and
   `U8`/`U16`/`U32` to `Int`, and widens `F32` to `Float`, before operating and
   returns the widened type. `U64` has no implicit generic arithmetic or Int
   conversion because its full domain does not fit; an explicit checked
   conversion is required. No operation not named here is silently supplied by
   a host numeric class.
6. A mixed `Int`/`Float` arithmetic operation converts the Int operand to
   binary64 once and returns `Float`; this conversion can lose precision but is
   deterministic. Equality remains governed by rule 2 below and does not erase
   the domain tag.
7. `parse-long` accepts exactly an optional ASCII `+` or `-` followed by one or
   more ASCII decimal digits, consuming the entire String. `parse-double`
   accepts exactly the locale-free grammar
   `[+-]?(DIGITS(.DIGITS?)?|.DIGITS)([eE][+-]?DIGITS)?` plus the three canonical
   tokens `##Inf`, `##-Inf`, and `##NaN`, again consuming the entire String.
   Invalid or out-of-range input returns `nil`; it never returns a partial
   prefix, sentinel, or host exception.
8. Canonical Int text is minimal base-10 with `-` only for negative values.
   Canonical finite Float text is the shortest round-tripping decimal with a
   decimal point or exponent so it remains visibly Float; negative zero is
   `-0.0`. The three non-finite spellings are `##Inf`, `##-Inf`, and `##NaN` in
   every profile and every semantic serialization. A target emitter may use a
   different host token internally, but that token is not observable Beagle
   serialization.

Contract closure: numeric primitives are strict and pure; binary work is
constant time and a variadic operation is linear in its arity; scalars are
epoch-free and identity-free; the only failures are the named errors above;
portable use requires a profile to reproduce these exact ranges, rounding,
evaluation order, and serialization rather than expose its host number model.

### Divergence risk

Racket bignums and ratios, Clojure host numeric promotion, JavaScript precision
loss above `2^53`, JavaScript prefix parsing, host NaN payloads, and host number
printing all diverge. Existing programs that rely on any of those outcomes
require migration. The Native Core i64 decisions are evidence for this rule,
not a special Native exception.

### Smallest deterministic conformance case — not run

One table-driven source case evaluates, for every admitted numeric domain, its
minimum, maximum, one-step overflow, zero divisor, narrowing boundaries, mixed
promotion, `2^53 + 1`, both signed zeros, smallest subnormal, both infinities,
two NaN payload inputs, strict parse successes/failures (`"12x"` included),
and canonical text. It asserts the exact value bits/text or the semantic error
identifier. The case is labelled `HL-NUMBER-SEMANTICS` and is run separately
under `core`, `clj`, `js`, and `nix` wherever the operation is available.

## 2. `HL-EQUALITY-HASHING`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- Portable `=`, `not=`, `identical?`, `compare`, and `hash` are exposed over
  broad values: `beagle:beagle-lib/private/stdlib-portable.rkt:138`.
- The JavaScript runtime uses `===` for scalars, ordered structural equality for
  arrays, content equality for sets and plain objects, and host identity for
  other objects: `beagle:beagle-lib/lib/beagle/core.js:313`. Keywords and quoted
  symbols can be represented as strings, although the emitter has a narrow
  static keyword/string exception: `beagle:beagle-lib/private/emit-js.rkt:2738`.
- JavaScript's current hash is a representation-aware 32-bit content hash with
  a fallback through host `String(x)`: `beagle:beagle-lib/lib/beagle/core.js:499`.
- Native Core already declares equality, hash, and total comparison over an
  explicit closed type/layout graph instead of inferring behavior from bytes:
  `beagle:native-core/src/native/core.bclj:298`.

The JavaScript domain collapse and fallback coercion are accidental leakage.
Racket `equal?`, `eq?`, object identity, and hash codes are likewise never
language authority.

### DECIDED rule

1. Every semantic value carries its Beagle domain. `=` is domain-strict:
   `Int(1)`, `Float(1.0)`, `String("x")`, `Keyword(:x)`, and `Symbol(x)` are
   pairwise unequal even when a host uses the same representation. `nil` is
   equal only to `nil`; Bool is equal by truth value; integers by exact value;
   Floats by the rule above, with `+0.0 = -0.0` and NaN unequal to everything.
2. Lists and vectors are sequential values: they compare equal across those two
   representations when lengths and elements are equal in order. Sets compare
   by equal membership and maps by equal key/value association, independent of
   iteration or representation. Records are nominal: the declared record
   identity and all declared fields must match. Union values require the same
   union and variant before payload comparison. Representation choices such as
   JavaScript object versus HAMT are never observable through `=`.
3. Mutable cells, capabilities, functions, iterators, foreign/host objects,
   raw pointers, and Buffers do not have structural value equality or semantic
   hashing. Applying `=` or `hash` to one is a static
   `BEAGLE-UNSUPPORTED-VALUE-SEMANTICS` error when its type is known and the same
   named runtime error at an `Any` boundary. NaN is a value but is not an
   admissible map key or set element; admission fails with
   `BEAGLE-UNHASHABLE-VALUE` so key lookup remains reflexive.
4. `identical?` is defined only for explicitly identity-bearing Beagle values
   (currently mutable cells, iterators, capabilities, and foreign handles). It
   compares a Beagle allocation token, never a host pointer or address. It is a
   static `BEAGLE-NONIDENTITY-VALUE` error on immutable semantic values. A
   profile may move an object or scalar-replace it while preserving the token.
5. `hash` is `BeagleHashV1`: encode the value with
   `BeagleCanonicalValueV1`, compute 64-bit FNV-1a over those bytes, and
   reinterpret the result as signed `Int`. The canonical encoding is
   self-delimiting and domain-tagged; integers and canonical Float bits are
   eight-byte big-endian; text is byte-length-prefixed UTF-8; symbols encode
   qualification and name separately; sequential values encode elements in
   order; records encode nominal identity and declared field order; sets sort
   element encodings lexicographically; maps sort by key encoding and then value
   encoding. Thus equal values have byte-identical encodings and equal hashes.
   A collision never establishes equality. This algorithm and encoding version,
   not any host hash seed, are the observable contract.
6. Variadic equality evaluates operands left to right and compares adjacent
   values, short-circuiting at the first unequal pair. Equality and hashing are
   pure and do not mutate, allocate observable identity, call user code, or
   depend on collection traversal seeds. Work is linear in the traversed value
   size except canonical set/map hashing, which is `O(n log n)` in entry count.

### Divergence risk

The decision removes JavaScript string/keyword/symbol collapse, JavaScript
32-bit hashes and host-object fallback, host pointer identity, and any Racket or
Clojure cross-domain equality. It also makes `identical?` narrower than current
host routes. Any code that persists current numeric hash results or compares
immutable host representatives by identity requires migration.

### Smallest deterministic conformance case — not run

Build two separately allocated copies of every hashable atom and aggregate,
plus `1`/`1.0`, `"x"`/`:x`/`'x`, `+0.0`/`-0.0`, NaN, two nominal records with
the same fields, and the same map/set through two representations and insertion
orders. Assert the complete equality matrix, the exact `BeagleHashV1` numbers,
equal-implies-equal-hash, collision-not-equality with one fixed collision
fixture, successful key lookup, and the three named rejections.

## 3. `HL-SYMBOL-BEHAVIOR`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- Reader data remains Racket symbols until the semantic boundary; executable
  references split at the first non-edge slash into qualifier and local name:
  `beagle:beagle-lib/private/parse.rkt:258` and
  `beagle:beagle-lib/private/parse.rkt:2332`.
- The portable surface has `symbol(String) -> Symbol` and a broad `name`:
  `beagle:beagle-lib/private/stdlib-portable.rkt:94`.
- Clojure emits qualified references as `qualifier/name`, but quoted symbols
  are emitted as strings by JavaScript and Nix:
  `beagle:beagle-lib/private/emit-clj.rkt:71`,
  `beagle:beagle-lib/private/emit-js.rkt:3469`, and
  `beagle:beagle-lib/private/emit-nix.rkt:1148`.
- JavaScript `gensym` delegates to host `Symbol`: 
  `beagle:beagle-lib/private/emit-js.rkt:591`. Compiler-generated lowering names
  separately use a per-program counter specifically to avoid Racket's
  process-global `gensym`: `beagle:beagle-lib/private/macros.rkt:1182`.

Symbol-as-string outside Clojure and Racket symbol interning are accidental
representation leaks.

### DECIDED rule

1. A regular Symbol is an immutable tagged value `(qualifier?, name)`. Each part
   is an exact Unicode scalar sequence; Beagle performs no Unicode
   normalization. The first slash with non-empty text on both sides separates
   qualifier and local name. A leading slash, trailing slash, or slash-only
   spelling is an unqualified name; later slashes remain in the local name.
   `symbol(s)` applies exactly this decomposition. `name` returns the local name;
   `qualified-name` returns the qualifier or `nil`; `symbol(qualifier, name)` is
   the unambiguous two-part constructor. Invalid Unicode is
   `BEAGLE-INVALID-SYMBOL`.
2. Regular symbols compare and hash by the two textual parts and the Symbol
   domain tag. They are never equal to String, Keyword, executable reference,
   or generated symbol. Interning is an implementation choice with no semantic
   effect: repeated construction is `=` but `identical?` is rejected under rule
   2. Comparison is lexicographic by Unicode scalar value, with unqualified
   before qualified, then qualifier, then name.
3. Source shorthand `'foo` and `'space/foo` is accepted when the spelling is a
   safe reader token. The canonical semantic read/print form for every regular
   symbol is `(symbol "<escaped full spelling>")`, using JSON-style escapes for
   controls, quote, backslash, and non-printable scalars. It round-trips the two
   parts exactly and prevents a target printer from collapsing Symbol to String.
4. A generated symbol is a separate tagged value `(origin, ordinal, hint)`.
   Compile-time origin is the module semantic identity plus macro expansion
   path; runtime origin is the stable source call-site identity. Ordinals start
   at zero within that origin and advance in left-to-right evaluation order.
   Equality and order include origin and ordinal; the hint is print-only.
   Canonical print is
   `#generated-symbol[<origin>,<ordinal>,<escaped-hint>]` and is deliberately
   not accepted as author source. `gensym` is the explicit `FreshName` state
   effect; it may not delegate to a process-global host counter.
5. Symbol construction allocates no observable identity and has no effect;
   generated-symbol construction has only the declared `FreshName` effect.
   Both are available only where the profile can preserve the tag, parts, and
   canonical print. A profile that can only supply strings must report the
   form unavailable, not erase the distinction.

### Divergence risk

Racket may intern symbols, Clojure may inherit host namespaces and printers,
JavaScript has identity-bearing `Symbol`, and JavaScript/Nix currently erase
quoted Symbol to String. Canonical printing also differs from Clojure's bare
symbol printer. Programs observing those representations, `gensym` descriptions,
or host identity require migration.

### Smallest deterministic conformance case — not run

Construct `x` twice, `space/x`, `/`, `a/b/c`, `"x"`, `:x`, and two generated
symbols from the same call site. Assert part access, the equality/order matrix,
hashes, canonical print/read for regular symbols, non-readability and distinct
tokens for generated symbols, and the same expansion bytes when an unrelated
module is compiled first.

## 4. `HL-TRUTHINESS`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The checker models `and`/`or` as left-to-right, short-circuiting forms whose
  result is an operand: `beagle:beagle-lib/private/check.rkt:5748`.
- Native Core's truthiness conversion already makes Bool retain its value, Nil
  false, and every other closed non-union value true, recursively dispatching
  union arms: `beagle:native-core/src/native/lower.bclj:7730`.
- JavaScript currently emits host `Boolean`, `&&`, `||`, and raw host
  conditions, making `0`, `-0`, `NaN`, and `""` false:
  `beagle:beagle-lib/private/emit-js.rkt:276`.
- The macro evaluator says only Racket `#f` is false but represents macro `nil`
  as the empty Racket list, so macro `nil` is currently true:
  `beagle:beagle-lib/private/macro-eval.rkt:65` and
  `beagle:beagle-lib/private/macro-eval.rkt:604`.

The JavaScript truth table and macro-time Nil result are accidental and
mutually inconsistent host leakage.

### DECIDED rule

1. Exactly `false` and `nil` are falsey. Every other admitted value is truthy,
   including integer and Float zero, negative zero, NaN, empty String, empty
   List/Vec/Map/Set, Symbol, Keyword, records, unions with a non-Nil payload,
   functions, cells, and capabilities. A union is classified by its active
   value, not its static container type. There is no third truth state and no
   host coercion hook.
2. `if`, `when`, `cond`, predicate positions, `boolean`, and macro-time
   conditionals use that same table. `boolean(x)` returns its Bool result.
   `not(x)` accepts any admitted value and returns the negation of that result.
3. `and` and `or` evaluate operands left to right and return an operand rather
   than coercing it. `and` stops at the first falsey operand and otherwise
   returns the last; with no operands it returns `true`. `or` stops at the first
   truthy operand and otherwise returns the last; with no operands it returns
   `nil`. Skipped operands have no effects. `cond` evaluates tests left to right
   and only the selected body.
4. Truth testing is pure, constant-time after any required closed-union tag
   dispatch, allocation-free, and valid in all profiles. A foreign host value
   cannot cross an `Any` boundary without first receiving a Beagle domain; an
   untagged foreign value is `BEAGLE-FOREIGN-VALUE`, not an invitation to use
   host truthiness.

### Divergence risk

JavaScript's falsey zero, empty string, and NaN diverge. The present macro
evaluator's truthy Nil diverges. The portable signature currently narrows
`not` to Bool even though the decided operation accepts any semantic value.
All three are migrations. Clojure's false/Nil table happens to agree but is not
the reason for the rule.

### Smallest deterministic conformance case — not run

One case feeds `false`, `nil`, `0`, `-0.0`, canonical NaN, `""`, all four empty
collection kinds, one symbol, one keyword, one record, one function, and one
cell through `boolean`, `not`, `if`, `and`, and `or`. Effect counters in skipped
operands prove evaluation order. The same table is evaluated by one `defmacro`
whose expansion chooses a literal branch. Exact branch values and counter
values are asserted.

## 5. `HL-COLLECTION-ORDERING`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- Native Core's only declared collection order is insertion order, and Map/Set
  layouts carry that policy: `beagle:native-core/src/native/core.bclj:38` and
  `beagle:native-core/src/native/core.bclj:151`.
- JavaScript native objects expose `Object.keys`/`Object.values`, while HAMTs
  walk trie slots and collision buckets: `beagle:beagle-lib/private/emit-js.rkt:237`,
  `beagle:beagle-lib/lib/beagle/core.js:230`, and
  `beagle:beagle-lib/lib/beagle/core.js:483`.
- JavaScript arrays preserve sequence traversal, but `sort` currently delegates
  to host default sort: `beagle:beagle-lib/private/emit-js.rkt:249`.
- JavaScript equality and hash intentionally ignore Set/Map traversal order:
  `beagle:beagle-lib/lib/beagle/core.js:249` and
  `beagle:beagle-lib/lib/beagle/core.js:521`.

Object property order, HAMT shape, Clojure hash iteration, and a host default
comparator are accidental leakage.

### DECIDED rule

1. List and Vec traversal is authored element order. Map and Set traversal is
   insertion order in every profile and representation. A map literal inserts
   left to right. Inserting a new key appends it; replacing an equal existing
   key preserves its position; deletion removes it; deletion followed by
   reinsertion appends it. Set insertion follows the same rules for elements.
2. `seq`, `keys`, `vals`, `entries`, `map`, `filter`, `reduce`, `reduce-kv`, and
   callbacks driven by a collection observe that declared traversal order.
   Each callback completes before the next begins. Persistent updates preserve
   the relative order of unaffected entries. No iterator may expose bucket,
   pointer, property, or allocation order.
3. Map/Set equality and `BeagleHashV1` are order-insensitive as rule 2 states.
   Canonical semantic serialization, artifact identity, and digests sort map
   entries and set elements by their `BeagleCanonicalValueV1` byte encodings;
   they never depend on insertion order. An unencodable/unhashable element is
   rejected with `BEAGLE-UNHASHABLE-VALUE` at collection admission, so canonical
   serialization is total over admitted maps and sets.
4. `sort` is stable. Without a comparator it accepts only a homogeneous domain
   with a declared Beagle total order; otherwise it is
   `BEAGLE-NO-TOTAL-ORDER`. With a comparator, calls occur in the chosen stable
   sorting algorithm's comparison sequence, so an effectful comparator is
   statically rejected as `BEAGLE-EFFECTFUL-COMPARATOR`; only the sorted result,
   not an implementation's comparison schedule, is semantic.
5. Construction and traversal are strict in the elements they consume. Normal
   lookup remains expected `O(1)` or `O(log n)` according to the declared
   representation contract; insertion-order preservation cannot silently
   worsen a form's declared complexity. Canonical sorting is explicitly
   `O(n log n)` and belongs only to serialization/hash boundaries.

### Divergence risk

Current Clojure maps/sets, JavaScript integer-like object keys, JavaScript HAMT
walks, and host default sorting can all produce different orders. Programs that
observe those orders migrate to insertion order. Persisted digests derived from
current iteration order also require reminting under canonical serialization.

### Smallest deterministic conformance case — not run

Insert keys `"10"`, `"2"`, `:a`, and a compound key in two permutations into
both native and persistent representations; overwrite one key, delete/reinsert
another, and do the equivalent Set operations. Assert exact traversal after
each step, identical equality/hash/canonical bytes across representations,
different traversal but identical canonical bytes for the two permutations,
stable sorting of duplicate keys, and the named comparator rejection.

## 6. `HL-NATIVE-CORE-GC-OWNERSHIP`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED where identity was observed**.

### Current behavior observed

- The portable declaration says `bgl/promote` copies into an enclosing Core
  epoch but erases to identity on GC-hosted targets:
  `beagle:beagle-lib/private/stdlib-portable.rkt:175` and
  `beagle:beagle-lib/private/emit-js.rkt:2730`.
- Native layouts make Text, vectors, Buffers, maps, sets, references, and cells
  region-owned handles: `beagle:native-core/src/native/core.bclj:137`.
- Native obligations define the region lifetime tree, forbid old-to-young
  references, require LIFO closure on every path, and treat scalars as
  epoch-free: `beagle:native-core/src/native/obligations.bclj:1687`.
- Promotion is the one legal young-to-old edge because it copies, while calls
  without retention summaries conservatively require driver lifetime unless a
  surviving result is promoted:
  `beagle:native-core/src/native/obligations.bclj:2233` and
  `beagle:native-core/src/native/obligations.bclj:2274`.

The hosted no-op is a valid optimization only when identity and lifetime remain
unobservable. Collector reachability is not evidence that an ownership edge is
legal.

### DECIDED rule

1. GC timing, collection frequency, object movement, finalization, weak
   reachability, host object addresses, and host liveness are not Beagle
   semantics. Beagle has no implicit finalizers or weak references. External
   resources are released only by explicit capability/scope operations with
   their own effect and failure contracts.
2. Native Core ownership is the static region tree. A handle-bearing value is
   valid through its owner's lifetime. A parent strictly outlives a child. A
   reference stored in a destination must be owned by that destination's region
   or an ancestor. Every opened non-root epoch closes exactly once, in LIFO
   region order, on every normal and failure path. Escaping a younger handle is
   `BEAGLE-REGION-ESCAPE`; an unverifiable retention boundary is rejected as
   `BEAGLE-UNKNOWN-RETENTION`.
3. `bgl/promote(value)` is an explicit deep semantic copy from the current
   region into the named enclosing region selected by its contract. It preserves
   Beagle value and type, recursively copies every owned handle, produces no
   alias back into the younger region, and remains valid after that region
   closes. Cycles or value kinds without a closed promotion descriptor are a
   static `BEAGLE-NONPROMOTABLE-VALUE` error. Epoch-free scalars may lower to a
   copy/no-op because they have no observable allocation identity.
4. A GC-hosted profile must type-check and discharge the same ownership and
   escape obligations. It may implement promotion as identity only when rule
   2 makes identity unobservable and no later mutable/foreign edge can reveal an
   alias. Host reachability is not a discharge. `identical?` on a promoted
   immutable value is already invalid; an identity-bearing value is promotable
   only if its form-specific contract defines a new independent identity token.
5. Durable Store values contain a canonical copy of semantic data. They contain
   no arena pointer, host reference, capability token, iterator, function,
   foreign handle, or GC assumption. Store admission therefore serializes at
   the transaction boundary and rejects an inadmissible value as
   `BEAGLE-NONDURABLE-VALUE`. Promotion to a root arena is not persistence and
   does not substitute for Store admission.
6. Promotion is eager, left-to-right over declared fields/elements, pure with
   respect to semantic value but carries an explicit bounded allocation effect
   in the destination region. Its allocation and time bounds are the reachable
   promotable graph size. Store copying has the Store write effect and atomicity
   of its own form contract.

### Divergence risk

A hosted implementation that exposes the same reference before and after
promotion, relies on a finalizer, or permits a GC-reachable younger value to
escape diverges. Current hosted `bgl/promote` is semantically acceptable only
for immutable nonidentity values; code observing host identity or mutable alias
preservation requires migration. Native's currently incomplete promotion
domain remains a static availability limitation, not permission for shallow
copying.

### Smallest deterministic conformance case — not run

In a controlled allocator fixture, create a young nested record/vector/Text,
promote it, immediately poison and close the young arena, force allocation and
collection pressure, and assert the promoted canonical bytes and value. Attempt
an unpromoted escape and assert `BEAGLE-REGION-ESCAPE`; attempt a capability in
Store and assert `BEAGLE-NONDURABLE-VALUE`; store the promoted semantic data and
assert identical canonical bytes after the root arena closes. The allocator is
seeded and owned by the case; no wall-clock GC timing is an assertion.

## 7. `HL-HOST-MACRO-EXPANSION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED for host-valued macro results**.

### Current behavior observed

- `defmacro` already uses a pure compile-time evaluator and treats generated
  runtime calls as data, not host evaluation:
  `beagle:beagle-lib/private/macros.rkt:3`.
- Parsing is explicitly two-pass: meta forms and all local/imported macros are
  registered before ordinary forms expand, so source order does not limit
  module-local macro visibility: `beagle:beagle-lib/private/parse.rkt:1404`.
- Introduced binders are hygienically freshened; free module references resolve
  at definition site through deterministic aliases; imported macro free
  references are qualified against provider exports:
  `beagle:beagle-lib/private/macros.rkt:338` and
  `beagle:beagle-lib/private/macros.rkt:1146`.
- Expansion is outermost-first, recursively expands its result, traverses
  children left to right, and has a depth limit of 64:
  `beagle:beagle-lib/private/macros.rkt:317` and
  `beagle:beagle-lib/private/macros.rkt:433`.
- Syntax values retain span, origin, reader metadata, and generated-by data, but
  a macro result is rebuilt with an empty scope set:
  `beagle:beagle-lib/private/macros.rkt:245`.
- The evaluator currently delegates equality, arithmetic, symbol conversion,
  case conversion, formatting, and collection walks to Racket operations:
  `beagle:beagle-lib/private/macro-eval.rkt:49`,
  `beagle:beagle-lib/private/macro-eval.rkt:299`, and
  `beagle:beagle-lib/private/macro-eval.rkt:540`.

The pure evaluator and explicit hygiene are sound direction. Racket numeric,
symbol, equality, ordering, formatting, syntax-property, and error behavior
inside that evaluator remain implementation leakage.

### DECIDED rule

1. Macro expansion is a Beagle compile-time phase. It is pure and deterministic:
   no host evaluation, I/O, environment, clock, randomness, process-global
   counter, target runtime, or ambient syntax property is visible. Its number,
   equality, Symbol, truthiness, and collection behavior is exactly rules 1–5,
   restricted to the macro evaluator's declared value domain.
2. All `defmacro` declarations in one module are visible throughout that module
   after the meta-registration pass, independent of textual order. Imported
   macros are visible only through explicit `require` qualification or `:refer`.
   Macro phase sees macro parameters, local macro bindings, the closed macro
   primitive environment, and imported macro exports. Runtime values and
   target-host bindings are not inherited into macro phase; an attempted access
   is `BEAGLE-MACRO-PHASE-UNBOUND`.
3. A macro parameter and any syntax passed through unquote retains its use-site
   lexical scopes, exact source span, reader metadata, and origin chain.
   Template-introduced binders receive deterministic fresh scope identities and
   cannot capture use-site names. A lexically free reference in a macro body
   resolves at the definition module; for an imported macro it resolves through
   the provider's exported binding identity, never the consumer's same-spelled
   binding. Beagle currently has no intentional-capture primitive; attempted
   construction of a captured identifier is
   `BEAGLE-MACRO-INTENTIONAL-CAPTURE-UNAVAILABLE`.
4. Generated scope/name identity is derived from module semantic identity,
   expansion path, and local ordinal. Its debug spelling is not binding
   identity. Compiling unrelated modules first cannot change expansion bytes.
   Host gensym identity and Racket scope objects are not observable.
5. Expansion evaluates a macro body, callee, arguments, sequential bindings,
   and collection callbacks left to right and eagerly. It expands a macro call
   outermost, then recursively expands the produced form to a fixed point,
   visiting ordinary child forms left to right. Depth 64 is admitted; attempting
   a 65th nested expansion is `BEAGLE-MACRO-EXPANSION-DEPTH` with the complete
   Beagle macro origin chain.
6. Generated nodes that do not come from unquote carry the call-site span and an
   origin entry naming macro definition identity, call identity, and expansion
   depth. Unquoted nodes preserve their own spans and append that origin entry.
   Only Beagle reader metadata named by the syntax contract is inherited;
   arbitrary host syntax properties are dropped. Parse/type errors in output
   retain their semantic error identifier, are classified
   `BEAGLE-MACRO-OUTPUT-ERROR`, and blame the narrowest originating input span
   followed by the deterministic expansion chain.
7. The canonical expansion artifact contains semantic syntax, scope identities,
   admitted metadata, and origins, not host object IDs or host printer output.
   Expansion is linear in visited syntax plus the declared complexity of macro
   primitives; it allocates only compile-time syntax and values and has no
   runtime ownership consequence.

### Divergence risk

Macros relying on Racket bignums, `equal?`, symbol interning, hash traversal,
Unicode case/format details, current truthy macro Nil, Racket exception text, or
ambient syntax properties diverge and require migration. Current manual hygiene
that happens to agree remains evidence; the Beagle scope/origin rules above are
the authority.

### Smallest deterministic conformance case — not run

A provider exports a macro whose template has a free reference and an
introduced binder. A consumer shadows both spellings, passes syntax bearing
metadata through unquote, and invokes the macro before its local declaration;
the expansion also calls a second macro and deliberately creates one bad node.
Assert the canonical good expansion, provider resolution, absence of capture,
stable generated identities, preserved input span/metadata, left-to-right
origin chain, and exact named error/blame for the bad form. Repeat with an
unrelated module registered first and assert byte-identical expansion.

## 8. `HL-UNSPECIFIED-BEHAVIOR-AS-SPEC`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED wherever host choice is visible**.

### Current behavior observed

- The portable table explicitly says the monotonic clock epoch is unspecified
  and limits its use to elapsed time: `beagle:beagle-lib/private/stdlib-portable.rkt:108`.
  That is a bounded effect contract, not permission to inherit a wall clock.
- JavaScript currently delegates random values, UUIDs, shuffle, object order,
  default sort, parsing, and some coercions directly to its host:
  `beagle:beagle-lib/private/emit-js.rkt:215`,
  `beagle:beagle-lib/private/emit-js.rkt:481`, and
  `beagle:beagle-lib/private/emit-js.rkt:591`.
- Native Core demonstrates the opposite pattern by representing collection
  order, checked arithmetic, value semantics, regions, and capabilities as
  closed program data: `beagle:native-core/src/native/core.bclj:38`,
  `beagle:native-core/src/native/core.bclj:227`, and
  `beagle:native-core/src/native/core.bclj:298`.

Several current hosted routes therefore have observable behavior that is only
“whatever this host did.” That is accidental leakage, not a compatibility
promise.

### DECIDED rule

1. Every author-observable semantic point has exactly one of three contract
   classifications: **canonical result**, **named rejection**, or **explicit
   finite allowed-outcome set**. Missing, `UNKNOWN`, “implementation-defined,”
   “host-defined,” and “matches Racket” are inadmissible and make the form
   unavailable with `BEAGLE-UNSPECIFIED-SEMANTICS` before execution.
2. A finite allowed-outcome set lists every semantic value/error member and the
   condition under which choice occurs. It also declares whether choice is
   deterministic for a run, module, transaction, or call. Values outside the
   set are defects. Canonical serialization and artifact identity either erase
   the choice or include its explicit semantic outcome; they never include an
   allocator seed, pointer, hash seed, scheduler accident, locale, timezone, or
   host printer residue.
3. Deliberately nondeterministic operations such as entropy, UUID generation,
   monotonic time, and concurrency are not “unspecified.” Each is an explicit
   effect with required capability, evaluation/effect order, result domain,
   failure behavior, replay boundary, ownership, profile availability, and
   complexity contract. A deterministic conformance case supplies a controlled
   provider. Ambient host entropy/time/scheduling is never a correctness oracle.
4. An implementation may vary representation, allocation placement, traversal
   strategy, or optimization only when every observable contract dimension is
   unchanged: value/identity, order/strictness, mutation/persistence, effects,
   failure, ownership/lifetime, profile availability/obligations, and declared
   complexity. If a difference crosses one of those dimensions, the profiles
   need distinct form names or an explicit `similar-but-different`
   classification; silent fallback is forbidden.
5. A newly discovered unspecified point blocks only that form/profile from
   semantic admission. It is recorded as `UNDECIDED`, receives an owned rule
   decision, and cannot be converted into a `DECIDED` corpus assertion by
   copying output from Racket, a seed, Native Core, or a hosted target. Once
   decided, observable existing divergence is labelled `MIGRATION-REQUIRED`.

### Divergence risk

Any program depending on current JavaScript property/HAMT order, default sort,
prefix parsing, host formatting/coercion, Racket hash order, process-global
fresh names, allocator identity, locale, or ambient scheduler behavior may
change. Explicit random/time/UUID effects remain available only through their
eventual declared providers; this rule does not pretend their value is
canonical, but it does make their source and replay boundary semantic.

### Smallest deterministic conformance case — not run

Run one source/request twice under two controlled legal allocation, hash, and
traversal seeds. It includes a map/set artifact, macro-generated name, numeric
serialization, and one operation whose contract declares a two-member outcome
set. Assert byte-identical canonical output for the canonical fields, the exact
named rejection for one deliberately missing contract, and membership in the
two-member set for the declared choice. Supply fixed clock/entropy providers so
no public network, wall clock, scheduler, or ambient host state enters the
assertion.

## 9. `HL-DEFN-BINDING-AND-INVOCATION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The compiler represents a definition with name, parameters, rest parameter,
  return type, raises contract, documentation, and body facts:
  `beagle:beagle-lib/private/emit-facts.rkt:241`–`251`.
- Clojure emission lowers a `defn` form into a host `defn`, including callable
  signatures and body emission: `beagle:beagle-lib/private/emit-clj.rkt:561`–`577`.
- Compile-time binding walks and hygiene handling explicitly treat `defn` as a
  binding form: `beagle:beagle-lib/private/macros.rkt:884`–`928` and
  `beagle:beagle-lib/private/macros.rkt:1098`.

### DECIDED rule

1. `defn` creates one named Beagle function binding after its declaration is
   checked. Declaration checking is compile-time and executes no body, default,
   or user effect. A declaration with an unresolved type, malformed parameter,
   duplicate parameter, or invalid rest position is rejected with
   `BEAGLE-DEFN-SIGNATURE`.
2. A function has exactly its declared fixed arities plus one declared rest
   arity when present. A call with no matching arity is `BEAGLE-ARITY`; a call
   never falls through to a host overload or performs host varargs coercion.
   Fixed arguments bind left-to-right, then rest arguments in source order.
3. Definitions in one namespace are checked and bound as a definition SCC.
   Every function in that SCC is available by its semantic name throughout the
   SCC, so mutual recursion is valid without an explicit recursive-group form.
   The function body runs only on invocation. Its parameters and lexical
   captures are Beagle values. Definition order, host closure addresses, and
   generated function names are not observable identity. A function is not
   identity-bearing: `identical?` rejects it with `BEAGLE-NONIDENTITY-VALUE`.
4. A declared return contract is checked at the Beagle boundary. A mismatch is
   `BEAGLE-RETURN-DOMAIN`; a declared `raises` failure preserves its Beagle
   error identifier. Function construction and invocation do not acquire
   capabilities unless the body performs a separately declared effect.
5. All profiles expose the same arity, binding, error, mutual-recursion, and
   invocation behavior. A profile may lower the function differently, but
   cannot expose host overload selection, closure identity, or exception
   behavior.

### Divergence risk

Host overloads, lazy closures, generated names, definition-order dependence,
and exception/arity differences can otherwise make the same declaration mean
different programs.

### Smallest deterministic conformance case — not run

One source declaration set exercises zero, one, multiple, and rest arities,
duplicate parameters, mutually recursive definitions in one SCC, an effectful
body that must not run at declaration time, and a return mismatch. It records
the exact semantic outputs/errors under `core`, `clj`, `js`, and `nix` wherever
the operation is available.

## 10. `HL-EQUALITY-CALL-SEQUENCING`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable surface exposes `=` over `Any` values:
  `beagle:beagle-lib/private/stdlib-portable.rkt:139`.
- The decided equality rule defines the value relation and hashing algorithm,
  but the trace3 join still lists this builtin's strictness, effects, and
  failure rows as uncovered: `beagle:beagle-test/conformance/divergence-coverage.json`.
- The existing host implementations have different host evaluation and
  exception paths; the equality rule warns that host identity and coercion are
  not authority: `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:152`–`229`.

### DECIDED rule

1. For every arity admitted by the portable surface, `=` evaluates operands
   left-to-right until the first unequal adjacent pair, then stops. It evaluates
   no operand after that point and never calls a host equality method as a
   hidden effect. Surface arity is parser/type authority.
2. The comparison relation is exactly the domain-strict relation decided by
   `HL-EQUALITY-HASHING`. No lazy host collection traversal, coercion, callback,
   hash-seed dependency, or host pointer test is permitted.
3. Values that the equality contract does not admit produce
   `BEAGLE-UNSUPPORTED-VALUE-SEMANTICS` at the static boundary when their type
   is known and the same identifier at an `Any` boundary. Equality never
   returns a host sentinel or throws a host exception.
4. Equality is pure and allocation-free from the author's perspective. Any
   internal canonicalization is not an identity-bearing value and cannot change
   the result between profiles.

### Divergence risk

Host equality can invoke user code, walk a different representation, or turn an
unsupported value into a host boolean.

### Smallest deterministic conformance case — not run

Compare admitted two- and four-operand calls with a rightmost effect marker,
first-unequal marker, unsupported value, and equal values represented by
different hosts. The case checks skipped effects and the semantic error
identifier under `core`, `clj`, `js`, and `nix`.

## 11. `HL-IF-BRANCH-EXECUTION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The compiler's binding and macro machinery recognizes `if`-family forms and
  lowers them through host conditionals: `beagle:beagle-lib/private/macros.rkt:1007`–`1109`.
- The portable library documents the related nil-narrowing surface around
  `if` and `when`: `beagle:beagle-lib/private/stdlib-clj.rkt:93`.
- The decided truthiness rule supplies the intended truth table, but this
  builtin's full six-row host join remains undecided:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `if` evaluates exactly one test expression once. It evaluates the then
   branch when the test is truthy under the Beagle truth table and otherwise
   evaluates the else branch, if present. The unselected branch is not
   evaluated and cannot produce an effect, allocation, or error.
2. The result is the selected branch's Beagle value. A host's falsey empty
   collection, zero, NaN, `undefined`, or missing value does not alter the
   Beagle truth table. The parser owns accepted source arities.
3. A foreign value crossing the test boundary without a Beagle domain is
   `BEAGLE-FOREIGN-VALUE`. No host conditional exception or sentinel is
   observable.
4. Test and selected-branch effects follow source order. `if` itself is pure,
   does not allocate an author-visible identity, and has the same behavior in
   every profile.

### Divergence risk

A host may evaluate the unselected branch, use a different falsey set,
allocate a host sentinel, or report a host exception.

### Smallest deterministic conformance case — not run

Use each falsey/truthy boundary, an effect marker in each branch, a failing
unselected branch, and a foreign-value boundary. The case shows the exact
selected output and absent unselected marker under `core`, `clj`, `js`, and
`nix`.

## 12. `HL-JS-EXPORT-BOUNDARY`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/export` is registered as a compile-time combiner and strips or retains
  target export structure during parsing: `beagle:beagle-lib/private/parse.rkt:276`
  and `beagle:beagle-lib/private/parse.rkt:4197`–`4207`.
- The module interface describes `js/export` as the deliberate JavaScript
  publication surface: `beagle:beagle-lib/private/module-interface.rkt:237`–`240`.
- Deep checking is required for an export-wrapped definition, and the checker
  rejects a missing export wrapper at the module boundary:
  `beagle:beagle-lib/private/check.rkt:3997` and `beagle:beagle-lib/private/check.rkt:9078`.

### DECIDED rule

1. `js/export` is available only in the JavaScript profile. In `core`, hosted
   Clojure, and hosted Nix, use is a static `BEAGLE-TARGET-UNAVAILABLE` error;
   it is never silently ignored or reinterpreted as a host export form.
2. On JavaScript, the inner declaration is checked completely before module
   publication. `js/export` publishes snapshot own-data bindings under
   canonical Beagle qualified names, independently of source map, bundler, or
   property enumeration order. It does not publish live bindings or getters.
   `js/export-default` is a separate form; default-export behavior is not part
   of `js/export`.
3. Each exported name is published once. Duplicate or conflicting named
   exports are `BEAGLE-EXPORT-CONFLICT`; an unexportable value is
   `BEAGLE-EXPORT-DOMAIN`. Export construction has no author-observable side
   effect beyond the module publication boundary.
4. Values crossing the boundary retain their Beagle domain. Callbacks and
   returned values cross only through explicit capability/codec contracts; a
   mutable or foreign value requires its declared contract. `js/export` never
   exposes an arbitrary host callback, getter, or live host object.
5. No profile may expose a host module object, live-binding timing, property
   ordering, getter behavior, or host exception as a substitute semantic result.

### Divergence risk

Export lowering is a host/module boundary: eager module evaluation, live
bindings, default-export conventions, getters, object identity, and bundler
ordering can all leak.

### Smallest deterministic conformance case — not run

One module exports a scalar, callback, returned value, mutable/foreign boundary
value, named binding, duplicate name, and separate default form under `core`,
`clj`, `js`, and `nix`. The case checks snapshot own-data publication, explicit
capability/codec crossings, names, and errors.

## 13. `HL-NTH-INDEX-ACCESS`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable signature gives `nth` a vector and an `Int` index:
  `beagle:beagle-lib/private/stdlib-portable.rkt:28`–`30`.
- The collection accessor audit calls out `nth` with the other element
  accessors: `beagle:beagle-lib/private/stdlib-clj.rkt:457`.
- The decided collection rule constrains collection ordering, but the six
  `nth` dimensions remain a separate join target:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. The canonical `nth` contract is exactly `Vec × Int -> element`. `nth`
   evaluates the vector expression, then the index expression, requires a
   Beagle `Vec` and exact `Int`, and returns the element at zero-based index
   `i`. No other sequential domain, implicit sequence conversion, host array
   coercion, or lazy realization is admitted.
2. A negative index or index at least the vector count is exactly
   `BEAGLE-INDEX-OUT-OF-RANGE`. A non-`Vec` collection or non-`Int` index is
   `BEAGLE-NTH-DOMAIN`. Bounds violations have no non-error result: there is no
   host `IndexOutOfBoundsException`, `undefined`, or nil fallback.
3. Access does not mutate the vector, allocate author-visible identity, or
   invoke user code. The returned value has the vector element's Beagle domain
   and any identity-bearing element retains its identity token.
4. Core, hosted Clojure, hosted JavaScript, and hosted Nix use the same exact
   contract and errors, regardless of host collection implementation.

### Divergence risk

Host indexing differs on negative indices, sparse arrays, lazy sequences,
bounds exceptions, and whether access preserves or manufactures object identity.

### Smallest deterministic conformance case — not run

Index an empty, singleton, and multi-element vector at both bounds, negative
indices, and a large index, plus a vector containing an identity-bearing
element, a non-vector, and a non-Int index. The case asserts the exact result or
error under `core`, `clj`, `js`, and `nix`.

## 14. `HL-LET-BINDING-SEQUENCE`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The compiler has a dedicated lexical `let` binding walker and records
  binding targets and values: `beagle:beagle-lib/private/macros.rkt:796`–`804`.
- Clojure emission lowers `let` through an explicit binding emitter and body
  emitter: `beagle:beagle-lib/private/emit-clj.rkt:837`–`840`.
- The facts emitter records each let binding's target, annotation, constraint,
  and value: `beagle:beagle-lib/private/emit-facts.rkt:135`–`142`.

### DECIDED rule

1. `let` owns name introduction for the whole binding vector. Every leaf name
   introduced across that vector, including every name introduced by a
   destructuring pattern, must be unique. Any duplicate is rejected with
   `BEAGLE-DUPLICATE-BINDING`; shadowing an outer binding is allowed.
2. This rule pins name existence and uniqueness only. Destructuring-pattern
   matching and evaluation semantics, including binding RHS order and the
   visibility of names during evaluation, remain outside this rule for a
   separate future rule.
3. A malformed binding vector or invalid name-introduction shape is
   `BEAGLE-LET-FORM`. This rule does not assign a destructuring mismatch or
   evaluation failure to a host-specific result.
4. Host stack slots, JavaScript `let`/`const`, Clojure locals, and Nix thunks
   are implementation strategies only. They must not change the set of names
   introduced by one binding vector or the duplicate-name rejection.

### Divergence risk

Different leaf-name enumeration, duplicate acceptance, and host-specific
binding identity are silent divergence surfaces. RHS matching and evaluation
are deliberately reserved for a separate rule.

### Smallest deterministic conformance case — not run

Use one binding vector containing simple names, outer shadowing, and
destructuring patterns with a duplicate leaf name. The case asserts the
complete introduced-name set and exact duplicate rejection under `core`, `clj`,
`js`, and `nix`; matching and evaluation cases belong to the separate future
rule.

## 15. `HL-PLUS-NUMERIC-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable signature exposes variadic `+` over `Number`:
  `beagle:beagle-lib/private/stdlib-portable.rkt:114`.
- Numeric host behavior is divergent in the decided document, including host
  promotion and printing: `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:35`–`67`.
- The trace3 join names all six `+` dimensions as uncovered:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `+` evaluates operands left-to-right. Zero operands returns `Int(0)`; one
   operand returns the validated operand `x`; more operands fold in source
   order.
2. Dispatch and promotion use only Beagle numeric domains. No host numeric
   tower, JavaScript `Number`, Clojure ratio, or Nix coercion is consulted.
   Ranges, rounding, overflow, NaN, signed zero, and serialization are exactly
   those of `HL-NUMBER-SEMANTICS`. In particular, `U64` has no implicit generic
   arithmetic or mixed-Float route.
3. A non-number operand or numeric domain excluded from generic arithmetic is
   `BEAGLE-NUMERIC-DOMAIN`; overflow is `BEAGLE-NUMERIC-OVERFLOW`. The first
   failing operand stops the fold.
4. `+` is pure and has no allocation or identity effect. Every profile exposes
   the same zero/one/variadic arity and failure order.

### Divergence risk

The high-frequency call boundary can let a host change evaluation order,
promotion, intermediate representation, overflow, identity, or failure while
appearing to implement the same arithmetic.

### Smallest deterministic conformance case — not run

Use zero, one, mixed-domain, boundary, overflowing, non-number, signed-zero,
and NaN operands with an effect marker in each position. The case references
the decided numeric expected values under `core`, `clj`, `js`, and `nix` rather
than introducing new payloads.

## 16. `HL-JS-CALL-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/call` is a registered target combiner requiring a receiver, member key,
  and optional arguments: `beagle:beagle-lib/private/parse.rkt:4141`–`4149`.
- The checker has a dedicated callable-type diagnostic and form record for
  `js/call`: `beagle:beagle-lib/private/check.rkt:6167`–`6178`.
- The public cheatsheet shows both static and dynamic member calls, making
  receiver/key evaluation and host `this` binding observable:
  `beagle:beagle-lib/private/cheatsheet.rkt:92`–`98`.

### DECIDED rule

1. `js/call` evaluates receiver, member key, and arguments left-to-right, then
   performs one member lookup and one call. The receiver is the explicit Beagle
   receiver and is the only permitted `this`/method context.
2. A missing member is `BEAGLE-JS-MEMBER-MISSING`; a non-callable member is
   `BEAGLE-JS-NONCALLABLE`; getters are `BEAGLE-JS-GETTER` and Promises are
   `BEAGLE-JS-PROMISE`. A JavaScript throw crosses the boundary as
   `BEAGLE-JS-THROWN` with the fixed data-only semantic payload, never as an
   arbitrary host exception class.
3. The call requires the declared foreign-effect capability. A Beagle value may
   be returned directly only under its declared codec contract; every returned
   object is wrapped as an identity-bearing foreign handle. Callbacks cross only
   under an explicit capability/codec contract. Promises are never silently
   awaited or coerced.
4. Lookup and call have no hidden retry, getter duplication, argument reorder,
   host overload selection, or author-visible allocation identity beyond the
   returned foreign-handle identity mandated above. Non-JS profiles reject with
   `BEAGLE-TARGET-UNAVAILABLE`.

### Divergence risk

JavaScript getters, method receiver rules, Promises, thrown values, callbacks,
and object identity are direct host leaks.

### Smallest deterministic conformance case — not run

Call a static member, dynamic member, missing member, non-callable member,
getter, Promise, throwing member, returned object, and callback with effect
markers in receiver/key/args. Run under `core`, `clj`, `js`, and `nix`.

## 17. `HL-JS-GET-DISPATCH`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- `js/get` is a registered combiner requiring exactly a receiver and member
  key: `beagle:beagle-lib/private/parse.rkt:4132`–`4139`.
- The checker has a dedicated `js/get` form and diagnostic path:
  `beagle:beagle-lib/private/check.rkt:6137`–`6140`.
- The cheatsheet documents both static and dynamic key access:
  `beagle:beagle-lib/private/cheatsheet.rkt:92`–`98`.

### DECIDED rule

1. `js/get` evaluates the receiver then the member key exactly once and reads
   one own property under the declared JavaScript interop capability. It does
   not search Beagle maps, prototype chains, or host representations
   implicitly.
2. The read is data-only. A missing member is exactly
   `BEAGLE-JS-MEMBER-MISSING`; there is no inherited-property search and no
   `Undefined` result. Getters are `BEAGLE-JS-GETTER` and proxies are
   `BEAGLE-JS-PROXY`; neither is invoked. A
   non-object receiver is `BEAGLE-JS-RECEIVER-DOMAIN`; an invalid key is
   `BEAGLE-JS-KEY-DOMAIN`.
3. The result is a declared Beagle value or foreign handle; every returned
   object is wrapped as an identity-bearing foreign handle. Getter/proxy
   behavior and host allocation identity are never invisible implementation
   details.
4. Non-JavaScript profiles reject with `BEAGLE-TARGET-UNAVAILABLE`. No profile
   may turn a missing property into a host sentinel.

### Divergence risk

The principal leaks are JavaScript `undefined`, prototype/inherited lookup,
getters/proxies, and host object identity.

### Smallest deterministic conformance case — not run

Read an own data property, inherited property, missing property, getter, proxy,
dynamic key, invalid key, and invalid receiver with ordered effect markers.
The case asserts own-data success and the named rejection for every excluded
boundary behavior under `core`, `clj`, `js`, and `nix`.

## 18. `HL-NOT-BOOLEAN-NEGATION`

Status: **DECIDED-ON-PAPER — MIGRATION-REQUIRED**.

### Current behavior observed

- The portable signature currently advertises `not` as taking `Bool`:
  `beagle:beagle-lib/private/stdlib-portable.rkt:156`.
- The decided truthiness rule says `not` accepts any admitted value and returns
  the negated Beagle truth value: `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md:313`–`369`.
- The trace3 join lists all six `not` dimensions as uncovered:
  `beagle:beagle-test/conformance/divergence-coverage.json`.

### DECIDED rule

1. `not` evaluates exactly one operand once and returns a Beagle `Bool`. It
   applies the same truth table as `HL-TRUTHINESS`: only `false` and `nil` are
   falsey; every other admitted Beagle value is truthy.
2. `not` is pure, constant-time after required closed-union tag dispatch, and
   allocates no author-visible value identity. It does not call host Boolean
   coercion, inspect collection emptiness, or turn `undefined` into false.
3. A foreign value without a Beagle domain is `BEAGLE-FOREIGN-VALUE`. The
   current Bool-only portable signature must migrate: every admitted Beagle
   value is a valid operand, exactly as `HL-TRUTHINESS` decides.
4. The result and all failures are deterministic and independent of host object
   representation, exception classes, and optimization.

### Divergence risk

The current type surface and decided truthiness prose disagree about accepted
inputs; host coercion would make a one-token negation vary by type checking,
coercion, allocation, and failure behavior.

### Smallest deterministic conformance case — not run

Apply `not` to `nil`, `false`, `true`, zero, empty String, empty collection,
NaN, a record, a function, and a foreign value under `core`, `clj`, `js`, and
`nix`. Assert the decided Bool result or `BEAGLE-FOREIGN-VALUE`.

## Paper closure

All eighteen gates now have an implementation-independent rule, named
divergence risk, and a smallest deterministic conformance sketch. Their status
is **DECIDED-ON-PAPER**, not `PROVEN`, not `PASS`, and not an oracle-retirement
receipt. The migrations named above must be implemented explicitly; matching
current Racket output cannot waive them.

The conformance case payloads for these ten tranche 2 rules are authorized once
the corpus manifest lands.

LEAKAGE-RULES-DONE
