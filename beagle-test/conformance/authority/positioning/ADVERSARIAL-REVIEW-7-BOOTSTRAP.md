# ADVERSARIAL REVIEW 7 — BOOTSTRAP: recovery after self-host failure

## Scope and evidence state

This review asks a narrower question than whether Beagle is Racket-free:
**if the current compiler cannot compile itself, can an agent reconstruct a
working compiler without trusting that broken compiler?**

Evidence is from Beagle main `96e5d08bfe35d186a137d962d960648b21aba45f`, the
read-only self-host stages lane at
`51a4ab784f7f84130b98d00bdec116948c8540d0`, the five immutable pin checkouts,
and a live drill in detached worktree
`~/code/beagle/worktrees/adv-bootstrap`. No shared lane or product checkout was
edited, and no code was landed.

| Finding | Verdict | Short reason |
| --- | --- | --- |
| A. A working recovery compiler exists | **PROVEN** | The `4c05adc3…` pin's Racket compiler and its checked-in Babashka seed both compiled the current main HEAD's complete 12-module self-host bundle. |
| B. The seed can recover itself | **PROVEN** | The seed-emitted compiler compiled the same bundle again and reproduced `main.clj` byte-for-byte. |
| C. Recovery continuity is operationally guaranteed | **REAL-OPEN-GAP** | Pin advancement is manual, no rule retains two known-working recovery pins, no canary builds pins against current HEAD, and no incident runbook is discoverable in Beagle's docs. |

## Finding A — recovery layers that exist today

### 1. Immutable compiler pins

Every checkout under `~/code/beagle/pins` was a clean detached checkout at its
directory object ID. The sidecars, including their declared consumers, are:

| Pin object | Sidecar and consumers |
| --- | --- |
| `487191b25f2493a5e8b50df0bc9421b12c7843bc` | `beagle:pins/487191b25f2493a5e8b50df0bc9421b12c7843bc.pin`; release `v0.23.0`; `fram:`. |
| `4aaf833c1edd27f155fbb744dfbbfa8ba9f1b55d` | `beagle:pins/4aaf833c1edd27f155fbb744dfbbfa8ba9f1b55d.pin`; `greywrought:`, `gjoa:`, `nixos-config:`, `wake:`, `fram:`. The prose identifies this as the Beagle v0.22.0 compiler/runtime pin. |
| `4c05adc3315888e913b8b34a7cdf799ca808357c` | `beagle:pins/4c05adc3315888e913b8b34a7cdf799ca808357c.pin`; `nixos-config:`, `gjoa:`. The prose identifies this as the FINAL compiler/runtime pin used for Firn tooling and packaged executables. |
| `4f9c6f874157e3e7746e7e5f47c8748260511f25` | `beagle:pins/4f9c6f874157e3e7746e7e5f47c8748260511f25.pin`; `greywrought:`. Native Core cache and qualified-global repair pin. |
| `a39e2b7fff8543c91d6fd6ecd50e6ba8c641b8ec` | `beagle:pins/a39e2b7fff8543c91d6fd6ecd50e6ba8c641b8ec.pin`; `greywrought:worktrees/playable`. Incident compiler/runtime pin. |

The pins are immutable source checkouts, not a managed archive of proven
bootstrap artifacts. They contain the self-host source and checked-in seed,
but no `self-host/native/beagle-selfhost` executable. The operationally useful
recovery payload is therefore the pinned seed or the pinned Racket source
compiler, not a binary presumed to be present in every pin.

The pin immutability and retirement rules are real protection: a live pin cannot
be edited or removed while a declared consumer still names it, and advancement
requires a new hash-named pin. That policy is in the repository operating rules
and is not a build-health guarantee.

### 2. Racket route when hosted dispatch is broken

The stage-3 dispatcher tries hosted stage0 first and then sources the pinned
Racket resolver; its own comment and control flow make the fallback explicit
(`beagle@selfhost-dispatch:bin/beagle:20-43`). The hosted seam handles only
`build`, `check`, `ast`, and `ast-bundle`
(`beagle@selfhost-dispatch:bin/_beagle-hosted-dispatch:288-298`). If the hosted
file is absent, cannot select stage0, rejects a shape, or emits a diagnostic,
the call returns the existing Racket command.

