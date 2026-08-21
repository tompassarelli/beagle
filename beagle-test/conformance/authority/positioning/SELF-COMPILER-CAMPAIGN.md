# Beagle self-compiler campaign

## Position

Beagle has a real self-hosted hosted compiler and a reproducible native
distribution of that compiler, but it does **not** yet have a Core-capable
native compiler that reproduces its own executable. The current native stage0
is a GraalVM native-image of the checked-in Clojure seed. It can read, parse,
check, project AST, and emit hosted Clojure, JavaScript, Nix, and source facts.
It cannot compile bare `#lang beagle` Core, freeze/lower a Core program, or
materialize C17/QBE/Wasm.

That distinction changes the speed plan:

- Replacing `bin/beagle-build-all` with the existing native stage0 can remove
  the serial Racket compilation of the hosted Native Core compiler modules.
  This is the direct repair for the two 300-second-no-artifact validation
  gates.
- It cannot by itself reduce the measured Fram **2,198-second C17 emission**.
  That phase is the generated Native Core compiler running under Babashka, not
  the Racket front end. Reducing that number requires a new Core-capable
  compiler binary containing the lowering and materialization implementation.
- The bootstrap is source-fixed today, not binary-fixed: the seed compiler
  reproduces its emitted `.clj` bytes, while GraalVM remains an external final
  packager. No gate proves compiler executable generation 1 equals executable
  generation 2 byte-for-byte.

Evidence is from clean read-only Beagle main
`55f3fbe848fdfd19a733e13c5e66ff66cacb44b0`, clean read-only Fram main, and
the 2026-08-18 records. No checkout or gate lock was changed.

## Reconnaissance boxes

| Box | Budget | Exit condition | Result |
| --- | ---: | --- | --- |
| Source authority | 8 minutes | Identify the self-host source, seed, driver, native packaging, and bootstrap gates. | Closed from `beagle:CLAUDE.md`, `beagle:self-host/README.md`, `beagle:docs/self-hosting.md`, and live scripts. |
| Current evidence | 12 minutes | Reconcile today's parity, Store, Fram, and validation records with main history. | Closed; stale records are called out below and source/main history wins. |
| Hot paths | 10 minutes | Trace every production/gate family that invokes Racket or `run-bounded.rkt`. | Closed by grouped executable-path inventory below. |
| Synthesis | 10 minutes | Bank one staged, dependency-ordered, one-worker-per-seam campaign. | Closed with 13 seams and named gates. |

## 1. Self-host state

### What it is and where it lives

The self-host is 11 Beagle-authored hosted modules plus one handwritten host
runtime:

- `beagle:self-host/src/selfhost/{ast,check,emit-clj,emit-js,emit-nix,facts-roundtrip,macros,main,parse,probe,reader,types}.bclj`
- `beagle:self-host/src/selfhost/rt.clj`, copied rather than compiled
- blessed emitted output under `beagle:self-host/seed/selfhost/*.clj`
- CLI entry `selfhost.main`, exposed as `ast`, `check`, `emit`,
  `emit-from-ast`, and `facts-roundtrip`

The source profile is hosted Clojure (`.bclj`, `#lang beagle/clj`). The seed
runs under Babashka. `bin/beagle-remint` enumerates the exact source bundle and
requires the seed compiler to reproduce every generated seed file. Promotion
also requires generation 1 to reproduce generation 2 and runs module
self-tests. `--oracle` adds three-way agreement with Racket.

The current native distribution is built by `nix build
.#beagle-selfhost`. `beagle:flake.nix` packages the seed as a GraalVM
native-image named `beagle-selfhost`; the ordinary output is
`result/bin/beagle-selfhost`. The mutable developer path is
`beagle:self-host/native/beagle-selfhost`, guarded by a sibling
`.seed-nar-hash`. Neither path exists in the current main checkout. Current
source pins likewise retain source and seed, not the executable; see
`beagle:beagle-test/conformance/authority/positioning/ADVERSARIAL-REVIEW-7-BOOTSTRAP.md`.

The landed opt-in route is `beagle:bin/beagle-dev` from commit `3713ef9b`:

```text
BEAGLE_SELFHOST_DEV=1
BEAGLE_NATIVE_BIN=result/bin/beagle-selfhost
BEAGLE_SELFHOST_SHADOW_PERCENT=0..100
```

It handles only one hosted build. Core, materializers, batch shapes, public
release paths, and gates fall back to the public Racket route. The older
`todo:selfhost-daily.md` says the lane is merely banked, but main contains the
commit and its focused test; repository history is the current fact.

### What the landed daily/release parity evidence proves

Today's two relevant landings are distinct:

