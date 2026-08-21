# ADVERSARIAL REVIEW 7 — CODE-AS-FACTS BLAST RADIUS

## Threat restated

The challenge is whether commit
`7c7522fe69270df71675947b5d3541b9c0514deb` prevents one changed core AST/type
node from invalidating every reusable stored gate fact. The answer is **no**.
The first cut has exact whole-repository source identity and exact-candidate
fact admission, but it has no semantic interface hash, no per-declaration
dependency graph, no reverse dependency cone, and no early cutoff. Any byte
change in any tracked file creates a new candidate root. Every gate claim embeds
that root. A cold query reads facts only from that exact root. Therefore every
current claim misses until it receives a new observation and candidate verdict.

The old facts are not deleted: Store facts are immutable. “Invalidated” here
means **ineligible for reuse by the changed candidate**. The measured reuse loss
is 102 of 102 current coverage claims for both a core type-AST change and an
unrelated leaf-module change.

## Evidence state

Implementation evidence is the detached exact commit above. The review read
the complete first-cut diff and executed the maintainer in
`~/code/beagle/worktrees/adv-blast`; no implementation or product change was
landed. The detached worktree was restored byte-for-byte after each mutation.

The real candidate contains 1,621 tracked files totaling 16,911,565 bytes. Its
active fact plan contains 102 `GatePhaseClaimV1` coverage facts: five top-level
gate phases and 97 active tier units. The denominator below is those 102 claims,
because the implementation creates one `FactMissEventV1` and one fallback
observation obligation per current claim.

Two attempts to populate the baseline through the complete old gate were
externally terminated with status 143. The first died in `consumer-smoke`; the
second died after 15 of 16 active-tier shards passed. Neither produced a gate
verdict, neither is called PASS, and no third flaky retry was made. To exercise
the hit/miss mechanism independently of gate runtime, a separate non-gating
experimental Store was populated with the actual 102 real-corpus claim
envelopes and explicitly controlled synthetic PASS observations. That seed is
evidence only for cache identity and lookup behavior. An identical cold
`shadow-prepare` then reported `misses=none retained=102 ... FULL`, proving the
seed reached the implemented hit path before either source mutation.

## 1. Fact identity: raw tracked bytes, then canonical envelopes

### Candidate identity

`source-entry` reads each selected file with `file->bytes`, records its byte
length, and hashes those exact bytes with SHA-256
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:223-231`). The importer
gets the path set from `git ls-files -z`, sorts it, and creates one source entry
for every tracked file that exists
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:238-254`).

The candidate root is SHA-256 over canonical EDN for this vector:

```text
GateCandidateIdentityV1
base commit
repository HEAD
importer
profile
source roots
all selected [logical-path byte-count raw-byte-sha256] entries
file count
byte total
```

That exact hashing call is
`beagle:beagle-lib/private/gate-fact-maintainer.rkt:260-271`; the resulting
root and the complete selected-file vector are stored in `GateCandidateV1` at
`beagle:beagle-lib/private/gate-fact-maintainer.rkt:272-281`. The envelope
schema confirms that `GateCandidateV1` carries the root, base/repository
revisions, importer/profile, source roots, selected files, file count, and byte
total (`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:101-142`).

No token stream, parsed AST, checked AST, type interface, elaborated interface,
or semantic-unit hash is consulted. A tracked search over the first-cut
maintainer, envelope, Store adapter, and gate wrapper has no `interface`,
`cone`, `transitive`, `semantic-unit`, or `unit-reuse` implementation path.

### Individual fact content addresses

Each fact ID is SHA-256 of the UTF-8 bytes of its complete canonical EDN
envelope, not a hash of a compiler object
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:422-453`). A Store entry
is exactly `[fact-id kind canonical-envelope-string]`
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:455-463`). The Store
adapter independently recomputes SHA-256 over the canonical envelope string and
rejects any mismatched fact ID
(`beagle:store/src/store/gate_facts.bclj:71-81`,
`beagle:store/src/store/gate_facts.bclj:102-119`).

Consequently:

- `GateCandidateV1` changes when any selected raw file byte, selected path,
  count, repository revision, importer, or profile changes.
