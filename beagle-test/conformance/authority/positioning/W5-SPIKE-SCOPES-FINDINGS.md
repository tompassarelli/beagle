# W5 Spike B: sets-of-scopes resolver findings

## Verdict

**The model attaches cleanly to the W1--W4 structural qualified-reference
identity, but not at the current AST stage.** The spike's binding table treats
the name as an opaque `equal?` key. Two independently allocated values with the
W1--W4 shape `(qualifier, leaf, provider-id)` select the same bucket, while the
scope set stays a separate identity dimension. No rendered `x/y` spelling,
split, suffix, gensym, or provider alias is involved.

The required attachment point is an identifier-bearing `Syntax` value before
ordinary AST lowering. Today the Racket AST represents a qualified reference
as `qualified-ref(qualifier, name, provider-id)` but represents an unqualified
local reference as an interned symbol (`beagle:beagle-lib/private/ast.rkt`,
`beagle:beagle-lib/private/parse.rkt:lower-qualified-reference` and
`parse-expr`). The self-host mirror uses `{"node":"ref","qualifier", "name",
"providerId"}` for qualified references and `{"node":"ref","name"}` for
locals (`beagle:self-host/src/selfhost/ast.bclj` and
`beagle:self-host/src/selfhost/parse.bclj`). Sets of scopes must cover both.
Adding a `scopes` field only to `qualified-ref` would miss the identifiers that
need lexical hygiene.

The clean shape is therefore:

```text
SyntaxIdent { name: StructuralName, scopes: ScopeSet, span, origin, props }
StructuralName = LocalName | QualifiedRef { qualifier, leaf, providerId? }
ResolvedRef { name: StructuralName, bindingId?: BindingId }
```

`providerId` remains module/provider identity from W1--W4. `bindingId` is the
lexical definition edge selected by sets-of-scopes. They are different axes
and must not share a field.

## What the spike proves

New standalone files:

- `beagle:beagle-lib/private/scope-resolve-spike.rkt` implements opaque fresh
  scopes, immutable `seteq` scope sets, flip/add/remove operations, the exact
  immutable `Map StructuralName (Map ScopeSet Binding)` table, duplicate-key
  rejection, and unique-maximal-subset resolution. Resolve returns a binding
  ID or explicit unbound/ambiguous data; it never returns a renamed string.
- `beagle:beagle-test/tests/scope-resolve-spike.rkt` runs seven deterministic
  property groups with 128 generated trials each. It varies fresh identities,
  irrelevant occurrence scopes, and binding insertion order.

The focused pinned-Racket command was:

```text
source bin/_beagle-racket && nice -n 19 "$RACO" test beagle-test/tests/scope-resolve-spike.rkt
```

Result: `7 tests passed`.

The properties establish:

1. Two scopes with the same debug kind remain different identities; flipping
   one scope twice is an involution.
2. A macro-introduced `tmp` binding is inapplicable to an antiquoted use-site
   `tmp` because its introduction scope is absent from the occurrence.
3. A call-site `tmp` binding is inapplicable to a generated `tmp` occurrence
   because its use-site scope is absent from the occurrence.
4. Nested definition-context scope sets select root, outer, or inner binding by
   the largest applicable subset, independently of table insertion order.
5. Incomparable maximal candidates are ambiguous even when one candidate has
   more scopes. Cardinality is not the ordering relation.
6. Separately allocated, structurally equal qualified-name values resolve
   without rendering or reparsing.
7. A wrong structural name or a missing binding scope remains unbound.

## Exact seams for the real wave

1. **Shared syntax/name model.** Add `ScopeId`, `ScopeSet`, identifier-bearing
   `Syntax`, `BindingId`, `Binding`, resolution results, and the immutable
   binding table to the Racket oracle. Mirror the same value shapes in
   `beagle:self-host/src/selfhost/ast.bclj` or a dedicated syntax module. Reuse
   the W1--W4 qualified-reference fields as the qualified `StructuralName`; do
   not duplicate qualification as a rendered string or vector key.

