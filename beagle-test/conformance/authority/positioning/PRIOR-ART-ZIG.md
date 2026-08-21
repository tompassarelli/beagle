# Prior-art steal sheet: Zig comptime for Beagle W5

> License and source notice: this is original analysis, not copied Zig code.
> Zig source examined at `zig` commit `738d2be9d6b6` is copyright Zig
> contributors and released under the MIT License (Expat); see
> `~/code/resources/zig/LICENSE`. Preserve that license and required notice if
> Zig implementation text is ever copied. This sheet proposes independent
> Beagle designs. The source tree is read-only.

## Bottom line

Beagle should treat its existing typed compile-time evaluator as a promising
**comptime-shaped extension system**, not as a half-finished Racket expander.
The high-value Zig lesson is: expose compile-time programming as ordinary typed
language code, make types ordinary compile-time values, and put the evaluator
inside semantic analysis so it gets ordinary name resolution, types, source
locations, errors, dependency recording, and cache invalidation.

This solves a large class of extension work more directly than macros: derived
types and declarations, serialization/schema code, specialized dispatch,
compile-time validation, and code selected from typed reflection. It does not
solve surface-language extension. A comptime function can choose and construct
meaning *inside the grammar it was given*; it cannot make a new parser form,
define a binding discipline, or establish hygienic lexical scopes in arbitrary
unexpanded source. W5 still needs real syntax macros for those jobs.

The recommended split is therefore not “macros or comptime.” Keep the current
typed evaluator as the default computation substrate; make its results typed
AST/IR values with provenance and dependencies. Add a small hygienic syntax
macro layer only when an extension must introduce notation or binding forms;
let such macros use the typed evaluator for computation rather than rebuilding
a second meta-language.

## What Zig actually implements

### One semantic pipeline, executed at compile time when required

Zig's parser/lowering first produces ZIR. `zig:src/Sema.zig` describes `Sema`
as the transformation from untyped ZIR to semantically analysed AIR, doing type
checking, comptime control flow, and safety-check generation in the same
component. Compile-time evaluation is thus not a pre-parse textual rewrite and
not a separate untyped macro interpreter.

`Sema.Block` carries `comptime_reason`; `Block.isComptime` decides whether a
block executes in compile-time context. The reason is preserved for diagnostics
(`Sema.zig`, around `BlockComptimeReason` and `ComptimeReason`): a failure can
say not only that a value was required at compile time but also whether the
reason was a `comptime` call modifier, a `comptime` parameter, a comptime-only
return type, or inherited inlining. `analyzeInlineBody` (around line 1051)
analyses a body and returns its result while propagating compile-time control
flow. In other words, the evaluator is the normal analyser executing the
normal language semantics, not a template expander interpreting a special
quotation language.

The call path makes the boundary concrete. In `Sema.zig` around lines
7240–7900, call analysis:

- detects a known function value and rejects a generic call target that is not
  comptime-known;
- enters a comptime block for an explicit `comptime` call or a comptime-only
  result type, which also forces the arguments to be comptime-known;
- swaps in the callee's ZIR and instruction map, binds the actual arguments,
  then analyses the callee body with a child block whose comptime state inherits
  from the call; and
- records a source-hash dependency on an inline call's whole function body.

`Sema/comptime_ptr_access.zig` and the comptime allocation state in
`Sema.zig` show that the model is not merely constant folding. The analyser
models compile-time allocation, pointer reads/writes, mutability constraints,
and paths used to explain why a value containing a comptime pointer cannot
escape to runtime. That is why a comptime program gets ordinary semantic
rejection rather than a macro's downstream malformed-output failure.

### Types are values, and values are interned compiler objects

The compact representation makes the familiar Zig claim literal. `Type` and
`Value` are thin wrappers around an `InternPool.Index`:

- `zig:src/Type.zig` has `Type.toValue`, which wraps the type's interned index
  as a `Value`.
- `zig:src/Value.zig` has `Value.toType`, which converts an appropriately
  represented value back to `Type`.
