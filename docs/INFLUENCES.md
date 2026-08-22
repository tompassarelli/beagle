# Influences

Beagle is a durable programming system moving its native boundary toward
proposition-first semantics. Its current Clojure-derived, JavaScript, and Nix
profiles prove that one checked representation can produce useful artifacts
for sharply different target regimes; those profiles remain explicit current
surfaces without defining Beagle's native ontology. None of Beagle's
*ingredients* are new — typed relational languages exist, Lean's error
machinery exists, and durable stores exist. What makes Beagle a thing is what
those ingredients are pointed at:

> **The compiler is a feedback engine for an agent, not a translator for a
> human.** Most languages' errors are designed for a person to read and act on.
> Beagle's are designed for a *program* to act on — structured, located,
> canonicalization-aware diagnostics and machine-applicable fixes that re-verify.

Everything below earns its seat by serving that thesis and the compounding
compiler-development feedback loop it enables.

The deeper bet is the Turtles Thesis:

> Pure software artifacts are reproducible projections of sealed semantic
> ModelRevisions; external reality is connected through explicit observations and
> capability-controlled effects.

A Model is the stable semantic program. A sealed ModelRevision is one immutable
coherent semantic admission, not a Store branch, universal key, or physical or
security domain. One durable identity, explanation, dependency, and provenance
model relates distinct Model, ModelRevision, BranchRevision, content,
assertion, rule, plan, and artifact identities; content identity is not trust.
`Declared`, `Derived`, and `Observed` are epistemic origins, while
`Intent`, `Authorization`, `Attempt`, and `EffectReceipt` form a separate
action protocol. Pure plans and artifacts can be derived from durable semantic
ModelRevisions; an external effect requires a capability and yields a
receipt plus later observations. External reality thereby participates in the
same typed fact system without being assumed pure. Target outputs are
replaceable materializations with explicit capability envelopes.

## Lean — diagnostics, as a discipline

Lean 4 treats error reporting as a first-class subsystem, not an afterthought.
We stole the mechanisms, not the type theory (Beagle is not dependently typed):

- **Structured messages (MessageData).** Diagnostics carry typed, structured
  payloads (`expected-type`/`actual-type`, missing union cases, …), not just
  prose — so a consumer acts on data instead of re-parsing English.
- **Source-position fidelity.** Origin/canonical position model with precise
  columns, so a fix lands on the exact span after we know *which*
  canonicalization ran.
- **`#guard_msgs`-style inline diagnostic tests.** Expected-error assertions
  live next to the code and update mechanically — diagnostics are regression-
  tested like any other output.
- **Macro hygiene.** Definition-site free-variable resolution; call-site blame
  that degrades gracefully.
- **Types-as-view via a delaborator.** The type shown in an error is a *pure
  view* rendered from the type, storing nothing — zero drift by construction,
  the way Lean renders terms. (`explain-type`.)

*Why it matters here:* the authoring loop is only as good as the precision of what
it repairs. Lean is the proof that this precision is achievable and worth the
engineering.

*Provenance:* Lean 4 primary-source audit.

## Racket's expander — syntax-manipulating-syntax

Racket makes hygiene a property of syntax objects, not a naming convention:
each identifier carries a set of opaque scopes, and resolution chooses the
most specific applicable binding. A macro expansion gets one fresh
introduction scope; caller syntax keeps its scopes. Beagle is adopting that
small kernel, with immutable syntax, source spans, and expansion provenance as
the API for syntax-manipulating-syntax.

- **Take:** scope sets beside structural names, one fresh scope per expansion,
  the same binder primitive for macros and ordinary binders, and exact child
  provenance through quotation and unquotation.
- **Refuse:** Racket's phase tower, module-scope machinery, inspectors,
  certificates, and legacy surface. Beagle has one explicit lexical
  phase and needs dependency records, not ambient expansion authority.
- *Why it matters here:* syntax, binding, expansion, and diagnostic facts can
  become queryable store facts, so an agent can repair structure without
  guessing from printed names.

*Provenance:* Racket expander primary-source audit; scope-set adoption is
bounded to the Beagle macro boundary.

## Koka — effect rows and evidence, with a two-regime memory model

Koka shows the value of effect rows that remain open until constraints close
them, then lower checked operations through explicit evidence. Its Perceus
pass also makes ownership and reuse measurable rather than magical.

- **Take:** retain checked effect requirements through lowering and pass only a
  private, transient handler context; use precise liveness/reuse analysis for
  bounded native values that escape an arena epoch.
- **Refuse:** universal reference counting, Koka's effect-row syntax and
  resumptive runtime, and any reuse token crossing an arena or store boundary.
  Beagle's arenas reclaim bounded evaluation graphs; Beagle Store owns
  durable reachability. A second persistence graph would blur that proof.
