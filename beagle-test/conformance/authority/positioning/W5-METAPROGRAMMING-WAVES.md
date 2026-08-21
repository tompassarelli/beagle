# Beagle-native metaprogramming — executable W5 wave plan

Dependency truth: store rename -> W5a syntax membrane -> W5b scope-set
hygiene -> W5c syntax-match over the typed evaluator -> W5d expansion
dependencies in cone invalidation -> W5e restricted static reflection.
W5a/W5b/W5c are paired Racket-oracle/self-host changes. Every self-host change
must remint the canonical `self-host/seed/` projection and pass the oracle
fixpoint before it can land. The store-facing seams below use their
post-rename `store/` paths only.

The two supplied spikes are proven inputs, not product implementation:
`W5-SPIKE-SYNTAX-FINDINGS.md` establishes the immutable syntax/provenance
membrane and exact-child identity requirement; `W5-SPIKE-SCOPES-FINDINGS.md`
establishes structural-name plus scope-set resolution, unique maximal-subset
selection, and explicit ambiguity. Racket supplies the one-phase scope kernel;
Lean supplies compiled structural pattern matching and expansion-use
provenance; Zig supplies the rule that ordinary typed evaluation is the default
for computation and that evaluator calls are analysis units. Do not import
Racket's phase tower, Lean's name-encoded hygiene, or Zig-style ambient
reflection.

## Landing order

1. Store rename lands. No W5 lane starts against the pre-rename path.
2. W5a lands the syntax-object contract and its Racket/self-host parity.
3. W5b lands scope-set resolution and binder/occurrence identity. The old
   name-rewriting hygiene path is removed in the same landing; the old and new
   hygiene systems must not run together.
4. W5c lands structural `syntax-match` and typed syntax/AST construction over
   the existing macro evaluator. It does not add reflection.
5. W5d lands complete expansion/evaluator dependency edges and cone
   invalidation. No memoization or cache claim is allowed before this gate.
6. W5e lands only the first static reflection capability, `fields-of`, over
   checked nominal records.
7. The W5 lineage gate runs after W5e on the exact integrated tree. It edits a
   reflected record used by a hygienic macro, proves the expansion/type/unit
   cone, and admits the affected materialization through the existing
   shadow/CAS path. W5 is not integrated if it needs a separate showcase.

Each focused gate is run once at its named seam. The full gate is run at each
serial integration boundary that changes the self-host compiler, and once more
for the completed W5 lineage. The full integration gate is:

```text
bin/beagle-ci
bin/beagle-remint --oracle
self-host/verify-selfhost.sh
bin/test/branch-compile-corpus/run.sh --check
```

`bin/beagle-ci` supplies the ordinary tiered Racket suite; the other three
commands make self-host parity, bootstrap agreement, and expected cones
explicit. A focused failure stops that lane; it does not get hidden by a later
full-suite result.

## W5a — syntax objects into reader and AST

**Purpose.** Make the spike-A membrane real at the first macro boundary while
retaining whole-output checking. Code enters expansion as immutable `Syntax`;
quoted data remains inert datum; antiquotation returns the original child
object, including its span and origin. This is a membrane change, not yet
hygiene or pattern matching.

**Exact seams and targets.**

- Racket oracle: `beagle:beagle-lib/private/ast.rkt:78-140,279-337` for
  `src-loc`, `->datum`, `stx-subs`, `qualified-ref`, and the shared parser
  parameters. Add the immutable `Syntax` variants, `ExpansionOrigin`, reader
  metadata, and the `StructuralName`/syntax-identifier carrier here; keep
  `qualified-ref`'s qualifier, leaf, and provider identity intact.
- Racket reader/adapter: `beagle:beagle-lib/private/parse.rkt:312-370` and
  `1307-1384`. Preserve exact source bytes and delimiter metadata while
  adapting reader output. `parse-program*` may inspect datum for existing
  metadata passes, but the macro-facing value must be `Syntax` rather than a
  fresh lossy datum tree.
- Racket macro boundary: `beagle:beagle-lib/private/macros.rkt:21-37,
  100-160,320-342`. Extend `macro-def`/`expansion-ctx` with source and origin
  facts; make `expand-macro`, `expand-template-macro`, and `expand-fully`
  accept/return `Syntax` through an explicit datum adapter. Keep the pure
  evaluator and existing expansion depth/error behavior.
- Racket generated-source blame: `beagle:beagle-lib/private/parse.rkt:
  2021-2110` and `2187-2207`. Generated wrappers inherit the macro call span;
  embedded antiquoted children retain their own spans. `syntax->datum` is an
  explicit lossy boundary, never the identity operation.
