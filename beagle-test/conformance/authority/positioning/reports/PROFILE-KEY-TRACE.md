# `#lang` profile identity trace

Scope: read-only inspection of `beagle:`; no build or test
was run, and `/tmp/beagle-gate.lock` was not touched. Here “profile” means the
source/dialect identity (`core`, `clj`, `js`, or `nix`), not Native Core’s
checker/ABI configuration string such as `profile=3`.

## Entry and parsed program

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| Reader datum stream | No | The shared reader only installs readtable behavior and calls `read`/`read-syntax`; it does not select a target: `beagle:beagle-lib/lang/reader-impl.rkt:560-568`. The Nix reader explicitly shares the base reader: `beagle:beagle-lib/nix/lang/reader-impl.rkt:3-16`. |
| `#lang` dialect wrapper | Yes, at the wrapper boundary | The language readers route to their target module: `beagle:beagle-lib/lang/reader.rkt:1-6`, `beagle:beagle-lib/clj/lang/reader.rkt:1-6`, `beagle:beagle-lib/js/lang/reader.rkt:1-6`, `beagle:beagle-lib/nix/lang/reader.rkt:1-6`. The wrappers inject `(define-target clj|js|nix)`: `beagle:beagle-lib/clj/main.rkt:9-12`, `beagle:beagle-lib/js/main.rkt:9-12`, `beagle:beagle-lib/nix/main.rkt:9-12`. |
| Bare `#lang beagle` | Yes | `beagle-module-begin` injects `(define-target core)` when no target declaration is present: `beagle:beagle-lib/main.rkt:33-44`. |
| Canonical profile catalog | Yes | `CORE-PROFILE` defines `core`; `TARGETS` defines `clj`, `js`, and `nix`: `beagle:beagle-lib/private/targets.rkt:39-82`. `source-profile-ids` returns the complete source-profile set: `beagle:beagle-lib/private/targets.rkt:97-101`. |
| Parsed `program-target` | Yes | The parser pre-scans `define-target` before reader-conditional resolution: `beagle:beagle-lib/private/parse.rkt:1341-1356`. It validates and stores the target: `beagle:beagle-lib/private/parse.rkt:1994-2002`; the `program` struct has an authoritative `target` field: `beagle:beagle-lib/private/ast.rkt:1005-1031`; construction passes `target`: `beagle:beagle-lib/private/parse.rkt:2225-2236`. |
| Parsed program forms | No | Metadata forms, including `define-target`, are excluded from `program-forms`: `beagle:beagle-lib/private/parse.rkt:2251-2259` and `beagle:beagle-lib/private/parse.rkt:2149-2163`. Any downstream consumer that receives only `program-forms` loses the profile unless it separately receives `program-target`. |

## Checked program and bundle receipts

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| Checked-program JSON `target` | Yes | The checked projection emits `target` from `program-target`, alongside `sourceId` and `sourceSha256`: `beagle:beagle-lib/private/ast-json.rkt:1210-1218`. Its projection digest hashes the complete base object: `beagle:beagle-lib/private/ast-json.rkt:1237-1240`. |
| Module interface object/digest | Yes | `module-interface` has a `target` field: `beagle:beagle-lib/private/module-interface.rkt:41-45`; the canonical interface datum includes `(target ,target)`: `beagle:beagle-lib/private/module-interface.rkt:868-879`; the resulting interface stores the target and hashes the canonical datum: `beagle:beagle-lib/private/module-interface.rkt:1016-1051`. |
| Bundle input source record | Partial | The request source object is exactly `sourceId`, `bytesBase64`, and `authority`; it has no target field: `beagle:beagle-lib/private/checked-bundle.rkt:168-191`. Target is recovered from the language header or extension and injected as `define-target`: `beagle:beagle-lib/private/checked-bundle.rkt:93-130`. The source ID extension therefore supplies an external discriminator, but the source record/hash alone does not encode the profile. |
| `sourceSha256` in each module receipt | No as a standalone key | The receipt hashes only source bytes: `beagle:beagle-lib/private/checked-bundle.rkt:362-379`, specifically `sourceSha256` at lines 374-375. A source-byte hash is not profile-bound if identical bytes are submitted under different source IDs or target interpretations. |
| `interfaceSha256` in each module receipt | Yes, transitively | The receipt stores `module-interface-digest`: `beagle:beagle-lib/private/checked-bundle.rkt:367-379`; the interface canonical input includes target: `beagle:beagle-lib/private/module-interface.rkt:868-879`. |
| Require edges in module receipts | No | `require-edge` emits only namespace and provider `sourceId`: `beagle:beagle-lib/private/checked-bundle.rkt:244-255`; receipt assembly uses those edges without a target field: `beagle:beagle-lib/private/checked-bundle.rkt:374-379`. |
| `sourceClosureSha256` | Yes only transitively | The closure hash is over `entrySourceId` and module receipts: `beagle:beagle-lib/private/checked-bundle.rkt:382-385`. Because each module receipt includes `interfaceSha256`, target changes normally flow into the closure; there is no direct target component in the closure hash domain. |
| `checkedBundleSha256` | Yes only transitively | The response includes target-bearing `entryProjection` and module receipts before hashing: `beagle:beagle-lib/private/checked-bundle.rkt:386-398`. |