- `zig:src/InternPool.zig` owns the structural, canonicalised entries for
  types, values, functions, memoized calls, and analysis units.

That is the important design property, not the particular pointer-sized
representation: a type can be computed, passed to a generic call, inspected,
and used to drive later checking without converting it into a string or an
untyped syntax template. `Sema` therefore has a single notion of a known value
whether it is an integer, aggregate, function, or type-level object. A Beagle
equivalent should make `Type` and typed AST constructors evaluator-visible
values with opaque stable identities, rather than encoding types as reader
data or making macros print type syntax.

### Comptime declarations are analysis units, not a global expansion pass

`InternPool.createComptimeUnit` creates a `ComptimeUnit` from a tracked ZIR
instruction and namespace; it is wrapped as `AnalUnit.comptime`. The compiler
work loop in `zig:src/Compilation.zig` asks `Zcu.findOutdatedToAnalyze` for
work and queues `AnalUnit.comptime` alongside declaration values, declaration
types, types, memoized states, and function analysis. The dispatched job calls
`Zcu.PerThread.ensureComptimeUnitUpToDate`.

`zig:src/Zcu/PerThread.zig` is especially clear about the contract:

- `ensureComptimeUnitUpToDate` first checks/update-tracks the analysis unit;
- `analyzeComptimeUnit` resolves the stored ZIR location and analyses it; and
- failed analysis is registered for reporting instead of being turned into an
  unlocated later-stage compiler crash.

This is lazy analysis in a meaningful sense: the compiler maintains units that
can be requested, invalidated, and brought current, instead of eagerly
expanding every possible compile-time computation before it knows what the
build reaches. It is not an unlimited promise of laziness—root analysis and
reachable work still determine what is evaluated.

### Incrementality is a dependency graph with precise invalidation

`Sema.declareDependency` (`zig:src/Sema.zig`, around line 36901) records a
dependee only when incremental compilation is enabled and explicitly avoids
self-dependencies that would cause needless re-analysis. Calls and type
analysis record source-hash dependencies on tracked ZIR instructions. The
compiler persists intern-pool state and `src_hash_deps` in
`Compilation.saveState`; it writes the saved state atomically so a crash does
not corrupt the preceding incremental state.

On an update, `Compilation.zig` runs `PerThread.updateZirRefs`, then its work
loop finds an outdated unit and queues the correct analysis job. `Zcu.zig`
propagates invalidation through `dependencyIterator`, distinguishes
`outdated` from `potentially_outdated`, and only marks a unit ready once its
outdated/potentially-outdated prerequisites allow it. If declaration cycles
prevent a trivially ready unit, `findOutdatedToAnalyze` chooses a dependency
graph heuristic to break the cycle. This is a real incremental-analysis design,
not merely a filesystem cache around a macro pass.

There is an important honest caveat in the source. `Sema.zig` explicitly
disables comptime call memoization under incremental compilation: callers do
not yet receive the dependencies a memoized call needs, so `want_memoize` is
false in incremental mode. Do not copy the headline without this constraint.
For Beagle, a cached evaluator result is sound only when its cache key and
dependency manifest include every definition/type/interface/reflection result
consulted by the computation.

## The strongest case for comptime-shaped Beagle extension

Beagle already has the key seed. `beagle-program-handoff:demo/proof-tree/self-host/src/selfhost/macros.bclj`
states that canonical `defmacro` bodies run in a pure compile-time evaluator;
its `defmacro` path evaluates ordinary bodies rather than merely performing
template substitution. It also refuses the old unsafe template route, stating
that template macros are type-checked end-to-end. The expanded program is
checked by `selfhost/check.bclj` through `type-check!` / `check-program!`.
That is closer to Zig's “normal computation participates in semantics” than
to a traditional untyped text macro facility, even though its present macro
inputs/outputs are raw reader data.

Build from that strength:

1. **Ordinary code, not an alternate metalanguage.** Let compile-time
   functions use Beagle's normal functions, values, conditionals, collections,
   type constructors, and diagnostics. Authors do not have to learn token
   surgery, pattern quotation, or a separate expansion evaluator merely to
   generate a typed declaration family.