- Self-host mirror: `beagle:self-host/src/selfhost/reader.bclj:247-307,441-469`,
  `ast.bclj:80-150`, `parse.bclj:447-552`, and
  `macros.bclj:45-59,301-332,444-485`. Replace the raw tagged macro-facing
  carrier with the same `Syntax` value shapes and origin rules. The evaluator
  seed at `macros.bclj:301-332` is the quasiquote/unquote adapter; do not
  reinterpret ordinary strings as identifiers.
- Spike-A implementation and focused fixtures: carry
  `beagle:experiments/w5-syntax-object.rkt` and
  `beagle:experiments/w5-syntax-object-test.rkt` into the real membrane
  boundary, then extend
  `beagle:beagle-test/tests/defmacro.rkt`, `macro-eval.rkt`,
  `macro-hygiene.rkt`, and `syntax.rkt` with one existing macro returning
  `Syntax`, one antiquoted child identity/span assertion, one generated-wrapper
  blame assertion, and one malformed typed-constructor failure at construction.

**Verification.** At the file-focused layer, run the four named Racket tests
with the pinned Racket launcher and assert the new membrane fixtures plus all
existing macro-output type checks. Run the self-host focused reader/macro
fixture and then `bin/beagle-remint --oracle` plus
`self-host/verify-selfhost.sh` before integration. The repository Racket suite
and cone gate run at the W5a landing boundary because both compiler surfaces
changed. Acceptance is `W5-G1 SYNTAX-MEMBRANE`: exact caller bytes/span survive
antiquotation, generated origin points to the call site and parent chain, and
invalid typed construction fails before ordinary parser/type-checker fallback.

**Parallelism and staffing.** The Racket membrane and self-host carrier can be
implemented in parallel after the shared value contract is frozen; their
integration, seed remint, and parity are serial. Assign
`gpt-5.6-terra` medium-xhigh to the oracle seam and
`gpt-5.6-luna` medium-high to the self-host mirror, with one integration owner.
Budget 7–10 engineer-days total, matching spike A; do not absorb scopes,
patterns, or dependency tracking into this estimate.

## W5b — scope-set hygiene in both expanders

**Purpose.** Integrate spike B before ordinary AST lowering. Every code
identifier is `SyntaxIdent { StructuralName, ScopeSet, span, origin, props }`;
`providerId` remains module identity and `BindingId` is the lexical edge. The
resolver returns a binding ID, unbound, or ambiguity; it never returns a
renamed string. Scope IDs are opaque and compilation-local until a separate
stable binding-ID scheme crosses a cache boundary.

**Exact seams and targets.**

- Shared Racket model: extend `beagle:beagle-lib/private/ast.rkt:127-140,
  279-337` with `ScopeId`, immutable `ScopeSet`, `BindingId`, `Binding`, the
  `(StructuralName, ScopeSet)` binding table, and unique maximal-subset
  resolution. Use the spike's duplicate-key rejection and incomparable-maxima
  error algebra.
- Racket macro invocation: replace the hygiene block at
  `beagle:beagle-lib/private/macros.rkt:344-430,1008-1077`. At each invocation,
  allocate one introduction scope, flip it onto input and output, preserve
  unquoted syntax unchanged, and remove the identity duties of
  `transform-template/scoped`, `hygienize-template`, `hygiene-alias-for!`,
  and injected `__hyg` aliases. Retain `fresh-lowered-sym` only for output-only
  lowering temporaries.
- Racket binder and occurrence seams:
  `beagle:beagle-lib/private/parse.rkt:2495-2510,4790-4860,4838-5010,
  5230-5260` for `letfn`, patterns, parameters, `let`/destructuring, and
  `for` regions; `parse.rkt:2206-2260` for identifier occurrences. Preserve
  sequential RHS visibility, `letfn` mutual recursion, constraints-before-RHS
  rules, destructuring projections, and all conditional/comprehension binder
  regions from the spike findings.
- Racket checker and projection: replace local name lookup at
  `beagle:beagle-lib/private/check.rkt:21-80,4971-4975,5486-5487,5842-5845`
  with `BindingId` lookup for resolved locals, retaining structural provider
  lookup for imports/globals. Extend
  `beagle:beagle-lib/private/ast-json.rkt:205-214,432-438` with the lexical
  `bindingId`/`refersTo` edge while retaining qualifier/name/provider fields.
