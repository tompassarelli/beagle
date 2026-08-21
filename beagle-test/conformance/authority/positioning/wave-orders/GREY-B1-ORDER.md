# Greywrought B1 / W8 dispatch order

Planning baseline: `greywrought:main` at
`862a4ab0b2583ba611860a868bf18b6526b6c7f2` (`862a4ab0`), clean and equal to
`origin/main` when inspected on 2026-08-18. This is the W8 `REBUILD` row in
`beagle-program-handoff:positioning/GREY-QUALITY-PLAN.md`: replace parallel
client terrain state machines with one persistent collision mirror, one
bounded Native meshing worker, and one promotion authority for collision and
rendering.

## W0 consequence

The completion addendum in `todo:w0-adjudication-evidence.md` is reflected in
the exact tree:

- `greywrought:src/game/terrain-collision.bjs` and
  `greywrought:tests/terrain-collision.test.mjs` exist.
- `greywrought:src/host/native-terrain-candidate.bjs` and
  `greywrought:src/host/native-terrain-candidate-worker.bjs` are absent.
- The journal, shadow, Stage 4, Stage 5, and quiet-tail surfaces listed by W0
  are absent.
- `greywrought:src/host/native-terrain-stream.bjs` and the world-render
  acceptance pair contain W0's current rewires.

The old order's `d312b338` blocker is therefore closed. Do not restore either
candidate file or any candidate compatibility name.

## Current-tree findings

The W0 mirror is a design start, not the completed B1 rebuild.

| role | current path and symbol | observed state at `862a4ab0` |
|---|---|---|
| persistent collision mirror | `greywrought:src/game/terrain-collision.bjs`; `CollisionMirror`, `new-collision-mirror`, `receive-manifest`, `receive-settled-manifest`, `receive-baseline`, `receive-edit`, `receive-advance`, `committed-query`, `visible-sequence`, `visible-scope-token` | 847 lines and directly covered by 528 lines of focused tests; no production module imports `game.terrain-collision` |
| Native transport stream | `greywrought:src/host/native-terrain-stream.bjs`; `NativeTerrainStream`, `make!`, `expect-scope!`, `receive-batch!`, `receive-settled-manifest!`, `ready?`, `installed-generation`, `installed-sequence` | 274 lines; separately caches canonical brick bytes and calls the Native generation join synchronously |
| Native generation join | `greywrought:src/host/native-terrain-generation.bjs`; `NativeTerrainGeneration`, `install-baseline!`, `install-candidate!`, `install-edit!`, `advance!` | 648 lines; stages Native state and publishes scene state, but still contains the now-orphaned `install-candidate!` API and C225G candidate comments; edits affecting more than two owners are refused for a Worker path that W0 removed |
| visual publication | `greywrought:src/host/terrain-scene.bjs`; `PreparedTerrainGeneration`; and `greywrought:src/host/scene.bjs`; `prepare-terrain-generation!`, `commit-terrain-generation!`, `discard-terrain-generation!` | existing validated prepare/commit/discard boundary; collision mirror is not part of its settlement |
| legacy persistent hosted worker | `greywrought:src/host/terrain-runtime.bjs`, `terrain-worker-core.bjs`, `terrain-worker-transport.bjs`, `terrain-worker.bjs`, and `terrain-session.bjs` | the application starts this worker beside the Native stream; it maintains another `TerrainSession`, demands owner meshes, and drives repair settlement |
| application composition | `greywrought:src/app/main.bjs`; `start-terrain-runtime!`, `stop-terrain-runtime!`, `accept-terrain-batch!`, `sync-terrain-interest!`, `world-entry-evidence!` | starts both the hosted runtime/Worker and the Native generation stream, feeds each terrain batch to both, and admits readiness from facts split across them |
| browser proof | `greywrought:acceptance/fixtures/world-render-browser.mjs`, `greywrought:acceptance/world-render.browser.test.mjs`, and `greywrought:tests/terrain-worker-bundle.test.mjs` | still construct or inspect the hosted terrain worker path; they must prove the replacement Worker asset and unified promotion path |

The current production shape therefore has two independently advancing terrain
representations while the new collision mirror remains test-only. B1 is not a
rename and is not satisfied by the W0 deletion alone.

## Substrate ruling

