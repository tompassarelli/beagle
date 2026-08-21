# Invalidation trace: native `let` evaluation-order change

All `beagle:` citations below are from the read-only checkout at
`~/code/beagle/main`. No build, test, compiler invocation, or access to
`/tmp/beagle-gate.lock` was performed.

## Chosen semantic change

Assume one native-profile rule change: strict `let` initializers change from
the current binding-vector order to right-to-left order. For example, in

```clojure
(let [a (effect-a) b (effect-b)] (use a b))
```

the accepted source form is unchanged, but the observable order of `effect-a`
and `effect-b` changes. The parser preserves binding-vector order: it consumes
the entries and reverses its accumulator in
`beagle:beagle-lib/private/parse.rkt:5098-5153`; the checker then walks those
bindings in list order while inferring each initializer and extending the
environment at `beagle:beagle-lib/private/check.rkt:6334-6373`. The hypothetical
change is therefore a native semantic-rule change, not a source-AST edit.

## Immediate finding: the requested miss lineage is not in current `main`

Current `main` contains no `FactMissEventV1`, `GateFactMiss`, or shadow-fact
implementation. That is a material negative finding: there are no current
shadow fact-store entries, no current `FactMissEventV1` miss path, and no
FactMissEventV1 lineage to invalidate or re-attest.

The live code has different, narrower artifacts:

- Code ingestion explicitly persists only AST propositions; `refers_to` and
  render markers are derived and not persisted at
  `beagle:store/bin/beagle-store-ingest-code:9-13`. Ingestion rebuilds a
  complete sibling FRAMLOG and atomically replaces the destination rather than
  appending a semantic miss record at `beagle:store/bin/beagle-store-ingest-code:201-243`.
- The FRI file is a disposable acceleration cache over the canonical
  TermStore/FRAMLOG, with a source `space-id`, fingerprint, and valid-byte
  position in `beagle:store/src/fri_port.bclj:1-31`. Opening it rejects a
  different space, source fingerprint/position, or payload checksum at
  `beagle:store/src/fri_port.bclj:541-560`; this is a source-cache miss, not a
  FactMissEventV1 lineage.
- The native query result cache is a runtime query-result cache. Its key is
  snapshot plus operation plus query digest at
  `beagle:store/src/store/native_query_ops.bgl:310-320`, and its miss path only
  increments a counter and returns an empty result at
  `beagle:store/src/store/native_query_ops.bgl:324-346`.

Consequently, “shadow fact-store invalidation” is not a current-main behavior;
it is an absent seam, not a selectively correct one.

## Artifact-by-artifact trace

### 1. Stored facts and their miss path

For the selected native-only rule change, the source AST and its persisted AST
propositions do not change. The FRI source binding therefore survives, which
is correct for a syntax/source cache but insufficient as a cache of native
semantics. If the source AST itself changes, ingestion rebuilds the complete
FRAMLOG and an old FRI image is rejected when its canonical-log fingerprint or
position no longer matches. Neither case produces a semantic miss lineage.

`source.facts` is also generated from the checked AST projection by the
projector invocation at `beagle:bin/beagle-build-core:620-646`; the native rule
is not an input to those source facts. Thus the facts survive the hypothetical
rule change, correctly as source data and wrongly if consumers treat them as a
native semantic attestation.

### 2. Source-unit semantic digests, read sets, and unit results

The source-stage schema has no native semantic-rule field. `SourceModuleV1`
stores source, checked-projection, and interface digests at
`beagle:native-core/src/native/stages.bclj:24-31`; `SourceUnitV0` stores a
semantic digest and source-unit read set at
`beagle:native-core/src/native/stages.bclj:33-40`. The source-fact slice merely
reads those supplied values: module receipts at
`beagle:native-core/src/native/slice.bclj:193-217`, and unit semantic digest plus
`semantic-read` edges at `beagle:native-core/src/native/slice.bclj:262-292`.

The dependency projection derives direct reads from source references and type
spellings and appends `semantic-read` rows at
`beagle:bin/beagle-build-core:1071-1135`. A native `let` evaluation-order rule
change changes none of those source facts, so:

- the affected unit's semantic digest survives unchanged;
- its direct read set survives unchanged;
- units that call it retain their read sets; and
- the source-stage/frozen-source digest remains unchanged because it is the
  content digest of the encoded source stage at
  `beagle:native-core/src/native/lower.bclj:565-588` and the encoding includes
  the unchanged unit fields at `beagle:native-core/src/native/stages.bclj:200-222`.

Those identities under-invalidate the new native semantics. They are identities
of source facts, not identities of the native rule set.

The unit wire payloads are content-addressed: typed-unit construction hashes its
encoding at `beagle:native-core/src/native/unit_reuse.bclj:1457-1470`, and
native-unit construction does the same at
`beagle:native-core/src/native/unit_reuse.bclj:1529-1542`. The payload digest
can therefore detect changed output bytes after recompilation, but it does not
make an old payload semantically stale by itself.

