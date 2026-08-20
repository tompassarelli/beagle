# Naming ledger

This ledger preserves each load-bearing naming verdict, its deciding prior, and its rejected bench so the argument is not repeated.

Entries stay dated. When a later ruling supersedes wording, reconcile that entry in place and point to the successor; git preserves the former text.

## Rule

Beagle Store's readers include LLMs, so repository vocabulary becomes generated vocabulary. Choose by **prior alignment**: the strongest established meaning must match the thing without a correction paragraph.

## fact — chosen 2026-06; superseded as a primitive 2026-08-01

The June ruling named a stored `(subject predicate object)` record **fact**. The recursive-Triple cut superseded that primitive: [Triple](glossary.md#semantic-kernel) is the sole structural semantic primitive, while fact is valid only for a proposition admitted by a view. Datalog and coordination projections may say fact; storage and kernel APIs say Term, Triple, proposition, and occurrence. This keeps truth and endorsement out of storage identity: one proposition may be asserted, disputed, withdrawn, or selected differently without changing its Triple.

The deciding prior is Datalog: a fact is a proposition present in the evaluated relation. The rejected primitive use is **fact-as-stored-row** — it falsely merges structure, assertion act, and view status.

## world — chosen 2026-07-26; retired 2026-08-07

**Retired 2026-08-07:** the Worlds service is deleted from the tree. `world`
and the bare historical name `version` name no current module or primitive and
are spent for new naming. The live closed-wire operation `:rpc/version` is
unrelated and remains current. Durable Store transaction-log data that service wrote
(`evidence.world`, `world.record`, `world.version:`) keeps its spelling:
respelling stored predicates is a data migration, not a rename.

The former ruling read: historical Worlds-service vocabulary; the service left
the public recursive-kernel runtime, so `world` and bare `version` are not
kernel primitives. This retirement does not name or remove `:rpc/version`.

The thing was a named, forkable lineage of immutable versions that fixed which facts a query saw without promising consistency. The possible-worlds prior decided it: propositions are evaluated at a way things could stand.

Rejected bench:

- **consistent-plane** — promises consistency that rival assertions deliberately violate.
- **plane** — collides with infrastructure control/data planes.
- **reality** — claims truth a world need not have.
- **universe** — claims totality although a version may be partial.
- **branch** — describes mechanics but not what is branching, and collides with git. **Superseded 2026-08-08** for a different thing: see [branch](#branch--chosen-2026-08-08), where the mechanics are what is being named.

## codegraph — chosen 2026-07-26

**Current scope:** historical experiment and sealed-consumer vocabulary, not a public data primitive. **Partly superseded 2026-08-02:** the `codegraph` skill was retired into `code-as-facts`; the subsystem verdict remains.

The thing was the code-intelligence surface that projected Beagle source to queryable relations for who-calls, blast radius, and rename analysis; it did not promise source authoring, formatting preservation, or non-Beagle input. Revealed preference decided it: users independently reached for `codegraph`, while `chartroom` required its experiment story. The lexical resolver was engine machinery and moved out; its former shim is gone and the Beagle resolver modules now build to `out/resolve.clj`.

Rejected bench:

- **chartroom** — an experiment codename costs an explanation at every call site.
- **callgraph** — names only one narrower relation and was already a module name.
- **codeintel** — imports IDE and vendor expectations this surface did not serve.
- **code-as-facts** as the subsystem directory — names the bet and live skill well, but is too long for the module.

The old `chartroom` name survives only where provenance would otherwise become false.

## Turtle — architecture prior, never a primitive — chosen 2026-08-01

**Turtle** invokes “turtles all the way down”: use recursive Terms for semantic
content and structural coordinates when the model permits. It never turns
operation or withdrawal rows into domain proposition Triples, and it never
names a record, identifier, log, or second stored type; the literal semantic
vocabulary is linked from the [glossary](glossary.md#semantic-kernel).

Roles remain ontology conventions, not kernel positions. Membership implied by spelling must be asserted, as [ontology](ontology.md#normalization) specifies.

Atoms terminate recursion honestly. When components need queries or descriptions, use more Triples instead of opaque compounds. Tagged handles, tables, and rows remain private representations; `TurtleRow`, `turtle-id`, and “turtle log” remain category errors.

## agent skill names — store-modeling, code-as-facts — chosen 2026-08-02

The thing was an unambiguous routing vocabulary for agent skills. The layer split decided it: Triple names kernel structure, while fact is the coordination projection's word. Therefore `fact-modeling` became **`store-modeling`**, named for the stable tool, and the read-side `codegraph` skill merged into **`code-as-facts`**, one write/read faculty over one projected AST.

Rejected bench:

- **code-as-triples** — kernel-accurate but wrong for the coordination handle already wired into North and the upstream guard.
- **codegraph** for the merged skill — routes users toward one historical consumer instead of the authoring faculty.
- **store-authoring** — collides with `beagle-authoring` and the graph-edit channel.
- **store-data** — omits Datalog derivation, half the faculty.

Skills are named for the tool (`store-modeling`, `beagle-authoring`) or the bet (`code-as-facts`), never the current layer's stored-thing word.

## normalized example — settled 2026-08-03; superseded 2026-08-14

The August 3 example removed the spelling namespace from `:contact/email`, but
left the noun `:email` in the relation position. That was not a valid positive
proposition example and is superseded by the `:contactable_at` example in
[ontology](ontology.md#normalization). The correction keeps the useful part of
the ruling—copyable positive examples and explicit vocabulary membership—while
requiring the middle Term, under that profile, to name the relationship actually
being stated.

Closed `:kernel/*` and `:rpc/*` tags are protocol vocabulary, not patterns
applications may copy into their ontology. `SPO`/`POS`/`OSP` remain private
rotations.

Rejected bench:

- **`:contact-email`** — hides the same membership behind different punctuation.
- **flat noun-as-relation triples** — removing a slash does not make `:email`
  name a relationship.
- **prohibition-only documentation** — loses to any nearby copyable counterexample.

## Fact Normal Form — fact-oriented profile discipline — chosen 2026-08-14

Fact Normal Form (FNF) applies to propositions admitted by a fact-oriented
profile, not to every assertion or recursive Term. Every semantic relationship
that profile needs to interpret, join, classify, or validate the domain is an
admitted Triple rather than structure recoverable only from Atom spelling, an
assumed slot, or a specialized out-of-band schema cell. Other asserted profiles
own their own admission discipline. In a profile whose middle position is
relational, that Term names the actual relationship: `:contactable_at` states
reachability while the noun `:email` does not.

FNF does not require a new opaque Term for each proposition. Use an existing
Atom directly when its kind and canonical payload provide exactly the domain's
equality contract. Introduce a new Atom kind through a deliberate kernel and
codec extension when intrinsic validation, ordering, canonical encoding, or
equality differs; ontology spelling cannot create one. Mint a resource identity
only when the denoted thing has continuity or representation independent of the
Atom.

The intended identity ruling is:

```text
Atom identity         Atom kind + canonical payload
Proposition identity  recursive structural Triple equality
Assertion identity    occurrence coordinate
```

Current Float behavior is a documented exception to the intended Atom ruling;
see N4 in [guarantees](guarantees.md#wire). Host interning makes NaN unequal to
itself and equates `+0.0` with `-0.0`, while Store RPC canonicalizes NaN and
distinguishes signed zero. The ruling stands, but the core does not yet satisfy
it for Float.

Self-denoting value and resource name are semantic roles of Atom, not physical
variants. Context comes from relations and never mutates the underlying Term.
Constructing or nesting a Triple does not assert it; an occurrence supplies
assertion identity.

## Beagle fact projections — identifiers retained; contracts split — chosen 2026-08-03

The thing is two Beagle projections sharing a family word but not fidelity: `bin/beagle-facts`/`emit-facts.rkt` emits a compact lossy CNF analysis view, while `beagle facts-roundtrip`/`facts-roundtrip.rkt` emits a verbose program-lossless view preserving reader-datum, not byte, identity. `.store/corpus.facts` materializes the compact view.

Datalog's admitted-proposition prior decided **fact** here; it names projection status, not Beagle Store storage. Keep the existing identifiers and always state which fidelity contract applies.

Rejected bench:

- **`beagle-triples` / `emit-triples.rkt` / `corpus.triples`** — names row shape but erases projection purpose and still conflates fidelity.
- **`beagle-codegraph`** — names one historical consumer, not either projection.
- **`program-roundtrip`** — fits only the lossless half and severs the shared source↔fact prior.
- **one “lossless CNF fact-triple” description** — is observably false for `emit-facts.rkt`.
- **`claims`** — belongs to assertion acts, not projected views.

## namespaced vocabulary outside fixtures — scoped 2026-08-04

The thing was every remaining `ns/name` family after normalization. An inventory at `a488892` found 26 non-`:kernel/*`/`:rpc/*` families across 692 occurrences and separated them by contract.

- **Semantic fixtures** (`ontology/slot`, `plangrep/*`, `example/*`, `builder/*`, `growth/entry`, `building/id`, `deep/*`, `agent/lane`) became unnamespaced because none exercised membership. The kernel slash probe and ExceptionInfo tag `:test/rejected-plan` remain intentionally namespaced.
- **Historical code** (`provider/*`, `world/*`, `worlds/*`) retained spelling because rewriting a service awaiting retirement buys no queryable structure.
- **Closed wire tags** (`authority/*`, `store/*`, `store.defcheck/*`, `lease/*`, `query/*`) retained spelling because a change is wire versioning, not ontology normalization.

The deciding prior is boundary ownership: at that revision no in-scope family was written verbatim to a configured live store, so nine fixtures and zero stores changed. Replan if a configured non-test `worlds/invoke-plan-to!` caller, an external corpus carrying `worlds/*` or `provider/*`, or a Store RPC tag rename appears.

**Discharged 2026-08-07:** the `world/*` and `worlds/*` spelling condition is closed by deletion — the service awaiting retirement was retired, so no shipped module carries those families. The surviving spellings are test fixture labels and durable Store transaction-log predicates, both already out of scope here, so the replan trigger cannot fire.

## positions of the Triple — t1/t2/t3 — chosen 2026-08-04

The thing is the three neutral positional addresses of `Triple := (Term, Term, Term)`. **t1**, **t2**, and **t3** follow 1-based tuple coordinates: projections π1/π2/π3, Prolog `arg(1,...)`, Erlang `element(1,...)`, RDF `rdf:_1`, and Scala `_1`; **t** comes directly from the kernel grammar, so t1 is the first Term.

The names do not change the binary wire, where triples encode as positional tagged arrays. They apply consistently across the client API, engine, generated output, tests, and documentation. `TripleRow` and the `SPO`/`POS`/`OSP` tries remain private storage mechanics, but their three coordinates use the same t1/t2/t3 vocabulary.

Rejected bench:

- **zero-based slot vocabulary** — combines a packet-language word with array-offset indexing, a hybrid with no single tradition behind it.
- **`s0`/`s1`/`s2`** — an abbreviation that needs a correction sentence.
- **bare `0`/`1`/`2`** — ungreppable and unpronounceable in prose.
- **one-based slot vocabulary** — keeps the invented word while changing only the defensible part.

## profile — and the EAV reading — chosen 2026-08-04

The thing is the word for an optional, stored contract above the unchanged
kernel, and the role vocabulary of the first one. **Profile** follows the
standards prior (Bluetooth profiles, OWL 2 profiles): a named usage convention
that constrains and reads one substrate without changing it. The stored profile
kind named `"relational"` reads the positions as **entity (t1), attribute (t2),
value (t3)** — the database literature's EAV prior. The name is historical: the
kernel is already relational in the weaker formal sense of one recursive
ternary relation. Role words are profile vocabulary; kernel and wire vocabulary
stays t1/t2/t3.

Rejected bench:

- **world** — retired to the historical Worlds service; reuse reopens a settled verdict.
- **schema** — implies stored enforcement types the kernel refuses to own.
- **dialect** — implies a different language rather than a convention over one.
- **layer / mode** — generic altitude words, and mode reads as a runtime switch.
- **renaming the stored `"relational"` anchor to `"eav"`** — a stored-value migration purchasing a spelling; the reading is recorded instead.

## time lives in the log, not the Triple — architecture ruling — chosen 2026-08-04

The thing is where time attaches. A Triple is timeless structural content;
assertion time belongs to the occurrence's log coordinate, and any time that
must be domain data is another Term, per the
[glossary](glossary.md#semantic-kernel). Two priors decide it. Recursion: a
quoted Triple must be timeless, or `((a, :works-for, b), :supported-by, doc)`
cannot say which content it quotes. Nesting that inner Triple does not assert it
independently. Datomic's datom fuses `(e, a, v)` with `(tx, added)` and
therefore cannot nest, reifying statements as entities instead. Type–token:
separate occurrences keep equal propositions asserted independently as two
corroborating events, where Datomic elides the redundant datom. The accepted
cost is that as-of filtering rides snapshot machinery at the query boundary
instead of a time field in every index row.

Rejected bench:

- **datom-style fused tuple** — breaks quotation and collapses independent corroboration.
- **a fourth time position** — makes the arity a lie and assigns a kernel role to a position.
- **validity-interval fields** — closing an interval mutates history that must stay append-only.

## build-stage vocabulary at the Beagle seams — adopted 2026-08-07

The thing is the words store uses for Beagle's build stages, which cross the seam
as runtime string contracts with no compile-time coupling. Beagle decided them
and store follows in lockstep; reopening either word here would only desynchronize
a gate.

- **freeze / frozen** replaced seal/sealed for the build stage, on the
  `Object.freeze` prior: the mechanism is immutability after construction. The
  affected contracts are the accepted report line `stage source-freeze
  ACCEPTED` and the QBE frontier refusal `native program is not frozen:
  validation obligations failed`, whose ledger class key is
  `program-not-frozen`.
- **program** and **module-overlay** replaced the retired Worlds vocabulary,
  both in that refusal and at the authoring checker:
  `facts-check-overlay.rkt`, receipt key `overlayDigest`, rejection code
  `beagle-overlay-rejected`.

Beagle Store's own seal surfaces are a different subject and are untouched: sealed
epochs and range manifests (a ledger-sealing prior, see the
[glossary](glossary.md#storage-and-query)), the sealed graph-edit runtime, and
the migration seal. A build stage freezes; a range of history is sealed. Both
words keep their own prior.

## branch — chosen 2026-08-08

The thing is a named line of appends over a shared segment chain: forking one
names the parent's sealed segments plus a fresh tail of its own, and the two
lines then differ only in what they append afterwards. It promises no ordering
between branches and no merge. It is durable on-disk vocabulary — the
`store.branch` module, `<log>.refs/` and `<log>.branches/` beside the store, and
the `revision-ref/v1` and `branch-fork/v1` format tags.

This reverses the [world](#world--chosen-2026-07-26-retired-2026-08-07) bench,
which rejected **branch** as describing mechanics rather than what is branching.
That ruling was about a query-visibility scope. Here the mechanics are the
thing, and the git prior — a named ref into one shared immutable history that
diverges at a point — matches without a correction paragraph, so the former
collision is the alignment. Sealing a segment keeps store's existing
ledger-sealing prior, and **fork** stays the verb for the operation and never
names its result.

Rejected bench:

- **world**, bare **version** — retired 2026-08-07 and spent for new naming;
  the closed-wire `:rpc/version` operation remains live.
- **lane** — carries no prior about sharing history with what it came from.
- **timeline** — imports an ordering across branches that no branch promises.
- **line** — too weak to carry a module name and a directory name.

**main** names the branch whose tail is the store file itself and which is
therefore unnamed in `<log>.branches/`. **Reversed 2026-08-08, same day, by
operator call:** the original bench picked **default** over **main** on the
theory that a git-specific argument was a cost, not a prior; the operator
overruled that in favor of the git prior itself — a reader arriving at this
engine from git already expects a checkout's starting line to be called
`main`, and that expectation outweighs the naming-neutrality this module
otherwise wants. **root** still names a tree position the chain does not
have.

Rejected bench:

- **default** — rejected 2026-08-08; treated the git-specific argument for
  **main** as a cost rather than the deciding prior. No store has forked yet,
  so this reverses cleanly with no stored spelling to migrate.
- **master** — imports a git-specific argument this engine has no stake in
  beyond the starting-line prior **main** already carries.

Respelling any of these once a store has forked is a data migration, not a
rename.

## Appending an entry

Record the date, what the thing is (including what it does not promise), the prior that decided it, and each rejected candidate with one honest sentence. Reconcile superseded rulings in place and link the successor; never let obsolete vocabulary pose as current doctrine.