Wrap the existing zero-import Native Wasm adapter and the repository's existing
Worker lifecycle/transfer conventions. Add only a thin bounded Native meshing
job contract. Do not adopt the current `host.terrain-worker-core` as the new
authority: it owns a second `TerrainSession` and calls the hosted mesher. Do not
restore the deleted one-shot candidate: it reconstructs and meshes a full
scope. Vendoring or forking an external substrate adds no capability needed by
this in-tree boundary.

Each worker job must carry one scope token, mirror generation, job identity,
canonical requested-owner list, and only the bounded brick payload needed for
those owners. The Worker may instantiate the existing Native Wasm adapter, but
it must not own an independently advancing full client mirror. The main thread
admits results and performs the sole collision-plus-render promotion.

## Target state and invariants

1. `CollisionMirror` is the sole persistent terrain content mirror in the
   browser client. It deep-owns committed and staging brick content and answers
   gameplay collision only from committed content.
2. A manifest, baseline, edit, advance, or scope change mutates only staging
   until all required collision content and requested-owner surfaces are
   complete and validated.
3. One main-thread settlement publishes the collision generation and visual
   generation together. Before settlement both consumers observe the prior
   generation; after settlement both observe the successor.
4. The Worker receives only canonical requested owners plus their bounded
   dependencies. It has no network authority, collision authority, scene
   handle, or direct publication capability.
5. Scope token, mirror generation, job identity, sequence, owner coordinate,
   dependency digest, and exact surface shape are checked before admission.
   Stale, duplicate, missing-owner, extra-owner, malformed, failed, or
   post-disposal results publish nothing.
6. Worker failure and disposal terminate the owned Worker, detach callbacks,
   discard staging, retain the committed mirror and scene, and trigger the
   existing bounded repair/failure route without a retry loop.
7. The production browser graph no longer imports or instantiates the hosted
   `TerrainSession` meshing runtime. Its modules and oracle tests may remain for
   later structural cleanup, but they are not a second live client mirror.
8. `native-terrain-candidate`, `install-candidate!`, and their C225G comments
   are absent from the tracked tree. No tombstone, alias, or removed-feature
   error remains.

## Independently verifiable seam list

B1 contains four disjoint file-ownership seams. They are ordered dependencies,
not concurrent landings. No worker may edit a path owned by another seam.

| seam | files touched | focused gates | cases proved |
|---|---|---|---|
| 1. mirror settlement data | `src/game/terrain-collision.bjs`; `tests/terrain-collision.test.mjs` | `bun test tests/terrain-collision.test.mjs` | deep-owned bounded job input, explicit ready-versus-published staging, fail-closed committed query, scope/sequence monotonicity, affected-owner and dependency completeness |
| 2. bounded Native worker contract | new `src/host/native-terrain-mesh-contract.bjs`; new `src/host/native-terrain-mesh-worker.bjs`; new `tests/native-terrain-mesh-contract.test.mjs`; new `tests/native-terrain-mesh-worker.test.mjs` | both new focused tests; `bun run build` | request/result shape, bounds, canonical owners, persistent sequential jobs, exact Native sequence/coordinate echo, transfer ownership, failure response, no full-scope or publication authority |
| 3. unified stream and atomic promotion | `src/host/native-terrain-stream.bjs`; `src/host/native-terrain-generation.bjs`; `src/host/terrain-scene.bjs`; `src/host/scene.bjs`; `tests/native-terrain-stream.test.mjs`; `tests/native-terrain-generation.test.mjs`; `tests/terrain-scene.test.mjs` | the three focused tests; `bun run build` | scope/job/sequence fences, only affected-owner jobs, duplicate/missing/malformed/transferred result handling, fault/discard, one collision/render settlement, removal of orphan candidate API |
| 4. application and browser cutover | `src/app/main.bjs`; `tests/character-app.test.mjs`; `tests/world-readiness.test.mjs`; `tests/reconnect.test.mjs`; `tests/prediction.test.mjs`; `tests/terrain-worker-bundle.test.mjs`; `acceptance/fixtures/world-render-browser.mjs`; `acceptance/world-render.browser.test.mjs` | five focused Bun tests; `bun run build`; `bun run test:browser-acceptance`; `bun run test:world-render` | one live terrain composition, teardown-before-callback, reconnect/scope/readiness fences, no callback after disposal, replacement Worker in the real bundle, visible terrain from the same accepted promotion |