- Self-host mirror: add the same value shapes around
  `beagle:self-host/src/selfhost/ast.bclj:87-145` and
  `parse.bclj:452-465,1012-1105,1080-1105,1195-1215,1294-1310,1395-1410,
  2874-2918`. Thread binding tables and current scopes through parameters,
  `let`, `letfn`, patterns, comprehensions, and identifier lowering. Mirror
  the macro flip boundary in `selfhost/macros.bclj:1052-1250` and replace
  string/gensym hygiene, while preserving `fresh-lowered-sym!` only for
  output lowering.
- Self-host checker/projection: update
  `beagle:self-host/src/selfhost/check.bclj:1020-1065,1768-1830,
  3960-4005,5073-5126` to consume resolved binding edges and expose them in
  the checked AST. Keep the self-host shape byte-equivalent to the Racket
  oracle; do not create a native-only resolver.
- Store/graph projection after the rename: preserve compiler-selected binding
  edges in `beagle:store/src/resolve_mint.bclj:123-147`,
  `beagle:store/src/resolve_walk.bclj:166-212,491-580`, and
  `beagle:store/src/fram/code_reader.clj:115-168`. The store records
  `refers_to`/`bound_to` edges; it does not reconstruct lexical hygiene from
  rendered names or its own stack walk.

**Verification.** First run
  `beagle:beagle-test/tests/scope-resolve-spike.rkt` from spike B, now against
  reader-produced syntax and occurrence nodes, then run
  `beagle:beagle-test/tests/macro-hygiene.rkt`, `parse.rkt`, `check.rkt`,
  `facts-render-roundtrip.rkt`, and the self-host scope/macro corpus. The
  focused assertions must inspect `ScopeSet` and `BindingId`, never suffixes.
  Before landing, run `bin/beagle-remint --oracle`,
  `self-host/verify-selfhost.sh`, and the full Racket/cone gate. Acceptance is
  `W5-G2 CAPTURE-MATRIX`: caller, introduced, and nested `tmp` cases select
  three intended binding IDs; antiquoted caller syntax is not captured;
  introduced binder/use pairs resolve together; incomparable maxima are a
  source-pointed ambiguity; and the removal search finds no macro-identity use
  of gensym, `__hyg`, or the old alias path.

**Parallelism and staffing.** After W5a freezes the syntax contract, the
  Racket resolver/binder work and self-host mirror can proceed in parallel on
  disjoint files. Checker, store projection, removal, remint, and parity are
  serial integration work; do not land one implementation without the other.
  Assign `gpt-5.6-sol` medium-xhigh as integration owner for the hardest
  hygiene/binder seam, with `gpt-5.6-luna` medium-high on the self-host mirror.
  Budget 10–15 engineer-days.

## W5c — `syntax-match` and typed templates over the existing evaluator

**Purpose.** Build the smallest structural matcher over the W5b syntax values
and use it to construct typed syntax/AST values through the existing pure
evaluator. This is the W5c vertical slice seeded by
`selfhost/macros.bclj`; it is not a second evaluator and it does not expose
type environments to ordinary macros.

**Exact seams and targets.**

- Racket matcher and constructors: add the internal matcher beside
  `beagle:beagle-lib/private/macros.rkt:62-160,320-342`, with typed constructor
  helpers in `beagle:beagle-lib/private/ast.rkt:279-337,625-686`. Compile only
  list/vector/map/identifier/literal/tail-splice cases into deterministic
  structural tests; bind `Syntax` objects, preserve clause order and origin,
  and reject invalid category or splice placement at the pattern span.
- Racket evaluator seam: retain `beagle:beagle-lib/private/macro-eval.rkt`
  as the computation engine and adapt the call/output boundary in
  `macros.rkt:100-160`. Typed constructors must validate shape and attach
  origin at construction; the existing whole-output checker remains the
  backstop. A generated binder must use W5b scopes, never a printed suffix.
- Self-host seed: implement the same matcher and constructors in
  `beagle:self-host/src/selfhost/macros.bclj:581-626,659-785,881-925`, using
  the existing macro evaluator and typed `make-*` AST constructors in
  `beagle:self-host/src/selfhost/parse.bclj:447-552,688-810`. The matcher seed
  is `(when test body...)`: identifier capture and tail splice are sufficient;
  no grammar-category or general transformer framework is in scope.
- Existing parser/checker seam: send the matched expansion through
  `beagle:beagle-lib/private/parse.rkt:4133-4149,4790-4816` and
  `selfhost/parse.bclj:2465-2510,2874-2918`, then through the existing checker
  rather than a matcher-specific type path.
