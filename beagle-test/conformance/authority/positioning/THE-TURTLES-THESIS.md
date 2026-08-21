# THE TURTLES THESIS — v2

## A manifesto for the substrate after files, builds, databases, deploys, and programs-as-text

The file is not the program. The build is not a phase. The database is not a
foreign country. Deployment is not permission to replace a running world. Text
is not semantic identity.

Those five separations look like laws of physics because the industry has spent
half a century building around them. They are historical interfaces. Beagle's
job is to make them optional.

Beagle is an independent typed Lisp built from a Clojure-derived core. It keeps
Clojure's vocabulary and structural authoring model where their semantics are
right, and names every divergence where they are not. That surface is the door,
not the thesis. The thesis is a substrate in which code, types, expansions,
durable state, compilation evidence, and promotion evidence are facts in one
provenanced store; native execution is a bounded materialization of those
facts; and a running materialization changes only through an admitted,
receipted transition.

This is not “an incremental compiler plus a database,” “hot reload with more
checks,” or “Smalltalk images with Git nearby.” Those designs preserve the old
boundaries and build bridges across them. The Turtles Thesis removes the need
for the bridges:

> The store is the heap for durable semantic state. Native Core manages bounded
> transient execution around it. Source is an exact, reviewable projection.
> Compilation is demand-driven fact derivation. Deployment is a compare-and-set
> over proven materializations. Programs are facts that can be queried without
> becoming ambient compiler state.

The century bet is the substrate, not the current syntax. Macro APIs can be
revised. Diagnostics can improve. Targets can come and go. The identity
constitution must become boring enough to ossify:

1. **Term identity** — a versioned, domain-separated `TermId` over fixed kind
   IDs and canonical recursive payload bytes. Equality, comparison, text
   encoding, and Float edge cases are part of the version. A new kind or
   equality law creates a new ID version plus explicit equivalence/migration
   facts; old bytes are never reinterpreted.
2. **Source and derivation identity** — `SourceRevisionId` names exact ordered
   authored bytes, paths, spans, and provenance. `DerivationId` names the
   ordered inputs, transformer materialization, interpretation/profile,
   authority, outputs, and byte-range/origin map that produced semantic facts.
   The relation is deliberately many source revisions to one semantic result.
3. **Definition identity** — a versioned hash of canonical typed facts,
   dependency identities, nominal seals, and checked effect/authority
   requirements. A rename or file move must not change it; a semantic
   dependency change must.
4. **Event and occurrence identity** — `EventId` commits to the exact parent
   history/event and canonical transaction frame; `OccurrenceId` is
   `(EventId, ordinal)`. `(SpaceId, sequence, ordinal)` is only a branch-local
   ordering coordinate and may collide across forks.
5. **History, routing, ref, and engine-head identity** — `RouteName` is mutable
   routing metadata; `HistoryRevisionId` is immutable logical history;
   `RefStateToken` is an opaque physical CAS token that may change on reseal;
   and `EngineHeadId` selects the visible admission commit. Promotion binds the
   logical old history and engine head while atomically comparing the ref token.
6. **Artifact, derivation, and compatibility identity** — `ArtifactId` names
   output bytes; `MaterializationDerivationId` commits to the definition closure,
   exact compiler artifact, backend/linker/sysroot/runtime closure, build
   options, policy, interface, target, ABI, obligations, and outputs;
   `RuntimeCompatibilityProfileId` commits to the CPU/OS/ABI and required host
   capabilities on which those bytes may run.
7. **Attestation and promotion identity** — freely assertable claims are not
   certified facts. Sealed attestations name issuer/verifier, verifier and policy
   versions, trust root, authority/lease epoch, and verified objects. A
   `ParityReceiptId` binds the exact candidate materialization closure. A
   prepared `PromotionCommitId` binds old engine head, candidate, exact state
   revision, journal cursor, tick, lease epoch, parity receipt, and policy; the
   visible head points to that commit after one fenced CAS. Success is durable
   reachability of the commit, never a circular `cas-result` inside its preimage.

No bare hash is enough. Canonical encodings and hash algorithms are versioned;
exact source provenance remains separately addressable; and knowing a hash does
not prove presence, authority, or admissibility. Receipt status has three axes:
**byte-integrity-valid**, **admissible under its recorded policy**, and **locally
replayable now**. A receipt commits to a closure manifest and archival
disposition. Online GC may evict bodies only after the proof pack is archived or
explicitly expired by a later auditable policy fact; replayability returns only
after fetch and revalidation.

### Truth ledger at synthesis time

“Landed” below means reachable from the clean published `main` of the owning
repository. “Commit-only” means real code and focused evidence exist, but the
artifact is not yet a product fact. This distinction is part of the doctrine.

| Artifact | State and evidence scope |
| --- | --- |
| Beagle v0.22.0 | **Landed and published.** Annotated tag `v0.22.0` names `4aaf833c1edd27f155fbb744dfbbfa8ba9f1b55d` and records the assertion that the serialized exact-commit non-publishing preflight passed before the tag (`EXEC-76`). The release includes coherent multi-module native builds, native/Wasm ABI work, compiler-owned semantic-unit reuse, exact-source provenance, and self-hosting machinery. The tag is stronger provenance than mutable prose, but this thesis does not link a full retained-output manifest. |
| Store Stage 2 | **Reachable on Beagle `main`; reported focused evidence only.** `a6b42feb` contains exact branch-ref CAS (`5909e9e0`), post-durable watch (`a5390b70`), reseal beyond 64 without logical revision drift (`13f4af44`), hosted/Native parity (`855da247`), and verified-root reachability GC (`1c5b2d09`). Reported counts are ref 49/49, fork 47/47, chain boot 15/15, parity 9/9, CAS 5/5, watch 5/5, reseal 13/13, GC 9/9. No immutable manifest currently binds command, exact tree/toolchain, exit, and retained stdout, so these counts are not independently replayable product receipts. |
| Store Stage 3 | **Reachable on Beagle `main`; focused Stage 3 evidence, not the acceptance receipt.** `7fa36f95` binds active native generations to store revisions. Reported focused evidence is revision visibility/restart 7/7, native ownership 5/5, generated obligations 10/10, ASan+UBSan clean, plus the recorded 512-epoch allocation comparison. The exact active-tier run produced no verdict and the required `slice-store` command exposed an incompatibility before compilation. The missing gate is one exact-commit supervised acceptance record with full command, input revision, exit status, test count, and retained output. |
| Structural facts W1-W2 | **Reachable on Beagle `main`; reported focused/full counts.** `283380e4` introduces structural qualified references; `ef018fbd` lowers once; `19f2ffc6` preserves qualifier, leaf, and provider identity in facts; the converter train ends at `f0ce4be7`. The exact-source repair is `a5e5c4ae`; 13/13 and 2406/2406 at `d51aab7a` are reported results, not independently replayable receipts until a complete manifest exists. |
| Structural facts W3-W4 | **Complete pending integration; still commit-only.** Self-host mirror `58ff3a7a` has reported remint oracle 48/48 and exact CI fixpoint 25/25. Store mint/burn-down `2f32791e` has reported store checks and code-as-facts rename 1/1, deletes the qualified-symbol scaffold, and has a zero-callsite grep guard (`EXEC-94`). Their integration lane is active; they do not become landed claims until one serialized full gate passes and main ancestry contains them. |
| Stage 4 journal + shadow engine | **Commit-only synthetic native-harness evidence.** Greywrought `a149cd96` adds an exact-order, revision-bound journal fixture (reported focused 4/4, 17 assertions); `26d3cf9` adds bounded read-only synthetic replay with effect-denying capability objects and matched/divergence formats (reported pure focused 1/1, 10 assertions). The history is freshly generated by the harness, not a retained authoritative production journal, and effect denial is not yet independently observed at the process/capability boundary. Landing plus the named real-history receipt remain required. |
| Stage 5 | **Comment-only wire harness reachable on Beagle `main`; semantic driver and proof absent.** `c5316ad1` accepts only `sourceEdit=comment-layout`, requires `semanticUnitsChanged=0`, and compiles `foundation` despite no affected semantic unit. Greywrought `dc0c3b7` is a commit-only scaffold with the same no-op story and placeholder hashes. This proves bounded wiring for a zero-semantic-cone case only; it is not evidence for semantic invalidation, affected-singleton cold compilation, admission, or live cutover. The next acceptance gate, **`STAGE-5-SEMANTIC-DRIVER`**, requires a landed driver with one declared semantic edit, a non-empty expected cone, unchanged identities for every unaffected unit, and a test that fails unless the cold-compiled singleton belongs to that cone; artifact #1 additionally awaits the real cutover, rejection, and current-state reverse-admission receipt. |
| Firn | **Product path landed; current system adoption is separately sequenced.** `nixos-config` `c7a7dc3c` advances the Beagle input with a reported zero-error validation. Firn authors `.bnix` as `#lang beagle/nix`, generates Nix projections, and builds commit snapshots; its native repository tools are themselves Beagle programs. This is one typed Lisp from system configuration to native tooling, not a claim that Nix ceased to exist as a target. |
| Live playable | **Running but degraded at synthesis time; not Stage 5.** A direct probe of Greywrought build `f8a4bd05` returned HTTP 200 with `state=ready`, durable revision 655, simulation frame/generation 148718, a valid lease, and bound checkpoint/terrain hashes. Reported focused evidence includes authority-host 71 tests, browser build, and native authority build. `EXEC-93` then recorded a production incident: all digs are rejected while investigation is active. These observations establish a real persistent world and establish that readiness is not semantic correctness; they do not establish interaction completeness or live promotion. |

