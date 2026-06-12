# kernel — tick kernel for the minds game (Phase 0)

The reference implementation the Zig backend is specified against
(life-os thread `20260612232001`). ~300 agent minds on a chunked voxel
heightfield: belief EMA + social alarm contagion + alarm-escalation
state machine; panicked minds burrow (the voxel-edit commit path).

## Memory model (brief §2 + voxel amendment)

- **tick arena** — all per-tick temporaries; reset once per tick by the
  harness (`.free_all` in Debug so cross-tick retention = detected
  use-after-free; `.retain_capacity` in release). Kernel code never
  frees.
- **mind state** — double-buffered SoA; tick reads `read` immutably,
  commit writes the next state, swap.
- **voxel grid** — third store: preallocated chunks, read-only during
  the tick; dig edits accumulate in the arena and are applied in
  deterministic order at commit (chunks marked dirty).

## Toolchain

Zig **master-nightly via zig-overlay** (flake-pinned; at adoption
`0.17.0-dev.813+2153f8143` — bump with `nix flake update zig-overlay`).
Renderer: **sokol** (official sokol-zig bindings, commit-pinned in
`build.zig.zon`); one instanced-cube pipeline draws terrain + minds in
a single draw call (hand-written GLSL 410, GL core backend; sokol-shdc
when a second platform appears). `use_llvm/use_lld` are forced: zig
master's self-hosted ELF linker currently trips on sokol's libGL
reference.

## Run

    zig build run                      # window, auto-orbit camera
    zig build run -- --headless 10000  # conformance run, prints hash
    ./zig-out/bin/kernel --headless 1000 --seed 0x42

Same seed → same hash, every run. The hash folds every mind's decision,
alarm, and position plus every applied voxel edit, per tick — it is the
fingerprint the Phase 1 emitted code and the Babashka differential
oracle must reproduce exactly.

Phase 0 acceptance (2026-06-12): 10k headless ticks in 5.8s under the
Debug allocator, zero leaks, deterministic
`hash=0x5A73651575B8F2C3` (seed 0xBEA61E).

## Phase 1 — the kernel is beagle-authored (2026-06-13)

`src/sim_kernel.bgl` is the source of truth for every per-mind rule.
`./build-sim.sh` compiles it through TWO backends:

    zig -> src/sim.zig          (replaces the handwritten Phase 0 file)
    clj -> bb/sim_kernel.clj    (the babashka differential oracle)

Acceptance, both green:
- `--headless 10000` hash is IDENTICAL to the Phase 0 handwritten
  kernel: 0x5A73651575B8F2C3 — every decision, alarm, position, voxel
  edit, and rng draw preserved across the rewrite.
- `./differential.sh 5000` — same beagle source run on zig and
  babashka with a shared Splitmix64 stream: byte-identical outputs.

Golden snapshots (26 modules, each byte-pinned AND zig-compiled) live
in beagle-test/tests/fixtures/zig-golden/ (suite: emit-zig.rkt;
re-bless with BEAGLE_ZIG_BLESS=1 after reviewed emitter changes).

## Scale (semantics v2, 2026-06-13) — 200,000 minds

`-Dbig=true` builds the ambition profile: 512x512 voxel world, 200k
minds, 256 dread wells, 8-thread mind pass. Three engine changes, the
beagle kernel source untouched (scripts decide what, the engine
decides how fast):

- O(N) observation: per-cell alarm aggregates replace the exact-radius
  O(N^2) pair scan (cell = SOCIAL_CELL).
- Counter-based rng per (seed, tick, mind) — order-independent, so the
  pure pass parallelizes with bit-determinism intact.
- Static dread-well threat/direction fields precomputed once
  (hash-verified bit-pure: big 0xEEB6CD3DA6B13038 @500t, small
  0x5147A68B21CB59F1 @1000t held through the change).
- Render: per-chunk GPU buffers — terrain cost scales with digs, not
  world size; minds stream every frame.

## The crossing — script→engine (2026-06-13)

The §9.7 question ("should the emitter generate the SoA layout and
iteration loop?") is answered: yes, and it's shipped. From tick-step's
typed signature alone, the zig backend now generates the engine layer
in sim.zig:

- `MindInSoA` / `StepOutSoA` — one slice per record field, with
  alloc/get/set/copyFrom (harness owns lifetimes; emitted code still
  never frees).
- `tickAllRange(tick, seed, tick_no, in, obs, max_x, max_z, out, lo, hi)`
  — the gather→step→scatter range loop. The counter-rng determinism
  policy (`mix64(seed ^ mix64(tick_no+1) ^ mix64(i + C))`) moved INTO
  generated code; record-typed params ride as per-entity arrays,
  scalars broadcast.
- `promoteAll` — commit promotion as bulk @memcpy of the name-matched
  world-lifetime fields; output-only transients (act) stay behind in
  tick memory.

world.zig shrank to genuinely world-side work: grid/wells/fields,
observation gathering, thread spawns, fingerprint. Acceptance: both
conformance hashes held bit-exact through the handover, and the
generated engine is FASTER than the handwritten harness loop it
replaced (bulk promotion + direct SoA access): 4.5 → 3.7ms/tick on
the big profile.

Convention (pointed errors otherwise): `tick-step [ctx :- Ctx,
entity :- E, rest...] :- O`; E/O fields scalar (they cross the commit
boundary by memcpy); record params per-entity, scalar params
broadcast.

## Phase 3 benchmark — minds per millisecond (same beagle module)

| backend / build            | config        | per tick | mind-steps/ms |
|----------------------------|---------------|----------|---------------|
| zig Debug                  | 300 minds     | 0.088ms  | ~3,400        |
| zig ReleaseSafe            | 300 minds     | 0.011ms  | ~28,600       |
| zig ReleaseFast            | 300 minds     | 0.009ms  | ~34,900       |
| zig ReleaseSafe, 8 threads | 200,000 minds | 5.8ms    | ~34,500      |
| zig ReleaseFast, 8 threads | 200,000 minds | 4.5ms    | ~44,300       |
| zig ReleaseFast, generated engine | 200,000 minds | 3.7ms | ~54,000  |
| babashka (same source)     | per-call      | —        | ~62           |

200k minds at 3.7ms/tick = 22% of a 60fps frame budget. Headroom
before the next wall: more threads and @Vector in the hot pass. Watch
it: `zig build run -Dbig=true -Doptimize=ReleaseSafe`.

## Conformance

    ./conformance.sh

One command, red/green: small hash (1000t, x2 for determinism), the
5000-case zig-vs-babashka differential, big hash (500t, 200k minds).
Baselines live at the top of the script — re-baselining is a
deliberate, diff-visible edit. Run it after ANY emitter or harness
change; "CONFORMANCE GREEN" is the merge gate.