1. `3713ef9b` proves the opt-in wrapper behavior: flag-off delegation, native
   hosted emission, deterministic Racket shadow sampling, divergence capture,
   and a real native/Racket byte match on
   `beagle:self-host/fixtures/lowering-temps.bclj`. Its focused driver is
   `beagle:bin/test/selfhost-daily/run.sh`.
2. `ddc6eb1f` repaired additive self-host release divergences. Oracle-backed
   remint passed 48/48 with generation-1/generation-2 source convergence; the
   current verifier seal is **136 passed / the same 44 known failures**, whose
   normalized label digest remains
   `67df2590d488903ae74cf0c4adec2eddb864e64ca2cfede48d587c9261d2cbcd`.
   Evidence: `todo:release-train-v024.md` and
   `beagle:self-host/verify-selfhost.sh`.

The seal proves no new failure label relative to the pinned backlog. It does
not prove zero divergence. It also does not prove Core compilation, the Store
Core closure, Fram, the 263-case conformance corpus, or executable binary
fixpoint.

### Feature envelope versus the Racket oracle

| Capability | Self-host today | Racket oracle today | Evidence |
| --- | --- | --- | --- |
| Reader, parser, checker, macros, hosted AST | Implemented; current fixed corpus exercises stage-isolated and full-chain parity. | Authoritative implementation. | `beagle:self-host/src/selfhost/`; `beagle:self-host/verify-selfhost.sh` rungs 1-5. |
| Closed modules and imported typed surfaces | Implemented for explicit `--source` bundles and `--module-root`. | Implemented with a wider typed-stdlib host-namespace catalog. | `beagle:self-host/README.md` “Module resolution” and rungs 6-7. |
| Hosted emitters | Clojure, JavaScript, Nix. | Clojure, JavaScript, Nix. | `beagle:self-host/src/selfhost/main.bclj`; target-specific parity is not complete. |
| Facts roundtrip | Implemented and already dispatched through the seed after the public Racket front-door setup. | Retained as certification oracle. | `beagle:bin/beagle`; `beagle:bin/beagle-certify-facts-roundtrip`. |
| Bare Core `.bgl` | **Absent.** | Implemented. | Self-host driver target switch has only `clj`, `js`, and `nix`; `beagle:bin/beagle-dev` explicitly rejects Core/materializer shapes. |
| Freeze, typed/native stages, obligations | **Absent from the self-host driver.** | Drives the hosted Native Core compiler. | `beagle:bin/beagle-build-core`. |
| C17, QBE, Wasm, native executable | **Absent.** | Implemented. | `beagle:bin/beagle-build-core`, `beagle:bin/beagle-materialize-wasm`, `beagle:bin/beagle-native-exe`. |
| Public query/authoring tools | Mostly absent. | Racket-backed. | Exact grouped inventory below. |
| Source locations | Deliberately absent from the self-host chain. | Present in checked projections and normal hosted builds. | `beagle:self-host/README.md`. |
| Cross-module macro import | Not ported. | Implemented. | `beagle:self-host/README.md` known gaps. |
| Parametric-union member constructors/accessors | Not ported. | Implemented. | Same evidence. |

### Can it compile the named workloads today?

| Workload | Verdict | Exact boundary |
| --- | --- | --- |
| Its own self-host sources | **YES, to hosted Clojure source.** | `bin/beagle-remint` proves seed -> generation 1 -> generation 2 byte identity. It does not produce a self-reproducing executable. |
| `src/store` complete closure | **NO.** | The current in-repo Store contains hosted `.bclj` leaves and a large bare-Core `.bgl` closure. The parity harness now admits only hosted `branch.bclj`; hosted files requiring Core providers are correctly refused. The self-host has no Core path. |
| Fram server sources | **NO.** | `fram:native/core_closure_sources.txt` is a dependency-first `.bgl` Core closure. `fram:bin/fram-native-build` requires bare `#lang beagle` and invokes `beagle build --materializer`. |
| Conformance corpus | **NO as a corpus compiler.** | The manifest has 263 decided cases: 245 `core`, 1 `native-core`, 4 hosted Clojure, 10 hosted JS, 2 hosted Nix, and 1 hosted Racket. The existing binary lacks the public `beagle` CLI shape and all Core cases; at most the hosted subset is individually in its language envelope. |
| Hosted Native Core compiler implementation | **Almost, but not accepted.** | Today's `todo:store-gate2.md` records a 1.895-second self-host run that reached a verdict but rejected the exact compiler closure on known union-narrowing gaps. This is the first load-bearing blocker. |

## 2. Native compiler binary state

### What exists

Yes, Beagle's self-host has been materialized as a native executable in the
ordinary operating-system sense: the GraalVM `beagle-selfhost` artifact. CI
and releases build it, `self-host/native/verify-native.sh` requires native =
Babashka seed = Racket emitted bytes over its eligible hosted corpus, and the
release workflow attaches the executable and seed-NAR sidecar.