With hosted dispatch entirely unavailable, these compile paths still work when
the pinned Racket environment is available:

- `beagle build SOURCE` for one hosted source uses `bin/beagle-build`, and
  multi-source/unsupported-shape builds use `bin/beagle-build-all`
  (`beagle@selfhost-dispatch:bin/beagle:255-297`; the scripts source
  `beagle:bin/_beagle-racket:1-45`). This covers the hosted `.bclj`, `.bjs`, and
  `.bnix` profiles and closed source bundles.
- `beagle check SOURCE` and multi-file checks use `bin/beagle-check` or
  `bin/beagle-check-all` (`beagle@selfhost-dispatch:bin/beagle:233-253`;
  `beagle:bin/beagle-check:1-22`; `beagle:bin/beagle-check-all:1-17`).
- `beagle ast SOURCE` and `beagle ast-bundle` remain Racket projections
  (`beagle@selfhost-dispatch:bin/beagle:311-315`; `beagle:bin/beagle-ast:1-14`;
  `beagle:bin/beagle-ast-bundle:1-9`).
- Core compilation, native executable linking, and the Wasm materializer remain
  Racket-owned (`beagle@selfhost-dispatch:bin/beagle:255-264`;
  `beagle:bin/beagle-build-core:1-23`; `beagle:bin/beagle-native-exe:18-23`;
  `beagle:bin/beagle-materialize-wasm:9-19`).
- Stage 3's downstream `.bnix` child attempts native stage0 and falls back to
  the exact pinned-Racket invocation for Core, checks, unsupported options, or
  any hosted failure (`beagle@selfhost-dispatch:bin/_beagle-downstream-compiler:1-19,60-74,86-105`).

Two distinctions matter. Stage 3's `beagle facts-roundtrip` case directly
executes the seed after the Racket front-door setup
(`beagle@selfhost-dispatch:bin/beagle:339-342`), so it is not a Racket-only
compiler path. The older direct Store-facing `bin/beagle-facts` and
`bin/beagle-roundtrip` scripts still invoke Racket
(`beagle:bin/beagle-facts:12-35`; `beagle:bin/beagle-roundtrip:10-12`).

### 3. Racket-free seed and native stage0

The checked-in seed is a working compiler: the self-host README calls the
Babashka seed the fallback and documents `ast`, `check`, and `emit` commands
(`beagle:self-host/README.md:1-16,63-78`). The source driver also exposes
`ast`, `check`, `emit`, `emit-from-ast`, and `facts-roundtrip`, resolves an
explicit closed `--source` bundle or `--module-root`, and emits `clj`, `js`, and
`nix` (`beagle:self-host/src/selfhost/main.bclj:1-20,55-66,552-558,784-852`).

The native stage0 is the same seed compiled as a GraalVM executable; the
selector only trusts a checkout-local native binary when its
`.seed-nar-hash` matches the current seed and otherwise falls back to Babashka
(`beagle:self-host/native/stage0-select.sh:1-5,27-72`). The native artifact is
built and checked in CI, with native = Babashka seed = Racket oracle parity
(`beagle:.github/workflows/native.yml:1-15,79-114`). It is a current recovery
layer in a release checkout or artifact, but it is not present inside the five
source pins enumerated above.

### 4. Seed fixed-point and parity checks

The recovery ladder has several real checks, but they certify the current
checkout's seed rather than the external pins:

- `bin/beagle-remint` enumerates every self-host source, emits generation one
  with the seed, rejects stale seed files, and compares generation one with the
  tracked seed byte-for-byte (`beagle:bin/beagle-remint:20-29,54-108`).
- `bin/beagle-remint --oracle` compiles the same closed bundle through
  `bin/beagle-build-all` and compares the Racket output to the seed
  (`beagle:bin/beagle-remint:110-137`).