- Every `GatePhaseClaimV1` changes when its embedded candidate root changes.
- Every observation changes because it embeds the changed claim ID.
- The candidate verdict and maintenance receipt change because they embed the
  candidate root and the new claim/observation links.

This is exact content addressing, but its semantic granularity is the complete
raw tracked tree.

## 2. Dependency edges and receipt: gate units, not program declarations

The first cut is keyed neither per source module nor per declaration. It creates
claims at two execution boundaries:

1. five top-level gate phases declared by `bin/beagle-test`
   (`beagle:bin/beagle-test:359-377`); and
2. active tier units emitted as `[unit-label unit-file unit-phase]`
   (`beagle:beagle-lib/private/tier-runner.rkt:1109-1132`). A unit can be one
   whole test module or one named phase within a test module.

A top-level phase claim has one nominal dependency,
`deadline-seconds:<value>`, while its `input-sha256` is the complete candidate
root (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:307-325`). A tier-unit
claim has nominal dependency strings `tier:<tier>`, `source:<test-file>`, and
`phase:<phase>`, but it also uses the complete candidate root as
`input-sha256`, and its claim ID hashes that root
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:340-380`). The claim
envelope merely stores those strings; it does not attach a content/interface
identity to the `source:` token
(`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:144-178`).

There is no dependency-cone computation. `analyze-coverage` iterates the flat
list of every current claim, finds a stored claim with the same `(scope,
label)` key, and decides that claim independently
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:404-405`,
`beagle:beagle-lib/private/gate-fact-maintainer.rkt:436-521`). It never walks
program reads, module imports, declaration uses, reverse edges, interface
consumers, or transitive closure.

There is also no cone receipt. `GateMaintenanceReceiptV1` contains:

- receipt ID, candidate root, verdict ID;
- all claim IDs and observation IDs;
- miss-to-fallback links;
- status counts and miss-class counts;
- scalar `retained`, `rechecked`, and `missed` counts; and
- fixed `SHADOW`, `0`, `UNPUBLISHED` markers.

Those are the exact fields at
`beagle:beagle-lib/private/gate-fact-envelope-v1.rkt:297-347`. It contains no
changed declaration IDs, dependency edges, invalidated cone, retained semantic
units, interface hashes, or cutoff decisions. `shadow-finish` sets `rechecked`
to the complete claim count regardless of diagnostic hits
(`beagle:beagle-lib/private/gate-fact-maintainer.rkt:891-903`).

## 3. Exact hit-versus-miss path: exact source root, no early cutoff

The path for one candidate is:

1. `shadow-prepare` derives the raw whole-tree candidate root and recreates all
   current claims with that root
   (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:587-605`).
2. It imports the candidate and claims, then cold-queries the Store for that
   exact candidate root
   (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:604-617`).
3. Store propositions are physically qualified by `(candidate-root, fact-id)`;
   `facts-for` returns only propositions whose subject carries the requested
   candidate root (`beagle:store/src/store/gate_facts.bclj:121-171`).
4. `cold-query!` opens that route and refuses it unless a `GateCandidateV1`
   exists under that exact root
   (`beagle:store/src/store/gate_facts.bclj:463-475`). Facts under the prior
   candidate root are not candidates for matching.
5. For each current claim, `analyze-coverage` checks, in order: unknown kind,
   substituted/stored policy, omitted dependencies, matching claim presence,
   policy equality, dependency containment, complete claim equality, prior red
   observations, and finally whether an admitted PASS verdict links this exact
   claim ID to a PASS observation under the same verifier and policy
   (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:426-434`,
   `beagle:beagle-lib/private/gate-fact-maintainer.rkt:480-507`).
6. If no such linked verdict exists, the claim is `absent`; every miss is
   durably written before fallback
   (`beagle:beagle-lib/private/gate-fact-maintainer.rkt:508-521`,
   `beagle:beagle-lib/private/gate-fact-maintainer.rkt:618-648`).