It is not the requested compiler-compiling-compiler in the stronger sense:

- the artifact packages already-emitted Clojure via an external GraalVM
  builder;
- it cannot compile Core or run Native Core lowering/materialization;
- it does not recreate its own executable;
- no gate compares executable generation 1 and generation 2 bytes;
- no current native executable is materialized in Beagle main or its retained
  source pins.

Therefore the answer is **native hosted front-end: yes; self-reproducing
Core-capable native compiler: no**.

### Stage 1: oracle compiles the full compiler to native

Stage 1 must produce one immutable Core-capable artifact, proposed as
`result/bin/beagle-compiler-native`, from an oracle-generated closed compiler
bundle. It must contain both:

- the self-hosted reader/parser/checker/hosted emitters; and
- the 13 hosted Native Core compiler modules enumerated by
  `beagle:bin/beagle-build-core` (`native.core`, stages, SIMD, lower,
  obligations, C11, slice, unit reuse/compile, fold/body C17, body slice, QBE)
  plus a native CLI driver for Core build/materialize.

Exact current blockers:

1. The self-host rejects the Native Core compiler closure on union narrowing;
   it cannot yet replace `bin/beagle-build-all` for that closure.
2. The existing `beagle-selfhost` binary exposes only hosted
   `ast/check/emit/emit-from-ast/facts-roundtrip`; there is no Core driver.
3. Core compilation still calls Racket for module-source resolution, AST
   projection/verification, and compiler-module emission.
4. Core lowering and C17/QBE emission execute under
   `bb -cp "$compiled"`, so packaging only the front end leaves the dominant
   2,198-second phase untouched.
5. The compiler runtime uses Clojure/JVM/Babashka facilities including EDN,
   JSON, filesystem/process APIs, and `clojure.java.shell`; the unified native
   driver must own equivalent closed host services.
6. Artifact provenance currently covers the seed NAR, not the full compiler
   source closure, generated compiler projection, Core driver, and
   materializer runtime together.

Stage 1 is complete only when the artifact directly compiles one exact Core
fixture through frozen native program and C17 bytes without Racket or
Babashka, while matching the oracle route byte-for-byte.

### Stage 2: the native compiler compiles itself

Stage 2 has no implementation today. The existing remint proves generated
source convergence, not executable convergence. A real stage 2 must:

1. run stage-1 `beagle-compiler-native` over the exact full compiler source
   closure;
2. emit every hosted compiler module and its Core-capable driver inputs;
3. materialize a second `beagle-compiler-native` through the same pinned,
   offline toolchain;
4. require exact equality of generated source trees, frozen native program,
   C17/QBE projection selected for the compiler, final executable, provenance
   manifest, and seed/full-closure sidecars;
5. run the stage-2 executable over the same closure and require the stage-3
   candidate to equal stage 2, preventing a one-generation accidental match.

The external GraalVM packager is the hard conceptual gap. If stage 2 still
requires GraalVM to turn generated Clojure into a binary, Beagle has a source
fixpoint plus reproducible packaging, not compiler executable self-hosting.
The campaign may use that as an intermediate gate, but the final binary
fixpoint requires Beagle's own Core materializer path to produce the compiler
artifact.

## 3. Racket hot-path inventory

### Load-bearing measured paths

