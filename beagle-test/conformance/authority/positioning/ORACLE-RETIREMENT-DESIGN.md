# Beagle Racket-oracle retirement design

## Status and scope

This is a design for the end state in which the Racket compiler is no longer
a production route. It is **DESIGNED**, not implemented or proven. No gate
receipt, pin, corpus runner, Nix closure, or recovery-host drill is created by
this document.

The accepted starting facts are recorded by the commander verification and
are cited here rather than re-derived:

- The current bootstrap path is the checked-in Babashka seed, the GraalVM
  native stage0, and the pinned Racket oracle, with native = seed = Racket
  three-way parity enforced in CI: `beagle:beagle-test/conformance/authority/positioning/ADVERSARIAL-REVIEW-7-BOOTSTRAP.md`
  Findings A and B, and `beagle:beagle-test/conformance/authority/positioning/SELFHOST-ROADMAP.md`
  sections “What the seed proves” and “Oracle, remint, and tooling”.
- B-1 through B-3 already require two independent recovery pins, a bounded
  current-HEAD canary, a release record, and a drill-proven incident runbook:
  `beagle:beagle-test/conformance/authority/positioning/FACTS-PRE-FLIP-REQUIREMENTS.md`
  sections B-1, B-2, and B-3.
- The three verified open gaps are oracle decay, a canary limited to the
  closed self-host bundle while Core/native linking/Wasm remain Racket-owned,
  and recovery hosts with no proven runtime availability:
  `beagle:beagle-test/conformance/authority/positioning/ADVERSARIAL-REVIEW-7-BOOTSTRAP.md`
  Finding C.

The retirement bar is conjunctive. The Racket route remains available until
the frozen-reference seal, corpus authority, full canary scope, recovery
runtime closure, parity, and every host-leakage gate below have future receipts
with status `PASS`. Writing this design cannot make any of them pass.

## Rulings

### 1. The last Racket compiler is a frozen reference oracle

The last authoritative Racket compiler is the exact sealed Beagle v0.24.0
commit. Its full Git object ID is recorded in the release seal and checked out
as a detached, hash-named pin under the repository pin law:

```text
beagle:pins/<full-v0.24.0-sealed-object-id>/
beagle:pins/<full-v0.24.0-sealed-object-id>.pin
```

The pin is clean, immutable, and never advanced in place. Its sidecar names
the real repository consumers with one `consumer-main:` record per consumer.
The release record names the same object ID, sidecar digest, and consumer set.
The exact object ID is intentionally not invented in this design; it must be
copied from the sealed v0.24.0 release record when the gate is implemented.

The oracle is hermetic under Nix. The frozen materialization records the Nix
input lock, Racket/toolchain closure, platform/profile identity, and the
content digest of the materialized oracle. A recovery or parity invocation may
use only that declared closure and the pinned source; ambient Racket libraries,
user profiles, network fetches, and the current Beagle checkout are not inputs.

The pin is a **reference oracle**, not a maintained implementation. It is
retained for historical comparison, recovery evidence, and audits of the
frozen surface. It is not promoted, feature-fixed, or used as a second
production compiler after retirement.

This follows the content-addressed, exact-commit posture of the compiler
materialization and release-seal records in
`beagle:beagle-test/conformance/authority/positioning/EPOCH-ROLL-DESIGN.md`; those records
are evidence patterns for this design, not proof that this design is built.

### 2. Authority decays and never backports

The frozen oracle is authoritative only for the semantic surface sealed by
v0.24.0. It is **SILENT** on semantics introduced after that seal. A later
compiler may not ask the oracle to decide a new form, a changed error, a new
numeric rule, or a newly observable ordering.

New semantics enter through an explicit, owned conformance case with a stated
rule, expected outcome, and corpus review. A parity comparison can expose a
disagreement, but it cannot decide which behavior is correct. Backporting a
later feature or semantic repair into the frozen oracle is forbidden. This
prevents parity zeal from resurrecting the oracle as a second production
compiler and makes its authority monotonically decay as the language grows.