Why this is not one seam: seam 1 is a pure mirror contract with a standalone
test; seam 2 is a message/Worker boundary with fake-Native tests and no scene or
application ownership; seam 3 owns the host join and scene transaction; seam 4
owns only top-level lifecycle and browser proof. Their path sets are disjoint,
and each can be reviewed and gated before its consumer lands.

## Ordering, lane, and common gate rules

Land in order `1 -> 2 -> 3 -> 4`. Each worker starts from the then-current clean
`greywrought:main` in a fresh lane under `greywrought:worktrees/`; no worker
uses the reserved `b1` leaf intended by the single-seam branch of this mission.
Stage paths by name, commit, run `safe-push --to main` from the lane, fast-forward
the clean main checkout, then remove the worktree and delete the local branch.

Before each lane is created, require:

- `greywrought:main` is clean and equals `origin/main`.
- The prior B1 seam's landed commit is an ancestor of main.
- No active non-superseded lane owns that seam's exact paths.
- The `playable`, `native-only`, `native-latency-measure`, `quality-f1`,
  `quality-f5`, `quality-r2`, `stage-5-recording`, and `wasm-v1-prediction`
  lanes remain untouched. `quality-f5` was absent when inspected. Coordination
  evidence classifies `stage-5-recording` and `wasm-v1-prediction` as
  superseded directions after W0; neither is a source to merge or rebase.

No build or test begins before 11:30 Asia/Taipei on 2026-08-18. After that
time, batch commands run at `nice 19`. In each fresh lane, run
`bun install --frozen-lockfile` once only when `node_modules` is absent. If the
focused tests lack generated `build/` modules, run `nice -n 19 bun run beagle`
as setup. Then run the seam's focused Bun tests and `nice -n 19 bun run build`.
Do not touch, take, poll, or wait on `/tmp/beagle-gate.lock`.

`bun run native:build` is not a planned B1 gate because the selected design
wraps the existing Native Wasm ABI without changing Native sources or its build
adapter. If a concrete implementation failure proves that
`tools/native-stateful-wasm.mjs`, `tools/native-stateful-wasm-build.mjs`,
`tools/native-stateful-wasm-host.c`, or `src/native/**` must change, stop that
seam and amend this order before expanding ownership. The amended gate must use
the three wasm toolchain exports from addendum 4 of
`todo:release-train-v024.md`; one retry at twice the failed phase bound is
authorized.

## DISPATCH-READY

### Seam 1 brief — mirror settlement data

From clean current `greywrought:main`, create a fresh lane and own only
`greywrought:src/game/terrain-collision.bjs` and
`greywrought:tests/terrain-collision.test.mjs`. Preserve the existing
`CollisionMirror` committed-query behavior and scope/sequence rejection.
Change the staging contract so complete collision content can yield a
deep-owned, bounded, canonical requested-owner job input without publishing the
successor mirror early; expose an explicit one-use settlement operation for the
later host transaction. Prove cold and incomplete queries fail closed,
committed queries stay stable while staging, scope tokens and sequences cannot
regress or equivocate, requested owners are canonical and bounded, every owner
has its required dependency bricks, and settlement cannot be replayed. After
11:30 run the common setup, then
`nice -n 19 bun test tests/terrain-collision.test.mjs`, followed by
`nice -n 19 bun run build`. Land only when those gates pass, `git diff --check`
passes, and only the two owned paths are changed.

### Seam 2 brief — bounded Native worker contract

Start after seam 1 lands. Create a fresh lane and own only the new paths
`greywrought:src/host/native-terrain-mesh-contract.bjs`,
`greywrought:src/host/native-terrain-mesh-worker.bjs`,
`greywrought:tests/native-terrain-mesh-contract.test.mjs`, and
`greywrought:tests/native-terrain-mesh-worker.test.mjs`. Wrap the existing
`greywrought-tools/native-stateful-wasm` adapter. Define a persistent Worker
protocol whose request carries exact job identity, scope token, mirror
generation, canonical requested owners, and only their bounded dependency
bricks. Return exactly one validated Native surface result per owner with
transferable buffers, or one bounded failure result. The Worker owns no network
transport, collision query, scene object, or promotion. Prove malformed and
oversized requests are rejected, sequential jobs do not share stale Native
state, exact sequence and coordinates are echoed, missing/extra/duplicate
owners cannot form a complete response, transfer lists contain each owned
buffer once, and exceptions yield failure without publication. After 11:30 run
the common setup, both new focused tests, then `nice -n 19 bun run build`. Land
only when those gates and `git diff --check` pass and only the four owned paths
are changed.