- Fixtures: add one `when`-shaped macro, one list/vector capture, one
  identifier capture retaining origin, one tail splice, one malformed pattern,
  and one generated typed expression to the focused macro tests. Keep the
  current `defmacro` fixtures as regression cases.

**Verification.** At the focused layer, run the matcher fixtures, the existing
`macro-eval.rkt` and `defmacro.rkt` tests, and the self-host fixture through
the Racket oracle and seed compiler. The gate must show pattern-span errors,
origin-preserving bindings, deterministic clause order, and a type-checking
expanded program. Run the full remint/oracle gate at integration; rerun the
full Racket/cone gate after the serial self-host seed update. Acceptance is
`W5-G3 STRUCTURAL-PATTERN`: the `when` macro expands through compiled
structural matching, invalid shape fails at the pattern, and the existing
typed checker accepts the valid expansion.

**Parallelism and staffing.** Matcher implementation and fixture authoring can
run in parallel after W5b's syntax API is stable. The typed-constructor contract,
self-host seed regeneration, and oracle agreement are serial. Assign
`gpt-5.6-luna` medium-high, with a 7–10 engineer-day budget. Keep any richer
pattern language, grammar categories, and transformer protocol as a later
request rather than expanding W5c.

## W5d — expansion dependencies into cone invalidation

**Purpose.** Make macro expansion and typed evaluator calls first-class
analysis units in the incremental graph. Record dependencies when observed,
not by scanning generated output. The load-bearing acceptance case is a macro
edit that invalidates its expansions even when the changed macro name or logic
does not survive in the emitted tree.

**Exact seams and targets.**

- Racket expansion records: extend
  `beagle:beagle-lib/private/macros.rkt:21-37,224-318,320-342` with stable
  macro definition identity, input/output syntax IDs, parser/syntax-provider
  IDs, source call span, parent origin, and observed evaluator/reflection
  dependencies. The trace callback is diagnostic only; the durable record is
  part of the expansion result.
- Racket parse/check handoff: thread the record through
  `beagle:beagle-lib/private/parse.rkt:1387-1405,2021-2110` and
  `beagle:beagle-lib/private/check.rkt:4971-4990,5486-5495,5842-5850` so the
  checked program and its interface manifest carry the exact expansion edges.
  Do not infer dependencies from output references or from the current
  weak node-identity macro table.
- Self-host mirror: record the same expansion/evaluator unit around
  `beagle:self-host/src/selfhost/macros.bclj:45-59,1172-1250` and
  `selfhost/parse.bclj:3024-3190`; carry it through
  `selfhost/check.bclj:5073-5126`. The seed must produce the same dependency
  facts and stable ordering as the oracle after remint.
- Store/graph integration after the rename: add expansion, evaluator, and
  `depends_on` fact projection at `beagle:store/src/resolve_mint.bclj:123-147`,
  `beagle:store/src/resolve_walk.bclj:166-212,491-580`, and
  `beagle:store/src/fram/code_reader.clj:115-168`. Connect those edges to the
  existing cone invalidation driver and branch-compile expected-cone fixtures;
  store
  facts must make the cone derivable after a clean restart.
- Cone harness targets: extend
  `beagle:bin/test/branch-compile-corpus/run.sh:197-222`,
  `beagle:bin/test/branch-compile-corpus/inspect.clj:97-196`, and
  `beagle:bin/test/branch-compile-corpus/unit_reuse_gate.clj:394-447,
  1575-1622` with a macro-definition mutation and its expected expansion
  cone. Keep the existing semantic-unit identity controls intact.
- Analysis-unit key: use definition identity, typed inputs, compiler/interface
  version, and capability set. Include every consulted macro definition,
  parser provider, evaluator definition, and reflection/interface result in
  the manifest. No cache hit or evaluator memoization is sound before the
  manifest is complete.

**Verification.** The file-focused gate uses the existing branch-compile cone
  harness plus a minimal two-module macro corpus: one used macro, one parser
  provider, one unrelated definition, and one macro whose changed body
  disappears from output. Assert exact expansion and downstream typed-unit
  invalidation, unchanged identities for unrelated units, and identical cones
  after restart. Add a negative test that fails on an observed but undeclared
  read. Run `bin/beagle-remint --oracle` and the full Racket/cone gate at the
  serial integration boundary. Acceptance is `W5-G4 EXPANSION-CONE`: changing
  a used macro/provider invalidates exactly its dependent expansions and
  downstream units; an unrelated edit invalidates none; a disappearing-output
  macro still invalidates; restart derives the same cone; and undeclared reads
  fail visibly.