### 3. The living oracle is the conformance corpus, not a second compiler

The frozen pin plus a living implementation-independent conformance corpus is
sufficient; a maintained second compiler is not a retirement prerequisite.

That decision has a strict condition: the corpus must be authored as language
contract evidence, not mined from seed, native, or Racket output. The corpus is
the living independent oracle because its expected semantics are explicit,
reviewed, versioned, and executable without invoking any compiler. If a case
has no decided rule, the language surface is not retired into production.

A second implementation may still be used for a bounded audit or research
comparison, but it is optional and carries no authority merely by agreeing
with Beagle. Maintaining one solely to preserve the appearance of diversity
would recreate the retirement problem with another implementation lineage.

## Conformance corpus

### Corpus artifact

The retirement artifact is a content-addressed `BeagleConformanceCorpusV1`
manifest plus its immutable case payloads. Each case has, at minimum:

| Field | Required meaning |
| --- | --- |
| `caseId` and corpus version | Stable identity of the case and the manifest that owns it. |
| Source/request bytes | Exact source, command/profile, target, and input closure; no ambient checkout files. |
| Decided rule | Plain-language semantic rule and the named error vocabulary, if rejection is the rule. |
| Expected assertion | Canonical result, diagnostic/error core, emitted artifact digest, accepted outcome set, or explicit divergence. |
| Coverage labels | Surface, host-leakage gate, ALARM-BELL class, and parity channels covered. |
| Decision authority | Language-contract owner, independent reviewer, decision reference, and decision date. |
| Implementation observations | Optional seed/native/Racket outputs, stored as evidence and never as the decision. |

Cases are `DECIDED` only when the rule and expected assertion are present.
`UNDECIDED`, `IMPLEMENTATION-OBSERVED`, `INFRASTRUCTURE-FAILURE`, and
`DISPUTED` cases do not satisfy a retirement gate. A case may deliberately
assert a rejection or a bounded set of allowed outcomes; it must not use
“whatever the host returns” as its expected assertion.

The corpus includes every required ALARM-BELL case from
`beagle:beagle-test/conformance/authority/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`:
each Clojure-shaped form whose observable semantics diverge has a case that
asserts the divergent behavior and its explicit error vocabulary. E003's
union-alias versus nominal distinction and the namespace-not-path emission
break are seed cases for this class, not exemptions from it. The two-regime
rule also remains binding: the Store is the heap for durable semantic state,
while Native Core owns bounded transient execution.

### Ownership and admission

The corpus is owned by the language-contract authority, not by the seed
remint or native-image producer. A compiler implementation may propose a case
or an observed counterexample, but it cannot self-approve the rule or replace
the expected assertion with its own output. A corpus change is a semantic
contract change: it gets a new manifest digest and an explicit decision record.

The smallest admission check for a corpus revision is a pure manifest verifier:
it rejects missing decisions, duplicate case IDs, missing expected assertions,
unresolved ALARM-BELL labels, and cases whose expected assertion was declared
as an implementation observation. It also proves that each release-required
surface and each host-leakage gate maps to at least one `DECIDED` case.

### Relation to existing parity

Before retirement, the existing three-way evidence remains valuable:

```text
frozen Racket oracle  =  checked-in Babashka seed  =  native stage0
```

It proves agreement among implementations for the exact channels and cases it
compares. It does not decide semantics, cover channels it did not run, or
remain authoritative for later language changes. The retirement receipt must
bind every parity observation to the exact frozen pin, seed artifact, native
artifact, corpus manifest, source closure, and compared channel.

After retirement, the routine gate is native stage0 and its Racket-free seed
against the decided corpus. Frozen-oracle parity becomes an infrequent,
quarantined reference operation over the frozen surface; it is never required
for a later semantic case. Matching seed/native/Racket behavior is never a
substitute for a decided corpus case.

