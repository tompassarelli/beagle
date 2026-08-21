# Prior-art steal sheet: Lean 4 for Beagle W5

> License and source notice: this is original analysis, not copied Lean code.
> Lean 4 source examined at `lean4` commit `7778d709df` is copyright its
> contributors and released under the Apache License, Version 2.0; see
> `lean4:LICENSE`.  Preserve that license and required notices if any Lean
> implementation text is ever copied.  This sheet proposes independent Beagle
> designs.

## Bottom line

Lean's high-value lesson is to make syntax a first-class, typed data boundary,
give every macro invocation a fresh hygienic identity, compile syntax patterns
into ordinary code, and record expansion-time dependencies at the expansion
boundary.  Its low-value-for-Beagle lesson is its name-encoded scope transport
and its proof-kernel/elaborator entanglement.

The planned W5 order is sound: syntax objects -> scope-set hygiene ->
syntax-match -> expansion dependency tracking -> static reflection.  Do not
make type lookup an ordinary macro operation.  In Lean, ordinary `macro`
functions run in `MacroM`, which deliberately has no direct environment/type access;
type-sensitive extensions are elaborators.  Beagle should keep that phase
boundary while exposing a smaller, explicit reflection capability later.

## What Lean actually implements

### Syntax representation and parser categories

`Lean.Syntax` is not a generic S-expression.  The core declaration is in
`lean4:src/Init/Prelude.lean`:

- `Syntax.missing` represents a recovered parse error.
- `Syntax.node info kind args` is a tagged, variadic tree.  `kind` is a
  `Name` (`SyntaxNodeKind`) and `args` is an array of syntax.
- `Syntax.atom info val` stores punctuation, keywords, and literals.
- `Syntax.ident info rawVal val preresolved` keeps the original substring, the
  structural `Name` (including hygiene), and quotation-time global/namespace
  candidates (`Syntax.Preresolved`).
- `SourceInfo` distinguishes original source text, synthetic spans (with a
  `canonical` flag for editor/error attribution), and no location.  Helpers,
  structural comparisons, traversal, and quotation/antiquotation recognition
  live in `lean4:src/Lean/Syntax.lean`.

The parser is extensible rather than a fixed grammar.  `ParserDescr` compiles
to parser functions in `lean4:src/Lean/Parser/Extension.lean`; adding syntax
updates a scoped environment extension containing token tables, node kinds,
categories, and parsers.  Each category has leading/trailing Pratt tables
(`lean4:src/Lean/Parser/Basic.lean`).  `leadingNode` checks its minimum
precedence and sets `lhsPrec`; `trailingNode` additionally checks the left
precedence.  `categoryParser` carries the requested precedence into the
category's Pratt parser.  Thus a notation declaration supplies both its tree
kind and exact parsing/associativity behavior, not merely a textual rewrite.

This is why `syntax`, `macro`, and `macro_rules` are inline notation extension:

1. `syntax` elaboration creates a named parser/node kind and registers it in
   the active parser environment (`lean4:src/Lean/Elab/Syntax.lean`,
   `lean4:src/Lean/Parser/Extension.lean`).
2. `macro` first elaborates its syntax declaration, turns its arguments into a
   quotation pattern, then emits a `macro_rules` declaration
   (`lean4:src/Lean/Elab/Macro.lean`,
   `lean4:src/Lean/Elab/MacroArgUtil.lean`).
3. `macro_rules` validates that every quoted pattern has the declared node
   kind, compiles the alternatives into an auxiliary `Syntax -> MacroM Syntax`
   definition, then registers it under the `macro` keyed attribute
   (`lean4:src/Lean/Elab/MacroRules.lean`).
4. `notation` is sugar for exactly that pair: make parser syntax, construct a
   quoted macro pattern, install macro rules, and optionally derive an
   unexpander (`lean4:src/Lean/Elab/Notation.lean`).

### Macro scopes and hygiene

Lean's hygiene is implemented as scope-bearing *names*, not as a separate
syntax-object field.  `MacroScope` is a monotonically allocated natural number
in `lean4:src/Init/Prelude.lean`.  A scope is appended to every identifier
introduced by a quotation in the macro invocation.  `MacroScopesView`,
`extractMacroScopes`, and `addMacroScope` serialize the original name, an
imported-context chain, unique quotation context, and scope list into a `Name`
containing `_@` and `_hyg` components.  Imported macro output retains its old
context as an imported component before receiving the caller's scope.

The allocation/control points are concrete:

- `Lean.CoreM.State.nextMacroScope` and `Core.withFreshMacroScope` assign a
  scope for elaborator work (`lean4:src/Lean/CoreM.lean`).
