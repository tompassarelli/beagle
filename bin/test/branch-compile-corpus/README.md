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

`units.tsv` declares the direct semantic read set. `expected-cones.tsv` freezes
the Phase B contract: module + definition kind/name owns unit identity; exact
source hashes remain provenance; a private body edit changes only that unit's
typed/native content; and a public signature edit invalidates its exact direct
consumer until an unchanged interface stops propagation.

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

`expected-boundaries.tsv` is an active falsifier today: the exact changed
source modules and true interface modules must match it. `expected-cones.tsv`
is the next falsifier for Phase B's unit index and dependency DAG. The tracked
`oracle/churn.tsv` documents current whole-build over-invalidation rather than
declaring it correct.

## Current verdict

The frozen oracle was measured at compiler baseline
`fb6fdf8a5233c1bdb2916b2ddce005731a6ad93e`.

- Comment/layout changes preserve every function ID and function encoding and
  produce byte-identical C17, but churn all four whole-stage identities and the
  frozen native program. Exact source provenance is still mixed into the
  monolithic pipeline identity.
- The private literal edit preserves the real public interface and every
  function ID. It changes C17 as required, but the `private-offset`
  `native-function-v0` encoding does not change. The current atom-instruction
  encoding binds only its SSA result and omits the literal `NativeAtom` payload.
  That encoding is therefore not a sound function-content identity.
- The public-interface edit correctly changes only `corpus.foundation`'s true
  interface. Nevertheless, the added parameter shifts global source-fact
  ordinals and changes seven unrelated or logically stable function IDs:
  `double-value`, `score-value`, `stable-score`, `independent-value`, and all
  three `corpus.app` functions. Their encodings then churn transitively through
  those unstable IDs. Only `adjust` and `score-value` belong to the expected
  semantic recomputation cone.

Phase B must replace preorder-derived unit identity with canonical module +
definition kind/name identity, publish a provenance-free semantic-unit digest
that still binds literal payloads, put the real module-interface digest in the
source-unit record, and export canonical resolved direct read sets. Unit-level
typed/native results can then be reused before reassembling the ordinary dense
whole program. The existing full build remains the artifact oracle; no result
in this directory claims that incremental assembly already exists.