| Hot path | Current Racket/Babashka seam | Measured cost | Native-binary requirement |
| --- | --- | ---: | --- |
| Fram server native artifact | `fram:bin/fram-native-build` calls the pinned public `beagle build --materializer c17,qbe`; `beagle-build-core` uses Racket to emit the 13 compiler modules, then Babashka runs their Core pipeline. | C17 emission **2,198 s**; earlier complete QBE attempt held a core for roughly 40-43 minutes. | A full `beagle-compiler-native build --materializer ...` route. Point `FRAM_BEAGLE` at its immutable CLI or make public `beagle` select it. Bind Fram's compiler identity to the artifact closure digest, not a source-tree sweep. Existing stage0-only routing is insufficient. |
| Native source-freeze validation | `native-core/validation/slice-types/run.sh` calls `bin/beagle-facts`, then Racket `bin/beagle-build-all`, then `bb`. | 180.003 s on one Racket process with no namespace; two 300 s seeds produced no artifact; now preflight with a 1,200 s bound. | Replace build-all with `BEAGLE_NATIVE_COMPILER_BIN=/nix/store/.../bin/beagle-compiler-native emit-bundle`; then replace `bb` pipeline execution with the binary's slice command. Preserve artifact hashes. |
| Full typed-stage validation | `native-core/validation/slice-types-full/drive.sh` calls Racket `beagle-ast`, Racket build-all, then `bb native.slice`. | Same 300 s no-artifact class; preflight 1,200 s bound. | Direct native `ast` plus Core slice command; driver accepts `--compiler` or the same explicit binary env. |
| Store 21-source seed | Store builder calls public `beagle build --materializer`; Core build compiles the compiler through Racket and executes it under `bb`. | Fully uncapped seed **1,622 s**, then 45 pending native bodies on the sealed compiler; earlier 165/175/180/300 s attempts produced no artifact. | `BEAGLE_STORE_BEAGLE=/nix/store/.../bin/beagle-compiler-native`, full Core CLI parity, and Store manifest provenance updated to bind the native compiler artifact. The 45 pending bodies are a separate product-correctness blocker. |
| Bounded Store mint/activation | Same Store caller after seed/checkpoint selection. | 165 s QBE checkpoint timeout, 30 s canonical decode timeout, 124 s focused attestation gate; final mint still not complete. | Same full binary plus checkpoint-wire compatibility and identical `beagle-store-native-build/v1` receipts. A front-end-only binary cannot decode/lower/materialize the frozen program. |
| Self-host release parity | `verify-selfhost.sh` invokes Racket for every oracle emit/AST/bundle leg and uses Racket `run-bounded.rkt` as supervisor. | The integration owner is 360 s; the red candidate completed with 123/58 before the bound. Current seal is 136/44; no exact green wall time is banked. | Use the native compiler for the self leg and a platform supervisor; keep the frozen Racket oracle only for the sampled comparison leg until parity closure. |
| Remint/fixpoint | Plain remint uses repeated Babashka seed emissions; `--oracle` adds Racket build-all. | CI design records ~24 s bb-only; recovery drill measured ~32 s generation 1 plus ~21 s generation 2, or ~31 s pinned Racket. | Stage-1 binary can emit generation 1; executable stage-2 is required before replacing generation-2 Babashka honestly. Keep `--oracle` sampled until zero semantic divergence. |
| Active compiler gate | `bin/beagle-ci`, `bin/beagle-test`, and `tier-runner.rkt` schedule Racket/raco workers. | Today's active suite: 2,418 assertions plus gated suites; tier workers have a 420 s owner. Historical CI design estimates 954-1,173 s on four cores. | Port language behavior to the one-binary conformance/fixture manifest; do not merely rewrite the Racket coordinator. Platform supervision replaces `run-bounded.rkt`. |
| Conformance corpus | `run-corpus.py --compiler` currently targets public `beagle`, which sources Racket before every case. | 263 decided cases; no honest current wall time. | Pass `--compiler /nix/store/.../bin/beagle-compiler-native`. The binary must implement public `check/build` flags and all Core profiles before the whole corpus is eligible. |
| Routine hosted build/check/AST | Public `bin/beagle` sources `_beagle-racket` before dispatch. `beagle-dev` is opt-in build-only. | No repository comparison measurement; native stage0 startup is documented near 7 ms, not end-to-end compile time. | First use existing `BEAGLE_NATIVE_BIN` for parity-safe hosted shapes, then default the full compiler artifact after the 44 semantic gaps close. |
| Facts, Store facts, code-as-facts | Public facts-roundtrip reaches the seed only after Racket setup; `beagle-facts`, `beagle-roundtrip`, certification, and code-as-facts gates invoke Racket directly. | No single banked wall time. | Direct full-compiler facts subcommands; retain certification as sampled oracle evidence until retirement. |

### Complete grouped executable inventory

The following current path families shell into Racket, raco, `_beagle-racket`,
or the Racket `run-bounded.rkt` supervisor. Grouping avoids treating every test
fixture as a separate architectural seam while preserving every caller found.

**Public compiler and authoring routes:** `beagle:bin/beagle`,
`beagle-{ast,ast-bundle,build,build-all,build-core,check,check-all,validate}`,
`beagle-{callers,callgraph,cheatsheet,doc-fill,expand,explain,explain-type}`,
`beagle-{facts,fields,fix,fmt,impact,import-nix,js-coverage,langs,lsp}`,
`beagle-{materialize-wasm,native-exe,provides,rename,repl,rewrite,roundtrip}`,
`beagle-{schema,semantic-index,shadow-diff,sig,syntax,test-tag,ts-externs}`,
and the daemon foreground/background pair. `beagle:bin/beagle-downstream` and
the public dispatcher make these fan out into consumer builds.