- `bin/beagle-remint --promote` requires generation one to compile the source
  again as generation two with byte identity, then runs each generated module's
  self-test before copying output into the seed
  (`beagle:bin/beagle-remint:140-165,172-183`).
- `self-host/verify-selfhost.sh` isolates module self-tests, emit parity, AST
  parity, and full-chain byte parity, then checks closed multi-module bundles
  (`beagle:self-host/verify-selfhost.sh:1-22,122-132,179-264,593-674`).
- `self-host/native/verify-native.sh` compares native output independently with
  both Babashka seed output and the Racket oracle
  (`beagle:self-host/native/verify-native.sh:1-15,32-48,84-117`). CI runs the
  bb fixpoint and the three-way oracle gate
  (`beagle:.github/workflows/test.yml:19-37,168-174`).

These checks prove a fixed point and parity for the current seed. They do not
prove that any older pin can compile today's HEAD.

## Finding B — live recovery drill

The drill created the requested detached checkout at current main HEAD:

```text
git -C beagle: worktree add --detach \
  beagle:worktrees/adv-bootstrap
HEAD 96e5d08bfe35d186a137d962d960648b21aba45f
```

All compile commands ran under `nice -n 19`. The compiler pin was
`4c05adc3315888e913b8b34a7cdf799ca808357c`.

| Drill | Result | Receipt |
| --- | --- | --- |
| Pinned Racket compiler over all 12 current `self-host/src/selfhost/*.bclj` sources | PASS, `12 built, 0 error(s)` | `30.731s` elapsed; output `main.clj` SHA-256 `ae4cdd4912d8e0933d169ec079fabd9ebc42cd3ad3c499da0db15439307cc1ff`. |
| Pinned Babashka seed over the same 12-source closed bundle | PASS, all 12 emitted | `32s` aggregate elapsed; output `main.clj` SHA-256 `06548fbe3f0cf3a8d94fdb29e7332045551cb63affb606f6b5f7d8297bf12186`. |
| Generated compiler (seed output as classpath) over current `main.bclj` | PASS | `20.733s` elapsed; generation-one and generation-two SHA-256 both `06548fbe3f0cf3a8d94fdb29e7332045551cb63affb606f6b5f7d8297bf12186`; `cmp` exit `0`. |

The warnings observed were existing lint warnings about capitalized `E` and
shadowing; they did not change exit status or output identity. This is a live
proof that a pinned compiler can compile the current Beagle main HEAD's
self-host compiler today, and that the Racket-free pinned seed can bootstrap a
new working compiler from that output.

## Exact incident runbook

