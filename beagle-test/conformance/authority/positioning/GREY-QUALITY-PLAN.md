# Greywrought quality plan

Status: survey complete; planning only. No Greywrought source, test, deployment,
or parked-worktree file was edited for this plan.

## Verdict and sizing

Sizing is **LESS** than a whole-codebase rewrite. The authority boundary is
already explicit: Native owns simulation and terrain decisions, hosted code
owns identity/projection/publication, and the browser renders one way. The
campaign should preserve those decisions and concentrate on vocabulary,
module seams, and two designs whose state ownership is harder to reason about
than it needs to be.

The current main checkout is clean at `greywrought` commit `56fe195`. The
parked playable checkout is detached at `45d60a0`, has untracked operator notes
and a log, and has already passed the checks recorded in its `PLAY.md`.

## Findings

### R1 — Fram vocabulary is stale after the engine became Beagle Store — RENAME

Anchors: `greywrought:README.md:111-131,218-227`,
`greywrought:tools/fram-authority-runtime.mjs:56-66,569-623`,
`greywrought:tools/fram-authority-ontology.mjs:99-109,251-256`,
`greywrought:tools/native-replay-harness.mjs:237-242,324-356`, and
`greywrought:deploy/linux/README.md:143-171,585-598`.

`FramAuthority`, `DurableFram`, `FakeFramClient`, `fram-*` deployment names,
`FRAM_*` application configuration, and prose that calls the engine “Fram” no
longer describe the product surface. Rename the Greywrought-side names to
`StoreAuthority`, `DurableStore`, `FakeStoreClient`, `beagle-store-*`, and
`STORE_*`/the already-ratified store configuration names. Migrate the deploy
tree, tests, support fakes, release packaging, health checks, and every import
in one change.

Do not rewrite compatibility-bound wire identities merely to make grep quiet:
`FRAMLOG/v1`, the historical `framrpc` package, and other externally defined
protocol bytes remain explicit compatibility boundaries until their producer
wave changes. The acceptance condition is semantic product vocabulary with a
documented compatibility exception, followed by a tracked-tree token search
for every removed product name.

### R2 — Stage 4/5 and demo names are frozen campaign vocabulary — RENAME

Anchors: `greywrought:tools/stage-5-demo.mjs:254-370,410-470,625-665`,
`greywrought:acceptance/stage-5-demo.test.mjs:1-37`, and
`greywrought:acceptance/fixtures/stage-5-demo-receipt.mjs:1-44`.

The live behavior is a bounded historical parity/cutover receipt, not a
permanent “Stage 5 demo.” If this seam survives the playable redeploy, rename
it to semantic names such as `historical-cutover-receipt`,
`real-history-window`, `candidate-parity`, and `cutover-receipt`; migrate the
protocol string, errors, fixtures, tests, and driver APIs together. If the
parked playable redeploy lands first, it deletes this entire harness and its
Stage 4 fixtures; then the correct remedy is removal, not a replacement demo
shim. In either case, finish with a tracked-tree search proving that
`stage-4`, `stage-5`, and `stage-5-demo` no longer name live production code.

### R3 — The terrain model is named as a generic volume — RENAME

Anchors: `greywrought:src/game/volume.bjs:2-68`,
`greywrought:src/app/main.bjs:6-29`,
`greywrought:src/server/terrain.bjs:2-5`, and
`greywrought:src/host/native-terrain-stream.bjs:2-36`.

`game.volume`, `Volume`, `Brick`, and `DigCommand` are all terrain-domain
objects. The generic names obscure the authority/client terrain boundary and
make the worker, server, and wire code read as if they share an arbitrary game
volume. Rename the module and exported domain types to
`game.terrain-volume`, `TerrainVolume`, `TerrainBrick`, and `TerrainDigCommand`
with every in-tree reference moved in one change. Do not mechanically rename
unrelated local variables or the protocol fields whose wire spelling is
already established. End with a tracked-tree token search for the old module
and exported type names.

### F1 — Authority runtime is a god module — REFACTOR

Anchors: `greywrought:src/server/main.bjs:2-14`,
`greywrought:src/server/main.bjs:991-1011`,
`greywrought:src/server/main.bjs:1610-1775`,
`greywrought:src/server/main.bjs:2847-3180`, and
`greywrought:src/server/main.bjs:3852-4828`.