An identical candidate hits because it regenerates the identical root, claim
IDs, observation IDs, and verdict links. Any tracked source-byte change creates
a new root. `shadow-prepare` imports fresh claims under that root, so the claims
themselves exist, but there are no observations or verdict for them. The final
branch is therefore `absent` for every claim. No code compares an old and new
dependency interface, and no code can stop propagation when an interface is
unchanged.

Even a diagnostic hit does not skip work in this cut. The wrapper explicitly
says a hit is diagnostic and invokes the old gate with its result cache disabled
(`beagle:bin/beagle-test-facts:60-75`,
`beagle:bin/beagle-test-facts:90-104`).

## 4. Measured experiment

### Controlled baseline

Baseline exact candidate:

```text
commit          7c7522fe69270df71675947b5d3541b9c0514deb
candidate root  sha256:90c160ab5f50374442a489fcfe0258402c150166a522606106a885b0304f8e2a
tracked files   1,621
tracked bytes   16,911,565
claims          102 = 5 phase + 97 active tier-unit
cold reopen     misses=none retained=102 coverage=FULL
```

The cold reopen is from the explicitly controlled non-gating PASS seed
described above. It establishes that all 102 baseline claims were present and
reusable before mutation.

### Core type-AST mutation

One line in `beagle:beagle-lib/private/types.rkt:49` changed from:

```racket
(struct type-prim  (name)                      #:transparent)
```

to:

```racket
(struct type-prim  (name)                      #:transparent #:authentic)
```

The valid mutation compiled through the pinned 201-module Racket closure. The
file SHA-256 changed from
`65bac5314ab4974bf54848914bef57ab2b972f4eb276436c359a5b4021389679` to
`08835dc5d11cb225a6bc7ef336c929ee4885a0bbbdda0539ac72fa1b14c69507`.

Measured maintainer result:

```text
candidate root  sha256:494606b9a41ae898efa2918730a99c80dd7ab6554b26cb5b62e1410a971141a5
miss class      absent
retained        0
missed          102
denominator     102
cascade         102/102 = 100%
```

### Leaf-module mutation

After restoring the core file byte-for-byte, one unused private definition was
added after `beagle:beagle-test/tests/license-metadata.rkt:11`:

```racket
(define blast-radius-leaf-probe #t)
```

The valid leaf mutation also compiled through the pinned closure. The file
SHA-256 changed from
`32ef0b0eb471b6b3e5597922ddf7d8fdff063bc05dddf64764c52491c538d999` to
`05c5f4cff40b4972bd0d89c86730db255246b4d68d293a193a5a17b4dd442d9f`.

Measured maintainer result:

```text
candidate root  sha256:a2310d75b5983e0fe285d5add64f30ff92ccbc38b61e1c7fcafa1abd2745cb68
miss class      absent
retained        0
missed          102
denominator     102
cascade         102/102 = 100%
```

The contrast is exact: core and leaf locations are indistinguishable to this
cache. Both are one changed raw tracked file, so both generate a new whole-tree
root and lose every prior coverage fact.

### Exact miss inventory for both mutations

Both changed candidate roots missed the same 102 claims below. The first five
are top-level phase claims; the remaining 97 are active tier-unit claims.