Counts in this ledger are evidence claims at the scope explicitly printed in
their row. A count becomes an independently replayable receipt only when an
immutable manifest binds the commit, command, input/lockfile/compiler identities,
exit status, summary, and retained stdout digest/path. The v0.22.0 tag annotation
is the strongest present release assertion; the other rows await that manifest
rather than borrowing the word “receipt” from mutable coordination prose.

## I. THE FIVE DEAD BOUNDARIES

### 1. KILL THE FILE

#### The industry assumption it kills

A codebase is a directory tree. Paths and file contents are the authoritative
identity of definitions. Compilers rediscover structure by parsing that tree;
refactors rewrite text; tools infer provenance from whatever checkout happens
to be open.

The file earned this status because it is inspectable, diffable, mergeable,
copyable, and supported by every tool. Smalltalk proved the opposite extreme:
the live image gave liveness, inspectability, and identity surgery, but its
binary heap was a bad merge base, a bad clean-build input, and an isolated tool
world. Unison proved that definitions can instead have content identity, but
also showed the danger of making a bespoke codebase manager the only practical
authoring surface.

Beagle refuses the false choice. Files remain excellent authored projections
and Git remains an excellent collaboration protocol. Neither is semantic
identity.

#### What Beagle has already demolished

- The store kernel exposes `Term := Atom | Triple`; recursive structural terms
  are semantic values while integer handles, rows, hash slots, and index
  rotations are private mechanics (`beagle:branch-core/docs/architecture.md`).
- Stage 2 makes durable history operational rather than metaphorical: exact-head
  CAS chooses one winner, watch fires only after durability, reseal changes
  physical organization without changing the v2 revision, and GC walks verified
  named roots instead of a process pointer graph.
- W1-W2 parses a qualified reference once and carries qualifier, leaf, and
  provider identity through checking, emitters, catalogs, Native Core, JSON,
  and source facts. Commit `19f2ffc6` explicitly replaces a rendered compound
  symbol in facts with structure.
- Beagle's checked bundles preserve exact source bytes separately from semantic
  structure. The failure introduced at `138230d0` and repaired at `a5e5c4ae`
  matters: a store-first language that cannot reproduce the author's bytes has
  merely reinvented the image.
- Firn already treats `.nix` as a generated projection of `.bnix`; the sanctioned
  rebuild consumes a committed snapshot rather than ambient working-tree state.

#### What remains

W3-W4 must land so the self-host and store mint the same structural identity and
the last render-back accessor is absent. W7 must then define versioned semantic
definition/component hashes; keep exact source revisions orthogonal; make
names, aliases, packages, and branch heads routing facts; validate claimed
objects before insertion; and provide deterministic file import/export. The
store must never become an opaque authoring prison. A clean clone with ordinary
Git tools remains a required participant.

#### The falsifiable demo — `DEAD-FILE-GATE`

Import two differently laid-out source trees that denote the same typed
definition closure. Require one definition identity and two exact source
revisions. Rename and move the definition by changing routing facts only; the
definition and materialization hashes must remain fixed. Change a type, effect,
or dependency; the definition hash must change. Delete the projection, export
it again byte-for-byte, and reproduce the same checked bundle in a clean clone.
Then make independent edits in two clones and force either a normal Git merge
or a named source/fact conflict.

The bet fails if path or pretty name leaks into semantic identity, if two
semantic changes collide, if exact authored bytes cannot be recovered, if an
unknown/mismatched object can enter the store, or if collaboration requires
merging a binary heap.

### 2. KILL COMPILE/RUN

#### The industry assumption it kills

First source exists. Then a compiler runs. Then an artifact exists. Then a
runtime starts. Compile-time computation is a privileged side language or a
phase before the real program. Incrementality is a cache wrapped around that
phase.

The replacement is not “everything evaluates forever.” It is a graph of typed
facts and derivations. A definition, macro expansion, reflection result,
checked interface, lowered unit, and target artifact are analysis units with
explicit inputs. An edit invalidates its dependency cone. Evaluation happens
when a demanded fact is absent or stale. A build is only a receipt describing
which facts were demanded and which materializations were admitted.

#### What Beagle has already demolished

- v0.22.0 lands compiler-owned semantic units and deterministic reassembly.
  Whole-program compilation remains authoritative, but the compiler already
  knows a reusable unit is a semantic object, not a timestamped file fragment.
- The self-host pipeline treats Beagle compile-time bodies as program
  evaluation and checks their outputs end to end. W3's commit-only mirror has a
  byte fixpoint against the Racket oracle.
- Stage 3 binds a hydrated Native Core generation to named source, program, and
  state revisions and rejects mismatches before replacing the visible
  generation. Focused evidence exercises transient lifetime as part of the
  materialization boundary; the full Stage 3 acceptance receipt remains open.
- Stage 4's commit-only synthetic journal and shadow harness make the intended
  seam executable: a candidate can be evaluated read-only against a bounded
  fixture. They do not yet show replay of retained authoritative history or
  independent process-boundary effect denial.

#### What remains

W5 must make syntax objects and typed evaluator calls first-class analysis
units, record every macro/parser/reflection dependency at the point of use, and
feed those edges into semantic cone invalidation. Cached compile-time results
are forbidden until their complete dependency manifest is proven. W7 must
store the derivations and receipts so restart or another machine can explain
why an artifact is current without trusting an in-memory compiler environment.

#### The falsifiable demo — `NO-BUILD-PHASE-GATE`

Start from a fully receipted live engine. Make one semantic edit inside one
macro/reflection dependency cone and one unrelated source-only edit. Demand the
running program. The receipt must show exactly which syntax, expansion, type,
unit, and materialization facts invalidated; the unrelated units must retain
their identities; the affected singleton must cold-compile; and the incumbent
must continue serving until admission. Restart the compiler before demand and
obtain the same invalidation and artifact hashes from stored facts.

The bet fails if correctness requires a whole-tree build, if an undeclared
dependency changes output without invalidation, if unrelated edits churn
semantic artifacts, or if only an ambient compiler process can explain the
result.

### 3. KILL LANGUAGE/DATABASE

#### The industry assumption it kills

Programs have one type system and durable state has another. The language talks
to the database through strings, generated clients, serializers, ORMs, query
DSLs, migration scripts, and transaction callbacks. The impedance mismatch is
treated as employment rather than a design failure.

Beagle's claim is narrower than “all data is code.” Code and durable domain
state are different roles with different authorities. They can nevertheless be
values and facts in one typed information model. Queries are typed expressions.
Transactions are checked effects. Program definitions, domain propositions,
occurrence history, and promotion receipts remain distinguishable without
crossing an untyped foreign boundary.

#### What Beagle has already demolished

- branch-core's recursive Term grammar, typed source, canonical binary wire,
  branch-local assertion coordinates, withdrawal facts, Datalog projection,
  and explicit transaction order already put durable state behind typed
  semantic values rather than an object/row mapper. Fork-stable `EventId` and
  `OccurrenceId` remain W7 work; the present coordinate is not promoted into
  that claim.
- Stage 2 gives that model explicit concurrency, durability, compaction, and
  reachability semantics. A stale contender changes no bytes; a watch cannot
  run ahead of durability; malformed roots abort GC before deletion.
- Stage 3 ties store revisions to native allocation generations: a durable
  revision owns a materialized generation, mismatch destroys the candidate
  arena, and a genuine older-lifetime crossing remains an explicit promotion
  copy.
- Greywrought's live playable is a real Beagle-authored game authority backed by
  a durable store revision, not a database toy. Firn is the other end of the
  spectrum: the same language family authors system configuration and native
  repository tooling.

#### What remains

The store must admit program facts under the same canonical identity law as
domain facts without pretending they are the same relation. Checked query
result types, transaction effect rows, schema/profile identities, migrations,
and authority requirements must enter definition and bundle identity. Native
evidence objects must remain transient; no handler pointer, RC count, or arena
address may become durable identity. W7 must make reflection an ordinary typed
query over immutable program facts rather than a backdoor into compiler state.

#### The falsifiable demo — `ONE-TYPE-GATE`

Define one relation and query once. Use the same checked query in the authoring
tool, the native game authority, and store reflection. Prove one result type and
one canonical result digest. Attempt the transaction without its checked
authority and require rejection before durability. Change the relation's type
or transaction effect; require the definition identity, dependent queries,
bundle, and candidate engine to invalidate together while unrelated domain
facts retain identity. Promote only after replay parity.

