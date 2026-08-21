# Prior-art steal sheet: Racket expander for Beagle W5

> License and source notice: this is independent analysis, not copied Racket
> implementation text. The inspected checkout is
> `~/code/resources/racket`, commit `730f8aee544927dd18a5edaad96c45d31dbf5fed`.
> Racket is available under MIT or Apache-2.0 at the recipient's option; see
> `racket:LICENSE.txt`. Preserve the selected license and required notices if
> any Racket expression is ever copied. This sheet proposes an independently
> implemented Beagle design.

## Bottom line

Take Racket's small lexical kernel literally: a scope is a fresh identity;
each identifier carries a set of those identities; a binding is indexed by
`(structural name, binding-scope-set)`; resolution selects the applicable
binding with the largest scope set and rejects incomparable maxima. A macro
expansion toggles one fresh introduction scope around the transformer call.

Do not take its module/phase/runtime machinery. Beagle W5 needs one lexical
phase, structural names, immutable syntax values, and explicit provenance. It
does not need Racket-compatible modules, inspectors, certificates, serializing
compiled syntax, or a phase tower.

## Implementation truth: the minimal data model

### Syntax and scope

Racket's concrete `syntax` struct holds nested datum, ordinary scopes,
phase-shifted module scopes, module-path-index shifts, source location,
properties, and an inspector (`racket:racket/src/expander/syntax/syntax.rkt:52-59`).
For a W5 identifier, retain only the corresponding useful core:

```text
Syntax = Atom | Ident { name: StructuralName, scopes: ScopeSet, span, origin, props }
       | List { children, delimiter, span, origin, props } | Vector | Map | Set
Scope = fresh opaque ScopeId
Binding = { id: BindingId, name: StructuralName, scopes: ScopeSet, kind }
BindingTable = Map StructuralName (Map ScopeSet Binding)
```

A Racket scope is an authentic record with a unique, monotonically allocated
identity, debug `kind`, and mutable binding table; the numeric identity is
used for sorting, not for user-visible naming
(`racket:racket/src/expander/syntax/scope.rkt:81-89,318-344`). Thus the
implementation fact to copy is *identity membership*, not a generated textual
suffix. `add-scope` and `flip-scope` add/remove an identity through a syntax
tree; `flip` is symmetric difference (`racket:racket/src/expander/syntax/scope.rkt:556-580`).
Racket delays child propagation for sharing, recording operations in a
`propagation` wrapper and applying them when syntax content is forced
(`racket:racket/src/expander/syntax/scope.rkt:603-659,676-714`). Beagle can
start eagerly and immutable; lazy propagation is an optimization, not part of
hygiene's contract.

Keep `ScopeSet` separate from W1--W4's `StructuralName`. The latter remains
the authored qualifier/leaf/provider representation and the former is an
unprintable lexical dimension beside it. A qualified identifier resolves by
the same structural name fields plus scopes; scope membership must never be
encoded into `name`, a rendered alias, or `fresh-lowered-sym!`.

### Binding table and resolution

Racket stores the ordinary table precisely as an immutable hash nesting
`symbol -> scope-set -> binding` (`binding-table-add` in
`racket:racket/src/expander/syntax/binding-table.rkt:115-145`). It physically
places that table on the newest scope in the binding set, so searches start at
a useful location; adding a binding clears the resolution cache
(`racket:racket/src/expander/syntax/scope.rkt:927-947`). The `bulk-binding`
path is module-import machinery and is outside Beagle's initial table.

`resolve` first forms the identifier's effective set at the requested phase.
It visits candidate entries for the identifier spelling and retains only those
whose binding set is a subset of the use set. Among applicable candidates, a
strictly larger set wins; equal/subset candidates lose. If incomparable
maximal sets remain, the result is ambiguous; no candidate means unbound
(`racket:racket/src/expander/syntax/scope.rkt:958-1028`).

Beagle's one-phase resolver should implement exactly that relation:

```text
applicable(b, use) = b.name == use.name && b.scopes ⊆ use.scopes
resolve(use) = unique maximal applicable binding by ⊆
             | unbound
             | ambiguous
```

The value returned should be a stable `BindingId`/definition edge, not a
renamed string. This fits W4's structural `refers_to`: resolve installs that
edge from a syntax identifier occurrence to the selected binding, while
rendering remains a separate concern. Racket's own local bindings demonstrate
the right separation: their scope-selected key points into an expansion-time
environment instead of embedding the compile-time value in expanded syntax
(`racket:racket/src/expander/syntax/local-binding.rkt:18-44`).