```text
checkout-first
consumer-smoke
qualified-ref-scaffold
racket-scope
tier-runner
check.rkt
definition-inference.rkt
effective-signature-publication.rkt
daemon-effective-signatures.rkt
binding-constraint-check.rkt
binding-constraint-interface.rkt
scratch-containment-test.rkt
build-edn-datum-ir.rkt
cheatsheet.rkt
docfill.rkt
wasm-materializer.rkt#wasm-bootstrap-emits-a-r-eb4d66
wasm-materializer.rkt#multiple-arena-bearing-e-6a5145
wasm-materializer.rkt#entries-that-flatten-to-057b8d
wasm-materializer.rkt#missing-supported-enviro-4b6109
wasm-materializer.rkt#compiler-failure-remains-6c9aea
wasm-materializer.rkt#compiler-timeout-owns-an-10142c
wasm-materializer.rkt#runtime-timeout-owns-and-1989ce
wasm-materializer.rkt#provenance-splice-matrix-79516a
wasm-materializer.rkt#publication-failpoints-n-73fa24
wasm-materializer.rkt#core-publication-preserv-db27b4
wasm-materializer.rkt#generation-verifier-dete-579176
wasm-materializer.rkt#tool-resolver-timeout-re-169242
wasm-materializer.rkt#seam-validator-timeout-o-0d50b6
wasm-materializer.rkt#entry-validator-timeout-c5fc3e
wasm-materializer.rkt#entry-contract-matrix-re-4ada49
wasm-materializer.rkt#strict-source-entry-abi-7f42c4
wasm-materializer.rkt#unsupported-callable-ent-d4bc24
wasm-materializer.rkt#supported-toolchain-buil-cfd33d
wasm-materializer.rkt#runtime-io-surface-drive-7c1cab
wasm-materializer.rkt#residual
native-simd.rkt
native-c17-parallel.rkt
facts-render-roundtrip.rkt
gate-fact-maintainer.rkt
code-as-facts-rename.rkt
cross-module-dynvar.rkt
export-xmodule.rkt
ts-externs.rkt
variant-xmodule.rkt
generic-type-arity.rkt
scrutinee-narrowing.rkt
module-source-root.rkt
module-overlay-check.rkt
checked-bundle.rkt
defmacro.rkt
diagnostic-kind.rkt
expand-tool.rkt
error-explanation.rkt
exhaustive-match-fix.rkt
repair-apply.rkt
expected-errors.rkt
macro-eval.rkt
syntax-match.rkt
second-order-contracts.rkt
lint.rkt
license-metadata.rkt
lsp-effective-signatures.rkt
macro-hygiene.rkt
scope-resolve-spike.rkt
parse.rkt
annotation-parse.rkt
annotation-printer.rkt
annotation-macros.rkt
purity.rkt
purity-consumers.rkt
quasi-quote-reader.rkt
reader-conditionals.rkt
reader-path-parity.rkt
reader-shorthand.rkt
rewrite-roundtrip.rkt
semantic-index.rkt
signature-format.rkt
sourcemap-fidelity.rkt
syntax.rkt
test-tags.rkt
threading.rkt
threading-marker.rkt
repl.rkt
type-inference-core.rkt
type-view.rkt
types.rkt
emit-nix.rkt
nix-emit-errors.rkt
nix-lints.rkt
nix-parse.rkt
nix-roundtrip.rkt
nix-import-roundtrip.rkt
validate-nix.rkt
check-all-nix.rkt
build-all-nix-reader.rkt
emit.rkt
emit-clj-behavioral.rkt
emit-matrix.rkt
query.rkt
conformance.rkt
rep-soundness.rkt
emit-js-behavioral.rkt
```

Every one missed for the same reason: its changed candidate-root claim had no
linked observation and admitted PASS verdict inside the new exact-root Store
view. None missed because the implementation found a semantic dependency from
the edited declaration or module.

## 5. Verdict

**REAL GAP — NO BLAST-RADIUS BOUND EXISTS IN THE FIRST CUT.**

The exact mechanism preventing a core change from cascading does not exist.
The implemented mechanism is the opposite: one raw whole-tree candidate root
is embedded into every claim and is also the Store query partition. Therefore
any tracked byte change—core type definition, leaf module, comment, formatting,
fixture, generated tracked output, or documentation—makes all prior claim
observations and verdicts ineligible for the new candidate.

Measured on the real 102-claim active corpus:

```text
core type-AST change: 102 invalidated of 102 = 100%
leaf module change:   102 invalidated of 102 = 100%
```

The first cut succeeds at exact identity, durable miss-before-fallback, cold
reopen, and shadow parity. It does not implement the operating model's
per-declaration or interface-bounded invalidation semantics. Its retained count
is useful only for an identical raw tree.

## 6. Banked hardening plan

No code landing is authorized by this review. The minimal closing design is a
V2 structural/nominal split grounded in the existing Store types.

### A. Separate exact source identity from reusable semantic identity

Keep `GateCandidateV1` (or a V2 successor) as the exact authored-byte and Git
provenance root. Stop using that root as every claim's semantic
`input-sha256`.