- *Why it matters here:* effect evidence makes execution authority explicit,
  while the deliberate arena/store split keeps language memory and durable
  state in one thesis without pretending they have one lifetime.

*Provenance:* Koka effect-evidence and Perceus primary-source audit; the
two-regime arena/store boundary is the controlling Beagle constraint.

## Kernel (John Shutt) — one combiner rule

Kernel unifies macros and special forms under a single idea: *operatives* —
head-tagged combiners that receive their operands and dispatch by one rule.
Beagle takes that uniformity and makes one deliberate amputation:

- **No runtime fexprs.** True Kernel operatives receive *unevaluated* operands
  plus the live environment at runtime. Beagle emits Nix (and JS, Clojure, …) —
  targets with no runtime `eval` or reified environment. Runtime fexprs are
  therefore impossible, by construction, not by choice.
- **Operatives at compile time.** The achievable, correct realization: resolve
  combiners at compile time. One registry where every head — built-in
  (`let`/`if`/`match`/…) and user macro alike — is dispatched by one resolver
  and lowered to the *same typed IR* before any backend runs. A compile-time
  operative *is* a unified macro/special-form.
- **Naming discipline.** We call these **compile-time combiners**, not
  "operatives." The word "operative" implies runtime fexprs and cost months of
  confusion: the name suggests runtime evaluation, while Beagle's combiners
  are resolved before target code runs.

*Why it matters here:* one dispatch rule → one IR means the *entire* surface is
uniformly analyzable and repairable. Two checkers and a bolted-on macro path
cannot be reasoned about as one thing — which is exactly why the phantom was
killed.

*Provenance:* Kernel combiner and compile-time-unification primary-source
audit.

## ML family — type semantics, not ML's grammar

Beagle's type discipline is ML-lineage in *semantics*, deliberately not in
*surface*: algebraic data types, exhaustiveness checking over their cases,
explicit and bounded polymorphism, variance, and heterogeneous positional
types (`HVec`) all read as "what would a Hindley-Milner-family checker
enforce here" — realized as `defrecord`/`match`/`forall (T <: Bound)` inside
Clojure's own grammar, never ML's `let ... in`/`match ... with` concrete
syntax. Two amputations are deliberate, not oversights:

- **No ML grammar.** The borrowing stops at what the checker *proves*, not
  what the source *looks like* — see "The Lisp/Clojure/EDN surface" below for
  why the authoring medium stays s-expressions.
- **No claim to full Hindley-Milner.** Beagle uses structural boundary
  declarations (`(binding-form Type [constraint])`) and mandatory positional
  return types, plus definition-local inference with bounded SCC
  generalization. It does not claim principal-type global inference or the rest
  of HM's machinery. "ADTs and exhaustiveness" is a much smaller, honestly
  scoped debt than "we implemented ML."

*Why it matters here:* exhaustiveness and bounded polymorphism are exactly
the failures the authoring loop is best at — a missing match arm or a bound
violation is structured, located, and machine-fixable in a way an untyped
runtime error never is.

## Unison — content identity as the nearest store cousin

Unison is the nearest cousin of the store thesis: definitions are validated
content identities, names and branch heads are routing metadata, and the
codebase is a database rather than an authoritative directory of files.

- **Take:** versioned semantic identity for durable definitions, validated
  transfer before insertion, and rename/refactor as metadata changes over
  stable referents. Keep exact source bytes separately as provenance.
- **Refuse:** making the content-addressed codebase and its dedicated tooling
  the only authoring surface, treating a bare hash as proof of presence or
  authority, or assuming identity alone resolves concurrent intent. Ordinary
  files, editors, review, and explicit receipts must remain usable outside the
  store.
- *Why it matters here:* Beagle Store can be the durable semantic heap
  without becoming an opaque repository. Immutable definitions, source
  revisions, materializations, and promotion receipts can be related without
  confusing any one of them for the others.

*Provenance:* Unison content-addressing, codebase, and transfer primary-source
audit; the turtles thesis supplies the store/source boundary.

## Smalltalk — the image before files

Smalltalk's image is the 45-year ancestor of unifying language, memory, and
persistence. It got liveness, inspectability, and identity replacement right:
the world stayed alive while code and objects changed, and tools saw the same
world the program inhabited.

- **Take:** durable semantic liveness, public inspection of state and history,
  and explicit identity evolution that lets a running world continue.
- **Refuse:** the opaque binary image as repository, merge base, or sole
  authority. It loses reproducibility, external review, ordinary VCS merges,
  and tool interoperability; source export then creates split-brain authority.