- `Macro.State.macroScope` and `Macro.withFreshMacroScope` do the equivalent
  for ordinary macros (`lean4:src/Init/Prelude.lean`).
- `expandMacroImpl?` fetches expanders by syntax kind and invokes each selected
  one under `withFreshMacroScope`; an `unsupportedSyntax` exception selects the
  next rule (`lean4:src/Lean/Elab/Util.lean`).
- Quotation code adds the current scope to non-antiquoted identifiers, while
  antiquoted syntax is inserted unchanged.  The elaborator also resolves and
  stores global constants, section variables, and namespaces at quotation
  definition time as `preresolved` alternatives
  (`lean4:src/Lean/Elab/Quotation.lean`).

The result prevents an identifier invented by a macro from accidentally
resolving to, or being captured by, an identifier at a use site.  It is not a
general set-of-scopes algorithm: equivalence is the encoded context plus an
ordered scope list (`MacroScopesView.equalScope` in
`lean4:src/Lean/Elab/Util.lean`).  Lean intentionally offers escape hatches
such as `Unhygienic.run` and a `hygiene` option for infrastructure that must
manufacture surface syntax.

### Quotations, antiquotations, and syntax matching

Parser support recognizes quotation node kinds ending in `quot`, ordinary
antiquotation, escaped antiquotation (`$$x`), token antiquotation, and
optional/many/separator splices.  The data constructors and classifiers are in
`lean4:src/Lean/Syntax.lean`; parser combinators that create them are in
`lean4:src/Lean/Parser/Basic.lean`.

`lean4:src/Lean/Elab/Quotation.lean` elaborates a quotation into code that
constructs `Syntax` at runtime.  It gives introduced tokens synthetic source
information, applies the invocation scope to introduced identifiers, preserves
antiquoted syntax verbatim, and builds arrays efficiently for splices.  A
quotation is therefore an effectful value over `MonadQuotation`: it obtains the
current macro scope and source reference at execution, rather than baking
freshness into the compiler's own quotation.

`match` syntax patterns are compiled, not interpreted.  The same file lowers
quoted patterns into a decision tree over node kind, arity, literal/identifier
identity, and splice shape; it binds antiquotations as typed `TSyntax` wrappers
and emits ordinary `match`/conditional code.  Its precheck hook
(`lean4:src/Lean/Elab/Quotation/Precheck.lean`) recursively unfolds ordinary
macros to report unbound identifiers in a quotation early.  It explicitly
warns that type-sensitive syntax needs its own precheck support.

### Macro expansion versus elaboration (and where types are queried)

At every term and command node, Lean tries macro expansion first, then
dispatches to an elaborator only when no macro applies:

- `Term.elabTermAux` in `lean4:src/Lean/Elab/Term/TermElabM.lean` expands the
  root, records a macro-expansion info/diagnostic stack, and recursively
  elaborates the expansion with the expected type.
- `Command.elabCommand` in `lean4:src/Lean/Elab/Command.lean` does the same
  for commands.  The frontend parses one command using the environment made by
  preceding commands, then elaborates it (`lean4:src/Lean/Elab/Frontend.lean`).
- `Term.adaptExpander`, `Command.adaptExpander`, and `Tactic.adaptExpander`
  turn an elaborator-monad syntax transformation into a normal elaborator and
  preserve expansion provenance.

So ordinary macros may resolve names and test declaration existence through
the narrow `Macro.Methods` bridge, but they cannot inspect local types or infer
terms.  A type-sensitive extension is an elaborator running in `TermElabM`/
`MetaM`: it may call `elabTerm` on a child, inspect its inferred type, then
return an expression or expand further syntax.  This is the actual
macro/elaborator interleaving; it is not "macros query types."  Each expansion
also leaves `before`/`after` syntax in `MacroStack` and the editor information
tree (`lean4:src/Lean/Elab/Util.lean`,
`lean4:src/Lean/Elab/Term/TermElabM.lean`).

### Dependency tracking and self-hosting bootstrap

`Macro.State.expandedMacroDecls` records non-builtin macro declarations used
during expansion.  `liftMacroM` drains that list and calls
`recordExtraModUseFromDecl (isMeta := true)`
(`lean4:src/Lean/Elab/Util.lean`).  Commands additionally traverse the final
syntax tree and record used non-builtin syntax kinds
(`lean4:src/Lean/Elab/Command.lean`).  `ExtraModUses` turns a declaration into
the defining module plus any indirect module uses, preserving meta/public
status for `shake` (`lean4:src/Lean/ExtraModUses.lean`).  This catches an
important non-AST dependency: a module can need an import because its source
was expanded by a macro or parser registered there, even if no resulting core
term mentions that declaration.