**Parallelism and staffing.** Expansion-record plumbing and store/graph
  projection can be developed in parallel only after the dependency manifest
  and identity fields are frozen. The actual invalidation driver, restart
  proof, self-host remint, and full gate are serial. Assign
  `gpt-5.6-sol` medium-xhigh because this wave carries incremental soundness;
  budget 7–12 engineer-days. Do not add reflection breadth or optimize the
  resolver/cache before the negative gate passes.

## W5e — restricted static reflection: `fields-of` first

**Purpose.** Add one read-only, capability-limited typed query over the
  immutable checked module/store snapshot. `fields-of` starts with nominal
  checked records and returns typed field metadata, never printed type syntax
  and never mutable inference state. Each result records the defining record
  definition/interface identity in the W5d dependency set. Ordinary
  `defmacro` remains unable to call the API.

**Exact seams and targets.**

- Racket checked-record source: expose the narrow query beside
  `beagle:beagle-lib/private/check.rkt:1121-1160,2310-2410,6292-6325` and the
  record/type lookup paths around `1548-1565`. Read only finalized nominal
  record fields and their checked annotations. Return immutable reflection
  records with the defining definition/interface ID and compiler interface
  version.
- Racket evaluator capability boundary: add an explicit
  `ElabMacroContext` capability at `beagle:beagle-lib/private/macros.rkt:98-160`
  and `macro-eval.rkt`'s builtin dispatch. Ordinary macro environments receive
  no context; only the later typed evaluator path receives `fields-of`. Every
  query appends its dependency to the current W5d expansion/evaluator unit.
- Self-host record lookup: use
  `beagle:self-host/src/selfhost/check.bclj:1548-1585,2310-2392` and the
  checked-program boundary at `5073-5126`. Mirror the immutable record-field
  result and its defining interface identity; do not consult the mutable
  inference work state after checking.
- Self-host evaluator capability: thread the capability through
  `beagle:self-host/src/selfhost/macros.bclj:264-288,659-785,881-925` and the
  typed-constructor path from W5c. The seed and Racket oracle must reject
  `fields-of` from an ordinary `defmacro` with a phase/capability diagnostic.
- Store/manifest projection: persist the `fields-of` result and consulted
  interface edge through `beagle:store/src/resolve_mint.bclj:123-147`,
  `beagle:store/src/resolve_walk.bclj:166-212,491-580`, and
  `beagle:store/src/fram/code_reader.clj:115-168` using the post-rename
  paths. Do not
  make static reflection a route to arbitrary store writes or ambient compiler
  state.

**Verification.** The focused gate derives one codec or field-name declaration
  from a nominal checked record, checks its typed output and provenance, and
  asserts the manifest names the record definition/interface and compiler
  version. Change an unrelated definition and assert no evaluator rerun;
  change a record field/type/effect and assert rerun through W5d's cone. Add a
  negative ordinary-`defmacro` capability test. Run the remint/oracle gate and
  full Racket/cone suite once at W5e integration. Acceptance is
  `W5-G5 REFLECTION-CAPABILITY`: reflection is read-only, typed,
  dependency-complete, record-scoped, and unavailable to ordinary macros.

**Parallelism and staffing.** Racket and self-host record-query adapters can
  proceed in parallel after the W5d manifest contract is stable; capability
  enforcement, dependency assertions, and lineage integration are serial.
  Assign `gpt-5.6-terra` medium effort, budget 4–6 engineer-days. Keep
  `resolve`, `type-of-syntax`, `lookup-def`, `members-of`, unions, effects, and
  arbitrary store queries out of this wave until `fields-of` is proven.

## Final W5 acceptance gate

`W5-STAGE5-LINEAGE` is the only final W5 acceptance gate. On the live demo
lineage, edit a nominal record consulted by a hygienic macro that uses
`fields-of`. The retained evidence must name the source revision, syntax IDs,
scope/binding edges, macro definition, reflection interface, expansion result,
typed unit, materialization, and exact invalidation cone. The unrelated edit
control must retain its identities. The affected materialization must be cold
compiled, the incumbent must serve until admission, and the candidate must
enter through the existing shadow/CAS protocol. Restart once before demand and
prove the same cone and artifact identities from stored facts.

W5 is complete only when `W5-G1` through `W5-G5`, the self-host oracle/fixpoint
gate, and `W5-STAGE5-LINEAGE` pass on the integrated post-rename tree.

W5-PLAN-DONE