One 4,828-line module currently joins Native result validation, lifecycle and
shadow realms, input planning, candidate/checkpoint admission, effect fencing,
WebSocket publication, chat fan-out, disconnect handling, and the timer
driver. The behavior is already the desired authority behavior; the quality
problem is that a change in one responsibility must compile and reason through
all the others. Extract typed seams for authority state/candidates,
transition admission, lifecycle/shadow handling, publication, ingress, and
the scheduler. Preserve one orchestration entry point and the existing
fail-closed ordering.

### F2 — Terrain authority mixes policy, durability receipts, and client scope — REFACTOR

Anchors: `greywrought:src/server/terrain.bjs:43-163`,
`greywrought:src/server/terrain.bjs:548-950`,
`greywrought:src/server/terrain.bjs:1063-1451`, and
`greywrought:src/server/terrain.bjs:1642-1904`.

The 1,904-line module contains request admission and reach proofs, terrain
candidate construction, durable outcome validation, volume commit checks,
peer scope/budget accounting, repair streaming, and wire result construction.
Extract `authority/terrain-policy`, `authority/terrain-commit`, and
`authority/terrain-scope` while keeping the current `TerrainAuthority` state
and result records as the narrow seam. This is a behavior-preserving split,
not a redesign of terrain authority.

### F3 — The client boot module owns too many mutable lifecycles — REFACTOR

Anchors: `greywrought:src/app/main.bjs:35-108`,
`greywrought:src/app/main.bjs:537-755`,
`greywrought:src/app/main.bjs:1166-1330`, and
`greywrought:src/app/main.bjs:1918-2324`.

The entry module owns renderer startup, frame timing, reconnect and session
callbacks, terrain transport generations, pending-dig persistence, prediction
reconciliation, UI routing, input registration, and teardown. Extract a client
session coordinator, client terrain lifecycle, frame/prediction loop, and
character navigation adapters. Keep the existing generation fences and
teardown-before-callback rule; do not merely rename this file.

### F4 — Store codecs and filesystem publication are coupled — REFACTOR

Anchors: `greywrought:tools/content-addressed-store.mjs:63-80`,
`greywrought:tools/content-addressed-store.mjs:769-900`,
`greywrought:tools/content-addressed-store.mjs:1105-1227`, and
`greywrought:tools/content-addressed-store.mjs:1514-3219`.

The 3,559-line tool contains world/checkpoint, terrain-radix, and journal
codec validation beside path security, writer leases, crash recovery, quotas,
and filesystem publication. The content-addressed API is valuable and
already bounded; split domain codecs from the filesystem store backend and
make the journal depend on the codec/store interfaces. Keep canonical bytes,
descriptor identity, lock recovery, and poison-on-filesystem-failure behavior
unchanged.

### F5 — Native production kernels contain laboratory and fixture entrypoints — REFACTOR

Anchors: `greywrought:src/native/mesher.bgl:1-32,1216-1259,1301-1447`,
`greywrought:src/native/advection_reference.bgl:1-20`,
`greywrought:src/native/field_grid.bgl:1-20`, and
`greywrought:src/native/lifecycle_fixture.bgl:1-20`.

The mesher file contains both the production kernel and flat/sphere/isolated/
diagonal fixture generators and check entrypoints. The advection, field-grid,
and lifecycle fixture modules are valuable evidence but are not game runtime
authority. Move fixture/laboratory sources under `src/demo/native` or
`src/testing/native`, leave only runtime kernels under `src/native`, and make
the build scripts name the fixture inputs explicitly. Do not split the
meshing algorithm into arbitrary micro-modules; its production cohesion is a
strength.

### B1 — The transient full-baseline terrain candidate is the wrong client design — REBUILD

Anchors: `greywrought:src/host/native-terrain-candidate.bjs:10-140`,
`greywrought:src/host/native-terrain-candidate-worker.bjs:8-89`,
`greywrought:src/host/native-terrain-generation.bjs:28-40,213-443`, and
`greywrought:src/host/native-terrain-stream.bjs:18-36,154-275`.