**Release and correctness routes:** `beagle:bin/beagle-ci`,
`beagle:bin/beagle-test`, `beagle:bin/beagle-test-facts`,
`beagle:bin/beagle-remint --oracle`,
`beagle:bin/beagle-certify-facts-roundtrip`,
`beagle:self-host/verify-selfhost.sh`,
`beagle:self-host/native/verify-native.sh`,
`beagle:fuzz/harness/{run.sh,harness.clj}`, and the release/native workflows.

**Focused tests that explicitly invoke Racket:** byte-stable emit;
code-as-facts authoring, authoring verbs, delete, rename, and umbrella runner;
downstream CI/drift; engine demo; gate-fact maintainer; Racket-scope; Store
defcheck; and Store codegraph execution. These remain test-specific consumers
until their owned production route moves.

**Native validation drivers with direct Racket setup:** atom, file lease, host
context, process FIFO, SIMD f64, slice buffer, slice parallel runtime, and zero
variant. The two Store type gates additionally invoke `beagle-build-all` as
described above.

**Every direct `run-bounded.rkt` caller:**

- `beagle:bin/beagle-build-core`
- `beagle:bin/beagle-materialize-wasm`
- `beagle:bin/beagle-test`
- `beagle:self-host/verify-selfhost.sh`
- `beagle:bin/test/gate-fact-maintainer/run.sh`
- `beagle:bin/test/code-as-facts/rename.sh`
- native validation: atom, file lease, host context, process FIFO, SIMD f64,
  slice buffer, and slice parallel runtime

`run-bounded.rkt` is supervision, not compilation. A native compiler does not
remove it automatically. Replace it with one platform-owned supervisor seam
after compiler routing, preserving deadlines, process-group reap, and
completion receipts.

## 4. Honest speed floor

No repository measurement compares the full Core compiler under Babashka with
the proposed native compiler binary. The only direct native-stage0 evidence is
startup near 7 ms and one hosted fixture parity match. Therefore the guaranteed
minimum improvement is deliberately conservative:

| Number | What existing native stage0 guarantees | Campaign measurement floor |
| --- | --- | --- |
| Fram C17 emission 2,198 s | **0 s guaranteed improvement.** This timer is inside the Babashka-run Core emitter. | The first full-binary gate must beat 2,198 s on identical bytes; no multiplier is banked. `COLD-EMIT-T0` still requires ≤165 s with 16 workers, and `COLD-30` still requires ≤20 s total native shard work. |
| Native compiler closure >300 s without artifact | The same closure reached a self-host rejection in 1.895 s, proving startup and traversal are not intrinsically minute-scale. It does not prove successful emission time. | First acceptance ceiling: ≤30 s for exact compiler-bundle emission and byte identity. This is a campaign gate, not a claimed result. |
| Store seed 1,622 s | **0 s guaranteed end-to-end improvement.** The binary removes compiler-projection overhead only after parity; the remaining lower/materialize work and 45 pending bodies remain. | Report projection, check/freeze/lower, C17, QBE, and publication separately. Do not assign a total target until the first successful native profile exists. |
| 165/175/180/300/1,200 s Store/native bounds | Front-end replacement can turn the no-artifact compiler projection into a verdict; it does not prove the rest of each gate fits. | Keep the existing bound for the first comparison, record phase deltas, then tighten only from a passing trace. |
| Remint ~24 s or 32+21 s | A stage-1 binary may reduce generation 1, but current generation 2 still requires executing newly emitted source under Babashka. | No gate target changes until executable stage-2 exists. |
| Self-host parity owner 360 s | Native self legs can fall, but Racket oracle legs remain while the 44-gap seal is authoritative. | Measure native-only, sampled-oracle, and full-oracle modes separately; the routine lane moves only after zero semantic divergence. |
| 263-case corpus | No current timing exists. | First native whole-corpus result establishes the baseline; release law still requires the routine verification loop under three minutes. |

The 1.895-second rejection is the strongest reason to move immediately, but it
is not permission to advertise a successful two-second compiler.

## 5. Risk map and gates