The bet fails if any path reconstructs schema from strings, if a serializer can
silently change meaning, if an effectful transaction type-checks as pure, or if
program reflection and durable query use incompatible semantic models.

### 4. KILL THE DEPLOY

#### The industry assumption it kills

Deployment copies artifacts into a privileged place, restarts or redirects a
process, runs a migration callback, and asks monitoring whether the gamble was
acceptable. Rollback usually means selecting old code, not reversing state or
proving what continued to happen while the change was in flight.

OTP is the strongest old-world version: two module versions, supervised
quiescence, explicit upgrade plans, `code_change`, purge policy, and restart
escalation. It proves the protocol ran. It does not prove that the callback was
semantically right, every process was inventoried, external effects were
reversible, queued messages agreed, or a downgrade inverted the migration.

Beagle replaces deploy permission with admission evidence. A candidate is
immutable content. It must shadow the incumbent against bounded authoritative
history with external effects denied. Before a named tick boundary, the kernel
prepares an immutable `PromotionCommit` binding the logical history, exact
state/journal position, lease, policy, parity receipt, old engine head, and
candidate materialization. One fenced CAS over the whole expected tuple makes
the visible engine head point to that commit. A reseal-only `RefStateToken`
change is either refreshed after proving the same `HistoryRevisionId` or
reported as physical contention, never semantic staleness. Failure moves no
head, and a failed attempt receives a separate rejection ID.

#### What Beagle has already demolished

- v0.22.0 emits native command and Wasm engine materializations with bound ABI,
  capability, source, interface, and obligation evidence.
- Stage 2 provides the durable expected-head CAS and post-durable observation
  primitive. Stage 3 provides revision-bound native generations and explicit
  lifetime ownership.
- Stage 4's commit-only synthetic journal (`a149cd96`) records the intended
  order/tick, branch, actor capability, canonical input, consumed and committed
  revisions, nondeterminism, outputs, and result shape. Its synthetic shadow
  harness (`26d3cf9`) is read-only, bounded by `asOf`, and receives
  effect-denying network/persistence/gameplay capability objects. Neither is a
  real-history or independently observed denial receipt yet.
- The live playable proves the target is not hypothetical: an authoritative
  world is serving against an exact durable revision and valid lease. Its
  current all-digs rejection incident is equally important evidence that
  readiness cannot substitute for semantic parity or a promotion receipt.
- Firn's commit-snapshot rebuild demonstrates a related admission discipline at
  machine scale: uncommitted state is excluded and the generated system closure
  is derived from pinned inputs. It is evidence for provenance, not a substitute
  for Stage 5 live parity.

#### What remains

Stage 4 must land and replay a retained authoritative journal window whose
receipt binds the journal digest, `asOf` revision, incumbent and candidate
materializations, and an independently checked denial trace for network,
persistence, and gameplay effects. Its parity receipt must bind the candidate's
source/program/compiler/ABI/toolchain closure, and a cold process must validate
and admit only that artifact without the originating shadow object. Stage 5
must first replace the landed comment-only harness by passing
`STAGE-5-SEMANTIC-DRIVER`, then record the killer demonstration end to end.

The runtime must enforce at most one incumbent and one candidate, inventory all
active engine handles, bind every replay input to its consumed revision, reject
a third generation, and publish through the single durable `PromotionCommit`
point. “Reverse promotion” is not special: the old materialization becomes a new
candidate against the *current* state and must hydrate it, prove declared
schema/profile compatibility or an explicit reverse migration, replay the
cutover suffix to parity, cross the same effect fence, and win a new atomic
promotion CAS. Without that proof, recovery is roll-forward, not reverse
promotion. External effects require idempotence/compensation facts; no receipt
may imply that the outside world was rewound.

#### The falsifiable demo — `STAGE-5-RECORDED-CUTOVER` (artifact #1)

Run a live player session. Make one declared semantic Beagle source edit. Require
a non-empty exact invalidated cone, unchanged identities for every unaffected
unit, and a cold-compiled singleton proven to belong to the cone. Hydrate the
candidate from the exact durable state revision. Replay a retained authoritative
journal window with network, persistence, and gameplay effects denied and an
independently observed denial trace. Record equal canonical state, outputs, and
results in a parity receipt bound to that exact materialization closure. From a
cold process, prepare and verify the `PromotionCommit`; promote at a named tick
with one fenced expected-tuple CAS without disconnecting the player. Inject a
semantic mismatch, substituted candidate, third-engine attempt, and stale-head
race; all must produce canonical rejection receipts and no head movement.
Advance state, then treat the previous engine as a candidate against current
state and require hydration, schema/profile or reverse-migration proof, suffix
parity, effect fencing, and a new promotion commit.

The bet fails on a synthetic-only fixture, restart-only switch, deployment
symlink edit, unrecorded effect, parity receipt not bound to the admitted
candidate, split publication, mixed-generation execution, head movement after
rejection, player disconnect, or a “rollback” that merely restarts old code or
cannot admit the old engine against current state.

### 5. KILL PROGRAM-AS-TEXT

#### The industry assumption it kills

The program is a text that compilers repeatedly interpret. Types, resolved
bindings, macro expansions, provenance, dependencies, and diagnostics are
ephemeral annotations. Reflection either inspects a runtime object model or
opens an ambient compiler environment. A macro is trusted string/tree surgery
whose dependencies are guessed from its output.

Text remains indispensable for authors. It is not enough for the program to
reason about itself. The semantic program is a graph of syntax identities,
binding edges, typed definitions, effect requirements, expansion provenance,
dependency edges, source revisions, materializations, and receipts. Text is one
lossless projection of that graph.

#### What Beagle has already demolished

- W1-W2 replaces slash-bearing identifier strings with structural qualifier,
  leaf, and provider facts across the production compiler. Resolution and
  rendering no longer have to rediscover the same relation independently.
- The store already separates recursive proposition identity from branch-local
  assertion coordinates and physical handles. W7 adds fork-stable event and
  occurrence identity. That layered model is what program facts need: semantic
  facts once, history and routing explicitly, indexes derived.
- Exact-source checked bundles preserve the authored view alongside canonical
  facts. W3 and W4 have implemented, but not yet landed, the self-host and store
  halves of that same rule.
- Current macro output is checked end to end. That is a necessary backstop, but
  current raw reader data and fresh lowered symbol spellings are not a hygiene
  proof and are not claimed as one.

#### What remains

W5 must land immutable syntax objects, scope-set hygiene, structural
`syntax-match`, expansion dependency facts, and capability-limited typed static
reflection. W7 must store expansions, binding edges, types, effects, query
results, and provenance under versioned identities; reflection must run as a
typed query whose consulted facts become dependency edges. Pretty names and
generated text may never carry hygiene or binding identity.

#### The falsifiable demo — `PROGRAM-FACT-GATE`

Expand a binding macro twice around a caller variable. Query the store for the
introduced syntax objects, scope sets, binding IDs, expansion origin, macro
definition ID, reflected type/interface IDs, and output type. Prove no capture
by structural binding identity, not printed suffix. Change the macro definition
and require only its dependent cone to invalidate. Restart and replay the exact
expansion from stored inputs. Render a source view with different whitespace;
the semantic expansion identity must remain fixed while the exact source
revision changes.

The bet fails if reflection reads mutable inference state, if any consulted
definition is missing from the dependency receipt, if binding correctness
depends on generated spelling, if source provenance is lost, or if stored
expansions cannot be independently replayed.

## II. POSITIONING: STEAL THE PEAK, CHANGE THE SUBSTRATE

The comparison is about current authoritative models, not metaphysical
impossibility. Every system below can host new libraries and adjacent runtimes;
some could host a direct competitor. The last column names the integrated
authority its present language/runtime does not itself supply, and distinguishes
Beagle's landed mechanisms from its proposed Stage 4/5 constitution.