Mint compiler-native facts per declaration/analysis unit:

```text
SemanticUnitV2
  stable subject identity
  canonical parsed/checked definition identity
  implementation/body hash
  exported interface hash
  proof/effect hash
  source occurrence/provenance ID
```

The implementation hash changes for a body edit. The interface hash contains
the normalized exported name, effective type/signature, constraints, effects,
and representation/ABI contract that consumers actually consult. Formatting,
span, and raw source revision stay in occurrence/provenance facts and do not
change semantic identity when canonical meaning is unchanged.

### B. Replace nominal dependency strings with content-qualified read edges

Persist one direct edge per observed compiler/test read:

```text
DependencyEdgeV2
  consumer claim/unit ID
  provider semantic subject ID
  use kind = body | interface | macro | fixture | toolchain | policy
  exact consulted fact ID
```

The existing `source:<file>` string may remain human metadata, but it cannot be
the proof edge. A claim's derivation/input ID is the canonical ordered manifest
of the exact unit bodies, provider interfaces, fixtures, verifier, toolchain,
environment profile, and policy it consumed.

### C. Permit cross-candidate reuse in the existing Store

`FactRoute` may continue to select the experimental Store/Space, but
`facts-for` must no longer make candidate root the only lookup partition for
reusable claims. Store immutable facts globally by fact ID; add snapshot
membership edges from each candidate root to its current facts. Query prior
observations by stable claim ID plus exact derivation/input-manifest ID, then
bind the retained result into the new snapshot. Candidate root remains
provenance and publication identity, not a universal cache key.

This is a narrow evolution of the current `FactEntry` and triple substrate:
the envelope remains content-addressed; only subject routing and claim input
identity change.

### D. Implement interface-hash early cutoff

For each changed source projection:

1. parse/check only the changed declaration/module enough to produce new
   implementation and interface facts;
2. invalidate the changed unit's body consumers when its implementation hash
   changes;
3. compare its old and new interface hashes;
4. if the interface hash is equal, stop—do not enqueue interface consumers;
5. if it differs, traverse the reverse index of direct interface consumers;
6. re-derive each reached consumer, and stop again wherever that consumer's
   exported interface remains equal; and
7. keep whole-repository input only for claims whose reads are not yet
   observable; label them conservative instead of pretending they are exact.

A truly ubiquitous core interface change may still invalidate most claims.
That is an honest dependency cone. A core body change with a stable interface,
or an unrelated leaf body change, must not invalidate unrelated consumers.

### E. Make the receipt explain the cone

Add to `GateMaintenanceReceiptV2`:

- previous and candidate snapshot IDs;
- changed source revisions;
- changed semantic subjects with old/new body and interface IDs;
- direct edge/use kind that admitted every traversal step;
- exact invalidated and retained claim IDs;
- each early-cutoff decision and equal interface ID;
- conservative whole-tree claims and why they remain coarse; and
- re-derived facts, rechecked claims, reused verdicts, and rejected-reuse
  reasons.

Scalar totals remain useful, but they are not a cone proof.

### F. Deciding acceptance matrix

Before V2 can skip work, cold-reopen tests must prove:

| Mutation | Required result |
| --- | --- |
| whitespace/span-only edit | source occurrence changes; semantic unit/interface and unrelated claims retain |
| core body edit, stable interface | changed unit body claims miss; interface consumers retain |
| core interface edit | exact reverse interface cone misses; unrelated claims retain |
| leaf private body edit | leaf claim and actual body consumers miss; core/unrelated claims retain |
| macro definition edit | exact expansion call-site cone misses |
| fixture/toolchain/policy edit | only claims naming that exact input miss |
| deliberately omitted read | certification fails before reuse |

For the same 102-claim corpus, rerun the two mutations in this review and
publish the exact non-100% cone or an honest proof that the core interface is
actually consumed by every claim. Any unexplained retained claim is a
correctness failure; any unexplained whole-corpus miss is a blast-radius
failure.

FACTS-ADV-A-DONE — first-cut blast radius is 102/102 (100%) for both core and leaf changes; no interface cutoff exists.