2. **Reader-to-expander membrane.** Adapt
   `beagle:beagle-lib/private/parse.rkt:read-beagle-syntax*`, `->datum`,
   `stx-subs`, and `expand-fully/at-source` so code identifiers enter expansion
   as `SyntaxIdent` values. Preserve quoted symbols as datum. Mirror the
   membrane in `beagle:self-host/src/selfhost/reader.bclj`, whose symbols are
   currently plain strings inside raw tagged data.

3. **Macro invocation boundary.** Change
   `beagle:beagle-lib/private/macros.rkt:expand-macro`,
   `expand-template-macro`, and `expand-fully` to allocate one introduction
   scope, flip it on input, invoke the pure transformer, then flip it on output.
   Quasiquote creates syntax in the current introduction context; unquote and
   splice insert the original `Syntax` objects unchanged. Keep
   `expansion-ctx` and source-error provenance. Make the equivalent change in
   `beagle:self-host/src/selfhost/macros.bclj`.

4. **Retire name-based macro hygiene.** Remove the hygiene duties of
   `hygienize-template`, `transform-template/scoped`, binder gensyms,
   `hygiene-alias-for!`, and injected `__hyg` aliases in the Racket and
   self-host expanders. Split this from `fresh-lowered-sym`: compiler lowering
   temporaries may still need an output name, but they must no longer be the
   identity mechanism for macro bindings. Do not run the old renamer and scope
   resolver simultaneously.

5. **Binder scope allocation.** Thread a binding table and current scope set
   through the parser/elaborator. Allocate scopes at the existing binder seams:
   `parse-params`, `parse-let-bindings`, `parse-letfn-fns`,
   `parse-for-clauses`, `parse-pattern`, sequential/map destructuring, and the
   combiners for `fn`, `let`, `loop`, `with-open`, `for`, `doseq`, conditional
   bindings, `as->`, `catch`/`rescue`, and top-level definitions. `binding`
   rebinds an existing dynamic var and is not a fresh lexical binder. Preserve
   each form's visibility rule: sequential `let`/loop/for regions,
   mutually-recursive `letfn`, parameter/destructure body scope, and the
   pre-binding regions of constraints and RHS expressions. Mirror these seams
   at `parse-params!`, `parse-let-bindings!`, `parse-letfn-fns!`, and
   `parse-for-clauses!` in the self-host parser.

6. **Occurrence resolution before AST lowering.** Resolve every code
   identifier after macro expansion and binder scoping, then lower it to an
   occurrence-carrying AST reference with the selected `BindingId`. The native
   parser cannot attach this edge to today's bare interned symbols: its own
   source-location side-table already excludes symbols because one interned
   object represents many occurrences. Use an occurrence node, not a side
   table keyed by symbol identity.

7. **Checker environment cutover.** Replace name-only lexical lookup in
   `beagle:beagle-lib/private/check.rkt:reference-hash-ref` and the analogous
   self-host `reference-key`/`reference-map-ref` path with `BindingId` lookup
   for resolved locals. Retain structural-name/provider lookup for imports,
   stdlib entries, types, and genuinely unresolved globals. Providerless
   fallback must happen after lexical resolution and must not alter a binding
   table key in place.

8. **Checked projection and dependency edge.** Extend
   `beagle:beagle-lib/private/ast-json.rkt:reference-fields` and
   `expr->json/raw` with the lexical `bindingId`/`refersTo` edge while retaining
   `qualifier`, `name`, and `providerId`. Mirror the field in self-host checked
   AST maps. If the edge crosses compilation or cache boundaries, define a
   stable binding-ID scheme separately from ephemeral scope IDs.

