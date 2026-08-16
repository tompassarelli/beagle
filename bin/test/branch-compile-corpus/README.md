# Branch compilation corpus oracle

This is Phase C of the bounded branch-native compiler experiment. It supplies
four Native Core modules, three controlled mutations, and an independent clean
full-build oracle. It does not implement or simulate incremental compilation.

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
build must be byte-identical at every recorded identity.

The tracked oracle records:

- exact module source and true module-interface-v8 digests from `ast-bundle`;
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
and every mutation must preserve every semantic-unit ID. Its future assembled
reuse rows remain expectations rather than simulated cache behavior. The
tracked `oracle/churn.tsv` describes clean-full-build output; it does not turn
whole-build churn into the incremental contract.

## Current verdict

The corrected oracle was measured on semantic-unit compiler checkpoint
`b63f8f0a43391541598eac77d0830370c799a335`.

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

The emitted semantic identities and read sets now make those three assertions
active falsifiers. A later compiler may use them for unit-level typed/native
reuse before reassembling the ordinary dense whole program. The existing full
build remains the artifact oracle; no result in this directory claims that an
incremental cache or assembler already exists.