### Seam 3 brief — unified stream and atomic promotion

Start after seams 1 and 2 land. Create a fresh lane and own only
`greywrought:src/host/native-terrain-stream.bjs`,
`greywrought:src/host/native-terrain-generation.bjs`,
`greywrought:src/host/terrain-scene.bjs`,
`greywrought:src/host/scene.bjs`,
`greywrought:tests/native-terrain-stream.test.mjs`,
`greywrought:tests/native-terrain-generation.test.mjs`, and
`greywrought:tests/terrain-scene.test.mjs`. Make the stream own one
`CollisionMirror` and one persistent bounded Native Worker. Feed untrusted
terrain messages into mirror staging, request only affected active owners, and
admit results only for the exact live scope token, mirror generation, job, and
owner set. Make one main-thread transaction validate surfaces, prepare the
scene generation, commit Native/scene state, and consume the mirror settlement
so collision and rendering cross generations together. On any pre-commit
failure discard staging and retain the committed generation; on an ambiguous
post-commit failure fault the join. Delete `install-candidate!` and every C225G
candidate comment; do not add a compatibility surface. Prove stale scope and
job results, duplicate/missing/extra owners, malformed and transferred buffers,
Worker failure, disposal, affected-owner bounds, and atomic publication. After
11:30 run the common setup, then
`nice -n 19 bun test tests/native-terrain-stream.test.mjs tests/native-terrain-generation.test.mjs tests/terrain-scene.test.mjs`,
followed by `nice -n 19 bun run build`. Require `git diff --check` and a
tracked-tree search with no `native-terrain-candidate`, `install-candidate`, or
C225G hit. Land only when all pass and only the seven owned paths are changed.

### Seam 4 brief — application and browser cutover

Start after seam 3 lands. Create a fresh lane and own only
`greywrought:src/app/main.bjs`,
`greywrought:tests/character-app.test.mjs`,
`greywrought:tests/world-readiness.test.mjs`,
`greywrought:tests/reconnect.test.mjs`,
`greywrought:tests/prediction.test.mjs`,
`greywrought:tests/terrain-worker-bundle.test.mjs`,
`greywrought:acceptance/fixtures/world-render-browser.mjs`, and
`greywrought:acceptance/world-render.browser.test.mjs`. Replace the parallel
hosted-runtime-plus-Native-stream composition with the unified stream from seam
3. Preserve bounded repair transport, dig resend, transport/scope generation
fences, readiness, reconnect, logout, death, and world teardown. Worker
termination and callback detachment must complete before application state is
cleared; late callbacks publish nothing. Update the browser fixture and bundle
assertion to use the real replacement Worker asset and prove that visible
terrain and collision readiness name the same accepted generation. Do not
delete the standalone hosted terrain oracle modules in this seam; merely remove
them from the production browser import graph. After 11:30 run the common
setup, then
`nice -n 19 bun test tests/character-app.test.mjs tests/world-readiness.test.mjs tests/reconnect.test.mjs tests/prediction.test.mjs tests/terrain-worker-bundle.test.mjs`,
`nice -n 19 bun run build`, `nice -n 19 bun run test:browser-acceptance`, and
`nice -n 19 bun run test:world-render`. Require `git diff --check`, a clean
tracked-tree import search proving the production app no longer imports
`host.terrain-runtime`, and a built-asset check proving the bounded Native
Worker is emitted. Land only when every gate passes and only the eight owned
paths are changed.

## Final landing condition

B1 is complete only after all four seam commits are on main, main is clean and
equal to `origin/main`, the final seam's browser gates pass on the exact final
commit, the production import graph has one persistent terrain mirror, and the
candidate token search is empty. Remote CI is asynchronous confirmation and is
not a landing gate.

B1-ORDER-READY 4