| System | What it does best | What Beagle steals | The integrated authority Beagle must add that the current system does not supply |
| --- | --- | --- | --- |
| **Lean 4** | Dependent elaboration, a small trusted proof kernel, first-class syntax, syntax quotations and compiled syntax patterns, hygienic invocation identity, and a serious self-hosted bootstrap. | Tagged syntax with spans; fresh invocation scopes; compiled syntax patterns; expansion-use dependencies; the separation between ordinary macros and type-aware elaborators. Refuse Lean's scope-in-name encoding, Pratt surface, and proof machinery. | **A single durable identity/provenance/promotion graph for program facts and live application state.** Lean's environment and compiled modules establish propositions and code; they are not the durable heap whose revision is shadow-replayed and CAS-promoted. |
| **Koka** | Inferred open effect rows, evidence-passing handlers, and Perceus's precise RC plus unique-constructor reuse in a concrete C pipeline. | Normalize checked effects, lower private evidence operands after checking, constant-fold closed rows, and copy Perceus's pass separation only for measured residual native escapes/reuse. | **A language/runtime-authoritative durable reachability and promotion model, rather than RC/runtime ownership alone.** Koka can manage functional values exquisitely and a Koka application can use a durable store; its current language/runtime does not itself supply durable branch roots, source provenance, and live-engine admission as one authority. |
| **Racket** | The cleanest general-purpose macro expander: syntax objects carrying lexical context, scope-set binding, maximal-subset resolution, introduction-scope flipping, source properties, and a vast extension ecosystem. | The small lexical kernel exactly: `Syntax`, opaque `ScopeId`, `ScopeSet`, `(StructuralName, ScopeSet)` bindings, unique maximal-subset resolution, one-phase intro flip, and origin preservation. Refuse the phase tower, inspectors, certificates, module machinery, and compatibility surface. | **Queryable, typed, content-addressed expansions joined to durable program/state revisions and promotion receipts.** Racket's expander creates code in a module/runtime world; it does not make expansion, state, and engine admission facts in one store. |
| **Unison** | Content-addressed immutable definitions, causal namespaces, metadata-only rename/refactor, validated object transfer, and typed abilities. | Component hashing; names as routing metadata; hash-version indirection; validate-before-insert; checked abilities; atomic namespace moves; content-validated transfer, with explicit remote authority as a design direction. Keep exact source bytes and ordinary tools. | **Exact-source-provenanced live state promotion.** Unison's current codebase/runtime does not make an application's advancing durable state, native arena generation, shadow parity, and tick-bound engine head one CAS-admitted identity chain; that is an absent integrated model, not an impossibility proof. |
| **Zig** | Comptime as ordinary language execution inside semantic analysis; types as values; interned compiler objects; explicit analysis units and dependency invalidation; honest allocator control. | Make Beagle's typed evaluator the default extension engine, expose canonical Type/AST constructors, record analysis-unit dependencies, preserve diagnostic reason chains, and keep allocator control at materialization boundaries. | **Hygienic source extension plus persistent program-as-facts.** Comptime cannot define binding semantics for unexpanded source, and Zig's compiler intern pool is not a durable, queryable code/state/promotion store. |
| **Rust** | Static aliasing and lifetime proof over lowered control flow: MIR move/borrow collection, NLL constraint solving, initialization/loan dataflow, and compositional `Send`/`Sync` eligibility. | Put the proof where Beagle has explicit regions and control flow: `ArenaRead`/`ArenaWrite` permissions, close invalidation, old-to-young exclusion, promotion copy, and a small `TickHandoffReady` witness. Keep it seam-local; do not import source lifetimes or a trait universe. | **A language-level store authority that makes durable identity, reclamation, and promotion queryable semantic facts.** Rust's current language/runtime does not supply this model; a Rust application can build it, whereas Beagle proposes to make it authoritative. Borrow checking remains complementary process-local proof, not something the store model replaces. |
| **Erlang/OTP** | Operationally credible live code loading, bounded two-version discipline, supervision/failure domains, explicit upgrade plans, migration hooks, and restart escalation. | At-most-two live engines; named quiescence/barriers; ordered offline plans; explicit migration payloads; restart policy and intensity; structured failure reports. | **Semantic admission rather than trusted transition.** OTP's successful callback/release install cannot prove parity, complete process inventory, stale-head exclusion, or inverse state evolution. Beagle's proposed Stage 4/5 shadow-receipt and tick-bound-CAS protocol is designed to require those proofs; it is not a landed capability until `STAGE-5-RECORDED-CUTOVER` passes. |
| **Smalltalk/Pharo** | A genuinely live world: image continuity, contextual inspection, suspended computations, and VM-level identity replacement through `become:`. | Liveness, semantic inspectors, and explicit identity evolution. Recast `become:` as revisioned successor/alias facts; keep Git source projection and clean reconstruction outside the live world. | **Image-like continuity that remains externally reproducible and mergeable.** A Smalltalk image is inspectable in-world, but its arbitrary live heap is opaque as an external, reproducible, mergeable authority. Beagle proposes to bind exact source, semantic facts, state revision, and admission without denying Smalltalk's internal inspectability. |

Beagle does not win by imitating eight mature systems at once. It wins only if
their best mechanisms become local consequences of a different substrate:
syntax hygiene over structural identities; typed comptime over stored analysis
units; effects over explicit evidence; memory over two allocation regimes;
refactoring over routing facts; and live upgrade over admission receipts.

## III. THE WAVE PLAN, W5-W7

Every gate below is deterministic and named before implementation. Every wave
extends the Stage 5 lineage rather than creating an unrelated showcase.

### W5 — metaprogramming becomes typed, hygienic, and dependency-complete

#### Adjudication: macro-shaped at the boundary, comptime-shaped by default

Zig wins whenever the extension computes a type, value, declaration family,
codec, specialization, or validation inside grammar the parser already knows.
Use ordinary typed Beagle evaluation and canonical AST/Type constructors there.
It avoids an alternate metalanguage and avoids hygiene when it does not create
binders or splice unresolved caller syntax.

Racket and Lean win when an extension introduces notation, a binding form,
source-preserving transformation, or local syntactic abstraction. Comptime
cannot retroactively bind occurrences in unexpanded source. Use real syntax
objects and scope-set hygiene there. The moment a typed evaluator creates a
lexical binder, it must use the same syntax/scope substrate or be rejected.

There is one evaluator, not two language towers. Syntax macros use it for
computation; typed compile-time functions use validated AST/Type constructors;
only the syntax/binding membrane differs.

| Item | Mechanism | Named acceptance gate |
| --- | --- | --- |
| **W5.1 Syntax objects** | Introduce immutable `Syntax = Missing | Atom | Ident | List | Vector | Map | Set`. Every node carries exact span, delimiter/reader metadata, `SourceRevision`, and `ExpansionOrigin`; `Ident` carries `StructuralName` plus `ScopeSet`. Quotation creates syntax; antiquotation preserves the exact caller object. `syntax->datum` is explicit and lossy. Adapt current raw-data macros one boundary at a time and retain whole-output checking. | **`W5-G1 SYNTAX-MEMBRANE`**: an existing macro returns `Syntax`; an antiquoted child preserves exact bytes/span; a generated wrapper blames the call site and origin chain; a malformed typed constructor fails at construction, not in a later parser. |
| **W5.2 Scope-set hygiene** | Mint an opaque stable `ScopeId` from module content identity plus expansion path. One macro invocation flips its introduction scope on input and output. Core binders add lexical scopes to binders and their regions. Bindings are keyed by `(StructuralName, ScopeSet)`; resolution selects the unique applicable binding with maximal scope set and returns a `BindingId`, rejecting incomparable maxima. Scopes never print into names. | **`W5-G2 CAPTURE-MATRIX`**: caller `tmp`, introduced `tmp`, and nested introduced `tmp` resolve to three intended binding IDs; antiquoted caller syntax is not captured; introduced binder/use resolve together; incomparable maxima produce a source-pointed ambiguity. Assertions inspect scope sets and binding IDs, never suffixes. |
| **W5.3 `syntax-match`** | Compile list/vector/map/identifier/literal/splice patterns into structural decision trees. Bind syntax objects, preserve clause order, constrain splice positions, and attach errors to the pattern span. Do not import Lean's grammar-category machinery or Racket's general transformer zoo before a Beagle need exists. | **`W5-G3 STRUCTURAL-PATTERN`**: a `when`-shaped macro expands through compiled structural matching; identifier and tail-splice bindings retain origin; invalid category/splice placement fails at the pattern; the expanded program passes the existing type checker. |
| **W5.4 Expansion dependencies into cone invalidation** | `Expansion` stores input syntax ID, macro definition ID, syntax/parser provider IDs, output syntax ID, provenance, and every reflection dependency. The module/interface manifest records dependencies at expansion time, not by scanning output. An evaluator invocation is an analysis unit keyed by definition ID, typed inputs, compiler/interface version, and capability set. No memoization until the manifest is complete. | **`W5-G4 EXPANSION-CONE`**: changing a used macro or parser provider invalidates exactly its dependent expansions and downstream typed units; an unrelated definition changes none; changing a macro whose name disappears from output still invalidates; restart derives the same cone from stored edges. An undeclared observed read fails the gate. |
| **W5.5 Static reflection** | Ordinary macros receive no type environment. A separate read-only `ElabMacroContext` exposes typed `resolve`, `type-of-syntax`, `lookup-def`, `fields-of`, and `members-of` queries over the current immutable module/store snapshot. Each result names defining definition/interface IDs and appends them to the dependency set. Reflection returns values, never printed type syntax. | **`W5-G5 REFLECTION-CAPABILITY`**: derive one codec from a nominal record; an unrelated edit does not re-evaluate it; a field/type/effect edit does; the receipt names every consulted interface and compiler version; ordinary `defmacro` calling the API is rejected. |