## Semantic index

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| Per-file semantic-index entry `target` | Yes | `build-indexed-entry` emits `target` from the checked module interface: `beagle:beagle-lib/private/semantic-index.rkt:417-427`. |
| Per-file semantic-index `sha256` | No as a standalone key | The entry hashes only file bytes: `beagle:beagle-lib/private/semantic-index.rkt:420-424`. The profile is a separate JSON field, not part of this digest. |
| Semantic-index `rootHash` | No — authoritative defect candidate | `root-hash` hashes only sorted `path`, NUL, and file `sha256`: `beagle:beagle-lib/private/semantic-index.rkt:429-439`. `build-semantic-index` publishes that root hash with the entries, but does not hash the target field: `beagle:beagle-lib/private/semantic-index.rkt:467-476`. A root identity must bind profile explicitly; currently it relies on path/bytes or on consumers rechecking the entries. |

## CNF fact projection

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| CNF fact program/profile identity | No — authoritative defect candidate | `facts-emit-program` iterates only `program-forms` and emits triples; it never reads `program-target`: `beagle:beagle-lib/private/emit-facts.rkt:283-289`. Since `define-target` is metadata omitted from `program-forms`, no profile fact can be emitted: `beagle:beagle-lib/private/parse.rkt:2251-2259`. |
| CNF triple/node keys | No — authoritative defect candidate | Node IDs are fresh per emission (`cur-id`/`fresh-id!`): `beagle:beagle-lib/private/emit-facts.rkt:23-33`; semantic triples contain form/name/call/field data but no profile field: `beagle:beagle-lib/private/emit-facts.rkt:241-281`. The canonical target catalog explicitly describes `facts` as lossy and “no #lang”: `beagle:beagle-lib/private/targets.rkt:18-22`. |

## Native stage, unit, and reuse identities

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| Native `SourceModuleV1` record/id | No directly — defect candidate | The record has id, name, path, source/projection/interface digests, and root term, but no source target/profile: `beagle:native-core/src/native/stages.bclj:24-31`. Its canonical encoding has exactly those fields and no target: `beagle:native-core/src/native/stages.bclj:190-198`. The slice constructor derives module id from module name and relative path only: `beagle:native-core/src/native/slice.bclj:193-217`. An interface digest may carry target indirectly, but the module identity does not bind it. |
| Native `SourceUnitV0` id/semantic key | No — defect candidate | The source-unit record contains id, module id, kind, name, semantic digest, root term, and read set, with no profile: `beagle:native-core/src/native/stages.bclj:33-40`; its encoding likewise has no profile field: `beagle:native-core/src/native/stages.bclj:200-208`. The slice constructs the unit id from the fact node name: `beagle:native-core/src/native/slice.bclj:262-284`. |
| Frozen source-stage digest | Only indirectly — defect candidate | The digest is `content-digest(encode-source-stage stage)`: `beagle:native-core/src/native/lower.bclj:565-578`. The source-stage encoding contains modules, units, imports, locations, and terms, but no target field: `beagle:native-core/src/native/stages.bclj:210-222`. It is safe only when an upstream interface digest is guaranteed present and target-bound. |
| Typed-stage root/digest | No explicit profile — defect candidate | `typed-stage` root identity is derived from `source-digest` only: `beagle:native-core/src/native/lower.bclj:19450-19474`; `TypedStageV0` carries source digest and typed roots but no target: `beagle:native-core/src/native/stages.bclj:49-57` and `beagle:native-core/src/native/stages.bclj:224-233`. |
| Native-program id/digest | No — defect candidate | Native program id is `lower-id "native-program" [typed-digest]`: `beagle:native-core/src/native/lower.bclj:22230-22248`. The native-stage encoding includes terms, typed digest, program, and obligations, not profile: `beagle:native-core/src/native/stages.bclj:275-280`. |
| `stages.bclj` `PassReceiptV0` identity | No explicit `#lang` profile — defect candidate | Receipt id is derived from pass id, input digest, and output digest: `beagle:native-core/src/native/lower.bclj:532-548`. The encoded receipt includes configuration, output, backend, and artifacts but no target field: `beagle:native-core/src/native/stages.bclj:326-351`. Native callers do add `profile=3` and `abi=...`, but those are checker/ABI settings, not source dialect identity: `beagle:native-core/src/native/slice.bclj:524-537`. |
| Unit compiler context digest | Not proven — defect candidate | `PreparedCandidateV0` carries an opaque `compiler-context-digest`, but no profile field: `beagle:native-core/src/native/unit_compile.bclj:15-20`; preparation accepts the digest as an external string: `beagle:native-core/src/native/unit_compile.bclj:138-161`. No source in the inspected path constructs that digest from `#lang` identity. |
| `unit-result-key` | No explicit profile — defect candidate | The key hashes compiler-context digest, unit id, semantic digest, and dependency-context digest only: `beagle:native-core/src/native/unit_reuse.bclj:1544-1577`. The dependency context hashes read-unit ids and unit-contract digests only: `beagle:native-core/src/native/unit_reuse.bclj:1544-1565`. |
| Unit contract digest | No — defect candidate | `UnitContractV0` has unit id, qualified name, visibility, types, failure type, generated bindings, encoding, and digest, but no profile: `beagle:native-core/src/native/unit_reuse.bclj:12-21`; its canonical value has no target: `beagle:native-core/src/native/unit_reuse.bclj:288-326`. |
| Typed-unit and native-unit wire/digest | No — defect candidate | Typed-unit encoding is keyed by unit id and function/type/effect/capability payloads: `beagle:native-core/src/native/unit_reuse.bclj:1457-1470`. Native-unit encoding is keyed by unit id, function, layouts, ABIs, and regions: `beagle:native-core/src/native/unit_reuse.bclj:1472-1489` and `beagle:native-core/src/native/unit_reuse.bclj:1529-1542`. Neither wire identity includes source dialect profile. |