## Parity and retirement seal

The future retirement receipt must prove, for the exact candidate commit:

1. The v0.24.0 oracle pin is the exact frozen object, clean, hash-named,
   sidecar-consumed, and Nix-hermetic.
2. Every required case is `DECIDED`, including all ALARM-BELL and
   host-leakage cases. No semantic surface is admitted solely by an old
   parity label.
3. Native stage0 and the checked-in seed agree on every declared output,
   diagnostic, status, and artifact channel in the corpus and release
   profile.
4. Before the route is removed, native, seed, and the frozen Racket oracle
   agree on the frozen v0.24.0 surface wherever the corpus declares that
   surface comparable.
5. Both retained recovery pins pass the expanded current-HEAD canary,
   including the Racket-owned product surfaces named below, or the release is
   refused.
6. A clean recovery host can materialize and invoke the declared seed and
   oracle runtime closures without ambient runtimes.
7. Every host-leakage gate below has a `DECIDED` case and a passing future
   check. There is no waiver for an unclassified or unspecified behavior.

The seal is a one-way authority transition. It demotes Racket from a compiler
route to a frozen reference artifact; it does not delete the pin, rewrite its
history, or add a compatibility route that silently restores production Racket.

## Host-leakage gates

Each row is a named **pre-retirement gate**. “Decided rule” is the normative
contract that must be written into the corpus. The “smallest deterministic
FUTURE check” is the minimum check that can make that rule admissible; none of
these checks has been run by this design task.

| Gate | Decided rule | Smallest deterministic FUTURE check |
| --- | --- | --- |
| `HL-NUMBER-SEMANTICS` | Every numeric domain, conversion, comparison, overflow/underflow, non-finite value, and serialization behavior is explicit in Beagle's contract. Host number promotion, rounding, overflow, or printer behavior is never normative by accident. | One corpus case containing the boundary vector for each admitted numeric domain and operation; compare the canonical result or named error to the decided assertion, including the serialized form. |
| `HL-EQUALITY-HASHING` | Beagle defines equality and hashing over its semantic values. Host identity, pointer identity, mutable-host equality, and accidental cross-domain equality cannot enter the contract; equal values must have equal hashes, while hash collision is not equality. | One case builds equal and unequal atoms, symbols, collections, and cross-domain lookalikes, then checks equality, hash invariant, and key lookup against the canonical assertion. |
| `HL-SYMBOL-BEHAVIOR` | Symbol name, qualification, interning/identity, comparison, read form, and print form are explicit Beagle behavior. Host symbol interning and namespace representation are not inherited silently. | One case constructs repeated, qualified, unqualified, and lookalike symbols, round-trips their canonical representation, and checks the decided identity/error result. |
| `HL-TRUTHINESS` | The truth table is a Beagle rule: every admitted value category is explicitly true, false, or a typed error. Host truthiness is not a fallback for an omitted case. | One corpus truth-table case covers the empty, zero-like, collection, symbol, null-like, and ordinary value categories present in the language and compares branch results to the decided assertion. |
| `HL-COLLECTION-ORDERING` | An order is observable only where the contract declares it. Ordered collections have declared order; unordered collections have canonical serialization or an explicit unordered assertion. Host hash-table or set iteration order cannot become a semantic digest. | One case inserts the same entries in multiple permutations and checks iteration, rendering, hashing, and emitted artifact identity against the declared ordered/unordered result. |
| `HL-NATIVE-CORE-GC-OWNERSHIP` | GC timing, finalization, weak references, host object addresses, and collector reachability are not semantic ownership. Native Core explicitly owns transient values until promotion; durable Store values contain copied semantic data, never transient pointers or GC assumptions. | One controlled ownership fixture forces collection and allocation pressure immediately before and after promotion, then verifies the same canonical promoted value and artifact with no lifetime-dependent result. |
| `HL-HOST-MACRO-EXPANSION` | Macro expansion follows Beagle's lexical scope, phase, capture, generated-name, metadata, and error contract. Racket/host macro expansion, syntax properties, phase inheritance, and evaluation order are evidence only, never an inherited specification. | One corpus macro case exercises capture/shadowing, generated names, and phase visibility, then compares the canonical expansion or named error rather than accepting the host expansion because it matches. |
| `HL-UNSPECIFIED-BEHAVIOR-AS-SPEC` | “Unspecified” is not an unrecorded language rule. Each such point is canonicalized, rejected with a named error, or given an explicit finite allowed-outcome set with the observable nondeterminism documented. | One perturbation case runs the same input under two controlled legal allocation/order seeds and proves identical canonical output, the named error, or membership in the explicitly declared outcome set. |