**W5 wave gate — `W5-STAGE5-LINEAGE`.** In the live demo lineage, edit a
reflected record used by a hygienic macro. Show the exact expansion/type/unit
cone, compile only the affected materialization, query its origin facts, and
admit it through the existing shadow/CAS protocol. If W5 needs a separate demo,
W5 is not integrated.

### W6 — effects are evidence; memory is two regimes, not one miracle

Koka supplies two pieces of evidence and one warning. Effect-row unification
supports open checked requirements and a later pass can lower the chosen
handler as evidence, often a constant slot. Perceus can insert exact
retain/release operations and reuse uniquely dead constructors. But universal
RC would recreate a second durable reachability graph beside the store and add
edge traffic to values an arena already reclaims in one close.

Rust supplies the aliasing axis and the right phase placement. Its guarantee is
not allocator folklore: MIR move/borrow collection, NLL constraint solving, and
loan/initialization dataflow cooperate over lowered control flow. Beagle should
use that discipline at two seams only: arena handles and the Stage 5 tick
handoff. A compiler-owned handoff witness is eligibility, analogous to
`Send`/`Sync`; it is never parity, authority, or permission to bypass CAS.

The verdict is therefore explicit:

> Keep the two-regime model. Use arenas and derived epochs for bounded transient
> graphs; use the store for durable identity and reachability. Consider precise
> RC only for measured bounded native values that escape an epoch but must not
> become durable facts. Consider reuse only after uniqueness/liveness proof,
> inside one epoch, for layout-compatible values.

| Item | Mechanism | Named acceptance gate |
| --- | --- | --- |
| **W6.1 Effect evidence** | Normalize checked effect rows in typed IR. Lower handler crossings after checking to private evidence/context operands. Closed rows select a literal slot; genuinely open rows use deterministic lookup. Evidence is transient and cannot carry store identity. Add resumption machinery only for a checked resumptive effect. | **`W6-G1 CLOSED-EVIDENCE`**: an operation outside its handler is rejected; nested same-label handlers restore the right slot; C17 and QBE receive the same private ABI meaning; a closed row contains no dynamic lookup; an evidence value cannot serialize or cross promotion. |
| **W6.2 Arena aliasing and tick eligibility** | In Native Core, model `ArenaRead<E,T>` as aliasable, `ArenaWrite<E,T>` as exclusive/token-authorized, `Promoted<T>` as a checked copy into an older regime, and `Closed<E>` as handle invalidation. Synthesize `TickHandoffReady<State,Revision,Head>` only when the candidate names its generation/head and retains no younger handle. The witness is consumed by the cutover protocol; it grants no store mutation authority. | **`W6-G2 ARENA-ALIAS-HANDOFF`**: allow two reads; reject conflicting read/write, old-to-young storage, and every use after close; accept only explicit promotion across age. A candidate with a child handle cannot obtain the witness. A ready candidate with a stale head still loses CAS and leaves the active head unchanged. |
| **W6.3 Escape census before RC** | Instrument one representative native authority workload so every allocation byte/site is exactly one of child-epoch local, explicit promotion/store materialization, or bounded non-epoch escape. Unknown is a failure. Pre-register the workload's latency and retained-byte budget. RC work is killed unless the residual class exceeds 10% of steady retained transient bytes, 5% of execution time through forced root retention/copying, or contains a required host/ABI value with no sound epoch owner. | **`W6-G3 ESCAPE-CENSUS`**: classification accounts for 100% of observed allocation bytes and sites; repeated runs give the same semantic classes; the receipt either authorizes one exact residual representation or records `RC-NOT-JUSTIFIED`. No general RC implementation may precede this gate. |
| **W6.4 Narrow precise RC** | If authorized, run backwards owned/borrowed liveness on only the named Native Core representation and insert exact retains/releases. It may survive bounded sibling computations but may not enter store facts, branch roots, syntax objects, or source semantics. | **`W6-G4 RESIDUAL-RC-WALL`**: retain/release balance on every exit and failure path; sanitizer clean; no RC handle in canonical bytes; peak retained bytes or forced-copy time meets the pre-registered budget; otherwise delete the pass. |
| **W6.5 Same-epoch reuse** | After liveness proves a fixed-layout constructor uniquely dead, issue a reuse token consumable only by a same-layout allocation in the same epoch. Preserve unchanged fields only after semantic equality proof. Tokens cannot cross promotion, handler escape, or store materialization. | **`W6-G5 UNIQUE-REUSE`**: semantic output and artifact identity equal the non-reuse path; allocation count and high-water bytes improve on the named hot loop; epoch obligations remain green; an attempted cross-epoch/store reuse is rejected. No material win means the optimization dies. |
| **W6.6 Store/native firewall** | Versioned canonical store codecs accept only semantic values, freely assertable claims, and separately typed sealed attestation envelopes. Native addresses, arena IDs, evidence slots, RC counts, and reuse tokens are unrepresentable. Promotion is a typed copy into an older transient arena or a verified semantic insertion into the store—never pointer retention. An ordinary Triple cannot enter a certified relation by matching its shape. | **`W6-G6 TWO-REGIME-RATCHET`**: tracked codec/IR search plus negative fixtures proves every transient carrier is rejected; an untrusted assertion shaped like a promotion is never certified; Stage 3 mismatch/restart/ASan evidence remains green; store GC outcomes are invariant under native address/layout changes. |
| **W6.7 Structural promotion** | `bgl/promote` remains a complete typed copy; it never guesses that a field is semantically dispensable. Source states a smaller survivor through ordinary typed record/union/vector construction. A post-liveness projection pass may fuse that construction plus promotion into one copy plan over named field paths, with no discarded intermediate. Ambiguous dynamic, recursive, or alias-sensitive cases retain explicit construct-then-promote and a source-pointed reason. Perceus-style liveness/reuse may optimize the plan after survivor semantics are fixed; RC does not choose them. | **`W6-G7 STRUCTURAL-PROMOTION`**: an intertwined acyclic fixture retains one typed subshape; fused and explicit paths have equal semantic result and artifact identity; generated code performs no full-graph promotion; copied bytes are bounded by the projected value plus declared layout overhead; no younger handle survives close. Kill the pass if the named authority workload shows no material promotion-byte/time reduction or if it requires source ownership syntax. |
| **W6.8 Boundary inference failure contract** | Derive epochs from control flow and durability where proof succeeds. Otherwise emit `ARENA-BOUNDARY-UNDECIDABLE` at the allocation/escape, naming the value/type, blocking join or durability edge, and nearest explicit fallback. The fallback declares a driver-owned request/transaction epoch, fixed or bounded capacity, and explicit typed projection/promotion; it grants no unsafe escape and weakens no lifetime obligation. | **`W6-G8 BOUNDARY-DIAGNOSTIC-FALLBACK`**: one nontrivial fixture infers with no manual arena policy; one deliberately undecidable fixture names its exact blocker, succeeds under the explicit bounded fallback with identical semantics and complete counters, and still rejects a lifetime-invalid fallback. Kill the automatic-boundary claim and describe arenas as driver-managed if the representative authority infers no nontrivial boundary or any failure lacks an actionable fallback. |

**W6 wave gate — `W6-STAGE5-LINEAGE`.** Replay the retained authoritative
journal required by the Stage 5 gate with nested handled effects and the
measured memory policy. The shadow candidate
must be unable to emit external effects, memory receipts must account for every
epoch, full or projected promotion, residual escape, and explicit boundary
fallback, and promotion/state hashes must equal the unoptimized semantics.

### W7 — store identity is the language constitution

W7 is the wave that must be right enough to last a century. Unison validates
content identity and names-as-metadata. Smalltalk validates live continuity and
inspectability. Both also identify the cliffs: a codebase manager can isolate
tools, and an image can make collaboration/reproduction impossible. Beagle's
answer is the explicit identity constitution above: values, provenance,
definitions, occurrences, logical history, physical ref state, execution
closures, attestations, and admission commits stay separate and are joined by
verified edges—never collapsed into one magic hash or ambient heap.

#### W7 fact model

- `term(term-id-version, kind-id, canonical-payload-bytes, term-id)`
- `source-revision(source-id, exact-bytes, ordered-paths, spans)`
- `derives(derivation-id, ordered-input-ids, transformer-materialization-id,
  interpretation-profile-id, authority-id, output-ids, origin-map)`
- `definition(def-id, canonical-typed-facts, type-id, effect-row-id, nominal-seals)`
- `depends(def-id, dependency-def-id, use-kind)`
- `event(event-id, parent-history-id, canonical-transaction-frame)`
- `occurs(occurrence-id, event-id, ordinal, branch-local-coordinate)`
- `syntax(syntax-id, source-revision, structural-node, origin)`
- `binds(binding-id, structural-name, scope-set, definition-id)`
- `expands(expansion-id, input-syntax-id, macro-def-id, output-syntax-id)`
- `consulted(expansion-or-eval-id, reflected-fact-id)`
- `routes(history-revision-id, route-name, target-id)`
- `ref-state(route-name, history-revision-id, ref-state-token)`
- `artifact(artifact-id, exact-output-bytes)`
- `materialization(materialization-derivation-id, definition-closure,
  exact-toolchain-closure, build-options, policy, artifact-ids)`