| Risk/gap | Current evidence | Gate that detects it | Promotion consequence |
| --- | --- | --- | --- |
| 44 known self-host/oracle failures | Current seal is 136/44 with stable label digest, not green parity. Families include accept/reject, error core, emitted bytes, AST/externs, purity verdicts, and infrastructure/mint failures. | Release self-host seal plus saved normalized label ledger. | Stage 1 may be opt-in; no default or oracle demotion until semantic failures are zero and infrastructure deferrals are explicit. |
| Native compiler closure union narrowing | Exact closure rejected in 1.895 s. | New `NATIVE-COMPILER-CLOSURE-PARITY` tree comparison and verdict/diagnostic parity. | Blocks the first hot-path rewire. This is the biggest blocker. |
| Hosted namespace admission difference | Self-host admits only documented prefix families plus extern authorization; oracle also uses typed stdlib catalog. | Module rungs 6/7 and conformance cases. | Must be closed or represented as decided contract before public default. |
| Cross-module `defmacro` import absent | Oracle imports macro surface; self-host external projection carries none. | Add a closed-bundle macro case to the parity ladder and conformance manifest. | Blocks compiling the full compiler if its closure begins using cross-module macros. |
| Parametric-union member ctor/accessor import absent | Only union name is imported today. | Exact compiler-closure and Store-closure cases. | Already adjacent to the observed union-narrowing blocker. |
| JS/Nix target-only parity incomplete | Emitters exist, but docs explicitly defer target ladders. | Target-specific hosted corpus and differential fuzz. | Hosted default remains per-profile, never inferred from Clojure parity. |
| Core pipeline absent from binary | No stage0 command accepts bare `.bgl` or materializer flags. | `SELF-COMPILER-STAGE1`: one Core fixture to frozen program and C17, zero Racket/BB process roots. | Blocks any claim against Fram or Store emission. |
| Source fixpoint mistaken for binary fixpoint | Remint compares generated `.clj`; GraalVM packaging is external. | `SELF-COMPILER-BINARY-FIXPOINT`: exact stage1/stage2/stage3 executable and manifest bytes. | Blocks the “compiler-compiling-compiler” claim and Racket retirement. |
| Common-mode self-host bug | A compiler can reproduce the same wrong behavior forever. | `bin/beagle-remint --oracle`, `verify-selfhost`, `verify-native`, differential fuzz, and independent decided corpus. | Keep frozen Racket sampling until decided corpus authority and zero semantic divergence. |
| Stale native artifact | Checkout-local executable is absent today; mutable builds are trusted only with exact seed-NAR sidecar. | Existing `stage0-select.sh`; extend to full compiler closure digest and Nix derivation. | Never silently fall back from an explicit full-compiler path. |
| Supervisor dependency mistaken for compiler dependency | Several routes still launch Racket solely for `run-bounded.rkt`. | Tracked process-root census and supervisor receipt tests. | Racket-free claim requires both compiler and supervisor removals. |
| Byte identity lost in driver rewiring | Fram/Store receipts bind compiler/source inputs and artifact bytes. | Existing cold-vs-hit manifests, Native reports, QBE frontier, Store READY, and new dual-run byte compare. | Every rewire begins shadow-only and falls back closed. |

## 6. Staged bootstrap and rewiring plan

Each row is one worker seam. A worker owns only the named outcome and gate;
dependencies serialize shared contracts. “Dispatch” is the one-line brief
shape for an implementation campaign, not authorization from this document.

### Stage 1 — oracle-built full native compiler

| # | Seam | Outcome | Named gate | Dependencies | One-line dispatch shape |
| ---: | --- | --- | --- | --- | --- |
| 1 | Full compiler closure manifest | One canonical manifest enumerates self-host modules, handwritten runtime, 13 Native Core compiler modules, driver inputs, and toolchain identities. | `SELF-COMPILER-CLOSURE-MANIFEST`: missing/extra/reordered/changed input has one named failure. | None. | “Own only the full-compiler closure manifest and its pure verifier; no compiler behavior.” |
| 2 | Union/parity closure unblock | **REPAIRED — all thirteen closure modules are now byte-identical.** The five systematic divergences were repaired on the NATIVE projection; all retained oracle modules load under Babashka, and the extra native-only `:refer :all` plus generated `native.core` import rewrite is absent. Current-main native artifacts for the final three modules were regenerated after `204a96d0`. The three concurrent Racket oracle compilations ran at nice 19 with a 12,000-second per-module bound and exited 0: `unit_reuse` wall 157 s, `unit_compile` wall 159 s, `body_slice` wall 203 s. **Gate `NATIVE-COMPILER-CLOSURE-PARITY` PASSES: 13/13 byte-identical.** Receipts: prior `/tmp/beagle-require-parity-20260818`, `/tmp/beagle-seam2-parity8-20260818`, and `/tmp/beagle-seam3-order2.JMKeJD/compiled/native`; final native artifacts `/tmp/beagle-seam2-parity-tail-20260818/native/native/{unit_reuse,unit_compile,body_slice}.clj`; oracle artifacts `/tmp/beagle-seam2-parity-tail-20260818/oracle/native/{unit_reuse,unit_compile,body_slice}.clj`; per-module supervisor/status/stderr receipts `/tmp/beagle-seam2-parity-tail-20260818/control/oracle-{unit_reuse,unit_compile,body_slice}.{supervisor,status,stderr}`. | `NATIVE-COMPILER-CLOSURE-PARITY`: **PASS — 13/13 byte-identical.** | 1. | “Make self-host compile the exact 13-module Native compiler closure; stop at byte parity.” |
| 3 | Core-capable native CLI | One driver composes self-host front end with freeze/lower/obligations/C17/QBE and preserves public Core flags, closed roots, entries, reports, and atomic output. | `SELF-COMPILER-CORE-CLI`: small Core fixture yields oracle-identical frozen program, reports, C17, QBE/refusal, status, and streams. | 2. | “Add only the full compiler Core CLI contract; no packaging or caller rewires.” |
| 4 | Stage-1 reproducible artifact | **BLOCKED on the exact current-main build at `20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab`.** The supervised C17/LP64 build ran 3,709 s (61m49s), with load 4.66/5.62/6.07 at launch and 3.45/3.72/4.12 at completion. Source projection and freeze passed; `source-to-typed` rejected with 1,140 blocking occurrences across 44 diagnostic codes, 49 exact code/reason shapes, and 1,092 affected function labels. No `beagle-compiler-native` materialized. Exact ledger: `~/.local/state/beagle/stage1-bootstrap/20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab/remaining-rejection-inventory.tsv`. | `SELF-COMPILER-STAGE1`: **BLOCKED before the gate** because no artifact exists; NAR identity, standalone-child observation, and native compile timing were not run. | 1, 3, plus closure of the recorded source-typing inventory. | “Close the recorded Native Core rejection shapes, then rerun this exact supervised build; do not annotate compiler functions around the type system.” |
| 5 | Stage-1 breadth qualification | Stage-1 compiles its own source bundle, the Store 21-source closure to the first valid frozen program, the Fram pinned closure to the first valid frozen program, and all eligible conformance cases. | `SELF-COMPILER-STAGE1-BREADTH`: exact oracle artifact/diagnostic parity; known product failures stay named rather than waived. | 4. | “Qualify the stage-1 binary on self, Store, Fram, and corpus inputs; change no compiler.” |

