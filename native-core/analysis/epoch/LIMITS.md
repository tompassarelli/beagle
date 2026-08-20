# Epoch affordance analyzer limits

`affordance.clj` is a pure fold over `bin/beagle-ast` JSON. It never executes
the analyzed code. When classification is uncertain it reports `ESCAPES`,
never `INTERIOR`.

## Verdicts

- `INTERIOR`: every syntactic flow of the allocation remains inside the
  boundary region.
- `ESCAPES` with `crossing: true`: the value leaves through the boundary's own
  crossing set, such as its return, a loop-carried accumulator, or a collected
  callback result.
- `ESCAPES` with `crossing: false`: the value reaches non-local storage, a
  capture, an escaping callee, an error, or an unclassified flow.
- `PROMOTED` with `crossing: true`: the value crosses its allocating boundary
  but remains interior to the enclosing function boundary. `escapesFrom` names
  the crossed boundary.

## Flow rules

- Store builtins apply the atom-store rule before their return value is
  classified.
- `spit` consumes its argument. `slurp`, `fact`, and `text-id` produce fresh
  values. A same-named function definition takes precedence over builtin
  classification.
- Record values carry field taint through field-preserving moves. Reading a
  different field does not propagate that taint. Parameter summaries remain
  field-insensitive.
- Every function parameter starts at `interior` when named and `unknown` when
  unnamed. A missing summary is `escapes`.
- Text and codec operations are classified as fresh copies. This is unsound if
  lowering introduces borrowed text slices.
- Predicates, arithmetic, and printers do not retain arguments. `println`
  renders rather than retains.
- `match` clause bodies are all considered, regardless of which clause runs.
- Values reaching `ex-info` or `throw` escape through an error. `try` catch
  bodies flow to the `try` value.
- A value visible from a function literal is captured.

## Aliasing limits

Container writes taint the container and reads from that container re-taint the
result. The analyzer does not connect a write through one mutable alias to a
read through a different alias created before the write. Persistent Beagle Core
values do not expose that case; hosted mutable interop can.

## Call limits

- Parameter summaries use the lattice `interior < returns < escapes`. One
  escaping branch applies to every call site for that parameter.
- Variadic and destructured parameters are `unknown`.
- Indirect calls and host interop are `ESCAPES/unknown`.
- Unknown callees are `ESCAPES/unknown`; each run prints their spellings and
  counts.

## Boundary detection

- A function belongs to a root's ownership region only when all direct callers
  are the root or already-owned functions. Module-level callers break
  ownership.
- Keyword-discriminant conditionals define dispatch scopes. Handler discovery
  follows calls at clause spines that receive the discriminant parameter.
- Request/response-shaped `dispatch*`, `handle*`, `serve*`, and `commit-*`
  functions are dispatch roots even without a keyword-shaped discriminant.
- Stage roots are recognized by frozen-stage, stage-value, and result-union
  type shapes. A driver is recognized when it calls at least two distinct stage
  functions; dataflow between those calls is not proven.
- Counter brackets mark only bindings between the paired reads. Session forks
  and paired open/close vocabulary mark the whole function.
- Open/close vocabulary recognizes `open-X!`/`close-X!`, unbanged equivalents,
  and `open`/`commit!`, including one level of callee traversal.
- An otherwise unclassified function inherits the union of its direct callers'
  regions. Inheritance is one level and never flows through another inherited
  region.
- Module entrypoints are public functions with no callers inside the supplied
  module and dependency closure.
- Classification precedence is generation, dispatch, stage, then entrypoint.

## Retaining identity

Every escape reports `retainingType` and `identity`.

`retainingType` is, in order: the most recent record entered, an atom's content
annotation, the boundary root's return type, or the module definition's
annotation. It is a label and never changes the verdict.

`identity` is `domain`, `incidental`, or `unknown`. Domain types are records or
unions declared by domain namespaces, stage records, and explicit stage
products. Diagnostic, error, refusal, measurement, replay-result, load-result,
records-result and control records are incidental. Unresolved types remain
unknown.

## Enumeration and source limits

- Only constructs in the allocation taxonomy are sites. Hosted allocators
  outside it still participate in flow but are not enumerated.
- Conditional allocators are excluded from `alwaysAllocating` summaries.
- The program universe is the manifest's AST inputs plus its resolved require
  closure. Context modules contribute call resolution, summaries, and
  in-degree, but their sites are not reported.
- Source lines are reconstructed textually because the AST does not carry
  general source locations. `lineConfidence` describes the reconstruction.
  Verdicts never depend on line numbers.
- Reference resolution through local bindings has a depth cap of six.
- Each site has an 8,000-step flow budget. Exhaustion is `ESCAPES/unknown`.
- Parameter-summary iteration is monotone over a finite lattice and capped at
  500 iterations; non-convergence is reported.