The bootstrap is real generated source, not just a build flag.  The checked-in
`lean4:stage0/stdlib/Init/Prelude.c` contains the exported hygiene machinery,
and `lean4:stage0/stdlib/Lean/Elab/Quotation.c` contains quotation expansion.
`lean4:CMakeLists.txt` builds the archived `stage0/src` compiler, uses it to
compile current Lean sources into stage1, then stages 2/3 with the prior stage.
`lean4:doc/dev/bootstrap.md` explains the fixed-point reason and the
`update-stage0` regeneration path.  The quotation implementation is expressly
self-stabilizing: it can be initially compiled unhygienically and becomes
hygienic after recompilation (`lean4:src/Lean/Elab/Quotation.lean`).

## Steal for Beagle W5

| W5 step | Steal the invariant | Concrete Beagle shape |
| --- | --- | --- |
| Syntax objects | Make source syntax a tagged value with provenance, never a naked reader datum once it enters the macro API.  Keep error recovery explicit. | `Syntax = Missing span diagnostics | Atom token span | Ident {name : StructuralName, scopes : ScopeSet, span, origin} | List {delimiter, children, span, origin} | Vector ... | Map ... | Set ...`.  Keep current raw datum macros behind an adapter during migration; `syntax->datum` is explicit and lossy. |
| Scope-set hygiene | Allocate one fresh introduction scope per expansion; antiquoted input keeps its scopes; only introduced identifiers receive the scope.  Bind/reference resolution must see scope sets, not pretty names. | `ScopeId {module-id, expansion-id}` and immutable `ScopeSet`.  `(syntax-quote (let [tmp ~expr] tmp))` adds `intro` to both introduced `tmp`s; `~expr` is byte-for-byte the caller's syntax object.  Resolve by structural name plus the binding's applicable scope set.  Persist stable IDs derived from module content + expansion path, not an ambient counter, if reproducible artifacts need it. |
| `syntax-match` | Compile quotation-like patterns into structural tests, preserve match order, bind syntax objects rather than strings, and support explicit splice semantics. | `(syntax-match stx [(foo $x:expr) ...] [(let [$name:id $value:expr] $body:expr) ...] [_ ...])`.  Compile into tag/delimiter/arity tests and bindings `x : Syntax`; use `...$xs` only where a list/vector sequence is permitted.  Add source-pointed errors for invalid pattern category/splice placement. |
| Expansion dependency tracking | Record *the macro definition and reflection queries actually used* at the expansion boundary, not by scanning only the output. | `expand-one : MacroId × Syntax × MacroContext -> Expansion {syntax, macro-deps, reflection-deps, provenance}`.  The module builder unions stable `MacroId`/module IDs into its interface/dependency manifest before cache lookup.  Record parser/syntax-category providers too if W5 introduces them. |
| Static reflection | Give type-aware reflection a distinct capability and phase.  Every lookup must be deterministic, tracked, and constrained to the current module graph. | `ElabMacroContext` (not ordinary `MacroContext`) exposes `resolve`, `type-of-syntax`, `lookup-def`, and `members-of` returning immutable reflection records with defining-module IDs.  It may elaborate a child against an expected type; the API records both the consulted definition and the compiler-interface version.  Ordinary `defmacro` continues to receive no type environment. |

Two Beagle-specific consequences follow from W1--W4's structural names and
the current self-host code:

- Do not encode scopes by printing suffixes such as `x__17`.  `StructuralName`
  already separates identity from spelling; attach scopes beside it and retain
  a human-facing display name for diagnostics.  The existing
  `selfhost.macros/fresh-lowered-sym!` remains a lowering-name mechanism until
  W5 replaces the macro-facing path, not hygiene itself.
- Current `beagle:self-host/src/selfhost/macros.bclj` evaluates `defmacro`
  bodies over raw reader data, has quasiquote/unquote, and already rejects the
  former unsafe template route because output is type-checked.  Preserve that
  output checker.  Move the evaluator's inputs/outputs to `Syntax` in a
  compatibility slice; do not silently reinterpret strings as identifiers in
  the old macro API.

## Do not copy

- **Do not copy Lean's `_@ ... _hyg` name encoding.** It solves cross-module
  transport where names are the identity carrier.  Beagle's structural-name
  work makes an explicit `ScopeSet` field clearer, inspectable, serializable,
  and less vulnerable to string/name reconstruction bugs.