The current client creates a one-shot Worker, instantiates another Native
instance, stages a full baseline, meshes every named owner, transfers the
surfaces, then promotes a separate main-thread generation. This is a
correctness-heavy temporary architecture: collision, visual publication,
candidate admission, and worker lifetime are split across parallel state
machines with duplicated shape validation.

Rebuild it around one persistent client terrain mirror with explicit committed
and staging generations, plus a bounded worker that only meshes requested
owners. The parked playable lane already contains the candidate direction in
`src/game/terrain-collision.bjs` and changes to terrain generation/stream/scene;
do not invent a second design before that lane is adjudicated. The quality gain
is one promotion authority for collision and rendering, fewer stale-flight
cases, and a smaller worker contract. Migration cost is high: sequencing,
scope tokens, transferred buffers, native generation installation, and browser
acceptance fixtures all move.

Acceptance evidence must be named before implementation: the parked lane's
`bun test tests/terrain-collision.test.mjs tests/native-terrain-stream.test.mjs
tests/terrain-scene.test.mjs`, then `bun run build`,
`bun run test:browser-acceptance`, and the existing world-render acceptance.

### B2 — Client lifecycle is an implicit atom graph — REBUILD

Anchors: `greywrought:src/app/main.bjs:59-105`,
`greywrought:src/app/main.bjs:585-612`,
`greywrought:src/app/main.bjs:1930-1980`, and
`greywrought:src/app/main.bjs:2113-2324`.

Extraction alone would leave more than forty independently mutable atoms and
callbacks coordinating renderer, transport, world-entry, reconnect, lobby,
logout, and death transitions. The design problem is implicit ownership: a
late callback can still be valid only because several unrelated atoms are
checked together. Rebuild the client session around an explicit phase/revision
state machine whose effects are admitted by session identity; keep rendering,
UI, and transport as consumers of that state. This is deliberately a rebuild,
not a file split, because the quality gain is eliminating cross-owner state
invariants rather than relocating them.

Acceptance evidence must be fixed up front: `bun run build`; the focused
`character-app`, `character-session`, `world-readiness`, `reconnect`,
`prediction`, and `ui` tests; then `bun run test:browser-acceptance` and the
world-render acceptance. No gameplay rule changes are part of this seam.

## Target folder structure

The target layout communicates ownership without pretending that shared wire
contracts belong to either browser or authority:

```text
src/
  authority/       server admission, lifecycle, publication, terrain policy
  client/          app, input, rendering, UI, prediction, client terrain
  protocol/        shared records, wire schemas, terrain codecs/contracts
  native/          runtime Native kernels and service ABI only
  demo/            recorded cutover/parity receipts and numerical demos
  testing/         Beagle test helpers and test-only source
tools/
  authority/       authority host, ingress, coordinator, deployment adapters
  journal/          journal adapter and receipt orchestration
  native/          Native build, ABI, replay, and Wasm adapters
  store/            Beagle Store filesystem backend and domain codecs
  demo/             optional recorded demonstration runners only
tests/
  authority/ client/ protocol/ journal/ native/ demo/ support/
acceptance/
  client/ authority/ demo/
```

Move map:

| Current surface | Target surface | Rule |
|---|---|---|
| `src/server/main.bjs` | `src/authority/runtime/*` | split orchestration by admission, lifecycle, publication, scheduler |
| `src/server/terrain.bjs` | `src/authority/terrain/*` | policy/commit/scope; no browser code |
| `src/server/chat-ingress.bjs` | `src/authority/ingress/chat.bjs` | authority ingress only |
| `src/app`, `src/host`, `src/ui` | `src/client/*` | browser boot, host/rendering, and UI remain client-owned |
| `src/game/state.bjs`, terrain contracts, and terrain volume | `src/protocol/model/*` | genuinely shared structural and wire contracts |
| client-only `src/game/*` | `src/client/game/*` | prediction, interpolation, presentation, readiness, gestures |
| `src/net/*` | `src/protocol/*` | wire schemas/codecs |
| runtime `src/native/*` | `src/native/*` | keep the Native authority boundary stable |
| Native labs and fixtures | `src/demo/native/*` or `src/testing/native/*` | never bundled as runtime authority |
| `tools/authority-*.mjs` | `tools/authority/*` | operational authority seams |
| `tools/authority-journal.mjs` | `tools/journal/*` | journal adapter, not generic storage |
| `tools/content-addressed-store.mjs` | `tools/store/*` | codecs separated from filesystem backend |
| Native build/replay tools | `tools/native/*` | ABI and executable ownership |
| Stage/demo acceptance files | `acceptance/demo/*` or removal | semantic rename if retained; delete if redeploy supersedes |