Retirement is barred until every row has both a concrete decided corpus rule and
its passing future receipt. A row marked “host-compatible”, “matches Racket”,
or “not observed in parity” is not a pass.

## Resolution of the three verified gaps

### Oracle decay

The frozen pin plus corpus is the chosen resolution; a living second compiler
is not required. The pin preserves implementation diversity for the sealed
surface, while the corpus preserves living semantic diversity for all future
surfaces. The independence boundary is explicit: expected assertions are
language decisions, and implementation output is attached only as observation.
If the corpus cannot decide a behavior independently, that behavior remains
outside the production language and blocks retirement.

### Canary scope

The canary is extended rather than narrowed. B-1's closed self-host bundle
check remains, and each retained pin must additionally exercise the current
HEAD fixtures for:

- Core compilation, with a canonical Core/module digest;
- native executable linking, with a platform-qualified artifact manifest and
  deterministic link verdict; and
- the Wasm materializer, with canonical Wasm bytes or a defined section-normalized
  digest.

The canary runs the currently supported route for each surface. While Core,
native linking, and Wasm are Racket-owned, that means the pinned Racket route
must pass them. Once a replacement route exists, the same cases must pass
through the replacement before the corresponding Racket route may retire. A
closed-bundle-only pin receipt cannot satisfy this gate.

### Recovery-host runtimes

“A pin exists” is not runtime availability. Each retained recovery pin and the
frozen oracle pin must name a Nix recovery profile whose realized closure
contains every runtime needed by its supported route. If the seed route needs a
JVM, the profile contains the pinned JVM and seed runtime; if the Racket route
is supported, the profile contains the pinned Racket environment. The release
record carries the closure identity and the offline materialization source.

The future recovery-host gate starts on a clean host with Nix and the declared
closure/pin inputs only. It materializes the profile, performs runtime version
and closure checks, and runs the bounded closed-bundle recovery canary plus the
expanded Core/link/Wasm cases. An ambient JVM, ambient Racket installation, or
network success cannot satisfy the gate.

## Honest status and explicit deferrals

**DESIGNED:** the v0.24.0 frozen-pin rule; decaying authority; the
implementation-independent corpus; the relationship between corpus decisions
and three-way parity; the full-scope canary; recovery-host runtime closure;
and all eight host-leakage gates.

**NOT PROVEN:** the v0.24.0 object ID has not been recorded here; no immutable
pin or sidecar was created; no Nix oracle/recovery closure was materialized;
no corpus manifest or ALARM-BELL cases were admitted; no expanded canary or
host-leakage check ran; and no Racket-removal receipt exists. The cited
bootstrap findings remain the starting evidence and are not newly verified by
this document.

**Explicitly deferred:** implementation of the corpus schema and runner;
assignment of the language-contract authority and review workflow; the exact
semantic vectors and expected assertions for cases not yet decided; artifact
distribution and offline Nix-cache operations; the post-retirement audit
cadence for the frozen oracle; and implementation of Racket-free Core, native
linking, Wasm, and remaining tooling. Each deferred item that is required by a
gate blocks retirement until resolved; none is silently treated as green.

ORACLE-RETIREMENT-DESIGNED
