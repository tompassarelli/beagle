# Beagle self-compiler semantic-gap triage

Date: 2026-08-18

## Verdict

The campaign number is real: the preserved self-host verifier ledger contains
exactly 44 failure rows. It is not a list of 44 independent language defects.
The rows collapse into 5 broad families and 13 actionable root-cause clusters.
There are 6 small, 18 medium, and 20 large rows by the estimates below. Four
rows remain explicitly unsure because the captured evidence proves that the
Racket oracle failed to mint them, but does not distinguish an oracle defect
from a fixture/corpus contract drift.

No row is currently classified as an unspecified language semantic requiring a
commander ruling. The two checker-verdict rows, the four purity rows, and the
host-namespace question are contract decisions already represented by the
fixtures or campaign documents; the open question is attribution or repair,
not an unruled language meaning.

## Provenance and search boundary

The authoritative row list is the preserved runtime artifact
`/tmp/beagle-tier-repair-failures.txt`. It has 44 lines, one per verifier
failure. The release record `todo:release-train-v024.md` records the same
baseline as 136 passed / 44 failed and gives normalized-label SHA-256
`67df2590d488903ae74cf0c4adec2eddb864e64ca2cfede48d587c9261d2cbcd`.
`beagle:self-host/verify-selfhost.sh` confirms the five verifier sections and
their comparison rules. The campaign itself records only the aggregate and
broad families; it does not contain the row identities.

I searched:

- `beagle:beagle-test/conformance/authority/positioning/SELF-COMPILER-CAMPAIGN.md`;
- the full `todo:beagle-program-handoff/` tree and the plain `todo/` tree for
  semantic-gap, parity, divergence, shadow, oracle, conformance, and ledger
  records;
- read-only `beagle:main`, including `self-host/verify-selfhost.sh`, its
  fixtures and repro corpus, the self-host README, and source-side parity
  references;
- the preserved parity log
  `todo:train-integration-gate.red-f8b4a9be516259de39391d061b1cdd4f72af0763b1cdd4f72af0763-selfhost-parity.log`;
- prior conversation records for the 44-row seal, normalized-label digest, and
  oracle-rejection sweep.

No source, repository checkout, build state, or gate lock was changed.

## Cluster summary

| Cluster | Rows | Type | Difficulty | Root cause and shortest repair shape |
|---|---:|---|---|---|
| C1 Oracle mint / fixture contract | 1, 3, 4 | MIXED | medium | Row 1 is an oracle namespace-catalog defect; rows 3/4 are under-typed fixtures. Their mint failures are repaired, but downstream parity now exposes self-host-owned seams outside this lane. |
| C2 Source-aware AST identity | 2 | NATIVE | medium | One source-aware binding-identity projection differs in the typed AST. |
| C3 JS qualified extern shadow | 5–6 | NATIVE | small | One qualified `Map`/extern-shadow resolution or emission discrepancy is counted at stage-isolated and full-chain levels. |
| C4 JS second-order state | 7–8 | NATIVE | medium | Atom/union/HVec/loop state projection reaches a different self-host emission; repair the shared typed-state projection, then both checks fall together. |
| C5 JS dotted subpath | 9–10 | NATIVE | small | Qualified npm subpath/member spelling differs in the self-host emission; one import-path emission fix covers both legs. |
| C6 `js/quote` AST and emission | 11–13 | NATIVE | medium | Quoted JavaScript object/function syntax differs in AST and emitted bytes; repair the shared JS-quote representation/emitter seam. |
| C7 JS logical tail `recur` | 14–15 | NATIVE | medium | Short-circuit logical forms containing tail `recur` differ in emitted bytes; repair the common logical/recur lowering. |
| C8 JS `some` value semantics | 16–17 | NATIVE | small | `some` first-truthy lowering differs in emitted bytes; one lowering contract and regression should remove both rows. |
| C9 Checker error-core selection | 18–19, 21–34, 36–37 | NATIVE | large | Eighteen rejecting inputs reject on both sides but select different checker error cores; fix shared checker precedence/diagnostic projection rather than 18 cases independently. |
| C10 Checker accept/reject soundness | 20, 35 | NATIVE | large | The self-host checker accepts two inputs the Racket checker rejects; this is the only checker cluster changing the verdict, so it needs semantic checker repair. |
| C11 Purity accept contract | 38–39, 41 | ORACLE (repaired) | medium | Racket’s transient ownership transfer and profile-0 interface publication were too strict; the oracle now matches the accepted fixture contract and self-host. |
| C12 Purity warning witness | 40 | NATIVE | medium | Both sides accept under the warning profile, but Racket identifies `store` and self-host does not; align purity-definition extraction/witnessing. |
| C13 Checked module-interface projection | 42–44 | NATIVE | medium | Full-chain bytes agree, but self-host AST/externs lack the oracle’s checked interface fields (generated constructors/accessors and nominal signatures). |