- `compatible(runtime-compatibility-profile-id, cpu, os, abi, host-capabilities)`
- `attests(attestation-id, issuer, verifier, policy, trust-root, lease-epoch,
  verified-object-ids)`
- `parity(parity-receipt-id, candidate-materialization-derivation-id,
  source/program/toolchain-closure, journal-manifest-id, state/output/result-digests)`
- `promotion-commit(commit-id, old-engine-head-id, candidate-materialization-id,
  state-revision-id, journal-cursor, tick, lease-epoch, parity-receipt-id, policy-id)`
- `promotion-rejection(attempt-id, expected-tuple, candidate-id, reason)`

These are schema sketches, not a license to encode every internal row as a
public Triple. One fact, one semantic representation; private rows and indexes
remain free to change.

| Item | Mechanism | Named acceptance gate |
| --- | --- | --- |
| **W7.0 Canonical Term and occurrence bedrock** | Version and domain-separate `TermId` before definition hashing: fixed kind IDs, canonical recursive payload bytes, total comparison, UTF/text law, and exact Float NaN/signed-zero law. Mint `EventId` from the exact parent history/event and canonical transaction frame, then `OccurrenceId = (EventId, ordinal)`; retain `(SpaceId, sequence, ordinal)` only as a branch-local locator. New equality creates new versioned IDs and explicit migration/equivalence facts rather than reinterpreting old bytes. | **`W7-G0 TERM-EVENT-IDENTITY`**: hostile cross-runtime/machine vectors cover every Atom kind, recursive Terms, text, every Float edge case, and corrupt encodings. In a fork/join fixture, sibling first appends have equal local coordinates but unequal occurrence IDs, while their shared-prefix occurrences retain one ID. |
| **W7.1 Canonical definition identity** | Publish one normative canonical graph algorithm: domain-separated node kinds; de Bruijn indices or an equivalent specified binder/scope normalization; explicit structural versus nominal type rules and exported nominal seals; canonical capability IDs; deterministic automorphism handling for recursive components; and stable component-member IDs. Version the whole algorithm and exclude routes, paths, timestamps, and presentation. | **`W7-G1 IDENTITY-ORTHOGONALITY`**: adversarial alpha-renames, declaration permutation, symmetric SCCs, nominal twins, aliases, and file moves prove exactly which identities remain; type/dependency/effect/authority/seal changes move them; cross-runtime/machine vectors agree; every claimed hash is revalidated before insertion. |
| **W7.2 Exact provenance and projection** | Store exact source revisions beside a first-class `Derivation` graph. Its canonical preimage lists ordered input object IDs, transformer materialization ID, interpretation/profile ID, authority, output IDs, and byte-range/origin map. Every admissible semantic object has a verified path to an exact source revision or an explicit non-source origin. Multiple source revisions may denote one definition. Export files deterministically; imports preserve bytes before interpretation. | **`W7-G2 SOURCE-SEMANTIC-PROJECTION`**: whitespace/comment edits produce distinct source/derivation nodes but may converge on one definition; semantic edits change the intended outputs; byte export round-trips; clean clone replays every derivation and reproduces facts/materialization; altered bytes, reordered roots, transformer substitution, or a missing origin edge fail admission. |
| **W7.3 Routing, refactor, and explicit `become:`** | Names, aliases, packages, and branch heads are revisioned routing facts over `HistoryRevisionId`; `RefStateToken` remains a separate physical CAS concern. Identity evolution uses one snapshot-relative successor algebra: admission checks type/profile compatibility, rejects cycles, resolves chains deterministically, and returns an explicit conflict value for multiple live successors. Raw history never follows successors; the current semantic view does. Rename is one atomic logical step, never a global pointer rewrite. | **`W7-G3 REFACTOR-AS-FACT`**: rename changes routes only; forked occurrences retain fork-stable IDs; equal local coordinates do not alias; cycle and incompatible-successor admission fail; multiple successors return the named conflict; chain resolution agrees across hosted, native, Datalog, scan, reflection, export, and inspector paths; raw-history and current-view behavior differ only as specified. |
| **W7.4 Programs as facts and reflection as query** | Persist W5 syntax, binding, expansion, type, effect, dependency, diagnostic, and materialization facts. Static reflection is typed Datalog-like query against one immutable program snapshot; every input/result becomes a dependency fact. Inspectors expose semantic terms and “why retained/why rebuilt/why promoted” paths, never physical handles. | **`W7-G4 REFLECTION-CLOSURE`**: independently replay a stored expansion and type result; query every justification edge; rebuild derived indexes from canonical history; mutate any consulted fact and observe exact cone invalidation; mutate an unconsulted fact and observe none. |
| **W7.5 Bundle attestation and atomic promotion** | Split freely asserted claims from sealed system attestations. Only the admission transaction may mint a certified promotion attestation under an explicit trust root, verifier/policy version, and lease epoch. A checked bundle carries source/derivation closure, definitions, effects/authority, `ArtifactId`, `MaterializationDerivationId`, `RuntimeCompatibilityProfileId`, logical history, ref token, and engine head. Parity binds the exact candidate and full source/program/compiler/ABI/toolchain closure. Prepare `PromotionCommit` before publication, then perform one fenced CAS over route token, logical history, state revision, journal cursor/tick, lease, and old engine head; the visible head points to the commit. Success is reachability; failures are separate rejection receipts. Prior code is admitted against current state by the same protocol, never privileged as rollback. | **`W7-G5 ADMISSION-RATCHET`**: reject an ordinary assertion shaped like promotion, bad issuer/trust root, unknown dependency, altered source, mismatched type/effect, unauthorized ability, wrong artifact/toolchain/compatibility profile, failed obligation, parity/candidate substitution, third live engine, stale logical head, and stale physical token before head movement. A reseal-only token change is distinguished from semantic staleness. Crash at every publication boundary yields either the old head or one durable reachable commit, never a split state. A cold process admits only the bound artifact. Current-state reverse admission must hydrate, prove compatibility/migration, replay the suffix, and win the same fence. |
| **W7.6 Store-as-heap retention and proof-pack policy** | Durable online roots are branch heads, pins, checkpoints, active sessions, and explicit receipt-retention policies. Every receipt commits to a closure manifest/Merkle root and archival disposition. Integrity validity, recorded-policy admissibility, and local replayability are separate statuses. Online GC may evict a body only after its proof pack is durably archived or a later auditable policy fact expires it; native generations remain hydrated revision-bound views. GC is an explicit maintenance epoch, never implicit promotion work: its receipt records roots, unique/repeated segment references, bytes/facts decoded, wall time, and objects deleted under a predeclared store/control-authority hold budget. | **`W7-G6 SEMANTIC-REACHABILITY`**: retain exactly the declared online roots; malformed roots abort before deletion; archive and evict an exclusive proof-pack body without changing its integrity/admissibility status while local replayability becomes false; fetch and revalidate to restore replayability; expiry is itself auditable; reseal and native layout changes preserve semantic IDs; cold restart resolves the surviving head byte-identically. A representative maximum-size store with shared history must meet its predeclared maintenance budget. A miss requires verified caching/incremental marking or narrows the off-hot-path claim; moving full GC into promotion or revising the budget after the miss fails the gate. |

**W7 wave gate — `THE-MOTHER-OF-ALL-DEMOS`.** Run `DEAD-FILE-GATE`,
`NO-BUILD-PHASE-GATE`, `ONE-TYPE-GATE`, `PROGRAM-FACT-GATE`, and the Stage 5
cutover as one chronology over one source edit and one running world. Publish a
canonical manifest plus content-addressed proof pack containing every source,
derivation, journal, incumbent/candidate artifact, parity, denial trace, CAS,
state, and player-session-continuity edge. The journal comes from the retained
authority log; effect absence comes from an independently checked capability
denial trace; continuity comes from the bound session/event journal. One
read-only command, **`beagle verify turtles-demo <manifest-id>`**, must replay
the graph from a cold process. A negative matrix swaps each source, journal,
candidate, parity, CAS, or continuity edge in turn; every substitution and every
disconnected edge must fail before publication. The graph—not a staged video—is
the release artifact. If an external verifier cannot replay it, the wave has not
landed.

## IV. THE INSANE-BETS REGISTER

A bet without a kill-condition is branding. Every bet below is permitted to
die.