## Materialization and build receipts

| Artifact or key | Profile included? | Path evidence |
|---|---|---|
| C17/C11 materialized artifact identity | No — defect candidate | `C11Artifact` contains only header/source names and text: `beagle:native-core/src/native/c11.bclj:27-35`. Materialization accepts only program and module index: `beagle:native-core/src/native/c11.bclj:709-735`; the slice writes those files without a profile-bearing receipt: `beagle:native-core/src/native/slice.bclj:585-595`. |
| QBE materialized artifact identity | No — defect candidate | `QbeArtifact` contains only module name and text: `beagle:native-core/src/native/qbe.bclj:17-21`; even though materialization receives `abi-id`, the successful artifact stores no source profile: `beagle:native-core/src/native/qbe.bclj:2722-2811`. |
| Materialization output hash | No unless an enclosing receipt binds it | The artifact receipts hash artifact name/digest sets only: `beagle:native-core/src/native/stages.bclj:314-324`. The artifact structures themselves have no profile field, so identical output bytes can collide across source profiles. |
| Artifact `PassReceiptV0` id | No — defect candidate | `make-artifact-receipt` derives the id from pass id, input digest, and output digest: `beagle:native-core/src/native/stages.bclj:359-385`. The finalizer invokes it with a configuration and backend, but no source `#lang` identity: `beagle:native-core/validation/build-finalize.clj:574-595`. |
| C17/Wasm receipt validation key | No explicit source profile — defect candidate | C17 validation binds native commit/configuration, epoch input, backend/version, and artifact set: `beagle:native-core/validation/build-finalize.clj:181-203`; Wasm binds input artifact hashes, bootstrap configuration, backend/version, and artifact set: `beagle:native-core/validation/build-finalize.clj:220-330`. These are backend/build identities, not the source dialect identity. |
| `BuildManifestV0` / manifest identity | No — authoritative defect candidate | The manifest has only receipt artifact hashes and managed artifact hashes: `beagle:native-core/src/native/stages.bclj:76-83`; its encoding contains only those two sets: `beagle:native-core/src/native/stages.bclj:387-396`. The finalizer writes exactly that manifest: `beagle:native-core/validation/build-finalize.clj:597-602`. |

## Pre-flip defect candidates

These are the authoritative keys where the inspected source does not guarantee
that a hosted node and a visually identical Native Core node have distinct
identity:

1. `sourceSha256` as a standalone module/source key.
2. The checked-bundle require-edge key (`namespace`, provider `sourceId`) when consumed independently of the target-bearing interface digest.
3. Semantic-index `rootHash`.
4. CNF facts projection identity and its minted node/triple keys.
5. Native `SourceModuleV1` id/encoding.
6. Native `SourceUnitV0` id/semantic key.
7. Frozen source-stage digest when upstream interface metadata is absent or not target-bound.
8. Typed-stage root/digest.
9. Native-program id and native-stage digest.
10. Native `PassReceiptV0` id and configuration digest as source-profile identities.
11. The opaque unit compiler-context digest unless its producer is separately proven to include `#lang` profile.
12. `unit-result-key`.
13. `UnitContractV0` digest.
14. Typed-unit and native-unit wire digests.
15. C17/C11, QBE, and other materialized artifact identities/hashes.
16. Artifact receipt ids and C17/Wasm receipt identities.
17. `BuildManifestV0` identity.

The target-bearing checked projection and interface digest are the strongest
surviving anchors. They do not repair the listed defects when a downstream
consumer keys only on the target-blind hash/id, or when the facts/native path
does not carry the interface digest through.

PROFILE-TRACE-DONE — read-only trace completed; report written without builds, tests, or `/tmp/beagle-gate.lock` access.