9. **Output-only alpha rendering.** Emitters must render a binder occurrence
   and every reference with the same output name chosen by `BindingId`.
   Resolution identity must not be a suffix string, but erasing scopes while
   emitting two colliding authored spellings can reintroduce target-language
   capture. Add a binding-ID-to-output-name map at the Clojure, JavaScript,
   Nix, and Native Core rendering boundaries; preserve authored spelling when
   no collision requires a target-only alpha name. Apply the same rule in the
   self-host emitters.

10. **Store/graph projection.** W4 already stores qualified symbols as separate
    `qualifier` and `name` facts and writes `refers_to`/`bound_to` definition
    edges in `beagle:branch-core/src/resolve_mint.bclj` and
    `resolve_walk.bclj`. Native ingest already preserves those fields in
    `beagle:branch-core/src/fram/code_reader.clj`. Teach the checked-AST/fact
    ingest to preserve the compiler-selected `BindingId` edge; do not make
    branch-core reconstruct lexical hygiene from rendered names or reuse its
    current stack walk as the compiler resolver.

11. **Parity and removal gates.** Remint `self-host/seed/selfhost/*` only from
    canonical `.bclj` sources. Run the ordinary oracle/self-host parity gate
    after the focused scope and macro tests. The real wave's removal search
    must prove that macro-identity uses of gensym/`__hyg` are gone while
    deliberate output-only lowering temporaries remain explicitly classified.

## Hazards

- **Provider identity is not lexical identity.** A parsed qualified reference
  begins with `providerId = #f` and the checker may construct a new value with
  canonical provider identity. Mutating or replacing that value after using it
  as a binding-table key would break lookup. Use an immutable authored name at
  the lexical phase and attach provider and binding edges separately.
- **Scope serials are not stable IDs.** The spike serial is only debug output.
  A real allocator must be compilation-local; allocation order, parallelism,
  or a restarted process must not change serialized binding identity or cache
  keys.
- **Erasure can reintroduce capture.** Correct resolve edges are insufficient
  if emitters print every colliding binder as the same target identifier. The
  alpha-render seam is mandatory even though renaming is forbidden as semantic
  identity.
- **Binder visibility is form-specific.** Treating all binding vectors alike
  will incorrectly expose a binder in its own RHS/constraint, break sequential
  scopes, or lose `letfn` mutual recursion. Destructuring produces multiple
  bindings under one aggregate operation and must install all projected names
  in the correct region.
- **Definition contexts are more than nesting.** The spike proves nested
  subset selection, not Racket's mutable internal-definition API, use-site
  bookkeeping, lifting, or splicing. Keep those out until a concrete Beagle
  internal-definition case requires them.
- **Ambiguity is a partial-order result.** Never rank by set cardinality or
  insertion order. Equal `(name, scope-set)` entries are duplicate bindings;
  incomparable maxima are an error with all candidate binding IDs retained.
- **Quoted data must remain inert.** Applying scope propagation beneath quote
  turns data symbols into code identifiers. Quasiquote must distinguish newly
  introduced syntax from exact unquoted syntax objects.
- **Old and new hygiene cannot overlap.** Gensym renaming, free-reference alias
  injection, scope flipping, and output alpha naming have different jobs. A
  mixed transition can double-rename binders, capture imported free refs, or
  make diagnostics show lowering names.
- **Do not grow module/phase machinery.** W5 needs one lexical phase. Imports
  keep the W1--W4 structural provider path; module scopes, phase towers,
  inspectors, serialization, and Racket compatibility APIs are outside the
  seam.
- **Naive candidate scan is acceptable initially.** The spike scans the bucket
  for one structural name. Indexing tables onto the newest scope and caching
  resolution are optimizations that also introduce invalidation hazards; add
  them only after measurement.

## Recommendation

Keep the spike's resolver relation and result algebra essentially unchanged.
The real work is the syntax membrane, binder-region threading, occurrence
nodes, and output-only alpha rendering. Reusing the W1--W4 structural name as
the resolver key is clean; trying to graft scopes onto the already-lowered
qualified-ref AST node is not.

W5-SPIKE-SCOPES-FINDINGS-DONE