- *Why it matters here:* Beagle Store reclaims the image's continuity as
  typed, queryable facts, while exact source projections and receipts preserve
  mergeability, restartability, and evidence without requiring one VM-shaped
  world to remain alive.

*Provenance:* Smalltalk image and source-bridge primary-source audit; the
  store/source distinction is an explicit design constraint, not an image
  revival.

## Erlang/OTP — live upgrade on trust, promotion by receipt

OTP proves that a running system can carry two code versions, migrate state,
supervise failure domains, and move work across a controlled boundary. Its
upgrade plan is trusted: a successful load, callback, purge, or restart reports
that the protocol ran, not that the new engine is semantically equivalent.

- **Take:** explicit two-version discipline, supervision as a failure-domain
  graph, bounded migration callbacks, named barriers, and receipts that retain
  the failed phase while the incumbent stays visible.
- **Refuse:** mixed generations as the default, brutal purge as rollback, and
  operational success as semantic proof. Beagle requires shadow parity, an
  expected-head CAS at a tick boundary, and a checked migration before
  promotion.
- *Why it matters here:* OTP supplies the live-upgrade lineage; receipts turn
  “the system accepted the plan” into “this exact materialization was admitted
  against this exact state and head.”

*Provenance:* Erlang/OTP code-server, release-handler, and supervision
primary-source audit; Beagle's receipt requirement is the deliberate delta.

## Zig — comptime is the honest rival to macros

Zig's comptime treats compile-time computation as ordinary typed code, with
types as values, provenance, and dependency-aware analysis. Beagle agrees with
its no-hygiene-needed stance where computation returns values, types, or ASTs
without splicing caller binders.

- **Take:** one typed evaluator for compile-time work, canonical type values,
  dependency-recorded analysis units, and ordinary diagnostics for generated
  computation.
- **Refuse:** calling comptime a replacement for syntax extension. A function
  cannot add notation, change parsing, introduce a binding form, or preserve
  unresolved source shape. Those jobs require syntax-manipulating macros with
  scope sets; the evaluator should do their computation, not become a second
  macro language.
- *Why it matters here:* demand-driven compile-time facts make the compiler a
  feedback engine, while the macro boundary keeps notation and binding
  semantics explicit and repairable.

*Provenance:* Zig comptime and incremental-analysis primary-source audit;
  the macro/comptime boundary follows the Racket adoption above.

## Rust — aliasing discipline at the handoff seam only

Rust's strongest lesson here is local: shared observation and exclusive
mutation cannot coexist through the same access path. Beagle takes that
discipline only at the tick-boundary handoff: a sealed candidate and a
single-use expected-head publication right cross the seam, and one CAS wins.

- **Take:** check the representation that exposes the real transition—seal,
  expected-head CAS, durable observation, and next-tick publication—and reject
  stale or reused handoff authority.
- **Refuse:** a whole-language ownership regime, lifetimes, borrow checking,
  trait-solver derivation, or interior-mutability escape hatches. The two
  regimes already name the relevant lifetimes: arenas for bounded transients,
  the store for durable facts. General borrowing would expose physical storage
  choices in ordinary Beagle source without serving the thesis.
- *Why it matters here:* the handoff becomes an auditable capability boundary,
  not a claim that every Beagle value needs Rust's ownership vocabulary.

*Provenance:* Rust aliasing, MIR borrow-checking, and capability primary-source
audit; ownership is deliberately limited to the promotion seam.

## Datalog — recursive, stratified derivations, scoped to Beagle Store

Datalog contributes a narrow, specific borrowing: recursive and stratified
derivation over Beagle Store's triple graph — the way the store computes
transitive closures (callers-of-callers, blast radius, leverage) as a fixpoint
over the live base relations, not as hand-written recursive traversal code.

- **Scoped to the store's graph layer.** This answers relational questions
  such as "who calls this transitively," not a claim that Beagle's ordinary
  compiled programs execute as Datalog or that logic programming is a language
  feature.
- **Not ordinary computation.** A `.bclj` function body is still eager,
  typed, imperative-shaped Clojure-family code lowered to its target. The
  Datalog borrowing lives one layer up, in how the graph that *represents*
  the code answers queries about itself.

*Why it matters here:* the authoring loop's diagnoses ("this call site breaks
if you change that signature") are graph-shaped questions. Stratified
recursive derivation is the right tool for exactly that shape, without
smuggling logic-programming semantics into the compiled language itself.

## The Lisp/Clojure/EDN surface — the one small structural authoring medium

- **Clojure as the surface.** Beagle is "Clojure plus types, nothing else." Any
  divergence from Clojure must be load-bearing for the type system or a backend,
  or it gets removed. Boundary declarations are structural
  `(binding-form Type [constraint])` forms, executable returns occupy one
  mandatory positional slot, and definition-local interiors are inferred.