2. **No hygiene problem for computations that do not manufacture binders.** A
   comptime function that returns a `Type`, a field table, a validated constant,
   or a typed AST built from explicit constructors does not inject bare lexical
   identifiers into a caller. It needs names/resolution rules, but not the
   capture-prevention machinery that quotation-based syntax macros require.
   This is a substantial reduction in surface area, not a claim that name
   resolution disappears.
3. **Errors remain ordinary errors.** Type errors, failed constraints, and
   invalid AST construction can point to the computation or its input through
   normal diagnostic provenance. There is no artificial boundary at which a
   macro succeeds and a mysterious generated program later fails. Preserve
   `macros.bclj`'s expansion chain as provenance, but extend it with input
   spans, generated-node origins, evaluator call frames, and typed constructor
   failures.
4. **Typed reflection is computation rather than syntax guessing.** A restricted
   `type-of`, `fields-of`, `members-of`, and definition/interface query API can
   return typed immutable values. The evaluator can select an implementation,
   derive codecs, or verify an exhaustiveness policy without scraping printed
   type syntax. Each query records exactly the interface/value it observed.
5. **It fits incremental compilation.** Define an evaluator invocation as an
   analysis unit: `(definition-id, typed inputs, compiler/interface version)`
   produces `(typed result, provenance, dependency set)`. Invalidate it from
   consulted definition/type/interface IDs; re-run only its dependers. This is
   the transfer worth taking from Zig, independent of Zig's exact intern-pool
   data layout.

The immediate design boundary should be typed construction, not arbitrary raw
datum return. Replace the macro evaluator's implicit “reader datum becomes
program” path with a small capability API such as `Ast.expr`, `Ast.decl`,
`Ast.ident`, `Type.fn`, and `Diagnostic.error`. Those constructors validate
shape and attach origin at construction time. A result is accepted only as a
well-typed AST/IR value; the existing whole-output checker remains the
backstop, not the first time malformed generated structure is noticed.

## Where comptime stops and true macros remain necessary

Comptime can compute a value under an already parsed and elaborated construct.
It cannot interpret source that the parser does not already know how to turn
into that construct. Do not describe a typed evaluator as a replacement for
W5's macro work when any of the following is required.

| Need | Why comptime alone fails | Required macro-side capability |
| --- | --- | --- |
| New notation or literal surface | A function call has already been parsed under fixed grammar; it cannot give a new token sequence precedence, delimiter rule, reader treatment, or error recovery. | Parser/reader extension with explicit syntax categories only where Beagle actually needs them. |
| New binding forms | A function can return a declaration description, but it cannot change how unexpanded occurrences in its caller bind, shadow, recur, destructure, or sequence evaluation. | Syntax objects with scope-set hygiene, identifier resolution, and a binding-aware expansion contract. |
| Source-preserving transformation | Typed AST may have discarded comments, exact token choices, or unresolved identifier shape before the evaluator runs. | Syntax objects with spans/origin, quotation/antiquotation, and structural pattern matching. |
| General local syntactic abstraction | Asking users to encode every `when`, pipeline, match arm, or DSL fragment as data/function calls loses the intended direct notation. | Hygienic macros over syntax; generated binders get fresh scopes and antiquoted caller syntax keeps its scopes. |

The hygiene claim is deliberately narrow. Comptime “beats” macro hygiene when
it computes types/values or builds AST with explicit binder identities and
does not splice caller syntax. The moment a comptime API returns syntax with a
new lexical binder, it has reintroduced the macro problem. It must either use
the same scope-set machinery as W5 macros or forbid binder introduction. Fresh
string suffixes in the current `macros.bclj` are a transitional lowering
mechanism, not a correctness proof.