Assume the current HEAD compiler cannot compile itself. Do not edit a pin. Use
an existing retained pin and create a fresh recovery worktree from the broken
HEAD (or use the operator's already detached incident checkout):

```sh
PIN=beagle:pins/4c05adc3315888e913b8b34a7cdf799ca808357c
REC=beagle:worktrees/bootstrap-recovery
git -C beagle: worktree add --detach "$REC"
OUT=/tmp/beagle-bootstrap-recovery
mkdir -p "$OUT/seed/selfhost"

sources=("$REC"/self-host/src/selfhost/*.bclj)
bundle=()
for src in "${sources[@]}"; do bundle+=(--source "$src"); done

# Racket-free recovery from the immutable pin seed.
for src in "${sources[@]}"; do
  stem="$(basename "$src" .bclj | tr '-' '_')"
  nice -n 19 bb -cp "$PIN/self-host/seed" -m selfhost.main \
    emit --target clj "${bundle[@]}" "$src" \
    > "$OUT/seed/selfhost/$stem.clj"
done
cp "$REC/self-host/src/selfhost/rt.clj" "$OUT/seed/selfhost/rt.clj"

# Prove the rebuilt compiler is usable before replacing any local seed.
nice -n 19 bb -cp "$OUT/seed:$PIN/self-host/seed" -m selfhost.main \
  check "$REC/self-host/src/selfhost/main.bclj"

# If the source checkout needs the normal seed path, copy only into the fresh
# recovery worktree, never into PIN or the shared main checkout.
cp "$OUT/seed/selfhost/"*.clj "$REC/self-host/seed/selfhost/"
```

For the Racket fallback, use the same `REC` and source bundle, with the pinned
compiler's closed-bundle driver:

```sh
mkdir -p "$OUT/racket"
nice -n 19 "$PIN/bin/beagle-build-all" \
  "$REC/self-host/src/selfhost" --out "$OUT/racket"
cp "$REC/self-host/src/selfhost/rt.clj" "$OUT/racket/selfhost/rt.clj"
nice -n 19 bb -cp "$OUT/racket:$PIN/self-host/seed" -m selfhost.main \
  check "$REC/self-host/src/selfhost/main.bclj"
```

The measured budget is approximately 32 seconds for the Racket-free 12-module
seed remint plus 21 seconds for the generation-two proof, or 31 seconds for
the pinned Racket 12-module compile. These are local `nice 19` measurements,
not a repository performance guarantee.

## Finding C — gaps

1. **Pin advancement is manual and not coupled to Racket removal.** The five
   sidecars are consumer declarations, not a self-host recovery registry. The
   Beagle workflows contain current-tree remint/native checks but no job that
   advances or tests `~/code/beagle/pins`. No pre-Racket-removal acceptance rule
   requires a pin canary or recovery receipt.

2. **No rule guarantees an older working pin survives.** The immutability rule
   protects a pin while a named consumer exists, and `pin-retire` prevents
   premature deletion. Neither rule says that at least one, let alone two,
   older pins must remain known-good for current HEAD. A consumer pin can be
   valid for its consumer and still be unable to compile a future Beagle HEAD.

3. **No routine pin-builds-HEAD canary exists.** CI proves the current seed,
   native artifact, and Racket oracle agree. It does not run each retained pin's
   seed or Racket compiler against current main HEAD. The live drill here is
   evidence of today's state, not an ongoing guarantee.

4. **The incident runbook is not discoverable.** `beagle:self-host/README.md`
   documents ordinary seed use, remint, promotion, and native build, but it does
   not say how to select an older pin, compile a newer HEAD's complete closed
   bundle, preserve the pin, or replace a broken checkout's seed. No bootstrap
   recovery document is linked from the self-hosting summary.

5. **Native artifact availability is asymmetric.** Native stage0 is built and
   parity-checked in CI, but the pins retain source and seed, not the native
   executable. Recovery must know Babashka or Racket; “the pin” alone does not
   imply a runnable native binary.

## Minimal hardening plan

No implementation is landed by this review. The smallest real fixes are:

- Add a bounded `pin-builds-head` canary, run on every main change and before
  pin advancement, that enumerates each retained pin, compiles the current
  self-host bundle with both its seed and its Racket route, and stores the commit,
  pin object, status, and elapsed time. A failed pin is not retired or advertised
  as a recovery layer until repaired or explicitly reclassified.
- Make the pin policy retain **two independent known-good recovery pins** before
  any Racket-removal stage, with distinct object IDs and canary receipts. Never
  retire the older one until the replacement and the remaining pin both pass the
  current-HEAD canary.
- Keep advancement manual if desired, but require the canary receipt and an
  enumerated sidecar update as the release-stage acceptance record; automation
  should enforce evidence, not silently repoint consumers.
- Add `docs/bootstrap-recovery.md`, link it from `self-host/README.md` and
  `docs/self-hosting.md`, and include the exact pin-selection, closed-bundle,
  seed-remint, Racket-fallback, timing, and pin-immutability commands above.
- Either publish the native stage0 binary alongside a recovery pin, or state
  explicitly in the pin manifest that the supported recovery payload is the
  checked-in Babashka seed plus the pinned Racket source route.

The scenario is therefore recoverable today for the hosted self-host subset,
with a measured Racket-free path. It is not yet a continuously guaranteed
repository-wide recovery property, and it does not recover Core/materializer or
the remaining Racket-only tooling without the pinned Racket route.

BOOTSTRAP-REVIEW-DONE
FINDING A — PROVEN
FINDING B — PROVEN
FINDING C — REAL-OPEN-GAP