Do not create a catch-all `shared` folder. A module moves to `protocol` only
when both authority and client import its structural contract; otherwise its
new owner is explicit.

## Wave plan and one-worker seams

Each row is one worker with exclusive file ownership. No two rows touching the
same path run concurrently.

| Wave | Remedy | Exclusive seam | Verification before landing |
|---|---|---|---|
| W0 | ordering barrier | parked playable redeploy's 45 changed paths, especially `src/game/core.bjs`, `src/game/replay-contract.bjs`, `src/game/terrain-collision.bjs`, terrain stream/generation/scene, and the Stage/demo deletions | use the evidence in `playable:PLAY.md`; rerun its focused authority, build, and native checks if the lane changes |
| W1 | RENAME | Store vocabulary in `README.md`, `deploy/linux`, `tools/fram-*`, authority helpers, support fakes, tests, and package/vendor references | focused authority/store tests; `bun run build`; tracked-tree search for removed product names, with protocol exceptions listed |
| W2 | RENAME or removal | Stage/demo harness, fixtures, acceptance test, and demo protocol; only paths surviving W0 | demo/cutover receipt test if retained; otherwise tracked-tree search for all stage/demo tokens |
| W3 | RENAME | `game.volume` and all terrain model imports/types | terrain codec/session/authority tests; `bun run build`; old-module/type token search |
| W4 | REFACTOR | `src/server/main.bjs` into authority runtime seams | authority host/session/WebSocket/server, logout, disconnect-shadow tests; `bun run build` |
| W5 | REFACTOR | `src/server/terrain.bjs` into authority terrain seams | terrain authority/service/scoped-server/codec tests; `bun run build` |
| W6 | REFACTOR | content codecs, journal adapter, and Store filesystem backend | content-addressed-store, terrain-radix, journal, authority-runtime, and restart tests |
| W7 | REFACTOR | Native production versus demo/testing fixtures | `bun run native:build`, Native mesher/terrain/lifecycle tests, and relevant numerical checks |
| W8 | REBUILD | persistent client terrain mirror, only after W0 and after any terrain rename | named B1 acceptance evidence, build, browser acceptance, world-render acceptance |
| W9 | REBUILD | explicit client session state machine and effect admission | named B2 focused tests, build, browser acceptance, world-render acceptance |
| W10 | structure | folder moves and import namespace cleanup after behavior seams are green | full `bun run test`, then tracked-tree path/token searches and a clean status |

Renames are atomic migrations: move the file, namespace, exported symbols,
imports, tests, fixtures, deployment names, and documentation together. No
compatibility aliases or “removed” shims. Rebuild seams start with their
acceptance evidence above; a green compile alone is not sufficient.

## Parked playable redeploy ordering

W0 is an explicit decision barrier because the parked lane deletes
`tools/authority-journal.mjs`, `tools/shadow-engine.mjs`, `tools/stage-5-demo.mjs`,
the Stage 4 fixtures, and their tests, while adding shared simulation/replay
and client terrain-collision seams. It also modifies the terrain stream,
generation, scene, server terrain, authority host, content store, and browser
acceptance files. Those are the exact paths most likely to be moved or rebuilt
by this plan.

Therefore:

1. Adjudicate and land or reject the parked playable redeploy first.
2. If it lands, rerun this plan's token survey against the landed tree; W2 is
   then a removal verification and B1 starts from the parked mirror design.
3. If it is rejected, retain the current Stage/journal/shadow seams and run W2
   as the semantic rename before W4/W6.
4. Do not merge a quality worker that edits a W0 path while W0 is parked.

The final release gate is the repository's existing `bun run test`, preceded
by the focused gate for each seam. No remote CI result is a landing gate.

## Counts

- RENAME: 3
- REFACTOR: 5
- REBUILD: 2

GREY-PLAN-DONE