### Stage 2 — executable fixpoint

| # | Seam | Outcome | Named gate | Dependencies | One-line dispatch shape |
| ---: | --- | --- | --- | --- | --- |
| 6 | Native remint | Stage-1 emits the entire full-compiler closure and reproduces the oracle bootstrap source tree, frozen program, and materializer inputs byte-for-byte. | `SELF-COMPILER-NATIVE-REMINT`: oracle bootstrap = stage-1 output for every declared artifact. | 4, 5. | “Use stage-1 to remint only the full compiler closure; compare every bootstrap byte.” |
| 7 | Stage-2 compiler artifact | Stage-1-produced compiler inputs build a stage-2 executable through Beagle's Core materializer path, not GraalVM-only packaging. | `SELF-COMPILER-STAGE2`: stage-2 runs the same Core canary with zero Racket/BB/Graal runtime dependency. | 6 and Core runtime gaps exposed by 5. | “Materialize stage-2 from stage-1 outputs; own only executable production and provenance.” |
| 8 | Binary fixpoint and recovery pin | Stage 2 produces byte-identical stage 3; executable, manifest, frozen program, projections, and sidecars all match. Bank two immutable known-working bootstrap artifacts/runbook evidence. | `SELF-COMPILER-BINARY-FIXPOINT`: stage2 = stage3 bytes and both compile the decided bootstrap canary. | 7. | “Close executable fixpoint and recovery evidence; no production routing.” |

### Hot-path rewiring

| # | Seam | Outcome | Named gate | Dependencies | One-line dispatch shape |
| ---: | --- | --- | --- | --- | --- |
| 9 | Core compiler projection route | `beagle-build-core` uses `BEAGLE_NATIVE_COMPILER_BIN` for the compiler-module bundle instead of Racket `beagle-build-all`; cache identity includes artifact digest. Racket remains an explicit shadow. | `CORE-COMPILER-PROJECTION-NATIVE`: exact compiled tree, streams, miss/hit keys; ≤30 s cold projection. | 2, 4. | “Rewire only build-core compiler projection behind an explicit native selector and dual-run gate.” |
| 10 | Core lowering/materializer route | `beagle-build-core` invokes the full compiler binary instead of `bb -cp compiled`; platform supervisor replaces Racket supervision on this path. | `COLD-EMIT-T0` plus `T0-PARALLEL-BYTE-IDENTITY`: 4/8/16 workers, exact serial bytes, empty-cache 16-worker emission ≤165 s. | 7, 9. | “Move only Core lower/emit execution into the binary; preserve reports, caches, and materializer bytes.” |
| 11 | Native validation and test route | Source-freeze/full typed-stage and the direct native validation drivers select the immutable binary; Racket versions become sampled reference jobs. | `NATIVE-PREFLIGHT-NATIVE`: both Store gates finish with verdicts under three minutes and identical artifacts; all supervisor receipts pass. | 9, 10. | “Rewire native validation drivers and supervisor only; preserve each gate's assertions.” |
| 12 | Fram and Store production builders | `FRAM_BEAGLE` and `BEAGLE_STORE_BEAGLE` point to the immutable full compiler; input manifests and READY/provenance bind its closure digest. | Fram pinned COLD/WARM identity gate plus Store seed/mint/READY and release-receipt gates; no fallback on explicit binary failure. | 10, 11. | “Route Fram and Store builders to the full compiler and preserve every artifact/receipt contract.” |
| 13 | Corpus, public default, and oracle demotion | The 263-case corpus and parity-safe public commands use the native compiler by default; daily shadow sampling retains frozen Racket until the 44 semantic gaps are zero and retirement seals pass. | `SELF-COMPILER-PUBLIC`: whole corpus green, zero semantic divergence, remint/native/fuzz green, tracked process-root census shows no routine Racket. | 8, 11, 12 and parity closure. | “Promote native compiler to corpus/public default; demote Racket only after zero-gap evidence.” |