- **Static types erase before emit** (closer to Typed Racket's stance than to a
  type system that drives codegen). Type information checks at compile time and
  vanishes. An explicitly authored binding constraint is an ordinary predicate
  value rather than type metadata, so it deliberately emits one local runtime
  guard. The resulting Nix/JS/Clojure remains idiomatic for its host, never a
  typed-runtime artifact.
- **Parens as a machine-editable medium.** A fix is a tree splice, not a regex
  over free-form syntax. The s-expression surface is what makes auto-apply
  tractable.
- **Exact Clojure syntax is not inevitable; the typed EDN/Lisp *family* is
  what wins.** Nothing about the authoring loop requires parentheses spelled
  exactly Clojure's way — a different bracket convention or reader could carry
  the same property. What is load-bearing is the *family*: a small,
  homoiconic, structurally-editable EDN/Lisp medium, because that is what
  makes "the fix is a tree splice, not a regex" true. Clojure was the specific
  member of that family Beagle picked to start from; the family, not the
  specific grammar, is the thing the thesis depends on.

## The synthesis

The borrowings are not a remix — each is a means to the same end, and each is
scoped to a specific concern rather than an adopted surface or runtime:

| Borrowed from | Concern it supplies | Serves the authoring loop by… |
|---|---|---|
| Lean | diagnostics discipline | giving the loop something *precise* to repair |
| Kernel | combiner uniformity | making the whole surface analyzable as one thing → one IR |
| ML family | type semantics (ADTs, exhaustiveness, explicit/bounded polymorphism, variance, heterogeneous positional types) — not ML's grammar, no full-HM claim | generating diagnoses (types) that are structured and machine-fixable, without importing a second concrete syntax |
| Racket expander | scope-set hygiene and syntax provenance — not its phase tower | making syntax-manipulating repairs structural, capture-safe, and explainable |
| Koka | checked effect evidence and narrow liveness/reuse lowering — not universal RC | keeping execution authority explicit while preserving the arena/store split |
| Unison | content identity and validated transfer — not tooling isolation or a bare hash | making the store a durable semantic heap while source remains reviewable |
| Smalltalk | liveness, inspectability, and explicit identity evolution — not an opaque image | joining continuity to reproducible source and receipts |
| Erlang/OTP | two-version live upgrade and supervision — not trust as semantic proof | making promotion a receipted admission at a controlled boundary |
| Zig | typed comptime and dependency-aware analysis — not comptime as syntax extension | making compile-time work part of the feedback engine |
| Rust | local aliasing discipline at tick handoff — not whole-program ownership | making publication authority single-use and auditable |
| Datalog | recursive/stratified derivation inside Beagle Store's graph — not Beagle's ordinary computation | answering the graph-shaped questions ("what breaks if this changes") the authoring loop's diagnoses depend on |
| Lisp/Clojure/EDN | one small structural authoring surface — the family, not Clojure's exact grammar | making the medium itself machine-editable, so fixes are tree splices instead of textual guesses |

On top of that foundation sits the part with no upstream analogue: the
**auto-authoring loop** — `detect → diagnose → fix → re-verify` — where the
compiler enumerates missing match cases, emits clause skeletons, and applies
fixes that typecheck. That is Beagle's own frontier, not a steal.

## Current evidence and destination

The bet is that **one checked semantic Model with an authoring loop can target
many real ecosystems at once** — and that authoring against it beats writing
each target by hand. The breadth is not a distraction from the pitch; it *is*
the pitch. The current shared AST that lowers to lazy Nix attrsets, eager
Clojure maps, and JavaScript is evidence across different runtime models. The
native destination moves authority to sealed ModelRevisions and checked plans;
it does not claim that every target, executor, or Model-protocol connection has
shipped, or make a current hosted profile native precedent.

Current shipped evidence includes:

- **Nix** — firn, a complete NixOS system typed end-to-end against its
  16k-option schema. The target where the pain is most real (untyped,
  error-hostile) and writing it by hand is worst.
- **Clojure** — a different runtime model entirely (eager maps, JVM), driven by
  real `.bclj` code.
- **JavaScript** — gjoa, a Firefox overlay UI, 43 `.bjs` modules ported from
  TypeScript.

Each target that lands clean carries the thesis one ecosystem further. The
destination is a compounding compiler-development feedback loop in which, as
the repository and compiler scale, a one-function edit touches only true
dependents and agrees with sampled clean results. An unchanged cache hit alone
does not prove edit proportionality. The frontier is the *depth* of the
authoring loop, not the count of targets.

---

*The full development history is retained separately. This document is the
distilled lineage.*