| Century bet, stated falsifiably | Evidence to date | Kill-condition |
| --- | --- | --- |
| **1. Files can become lossless projections rather than semantic authority.** Equivalent typed definitions can keep one identity across path/name/layout changes while exact authored bytes remain independently reproducible. | W1-W2 structural references through facts (`283380e4`..`f0ce4be7`); exact-byte regression caught and repaired (`a5e5c4ae`, focused 13/13, full 2406/2406); Firn already regenerates `.nix` from `.bnix`. | Kill if `DEAD-FILE-GATE` cannot preserve semantic identity and exact byte provenance simultaneously, or if ordinary Git collaboration requires an opaque store/image client. |
| **2. The build can disappear as a correctness phase.** Demand plus dependency-complete fact invalidation can replace whole-tree compile/run sequencing. | v0.22 semantic units; self-host fixpoint machinery; W3 commit-only remint 48/48 and CI fixpoint 25/25; Stage 3 revision-bound materializations. | Kill if any output-affecting macro/reflection/compiler read cannot be recorded, if clean restart changes the cone, or if whole-tree execution remains the only sound gate after W5. |
| **3. Code and durable state can share one type/effect substrate without sharing one undifferentiated relation.** | Recursive typed Term kernel; typed native source and FRAMRPC; Stage 2 CAS/watch/reseal/GC; focused Stage 3 generation evidence; live Grey durable revision. | **`ONE-TYPE-NEGATIVE-RELATION`** must encode and query one predeclared required W5-W7 program/domain relation through authoring, native authority, and reflection with one result type/digest, while the no-authority transaction is rejected before durability. Kill if any route requires strings, a second schema/serializer semantics, or cannot represent the relation: mark the bet `DEAD` or explicitly narrow it; follow-up work is not a pass. |
| **4. The store can be the durable heap while arenas remain the transient heap.** | Native Core explicit regions/effects/capabilities, old-to-young exclusion, `bgl/promote`, ASan fixtures; reported focused Stage 3 512-generation reclamation evidence; Stage 2 segment reachability GC. The bounded external-review fixture measured roughly 11.8k–12.8k decoded facts/s from 10k through 100k facts; this is current-machine cost evidence, not a production receipt or native-GC comparison. | Kill if durable correctness depends on native addresses, if store GC cannot explain retention from explicit roots, or if representative transient workloads cannot be bounded without a universal source-level ownership/GC model. Kill or narrow “off hot path” when `W7-G6` misses the predeclared store/control-authority hold budget without a verified incremental/cached remedy; kill automatic-boundary ergonomics when `W6-G8` infers no nontrivial representative boundary. |
| **5. Deployment can become proven admission.** A candidate can replace a live engine only after real-history parity and one atomic expected-tuple CAS at a tick. | Stage 2 CAS; focused Stage 3 generation evidence; Stage 4 commit-only synthetic harness; live playable readiness evidence. The landed Stage 5 comment-only zero-cone wire harness is explicitly not evidence for this bet. | Kill if `STAGE-5-RECORDED-CUTOVER` cannot admit the exact parity-bound candidate without disconnect/mixed generation, if rejection changes any head or emits an effect, if publication can split commit/state/head durability, or if prior code cannot pass current-state hydration, compatibility/migration, suffix parity, and the same admission fence. |
| **6. Programs can be durable facts and safely query themselves.** | W1-W2 structural program facts; store semantic/private split; exact checked bundles. | Kill if hygienic identity must live in spelling, if reflection cannot be read-only and dependency-complete, or if persisted expansion/type facts cannot be replayed independently. |
| **7. Smalltalk liveness and Git reproducibility can coexist.** A living semantic world can be resumed and inspected without an opaque image becoming the repository. | branch-core restart/history model; Stage 2 durability/reseal/GC; focused Stage 3 revision-generation evidence; live playable; exact-source bundle mechanisms and reported checks. | Kill if a clean clone cannot reconstruct named source/program/state generations, if live identity evolution requires hidden pointer surgery, or if state continuity and external mergeability cannot both pass the Smalltalk experiments. |
| **8. One typed Lisp can span browser game logic, native authority, durable store, compiler, and system generation without a lowest-common-denominator runtime.** | v0.22 targets; branch-core hosted/native/wasm routes; Grey live playable; Firn `.bnix` and Beagle-native tools; North `c1f18815` consumes Beagle branch-core with SDK 1774/0. This is coverage, not yet a shared-closure receipt. | **`ONE-CLOSURE-CROSS-TARGET`** must bind one source/definition closure ID to per-target materialization IDs plus compiler/ABI identities and equal canonical result digests for one named operation across browser, native authority, store/reflection, compiler, and system generation. Kill on a target-specific source fork, missing closure edge, or divergent digest: mark the bet `DEAD` or explicitly narrow its target set. |
| **9. Receipts can be the unit of trust across compilation, persistence, and promotion.** | The v0.22 tag carries an exact-commit preflight assertion; Stage 2/3 counts are focused evidence without complete immutable manifests; Stage 4 supplies commit-only synthetic formats; Firn uses commit snapshots. | **`RECEIPT-OMITTED-INPUT`** deliberately removes one output-affecting input, and a substitution matrix alters each referenced object, authority, policy, and candidate edge. The cold verifier must reject every case. Kill if an omitted input or false/absent authority still verifies, or if validation needs the originating process; mark the bet `DEAD`. |
| **10. A tiny recursive fact kernel can carry a century of program and domain structure without growing a universal public tuple/object type.** | `Term := Atom | Triple`; nested structural identity; branch-local occurrence/withdrawal history separate; private rows/indexes free to widen; W1-W2 reference schema uses nodes/facts rather than compound names. | **`TERM-KERNEL-NEGATIVE-CORPUS`** contains one predeclared required relation from each of W5 syntax/binding, W6 evidence boundary, W7 provenance/attestation, and domain state. Kill if any relation cannot preserve its canonical semantics and query plan as `Atom | Triple` without changing Term equality or adding a second privileged public carrier: mark the bet `DEAD` or narrow the kernel claim. One red required case decides; “not repeated yet” is not a pass. |

## V. TWENTY REASONS THAT ARE MECHANISMS

The promised hundred reasons compress to these twenty. Everything else is an
adjective, a consequence, or a duplicate.

1. **Single lowering:** authored qualification is decomposed once into
   structural qualifier, leaf, and provider identity (`ef018fbd`), not reparsed
   in every consumer.
2. **Structural binding edges:** resolution yields stable binding/definition
   edges; rendering is a separate terminal operation.
3. **Exact source revisions:** checked bundles retain authored bytes and ordered
   roots independently from semantic facts; the 13/13 regression proves the
   distinction is enforced.
4. **Recursive semantic values:** `Atom | Triple` gives code and domain models a
   nestable structural value without making physical rows public identity.
5. **Fork-stable occurrence identity:** W7 mints an event from parent history and
   canonical transaction bytes, then names an occurrence by event plus ordinal.
   Equal branch-local coordinates may diverge after a fork while shared-prefix
   occurrences remain identical; today's coordinate is only the locator.
6. **Separated logical and physical CAS identity:** `HistoryRevisionId`,
   `RefStateToken`, and `EngineHeadId` cannot masquerade as one head. One durable
   contender wins; a stale contender changes no bytes, while reseal-only token
   contention is not semantic staleness.
7. **Post-durable watch:** observation follows the forced ref move and resumes
   monotonically without gaps or duplicates.
8. **Identity-preserving reseal:** chains pass the old 64-segment ceiling while
   v2 revision identity survives physical reorganization.
9. **Verified-root GC:** heads, pins, checkpoints, and active sessions determine
   durable segment reachability; malformed roots stop deletion. Collection is
   an explicit authority-held maintenance epoch whose receipt must expose
   repeated segment visits, decoded bytes/facts, wall time, and the declared
   authority-hold budget; it is never hidden inside engine promotion.
10. **Revision-owned generations:** hydrated native arenas are bound to named
    source/program/state revisions; mismatch destroys the candidate and keeps
    the incumbent visible.
11. **Explicit lifetime crossing:** `bgl/promote` is a typed copy; local or
    already-old values erase to no-op/register copy, genuine crossings stay
    measurable.
12. **Closed effect evidence:** checked effect requirements lower to private
    evidence operands and constant slots where rows are closed, rather than
    ambient callbacks or source-level dictionaries.
13. **Seam-local alias and handoff proofs:** `ArenaRead`/`ArenaWrite` modes prove
    aliasing inside an epoch, while `TickHandoffReady` proves only that a
    candidate carries no younger handle; neither witness bypasses CAS.
14. **Two-regime firewall:** durable facts cannot contain arena IDs, pointers,
    evidence vectors, RC counts, or reuse tokens.
15. **Typed compile-time evaluation:** the normal Beagle evaluator constructs
    canonical Type/AST values; whole-output checking remains a backstop.
16. **Scope-set hygiene:** opaque introduction and lexical scopes plus
    maximal-subset resolution prove capture behavior without symbol suffixes.
17. **Dependency-complete reflection:** macro, parser, reflection, and interface
    reads occur through immutable typed queries, become dependency edges when
    used, and invalidate exact cones even when they disappear from output.
18. **Canonical authority journal:** the design binds every input to order/tick,
    capability, nondeterminism, consumed revision, committed revision, outputs,
    and result bytes. Present evidence is a commit-only synthetic native harness;
    the acceptance receipt awaits a retained authority-journal digest and
    independently replayable manifest.