### Corrected cluster counts

The exact, non-overlapping cluster counts are: C1 3, C2 1, C3 2, C4 2, C5
2, C6 3, C7 2, C8 2, C9 18, C10 2, C11 3, C12 1, and C13 3. They sum
to 44.

## Per-gap inventory

`Racket` means the frozen oracle leg; `self-host` means the native/self-host
leg. “NATIVE” and “ORACLE” identify the side that should change. “UNSURE” is
used only where the captured run does not provide enough evidence to assign a
side honestly.

| # | Recorded identity | Affected construct / behavior | Divergence | Classification | Difficulty and justification |
|---:|---|---|---|---|---|
| 1 | `hosted-namespace-contracts` oracle mint | Hosted `clojure.string` namespace and `:refer [index-of]` contracts | Racket mint failed because parser-created `Any` placeholders masked the catalog contract for the alias and bare `:refer` name; self-host accepted the fixture. The oracle mint now succeeds, but verifier parity exposes a self-host alias-spelling seam. | ORACLE (mint repaired; downstream self-host seam remains open) | Medium: catalog alias/refer projection was the oracle defect; the remaining parity finding is outside this lane. |
| 2 | `lowering-temps` AST parity | Source-aware binding identities in the typed AST | Self-host AST differs from Racket AST; the recorded comparison is self AST versus oracle AST | NATIVE | Medium: likely one source-aware identity/projection seam, but AST evidence must be compared after the shared repair. |
| 3 | `threading` oracle mint | Seven Clojure threading forms, including nested binder minting | Racket reported `call to +: arg 1 expected Number, got Any`; self-host reported the same invalid arithmetic. The fixture declared `first-int` as `Any` despite returning `Int` or `nil`; annotating it `(U Int Nil)` makes both mints/checks succeed. The verifier then exposes a self-host AST seam. | FIXTURE (repair applied; downstream self-host seam remains open) | Medium: the captured error identifies an under-specified fixture return contract. |
| 4 | `grey-js-contracts` oracle mint | JS interop contracts: `Map`, `Math`, `Date`, browser types, numeric overloads | Racket reported `js/new Map cannot infer type parameters K, V without an expected result type`; self-host reported the same missing expected type. Annotating the binding `(JsMap Any Any)` makes both mints/checks succeed. The verifier then exposes self-host JS emission parity failures. | FIXTURE (repair applied; downstream self-host seam remains open) | Medium: the captured error identifies the untyped `Map` construction as the fixture defect. |
| 5 | `grey-js-map-extern-shadow` stage-isolated byte parity | Qualified external `Map` constructor under JS target | Self-host stage-2 bytes differ from the Racket-emitted bytes | NATIVE | Small: one qualified extern-shadow emission path is exercised directly. |
| 6 | `grey-js-map-extern-shadow` full-chain byte parity | Same qualified `Map` constructor after self-host parse/check/emit | Self-host full-chain bytes differ from the same Racket oracle bytes | NATIVE | Small: duplicate observation of row 5, so the same fix should close both. |
| 7 | `grey-second-order-state` stage-isolated byte parity | Typed Atom/union/HVec state, loops, and conditional values in JS fixture | Self-host stage-2 bytes differ from Racket bytes | NATIVE | Medium: several typed-state shapes share one fixture, so root attribution is broader than a one-token emitter fix. |
| 8 | `grey-second-order-state` full-chain byte parity | Same second-order state fixture through the complete self-host chain | Self-host full-chain bytes differ from Racket bytes | NATIVE | Medium: repeated symptom of row 7, but full-chain provenance must remain byte-clean. |
| 9 | `js-parity-dotted-subpath` stage-isolated byte parity | Dotted npm import `three/addons/loaders/GLTFLoader.js` | Self-host stage-2 bytes differ from Racket bytes | NATIVE | Small: one qualified dotted-subpath spelling/emission seam. |
| 10 | `js-parity-dotted-subpath` full-chain byte parity | Same dotted subpath after complete self-host processing | Self-host full-chain bytes differ from Racket bytes | NATIVE | Small: repeated symptom of row 9. |
| 11 | `js-parity-quote` stage-isolated byte parity | `js/quote` function/object/delete/optional-property surface | Self-host stage-2 bytes differ from Racket bytes | NATIVE | Medium: quoted JS has its own parser and emitter representation. |
| 12 | `js-parity-quote` AST parity | Same quoted JS surface in AST JSON | Self-host AST differs from Racket AST | NATIVE | Medium: AST shape and emitted bytes must share the same representation repair. |
| 13 | `js-parity-quote` full-chain byte parity | Quoted JS after the complete self-host chain | Self-host full-chain bytes differ from Racket bytes | NATIVE | Medium: repeated symptom of the shared `js/quote` seam. |
| 14 | `js-parity-recur-logical` stage-isolated byte parity | Tail `recur` inside `and`/`or` short-circuit forms | Self-host stage-2 bytes differ from Racket bytes | NATIVE | Medium: control-flow lowering must preserve both short-circuiting and recur tail position. |
| 15 | `js-parity-recur-logical` full-chain byte parity | Same logical tail-recur forms through the full chain | Self-host full-chain bytes differ from Racket bytes | NATIVE | Medium: repeated symptom of row 14. |
| 16 | `js-parity-some` stage-isolated byte parity | `some` returns the first Clojure-truthy value | Self-host stage-2 bytes differ from Racket bytes | NATIVE | Small: one standard-library lowering contract, with a direct behavioral meaning. |
| 17 | `js-parity-some` full-chain byte parity | Same `some` fixture through the full self-host chain | Self-host full-chain bytes differ from Racket bytes | NATIVE | Small: repeated symptom of row 16. |
| 18 | `044333dc85bd` error core | Nested keyword lookup followed by numeric use | Both reject; Racket reports a bad type expression while self-host reports a later numeric argument error | NATIVE diagnostic parity | Large: one of 18 cases exposing shared checker error-selection drift, not an independent language rule. |
| 19 | `1c04be588e62` error core | `count` on a keyword in a later numeric expression | Both reject; error cores select different failing forms | NATIVE diagnostic parity | Large: same checker diagnostic-selection family. |
| 20 | `1ecc23512d15` accept/reject | Fuzzed typed form with a checker rejection boundary | Racket rejects; self-host accepts | NATIVE | Large: changes the checker verdict, so it needs semantic narrowing rather than message normalization. |
| 21 | `20b1c0026a1f` error core | `mapv`/vector shape followed by numeric use | Both reject with different error cores | NATIVE diagnostic parity | Large: shared checker precedence/propagation family. |
| 22 | `3a907432853b` error core | `nth` on `Float` versus omitted-type `defonce` | Both reject but blame different checker constraints | NATIVE diagnostic parity | Large: shared checker error selection, not an isolated fixture defect. |
| 23 | `3d41f6a456b1` error core | Dynamic binding and conditional type joins | Both reject with different core diagnostics | NATIVE diagnostic parity | Large: combines dynamic-var and type-join paths, requiring shared checker precedence evidence. |
| 24 | `42ad2d259ad2` error core | Unknown inferred return type in a `defn` | Both reject with different return-type diagnostics | NATIVE diagnostic parity | Large: same checker-tail family. |
| 25 | `509a72f87c74` error core | Malformed `defn` with nil binding vector | Both reject with different malformed-form diagnostics | NATIVE diagnostic parity | Large: parser/checker boundary dispatch is selecting different cores. |
| 26 | `5b7b4c8034e8` error core | Map literal/function value followed by numeric `+` | Both reject with different numeric/type-expression diagnostics | NATIVE diagnostic parity | Large: same checker error-core family. |
| 27 | `62bd65163f0f` error core | Malformed multi-arity/empty-parameter `defn` | Both reject with different `defn` shape messages | NATIVE diagnostic parity | Large: shared malformed-function dispatch. |
| 28 | `677470581f1a` error core | Malformed typed multi-arity `defn` | Both reject with different `defn` shape messages | NATIVE diagnostic parity | Large: repeated malformed-function dispatch symptom. |
| 29 | `6f151ff4eece` error core | `nth` on `Float` versus omitted-type `def` | Both reject but report different constraints | NATIVE diagnostic parity | Large: same checker error selection as row 22. |
| 30 | `7e9a14983210` error core | Function missing return type/body | Both reject; wording and selected parser core differ | NATIVE diagnostic parity | Large: shared function-form validation path. |
| 31 | `94c783024a2d` error core | Threaded sequence expression with malformed function shape | Both reject with different function/type cores | NATIVE diagnostic parity | Large: combines threading and function validation, but the recorded failure is checker-core selection. |
| 32 | `9e37d4c1f2b7` error core | Predicate use on dynamic value followed by numeric subtraction | Both reject with different type cores | NATIVE diagnostic parity | Large: shared checker error propagation family. |
| 33 | `c12eeda88def` error core | `if` union result consumed by `nth` | Both reject with different vector/union cores | NATIVE diagnostic parity | Large: shared union narrowing/error precedence family. |
| 34 | `c7786bec88f8` error core | `str` result used as numeric `+` argument | Both reject with different cores | NATIVE diagnostic parity | Large: shared checker error selection, not a new arithmetic rule. |
| 35 | `e6a120c21932` accept/reject | Fuzzed typed form at a second rejection boundary | Racket rejects; self-host accepts | NATIVE | Large: a second soundness failure; pair it with row 20 but do not waive either. |
| 36 | `f036de687e29` error core | Function missing return type/body | Both reject with equivalent meaning but different wording | NATIVE diagnostic parity | Large: duplicate of the shared function-form diagnostic root. |
| 37 | `fbeb9210ee4d` error core | Set literal/function expression in invalid typed context | Both reject with different function/type cores | NATIVE diagnostic parity | Large: same checker-tail diagnostic root. |
| 38 | `owned-transient-accept` purity verdict | Owned transient lifecycle with mutation and `persistent!` | Racket purity analysis incorrectly escaped the owned transient after discarded `conj!` calls and rejected `persistent!`; self-host accepted. Oracle transfer now preserves the owner, and both verifier legs accept. | ORACLE (repaired) | Medium: one ownership-transfer rule, covered by the purity parity section. |
| 39 | `strict-accept` purity verdict | Transient ownership plus ordinary `store!` effect | Racket rejected the same valid owned transient lifecycle; self-host accepted. The oracle transfer rule now accepts it, while representative alias/escape rejects remain rejected. | ORACLE (repaired) | Medium: one purity-profile interaction, not a broad compiler path. |
| 40 | `warn-profile-2` purity definitions | Warning profile should identify the `store` definition | Both accept, but Racket reports `store` and self-host reports a different/empty witness | NATIVE | Medium: the verdict survives, but the native purity witness extraction is incomplete. |
| 41 | `error-profile-0` purity dial | Error purity mode on the direct-bang fixture | Racket attempted to publish a finalized interface under parse-only profile 0 and failed before the purity verdict; self-host accepted. The oracle now uses a provisional interface at profile 0, and both verifier legs accept. | ORACLE (repaired) | Medium: profile-0 interface publication was the oracle defect. |
| 42 | `alias-user` module interface | Imported alias-qualified provider signatures/externs | Full-chain bytes agree; self-host checked AST/extern set differs from Racket | NATIVE | Medium: one checked-interface projection seam, shared with rows 43–44. |
| 43 | `shapes` module interface | Imported record constructor/accessor and nominal `Point` signatures | Full-chain bytes agree; self-host checked AST/extern set differs from Racket | NATIVE | Medium: generated record surface and nominal return types cross the module boundary. |
| 44 | `transitive-alias-user` module interface | Transitive provider alias/record surface | Full-chain bytes agree; self-host checked AST/extern set differs from Racket | NATIVE | Medium: same checked-interface projection root through a transitive alias. |