### The macro and binder boundary

For every transformer invocation Racket allocates one `macro` scope, flips it
onto the input, optionally adds definition-context use-site scopes, invokes the
transformer, and flips the same introduction scope on the output
(`racket:racket/src/expander/expand/main.rkt:370-405`). Existing use-site
syntax traverses both flips and keeps its original scopes; syntax introduced
by the transformer traverses only the post-call flip and gains the new scope.
That is the concrete mechanism that prevents accidental capture.

Core binders use the same primitive, not a separate alpha-renamer. For a
lambda, Racket adds one fresh local scope to formal identifiers and the body,
installs bindings at those scoped formals, then expands the scoped body
(`racket:racket/src/expander/expand/expr.rkt:35-72`). `let` similarly scopes
binders, the appropriate RHSs, and the body before binding
(`racket:racket/src/expander/expand/expr.rkt:187-249`). Beagle should do the
same in the parser/elaborator for `fn`, `let`, `loop`, destructuring binders,
and local macro binders.

Racket definition contexts have two edge scopes plus mutable environment
mixins and use-site-scope bookkeeping
(`racket:racket/src/expander/expand/definition-context.rkt:42-74,99-150`).
They solve internal definitions and splicing. They are valuable evidence that
scope operations, not symbol rewriting, are the extensible primitive, but are
not a W5 starting requirement.

### Source locations, properties, and provenance

`datum->syntax` inherits context scopes, phase/module context, and inspector;
it takes location from a separately supplied syntax object and properties from
another supplied syntax object (`racket:racket/src/expander/syntax/syntax.rkt:246-290`).
The expander's `rebuild` helper deliberately passes the original syntax as
both location and property source (`racket:racket/src/expander/expand/rebuild.rkt:6-11`).
`syntax-property` is a persistent hash update
(`racket:racket/src/expander/syntax/property.rkt:15-43`), while
`syntax-track-origin` merges old and new property maps and prepends an
`origin` trail (`racket:racket/src/expander/syntax/track.rkt:13-74`).

Copy the behavioral rule, with a smaller representation: an unquoted input
child keeps its exact `Syntax` object and span; a generated wrapper receives
the macro-call span and an `ExpansionOrigin { macro-id, call-span, parent }`;
rebuilding a parser form preserves its top-level span and non-conflicting
internal properties. Keep a small typed/internal property map initially
(`origin`, delimiter/reader metadata, diagnostic tags), rather than Racket's
general preserved-property, taint, inspector, and serialization protocol.

## Deliberate cut line: do not import the full expander

- **No phase tower or module scopes.** Racket's `multi-scope` gives a module a
  distinct representative scope at every phase and tracks phase shifts
  (`racket:racket/src/expander/syntax/scope.rkt:162-178,797-849`). Its binding
  records also include module bindings, module-path-index shifts, lazy bulk
  imports, `require`/`provide`, and cross-phase behavior. W5 is one lexical
  scope set at compile time. Imports retain the W1--W4 structural provider
  path; module interfaces are dependencies, not scope identities.

- **No Racket definition-context/use-site compatibility surface initially.**
  Do not expose Racket's `syntax-local-*` API, inside/outside edge rules,
  `local-expand`, lifting, or spliced-definition semantics merely to look
  compatible. Add a small Beagle internal-definition context only after a
  concrete `defmacro` use needs mutually visible generated definitions.

- **No inspectors, certificates/taints, arming, serialization, or fallback
  namespaces.** Racket syntax carries protected-binding access, taint-aware
  properties, compiled-code reachability/serialization, cache invalidation,
  and fallback multi-scope searches. Those support Racket's runtime and
  compatibility contract. Beagle needs immutable syntax plus explicit
  origin/dependency records; it should not invent ambient authority in a
  macro value.

- **No general Racket transformer protocol.** Do not import syntax parameters,
  rename/set! transformers, module visitors, portals, lifts, or expansion
  observers. Preserve Beagle's pure macro evaluator and its output checking;
  static reflection arrives only after expansion dependencies are recorded and
  through a narrow read-only capability.

The cut is therefore immediately after: `Syntax`, fresh `ScopeId`,
scope-set binding/resolution, a one-phase macro boundary, and source/provenance
preservation. Everything involving a module instantiation, a shifted scope,
or Racket compatibility API remains out.