19. **Effect-denied shadow replay:** the design makes a candidate consume a
    bounded retained journal read-only and independently proves that network,
    persistence, and gameplay effects were denied before admission. Present
    evidence is only the commit-only synthetic capability harness; the gate
    awaits bound incumbent/candidate IDs, `asOf`, and a process-boundary denial
    trace.
20. **Tick-bound atomic promotion commit:** a candidate-bound parity receipt and
    prepared commit join source, definitions, exact toolchain/compatibility,
    current state, journal cursor, tick, lease, policy, and old head. One fenced
    CAS makes the commit visible; success is durable reachability, and admitting
    prior code against current state uses the identical independently replayable
    protocol.

## The wager

Features diffuse. Substrates persist. If Beagle merely ships better macros,
faster incremental builds, a nice triple store, or a safer hot reload, those
advantages will be copied and the old boundaries will survive. The work matters
only if the store identity model makes the boundaries unnecessary.

That demands restraint as much as ambition. Do not collapse source identity
into semantic identity. Do not confuse a known hash with a present verified
object. Do not let reflection become ambient authority. Do not let RC become a
second persistence graph. Do not call a callback result parity. Do not call a
restart rollback. Do not call commit-only code landed. Do not call a video a
receipt.

Build the store constitution. Make every surface a projection. Make every
derivation queryable. Make every transition falsifiable. Then record one living
world crossing all five dead boundaries without hand-waving any of them back
into existence.

## CHANGELOG — v1 to v2

### Adversarial review 3 — substrate attack

| Finding | Repair |
| --- | --- |
| `SUBSTRATE-1` | Replaced fork-colliding bare coordinates with parent-bound `EventId` and `(EventId, ordinal)` `OccurrenceId`; retained `(SpaceId, sequence, ordinal)` only as a local locator; added the fork/join gate. |
| `SUBSTRATE-2` | Added the versioned, domain-separated `TermId` constitution and `W7-G0` hostile cross-runtime vectors, including Float and text laws. |
| `SUBSTRATE-3` | Split `RouteName`, `HistoryRevisionId`, `RefStateToken`, and `EngineHeadId`; made reseal-only token contention distinct from semantic staleness. |
| `SUBSTRATE-4` | Split freely assertable claims from sealed admission attestations with issuer/verifier/policy/trust-root/lease identity; ordinary Triple shape cannot certify promotion. |
| `SUBSTRATE-5` | Bound parity to the exact candidate `MaterializationDerivationId` and full source/program/compiler/ABI/toolchain closure; added cold-process validation and substitution rejection. |
| `SUBSTRATE-6` | Removed `cas-result` from receipt identity; introduced a prepared immutable `PromotionCommit`, one fenced expected-tuple CAS, reachability-derived success, and separate rejection receipts. |
| `SUBSTRATE-7` | Replaced privileged “reverse promotion” with fresh admission of prior code against current state, requiring hydration, compatibility or reverse migration, suffix parity, effect fencing, and a new CAS. |
| `SUBSTRATE-8` | Replaced provenance fields with a first-class ordered `Derivation` graph; renamed `SOURCE-SEMANTIC-BIJECTION` to `SOURCE-SEMANTIC-PROJECTION` and gated the intended many-to-one relation. |
| `SUBSTRATE-9` | Specified one snapshot-relative successor algebra: cycle/type checks, deterministic chains, explicit multi-successor conflict, raw-history/current-view split, and a seven-surface conformance matrix. |
| `SUBSTRATE-10` | Split receipt integrity, recorded-policy admissibility, and current local replayability; added closure manifests, archival disposition, auditable expiry, and fetch/revalidation. |
| `SUBSTRATE-11` | Replaced “hash SCCs deterministically” with a normative canonical graph algorithm covering binders, nominal seals, capability IDs, automorphisms, member IDs, and adversarial vectors. |
| `SUBSTRATE-12` | Split output `ArtifactId`, reconstructible `MaterializationDerivationId`, and `RuntimeCompatibilityProfileId`; promotion verifies all three. |

### Adversarial review 4 — claims falsifier

| Finding | Repair |
| --- | --- |
| `FALSIFIER-1` | Renamed `c5316ad1` to what it proves: a landed comment-only zero-semantic-cone wire harness. Denied it evidence status for bets 2 and 5 and named `STAGE-5-SEMANTIC-DRIVER` as the required semantic-edit/non-empty-cone/affected-singleton gate. |
| `FALSIFIER-2` | Recast Stage 3 as “reachable on main; focused evidence,” recorded the no-verdict active-tier run and `slice-store` incompatibility, and named the missing exact-commit supervised acceptance record. |
| `FALSIFIER-3` | Labeled Stage 4 and reasons 18–19 commit-only synthetic native-harness evidence; the gate now requires a retained authority journal, bound artifacts/`asOf`, and independent process-boundary effect-denial trace. |
| `FALSIFIER-4` | Turned the truth ledger into an evidence-scope manifest and declared counts non-replayable until commit, command, input/toolchain, exit, and retained-output digest/path are bound. |
| `FALSIFIER-5` | Added binary named negative fixtures for bets 3, 8, 9, and 10; a red required case now marks the bet `DEAD` or forces an explicit narrowing. |
| `FALSIFIER-6` | Made bet 8 require one definition-closure ID, per-target materializations/compiler/ABI identities, and equal canonical result digests; source forks and missing edges fail. |
| `FALSIFIER-7` | Made the Mother-of-All-Demos a canonical manifest/proof pack verified by one cold read-only command, with provenance for journal, denial, and continuity plus an edge-substitution negative matrix. |

### Adversarial review 5 — positioning honesty

| Finding | Repair |
| --- | --- |
| `POSITIONING-LEAN` | Corrected “typed quotations/patterns” to syntax quotations and compiled syntax patterns while preserving the macro/elaborator distinction. |
| `POSITIONING-KOKA` | Recast the contrast as absence of a language/runtime-authoritative durable reachability and promotion model; explicitly conceded that Koka applications can use a durable store. |
| `POSITIONING-RACKET` | Corrected “immutable syntax context” to syntax objects carrying lexical context. |
| `POSITIONING-UNISON` | Limited shipped credit to content-validated transfer, labeled remote authority a design direction, and stated live-state promotion as a current integrated-model absence rather than impossibility. |
| `POSITIONING-ZIG` | No repair required; the row already made the present-system, not metaphysical, claim. |
| `POSITIONING-RUST` | Rewrote the row for Rust's best advocate: a Rust application can build this architecture; Beagle's bet is to make the store authority language-level, complementary to borrow checking. |
| `POSITIONING-OTP` | Removed present-capability attribution; Stage 4/5 semantic admission is explicitly proposed until `STAGE-5-RECORDED-CUTOVER` passes. |
| `POSITIONING-SMALLTALK` | Preserved in-world inspectability and narrowed opacity to the arbitrary heap as an external reproducible/mergeable authority. |
| `POSITIONING-CROSS-ROW` | Replaced “structurally cannot” with a current-authority comparison and explicitly separated rival shipped features, Beagle landed mechanisms, and proposed gated mechanisms. |

### Adversarial review 6 — external allocation substrate

| Finding | Repair |
| --- | --- |
| `ALLOCATION-GC-COST` | Recorded landed Stage 2's actual segment-verification algorithm, store/control-authority maintenance epoch, bounded 10k/50k/100k benchmark, non-GC raw-read anchor, repeated-root cost, `FACT-GC-MAINTENANCE-BUDGET`, and the rule that an authority-hold-budget miss requires a verified cached/incremental remedy or a narrower claim. |
| `ALLOCATION-PROJECTION` | Recorded that current `bgl/promote` copies one complete supported value and Stage 2/3 added no survivor selection. Added `W6.7` structural promotion: source states the typed survivor shape; a compiler plan may fuse construction plus copy; Perceus-style liveness/reuse optimizes only after semantics are fixed. |
| `ALLOCATION-BOUNDARY-FAILURE` | Added the `ARENA-BOUNDARY-UNDECIDABLE` contract and `W6.8`: name the exact value and blocking control-flow/durability edge, offer an explicit bounded driver policy such as the 80 MiB scratch epoch, preserve every lifetime check, and kill the automatic-inference claim if no nontrivial representative boundary is inferred. |

TURTLES-V2-DONE — evidence: all five boundary sections remain; the positioning table has exactly eight system rows; the register has exactly ten bets with explicit kill-conditions; the mechanism list has exactly twenty numbered reasons; `c5316ad1` is scoped only to its landed comment-only zero-cone harness; Stage 3 is main-reachable focused evidence with its acceptance gap named; Stage 4 and Greywrought `dc0c3b7` remain commit-only; `STAGE-5-SEMANTIC-DRIVER` and `STAGE-5-RECORDED-CUTOVER` remain open gates rather than present capability claims; and every finding from all four supplied reviews is mapped above.