Parallel execution is safe only across disjoint code after its dependencies are
landed. In particular, seams 9 and 10 both touch `beagle-build-core` and are
strictly sequential; Fram and Store are separate repositories but share the
compiler contract and start only after seam 11 proves it.

## 7. Integration into the build-speed gate structure

Do not edit `beagle:beagle-test/conformance/authority/positioning/BUILD-SPEED-PROGRAM.md`.
Integrate by treating the self-compiler gates as prerequisites and phase
owners inside its existing measurements:

### COLD

- Add `SELF-COMPILER-STAGE1`, `SELF-COMPILER-STAGE2`, and
  `SELF-COMPILER-BINARY-FIXPOINT` before native compiler routing is eligible.
- Seam 9 moves serial Racket compiler projection into the paper's
  **source decode/check/freeze/facts ≤4 s** component. Its first local gate is
  ≤30 s; it does not satisfy the final 4-second budget.
- Seam 10 is the first change that can move the recorded **2,198 s native/C
  emission** number. Its acceptance is already named by the paper:
  `T0-PARALLEL-BYTE-IDENTITY` and `COLD-EMIT-T0` ≤165 s. It receives no credit
  toward `COLD-30` until the paper's ≤20 s native shard-emission/compilation
  budget passes.
- The canonical workload remains `fram-server-native-v1`, with the compiler
  artifact digest added to the pinned manifest. The old and new compiler paths
  run from distinct empty cache roots and compare all published bytes.

### WARM

- The paper requires **zero compiler phase work**. A faster compiler should not
  move `WARM-250`; any compiler process root on a same-commit hit is a failure.
- Use the native binary only for the cold fallback that populates the exact
  immutable artifact. Preserve `WARM-T0`, zero emission misses, zero unexplained
  C misses, and `WARM-O1-VERIFY`.
- Today's Fram record reports a 0.185-second verified whole-result reuse on a
  different measured route. It is encouraging but does not replace the pinned
  paper workload and promotion law.

### INCREMENTAL

- A one-shot native binary removes host startup/interpreter cost but cannot by
  itself meet `INCREMENTAL-100`. The paper budgets only 35 ms for
  check/freeze/lower/shard production.
- Stage 2 must expose an in-process/resident request surface or reusable
  compiler state before it can enter incremental timing. That work remains
  inside T1.1-T1.7; this campaign does not create a second cache or identity
  authority.
- `INCREMENTAL-SHADOW-EQUALITY` remains the first gate. The self-compiler adds
  compiler artifact identity and stage-read receipts to its manifest; it does
  not weaken exact caller-cone, Store FLIP, or fact-family/consumer-edge
  prerequisites.

### Gate ordering

```text
NATIVE-COMPILER-CLOSURE-PARITY
  -> SELF-COMPILER-STAGE1
  -> SELF-COMPILER-STAGE1-BREADTH
  -> SELF-COMPILER-NATIVE-REMINT
  -> SELF-COMPILER-STAGE2
  -> SELF-COMPILER-BINARY-FIXPOINT
  -> CORE-COMPILER-PROJECTION-NATIVE
  -> COLD-EMIT-T0 / T0-PARALLEL-BYTE-IDENTITY
  -> NATIVE-PREFLIGHT-NATIVE
  -> Fram + Store production shadow equality
  -> SELF-COMPILER-PUBLIC
```

The fastest legitimate first move is seam 2. It is already isolated by a
1.895-second failing proof, unlocks the 300-second compiler-projection paths,
and provides the exact closure needed to build the full native compiler.

SELFCOMP-MAP-DONE 13 seams — self-host still rejects Native Core compiler closure on union narrowing