There is also a real diagnostic wall. Ordinary code gives ordinary errors only
while the source-to-result provenance survives. Deep generated trees, nested
compile-time calls, and reflection-driven choices can still make errors opaque:
the user sees a type error in a synthesized AST or the final selected branch
rather than the policy that selected it. Zig's reason chains and tracked source
locations help, but do not abolish the problem. Beagle needs bounded expansion/
evaluation traces, generated-to-origin links on every AST node, and a display
that defaults to the nearest authored site while allowing “show generated
form” and “show compile-time call chain.” This is an implementation obligation,
not a reason to pretend comptime diagnostics are automatically ideal.

## Steal / do not steal

| Steal | Do not infer or copy |
| --- | --- |
| Compile-time computation through the normal typed evaluator, with explicit reason/provenance. | Zig's particular ZIR/AIR/intern-pool representation; Beagle needs a smaller typed AST/IR value model. |
| Types as evaluator-visible canonical values; typed reflection returns values, not printed syntax. | Unbounded reflection into mutable compiler state. Reflection must be capability-limited and dependency-recorded. |
| Analysis units and a dependency graph for evaluator calls/declarations. | Blind memoization. Zig itself disables comptime-call memoization in incremental mode because caller dependencies are incomplete. |
| Precise diagnostic cause chains for why an expression must be compile-time known. | The idea that all comptime failures are clear. Deep generated computation still needs origin and stack presentation. |
| Ordinary-code extension first; macros only at the syntax/binding boundary. | Calling raw reader-datum rewriting “comptime.” Raw datum output still needs a syntax/typed-AST boundary and, for binders, hygiene. |

## Three first experiments

1. **Typed evaluator result vertical slice.** Add a private `CompileValue`
   boundary containing canonical `Type`, constant, and typed-expression/
   declaration-builder values. Make one existing self-host `defmacro` body
   return a typed expression through constructors instead of raw data. Accept
   only a validated typed result, then still run the existing output checker.
   Acceptance: a valid generated expression retains the invocation span and a
   malformed constructor result reports at the constructor call, not as a later
   parser/type-checker mystery.

2. **Reflection dependency and invalidation probe.** Provide read-only
   `fields-of` for one nominal record and record its definition/interface ID in
   an `EvalResult { value, dependencies, provenance }`. Derive a field-name
   list or codec declaration from it. Change an unrelated definition, then the
   record definition. Acceptance: the unrelated edit does not re-evaluate the
   invocation; the record edit does; the emitted dependency manifest names the
   consulted record interface. Do not add memoization until this result is
   correct.

3. **Boundary test: comptime succeeds, macro required.** Implement a typed
   compile-time helper that derives a `Point` codec declaration and verify its
   generated output/type errors have source provenance. Then specify—not yet
   implement—a direct `with-point [x y] point body...` binding form. Acceptance:
   the team can state precisely why no ordinary evaluator function can bind
   `x`/`y` in unexpanded `body`, and the proposed W5 syntax-object expansion
   supplies fresh scopes for those binders while preserving caller scopes in
   `body`. This keeps the macro investment attached to a demonstrated need.

## Evidence

- Zig semantic/evaluation path: `zig:src/Sema.zig`, especially the header,
  `analyzeInlineBody`, call analysis around lines 7240–7900,
  `declareDependency`, and comptime allocation handling; also
  `zig:src/Sema/comptime_ptr_access.zig`.
- Zig values/types and compile-time units: `zig:src/Type.zig`,
  `zig:src/Value.zig`, and `zig:src/InternPool.zig` (`createComptimeUnit`,
  memoized-call key, and interned entities).
- Zig lazy/incremental machinery: `zig:src/Zcu/PerThread.zig`
  (`ensureComptimeUnitUpToDate`, `analyzeComptimeUnit`), `zig:src/Zcu.zig`
  (outdated/potentially-outdated graph), and `zig:src/Compilation.zig`
  (`updateZirRefs`, analysis job queue, incremental-state persistence).
- Beagle current baseline:
  `beagle-program-handoff:demo/proof-tree/self-host/src/selfhost/macros.bclj`
  and `beagle-program-handoff:demo/proof-tree/self-host/src/selfhost/check.bclj`.

PRIOR-ZIG-DONE