## Mapping onto Beagle W1--W4

| Layer | W5 change |
| --- | --- |
| Reader | Produce `Syntax` for code, preserving delimiter and exact span. An identifier leaf contains the existing structural `StructuralName` plus empty `ScopeSet`; quoted data stays datum, so its symbols never enter lexical resolution. This replaces raw-string identity at the macro boundary without reviving compound qualified names. |
| Macro boundary | Adapt `selfhost.macros` inputs/outputs from raw tagged data to `Syntax`. Quasiquote creates fresh syntax whose introduced identifiers receive the current intro scope; unquote inserts the original syntax object unchanged. Keep `selfhost.macros`' pure evaluator and the existing template-output type check. Its current contract explicitly says it evaluates raw syntax (`beagle:self-host/src/selfhost/macros.bclj:1-5,203-206`); its generated result must remain checked after the adapter. |
| Parser / expander | Expand before ordinary AST lowering. Each macro call makes one `ScopeId`, performs Racket's flip boundary, records `Expansion { macro-id, call-span, parent, macro-deps, reflection-deps }`, then parses the result. For every lexical binder, mint a scope, attach it to binder and lexical region, install `Binding { StructuralName, ScopeSet }`, and replace reference occurrences with structural `BindingId` edges. |
| Checker | Consume resolved binding IDs, not printed temporary spellings. Continue to type-check all macro output—the current parser already records macro-derived context so post-expansion type errors are identified as macro-expansion errors (`beagle:beagle-lib/private/parse.rkt:2021-2031`). A later reflection capability may query checked immutable interfaces only and must append each consulted definition/interface ID to `reflection-deps`; normal macros receive none. |
| Diagnostics / rendering | Preserve exact child spans through unquote; assign the macro-call span to generated wrappers; show `StructuralName`'s human spelling in errors and carry the origin chain separately. Rendering never reconstructs hygiene identity, just as W4 renders qualified spelling from structural facts at the final boundary. |

The existing native parser already uses `datum->syntax` deliberately to give a
synthetic wrapper its source form while preserving embedded child syntax
locations (`beagle:beagle-lib/private/parse.rkt:2175-2207`). W5 should retain
that blame rule, but move it from a Racket-host detail into the explicit Beagle
`Syntax` representation so self-hosted expansion can preserve it too.

## Three first experiments — one lane each

1. **Syntax-object membrane.** Add the internal `Syntax` ADT, source spans,
   `origin`, and raw-datum adapter at the self-host macro call boundary. Support
   list/vector/atom/identifier plus quote/unquote only. Acceptance: an
   existing `defmacro` returns `Syntax`, existing macro-output type checking
   still runs, and an antiquoted child retains its exact source span. No scopes
   or syntax patterns yet.

2. **One-phase scope resolver.** Implement immutable `ScopeId`/`ScopeSet`,
   `BindingTable[StructuralName][ScopeSet]`, maximal-subset resolution, and
   scope allocation for a tiny `let` plus one binding macro. Acceptance: a
   caller's `tmp` survives an antiquoted expression, while macro-introduced
   binder/use resolve to one another and cannot capture caller or nested-macro
   `tmp`. Assert binding IDs and scope sets, never suffix spellings.

3. **Pattern and dependency vertical slice.** Add only
   `syntax-match` for list/vector shape, identifier capture, and tail splice;
   implement one `(when test body...)` macro through it. Emit its `Expansion`
   provenance with the actual macro definition ID into the module dependency
   manifest. Acceptance: malformed patterns blame the pattern span, changing
   the macro definition invalidates the dependent module, and no reflection
   API exists yet.

## Evidence

Read directly from the Racket expander at
`~/code/resources/racket` commit `730f8aee544927dd18a5edaad96c45d31dbf5fed`:
`racket/src/expander/syntax/{syntax,scope,binding-table,local-binding,property,track}.rkt`
and `racket/src/expander/expand/{main,expr,definition-context,rebuild}.rkt`.
The source was clean at inspection. Beagle mapping was checked against
`beagle:self-host/src/selfhost/macros.bclj` and
`beagle:beagle-lib/private/parse.rkt`.

PRIOR-RACKET-DONE — requested implementation-focused handoff written with
source paths, line citations, license boundary, and three lane-sized probes.
