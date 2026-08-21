# TYPE-OF AS STORE QUERY — SPIKE FINDINGS

**Result: proved end to end.** Commit `0a1874b36af6e89f248e865414eed1173fb3c886` adds the three-definition fixture at `beagle:branch-core/tests/typequery_spike_fixture.bclj` and the executable proof at `beagle:branch-core/tests/typequery_spike.clj`. Nothing was landed or pushed.

## What ran

`bin/beagle check --agent` accepted the fixture with zero errors. Because that success surface intentionally prints diagnostics rather than types, the harness consumes `bin/beagle ast`, the checker's schema-v4 `beagle.checked-program` projection. Each top-level form supplies its `name`, structured `effectiveType`, and exact source provenance (`sourceId`, line, column, position, and span). The checked source and projection digests were also retained in the result.

The harness created a new scratch FRAMLOG through `database/create-triple-log!`, opened it through `database/open-database!`, and committed one durable transaction per definition through `database/commit!`. It then discarded that in-memory view, reopened the FRAMLOG cold, and queried its live propositions with a structured `fram.query/run!` Datalog plan. This is the real landed store API and query evaluator, not a map standing in for them.

The spike encodes types as recursive Terms. `Int` is `[:type/primitive :type/name "Int"]`; `(Fn [Int Int] Int)` is a `:type/function` Triple whose parameter list and return are nested type Terms. A provisional definition Term joins source, `:beagle/definition`, and name. Eight asserted propositions per definition record name, `:beagle/type-of`, a source-span Term, file, line, column, byte position, and byte length. The query starts with the supplied name, joins to the definition, then returns the type Term and span coordinates.

All three cold-reopened queries returned exactly one row:

| name | stored type | source span |
| --- | --- | --- |
| `answer` | `Int` | line 5, column 0, position 49, length 19 |
| `add` | `(Fn [Int Int] Int)` | line 7, column 0, position 70, length 56 |
| `label` | `(Fn [Int] String)` | line 10, column 0, position 128, length 56 |

## First cost data

One final run used niceness 19. Mint measurements use `System/nanoTime` around the durable store commit, including FRAMLOG append and `fsync`. Query measurements cover plan compilation plus evaluation over the 24 live propositions; “warm median” is 201 immediate repetitions per name.

| definition | facts | durable mint | FRAMLOG growth | first query | warm median |
| --- | ---: | ---: | ---: | ---: | ---: |
| `answer` | 8 | 6.485 ms | 1,262 B | 0.941 ms | 0.477 ms |
| `add` | 8 | 7.697 ms | 1,417 B | 0.534 ms | 0.497 ms |
| `label` | 8 | 8.471 ms | 1,366 B | 0.484 ms | 0.481 ms |

The mean durable mint cost was **7.551 ms per definition**. Median first-query latency was **0.534 ms**; the median of the three per-name warm medians was **0.481 ms**. The store ended at 3 transactions, 24 operations/live propositions, 69 interned Terms, and a 4,076-byte FRAMLOG. The three definition frames added 4,045 bytes total: **1,348 bytes per definition** or **169 bytes per asserted proposition** at this tiny scale. These are mechanism-proving numbers, not a throughput benchmark; the per-definition `fsync` deliberately dominates mint cost.

## Mapping to the thesis v2 identity constitution

The demonstrated schema is deliberately pre-constitutional. It proves storage and query shape, but its provisional definition Term contains path and name, so it must not become `DefinitionId`.

- Every recursive value and type Term should first receive the thesis's versioned, domain-separated `TermId` over canonical kind IDs and payload bytes. Store-private handles remain private; changing a Term equality law creates a new ID version rather than reinterpreting old facts.
- Exact fixture bytes, ordered path, and spans belong under `SourceRevisionId`. The present checker `sourceSha256` is useful input evidence, not by itself the complete source-revision envelope.
- A first-class `Derivation` should bind the ordered `SourceRevisionId` input, exact checker/compiler materialization, schema-v4 Clojure interpretation profile, checking authority, output type/definition IDs, and the byte-range origin map demonstrated here. The stored span is an origin edge, not semantic definition identity.
- `DefinitionId` should derive from canonical typed facts, dependency IDs, nominal seals, and checked effects/authority while excluding name, path, and presentation. Name becomes a `binds` or routing fact. The constitutional query is therefore name → binding → `DefinitionId` → type `TermId`, with `DerivationId` answering where that fact came from.
- This scratch store exposes `(SpaceId, transaction sequence, ordinal)` occurrence coordinates. Thesis v2 correctly treats those as branch-local locators; durable provenance eventually needs `EventId` from parent history plus canonical frame and `OccurrenceId = (EventId, ordinal)`.

The narrow conclusion is now empirical: **type-of can be an ordinary store query.** What remains for W7 is identity and admission—not a new storage or query mechanism.