The dependency-context digest hashes only the contract digest for each source
unit in the read set at `beagle:native-core/src/native/unit_reuse.bclj:1544-1565`.
Because a `let` rule change changes neither a source read set nor a public unit
contract, this digest survives wrongly. The unit result key adds the unit ID,
source semantic digest, dependency-context digest, and a caller-supplied
`compiler-context-digest` at
`beagle:native-core/src/native/unit_reuse.bclj:1567-1577`.

That last component is the only possible selective escape hatch. The singleton
compiler rejects a stale requested semantic digest or read set and recomputes
the expected result key at `beagle:native-core/src/native/unit_compile.bclj:198-255`;
native compilation repeats the key check at
`beagle:native-core/src/native/unit_compile.bclj:328-415`. If the caller bumps
`compiler-context-digest` for the rule change, old unit results miss and can be
re-attested. If it does not, the unchanged source/dependency digests and
unchanged context produce the same key and an old typed/native payload can be
accepted.

This is not the production native cache path today. The unit files describe a
“Phase-D branch-reuse experiment” and keep ordinary whole-program passes
authoritative at `beagle:native-core/src/native/unit_reuse.bclj:1-4`; the
production compiler module list does not include either unit file at
`beagle:store/bin/beagle-store-native-build:388-400`. They are nevertheless
included in the broad compiler-input sweep under `native-core/src` at
`beagle:store/bin/beagle-store-native-build:368-390`.

### 3. Hosted module receipts

`checked-bundle.rkt` checks the closed source overlay using the hosted checker
at `beagle:beagle-lib/private/checked-bundle.rkt:302-353`. Its module receipts
contain authority, source ID, raw source SHA-256, interface SHA-256, and require
edges at `beagle:beagle-lib/private/checked-bundle.rkt:362-381`; the closure and
checked-bundle hashes cover that response at
`beagle:beagle-lib/private/checked-bundle.rkt:382-398`.

The native-only `let` rule does not alter source bytes, hosted checking, module
interfaces, or require edges. The hosted receipts therefore survive unchanged.
They remain valid hosted receipts, but survive wrongly if treated as evidence
that native evaluation order is still the same. Re-running the hosted checker
can re-attest the hosted contract; it cannot attest this native rule without a
native-rule identity being included in the attestation.

### 4. Whole-program native cache

This is the over-invalidating layer. The native builder hashes every file under
the compiler/toolchain roots, including `native-core/src`, into
`beagle_identity` at `beagle:store/bin/beagle-store-native-build:368-403`.
Changing the native `let` rule changes that identity even when only one unit is
affected.

`write_program_input_manifest` includes the builder identity, the complete
Beagle compiler identity, ABI, program scope, entries, and every source path and
source digest at `beagle:store/bin/beagle-store-native-build:539-558`. The
manifest is hashed into one program-cache directory at
`beagle:store/bin/beagle-store-native-build:1063-1070`, and a cache entry must
match that exact manifest at `beagle:store/bin/beagle-store-native-build:1182-1193`.

Therefore one native semantic-rule edit invalidates the entire cached native
program for the selected ABI/scope/entry set: every unit is rebuilt or the whole
program cache entry misses. This is over-invalidation relative to the actual
semantic cone of the changed `let` rule. It does not invalidate the AST fact
log, FRI source image, source-unit digests, or hosted receipts.

## Final classification

| Layer | Native `let` rule changes; AST bytes unchanged | Classification |
| --- | --- | --- |
| Persisted AST facts / FRI source image | Survive; FRI remains source-valid | Correct for source data, under-invalidating for native semantics |
| FactMissEventV1 / shadow entries | No current-main artifact exists | Missing implementation, not an invalidation result |
| SourceUnit semantic digest/read set | Unchanged | Under-invalidates |
| Dependency-context digest | Unchanged when contracts are unchanged | Under-invalidates |
| Unit result key | Misses only if caller bumps compiler context; otherwise unchanged | Conditional; context bump can re-attest |
| Hosted module receipts | Unchanged | Under-invalidates for native semantics, valid for hosted checking |
| Whole-program native manifest/cache | Changes through `beagle_identity` | Over-invalidates |
| Rebuilt native program/receipt chain | Recomputed under the new compiler identity | Correct re-attestation, but only at whole-program granularity |

The concrete answer to “what stops one AST change from invalidating the whole
stored-fact cache today?” is: nothing in current `main` provides semantic,
shadow-entry, or FactMissEventV1 locality. The persisted fact layer is separate
because it stores source AST propositions, while the native manifest is a
single compiler-wide closure key. A source-AST edit can cause a complete source
FRAMLOG replacement, FRI rejection, and a whole-program native miss; a
native-only rule edit leaves the fact and hosted layers unchanged but still
forces the whole native program cache to miss. Selective semantic re-attestation
exists only as a caller discipline through `compiler-context-digest` in the
experimental unit path, not as a current fact-store lineage.

INVALIDATION-TRACE-DONE — current-main trace completed from read-only source inspection; no builds or tests run.