## Explicit unsure section

The following three rows are not guessed into a side attribution:

- rows 1, 3, and 4: the Racket oracle exits during mint, so no comparison
  artifact exists; the source can be a fixture that the oracle no longer
  accepts, an oracle catalog/checker defect, or both;

## Commander-ruling section

No row is assigned a commander ruling. The evidence does not expose an
unspecified language semantic. Rows 18–37 are diagnostic-core parity (both
reject in 18 cases), not a claim that the language has two possible meanings.
The host namespace, purity, and module-interface expectations are already
encoded in the campaign, verifier, and fixture contracts. If the commander
chooses to stop requiring exact diagnostic text, rows 18–19, 21–34, and 36–37
could be reclassified as non-semantic reporting debt, but that would be a gate
policy change, not an inference made here.

## Shortest credible path to zero

The exact normalized label list is already named by the 44 rows above. Work by
cluster, not row:

1. settle the three oracle-mint rows from their preserved oracle stderr and
   either repair the oracle, repair the fixture contract, or record the
   explicit contract outcome;
2. close the shared checker diagnostic-selection root, then separately close
   the two accept/reject soundness cases;
3. repair the six JS emission seams (qualified extern shadow, second-order
   state, dotted subpath, `js/quote`, logical `recur`, and `some`), using stage
   and full-chain rows as paired evidence;
4. align the purity oracle/profile contract and native witness extraction;
5. port the checked module-interface projection once for all three module
   rows;
6. rerun the named self-host verifier once and replace the aggregate with a
   zero-row normalized ledger and a new digest.

The dominant opportunity is the checker family: 20 rows are two shared
problems, not 20 independent repairs. The next opportunity is collapsing paired
stage/full-chain observations into one fix per JS seam. The campaign remains
unplannable only in the sense that the gate has not been reduced by root-cause
work; the current `136/44` number is now a restart-grade inventory rather than
an unexplained aggregate.
