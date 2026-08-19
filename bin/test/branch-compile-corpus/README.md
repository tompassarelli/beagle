# Branch compilation corpus oracle

This directory contains the Phase-C clean-build oracle and the compiler-owned
Phase-D unit seam for the bounded branch-native experiment, plus the Phase-E
lossless unit-wire checkpoint. It supplies four Native Core modules, three
controlled mutations, and an independent clean full-build oracle. It does not
add a cache or Beagle Store integration.

`TypedUnitV0` and `NativeUnitV0` now persist under the distinct
`typed-unit-wire-v1` and `native-unit-wire-v1` tags. The bounded codec binds
every semantic field of the corpus variants, strictly reconstructs one complete
canonical string, and requires exact UTF-8 byte count, SHA-256, unit identity,
record validation, and re-encoding before assembly. Old `typed-unit-v0` and
`native-unit-v0` payloads are deliberately non-decodable because their nested
encoders omit switch cases and token flow. Strict Base64 and UTF-8 decoding
remain the responsibility of the future projection boundary; this unit-local
seam consumes the resulting canonical string and its raw-byte metadata.

The corpus has two dependency arms:

```text
corpus.foundation/private-offset -> corpus.foundation/adjust
  -> corpus.feature/score-value -> corpus.app/run-score

corpus.foundation/double-value -> corpus.feature/stable-score
  -> corpus.app/run-stable

corpus.independent/independent-value -> corpus.app/run-independent
```

`units.tsv` declares the exact direct semantic read set. `expected-cones.tsv`
freezes the branch-compilation contract: module + definition kind/name owns
unit identity; exact source hashes remain provenance; a private body edit
changes only that unit's typed/native content; and a public signature edit
invalidates its exact direct consumer until an unchanged interface stops
propagation.

The three cases are deliberately narrow:

- `comment-layout` adds one comment and expands one signature layout.
- `private-implementation` changes one literal in `private-offset`.
- `public-interface` adds one `Int` parameter to `adjust` and updates only its
  direct consumer, `score-value`, while preserving behavior with a zero value.

`run.sh` copies each case into the same ignored, fixed logical source path,
then runs `beagle ast-bundle` and a fresh full Native Core build with C17. Every
case has explicit deadlines and visible start/end progress. A second baseline
build must be byte-identical at every recorded identity. In check mode the
focused unit gate then extracts exact compiler payloads, selects the expected
9/9, 8/9, and 7/9 reuse sets, and assembles each candidate independently.

The tracked oracle records:

- exact module source and true module-interface-v9 digests from `ast-bundle`;
- emitted semantic-unit IDs, provenance-free content digests, and resolved
  direct read sets from `source.facts`;
- source, typed, native, and epoch frozen-stage digests;
- actual compiler-emitted `NativeId` values for every reachable function;
- a harness-only SHA-256 of each canonical `native-function-v0` encoding, which
  observes the bytes currently published for a function but is not presented
  as a complete content or cache identity; and
- exact `source.facts`, frozen program, entry map, and C17 artifact hashes.

QBE is not silently treated as another successful oracle. Its current
materializer refuses ordinary `CallInstruction`s, so it cannot consume this
dependency-bearing corpus. The later C17/QBE differential therefore remains an
explicit upstream materializer gap rather than pressure to erase the calls that
make the invalidation experiment meaningful.

Receipt and generation hashes are written to the ignored `context.tsv`, not the
tracked oracle, because they bind the Git commit that names the build and would
make a file inside that same commit self-referential. The frozen stages and
program-specific artifacts remain the comparison surface.

Run the existing current-behavior oracle with:

```text
beagle:bin/test/branch-compile-corpus/run.sh --check
```

`--observe` performs the same bounded clean builds but leaves the observed TSVs
under `beagle:.beagle/branch-compile-corpus/` without comparing the tracked
current-behavior snapshot. This is the only recording route; there is no
incremental adapter or mutation cache hidden in the harness.

`expected-boundaries.tsv` actively checks the exact changed source and true
interface modules. `units.tsv` actively checks every emitted unit kind and
resolved direct read set in every case. The typed/native rows of
`expected-cones.tsv` actively check the exact changed semantic-content set,
and every mutation must preserve every semantic-unit ID. The unit gate now
checks the corresponding assembled reuse rows, exact clean typed/native/epoch
and C17 bytes, all ten obligations, all nine typed/native wire-v1 round trips,
the V0 semantic-collision witness, malformed/digest/order/identity/duplicate
falsifiers, collision rejection, and the nine-`defn` boundary. The tracked
`oracle/churn.tsv`
describes clean-full-build output; the gate is still a bounded compiler seam,
not a production incremental cache.

## Current verdict

The oracle was re-minted to carry the v9 module interface schema introduced by
`55f3fbe848fdfd19a733e13c5e66ff66cacb44b0`, which raised
`INTERFACE-SCHEMA-VERSION` from 8 to 9 and added an effects field to every
interface binding. The schema version is bound into the interface digest and
every module publishes bindings, so every module's interface digest moved and
carried the derived stage, bundle, `source.facts`, and frozen native-program
digests with it. Module sources, semantic-unit identities, contents and read
sets, function identities and encodings, and the emitted C17 were all
unaffected.

The three assertions below are unchanged from the original measurement at
`b63f8f0a43391541598eac77d0830370c799a335`: `churn.tsv` — which case changes
which identity — is byte-identical across the re-mint, so only absolute digest
values moved, never the invalidation relation this corpus exists to freeze.

The recorded identities deliberately bind no compiler commit (commit-bound
receipt and generation hashes go to the ignored `context.tsv`), so a change
elsewhere in the compiler tree does not by itself move them. Only a change that
reaches the recorded digests does.

- Comment/layout changes exact source provenance only at the semantic-unit
  layer: all nine unit IDs, content digests, and read sets remain identical.
  Function IDs/encodings and C17 output also remain identical. The clean full
  build still churns its provenance-bearing monolithic stages and frozen native
  program; this corpus does not pretend that unit reuse exists yet.
- The private literal edit changes exactly `private-offset`'s semantic content,
  `native-function-v0` encoding, assembled native program, and C17 source. Its
  unit/function IDs, direct reads, public interface, and every independent unit
  remain stable.
- The public-interface edit changes only `corpus.foundation`'s true interface
  and exactly the `adjust` plus `score-value` semantic-content/function-encoding
  cone. All nine unit and function IDs remain stable, including the independent
  arm and the downstream `corpus.app` callers whose consumed interface did not
  change.

The emitted semantic identities and read sets make those three assertions
active falsifiers. The bounded unit seam uses them for exact typed/native
payload selection before reassembling the ordinary dense whole program. The
existing full build remains the artifact oracle; no result in this directory
claims a production cache, durable projection, or incremental build path.