- **Do not copy the Pratt parser/inline precedence system as W5's core.** It is
  essential for Lean's mixfix surface; Beagle is Clojure-shaped Lisp.  W5 needs
  delimiter-aware structural patterns, not user-defined infix precedence.  Add
  parser categories only when a demonstrated Beagle surface needs them.
- **Do not copy quotation-time global `preresolved` overload sets wholesale.**
  Lean needs namespace/open-declaration overload resolution.  Beagle should
  start with exact structural resolution plus an explicit reflection result;
  importing Lean's ambiguous-name machinery would obscure W1--W4's gains.
- **Do not let regular macros call the full type checker.** Lean separates
  `MacroM` from `TermElabM` for phase/order/error reasons.  A Beagle macro that
  sees mutable inference state would be cache-hostile, order-dependent, and
  impossible to dependency-track precisely.  Use the later elaborator-macro
  capability.
- **Do not copy theorem-prover machinery.** Metavariables, unification,
  reducibility/transparency modes, tactic goals, and proof-term info trees are
  load-bearing for Lean's dependent type theory, not for typed Clojure macros.
  Take only the small provenance record: original syntax, expansion syntax,
  macro ID, and source span.
- **Do not copy Lean's environment-extension/attribute registration model
  blindly.** It permits rich plugin ecosystems but hides effects in mutable
  compiler state.  Beagle should use immutable, content-addressed registries
  whose additions are direct dependency-manifest entries.
- **Do not make syntax matching a giant general matcher first.** Lean's
  `match (syntax)` compiler is sophisticated because it supports grammar
  categories, ambiguity, tokens, and splice variants.  Beagle should ship the
  list/vector/map cases W5 needs, with exhaustive/error behavior decided
  deliberately, before optimization or pattern compilation complexity.

## Three first experiments

1. **Syntax quotation boundary.** Add an internal `Syntax` ADT and adapter at
   the self-host macro call boundary.  Implement only list, vector, atom, and
   identifier quotation/antiquotation.  Acceptance: an existing `defmacro`
   fixture returns `Syntax`, the current template-output checker still accepts
   its expansion, and exact caller spans survive an antiquoted child.

2. **One fresh scope, one capture proof.** Implement immutable `ScopeId` and
   `ScopeSet`, then a tiny binding macro that introduces `tmp` around a caller
   expression.  Acceptance: caller `tmp` remains reachable through the
   antiquoted expression, while the macro's binder/reference resolve together
   and cannot capture either a caller `tmp` or a nested invocation's `tmp`.
   Inspect identity structurally; do not assert only on printed suffixes.

3. **Pattern-and-dependency vertical slice.** Implement a small
   `syntax-match` pattern (`(when $test $body...)`) that expands through the
   syntax-object path.  Emit `Expansion` provenance containing the macro's
   stable ID and write it into the module dependency manifest.  Add one
   elaborator-only `type-of-syntax` probe behind an explicit capability and
   assert that its consulted definition/interface ID is recorded.  This proves
   the phase boundary and cache contract before broad reflection is exposed.

## Evidence

Read directly from Lean source, not manuals: `lean4:src/Init/Prelude.lean`,
`lean4:src/Lean/Syntax.lean`, `lean4:src/Lean/Parser/Basic.lean`,
`lean4:src/Lean/Parser/Extension.lean`, `lean4:src/Lean/Elab/Syntax.lean`,
`lean4:src/Lean/Elab/Macro.lean`, `lean4:src/Lean/Elab/MacroArgUtil.lean`,
`lean4:src/Lean/Elab/MacroRules.lean`, `lean4:src/Lean/Elab/Notation.lean`,
`lean4:src/Lean/Elab/Quotation.lean`,
`lean4:src/Lean/Elab/Quotation/Util.lean`,
`lean4:src/Lean/Elab/Quotation/Precheck.lean`,
`lean4:src/Lean/Elab/Util.lean`, `lean4:src/Lean/Elab/Command.lean`,
`lean4:src/Lean/Elab/Frontend.lean`,
`lean4:src/Lean/Elab/Term/TermElabM.lean`,
`lean4:src/Lean/ExtraModUses.lean`, and the generated bootstrap artifacts
`lean4:stage0/stdlib/Init/Prelude.c` and
`lean4:stage0/stdlib/Lean/Elab/Quotation.c`, plus `lean4:CMakeLists.txt` and
`lean4:doc/dev/bootstrap.md`.  Beagle's current macro boundary
was checked at `beagle:self-host/src/selfhost/macros.bclj`.

PRIOR-LEAN-DONE
