+++
id = "grey-b2-order"
title = "Greywrought B2 W9 client lifecycle state-machine rebuild"
shape = "task"
life = "planned"
updated_at = "2026-08-18T10:48:18+08:00"
owners = ["unassigned"]
depends_on = ["external:grey-wrought-F1-landing", "external:grey-wrought-W0-shape-landing", "external:grey-wrought-W8-landing"]
conversation_ids = []
coordination = []
+++

# Dispatch order: Greywrought B2 / W9

This is a rebuild, not an extraction-only split. Replace the implicit client
lifecycle atom graph with one explicit phase/revision state machine. Every
effect is admitted by session identity and revision; rendering, UI, transport,
terrain, prediction, reconnect, lobby, logout, and death consume that state.
Gameplay rules, Native authority, wire bytes, terrain generation fences, and
teardown-before-callback ordering remain unchanged.

The order is measured against the current landed Greywrought tree. The F1 lane
is still pending; W0 shape landed during this refresh, so its old worktree is
now stale. Every affected section below carries a `REBASE-CHECK` tag and must
be refreshed once after the moving lanes settle.

## Measured baseline [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

Inspection was performed on `greywrought:main` at
`862a4ab0b2583ba611860a868bf18b6526b6c7f2` on 2026-08-18. The checkout was
clean: `## main...origin/main`. This is the revision to which the inventory,
path sets, and line counts below refer.

The live moving lanes at measurement time were:

- F1: `greywrought:worktrees/quality-f1`, HEAD
  `8a3addd49cc08e8d64d1e043d7fbee9f2b4b8cf3`, clean but not landed; it contains
  the authority split.
- W0 shape: landed on current main as `862a4ab0b2583ba611860a868bf18b6526b6c7f2`
  (`redeploy: restore playable tree shape`). The stale
  `greywrought:worktrees/w0-shape` checkout remains at
  `769efdc1398533d9898dbed58eda4d05a77a7772` with its old dirty surface and
  is not a W9 owner.
- The separate parked playable checkout was detached at
  `45d60a0f60b8bf6f294bf52b613e4a50f30a00a9` and had only untracked operator
  notes/logs; it is evidence, not a W9 owner.

Before a W9 lane is created, reread `git status --short --branch`, rerun the
inventory’s `wc -l` measurement, and rerun the exact disjointness comparison against
the landed result of F1 and W0 shape. If either landing changes a W9-owned path
or a named acceptance fixture, stop and revise this order before dispatch.

## Seam inventory [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

Counts are `wc -l` from the measured HEAD. Existing modules are listed as
dependencies or consumers even when the W9 lane should not edit them.

| Role | Current path | Lines |
|---|---|---:|
| lifecycle orchestrator, frame loop, callback joins | `src/app/main.bjs` | 2,324 |
| character identity records and predicates | `src/game/character.bjs` | 158 |
| reconnect generation/backoff policy | `src/game/reconnect.bjs` | 143 |
| world-entry readiness facts | `src/game/world-readiness.bjs` | 176 |
| prediction/replay bookkeeping | `src/game/prediction.bjs` | 199 |
| terrain contract consumed by world entry | `src/game/terrain-contract.bjs` | 332 |
| terrain interest/generation contract | `src/game/terrain-interest.bjs` | 380 |
| character HTTP/session effects | `src/host/character-service.bjs` | 410 |
| socket callbacks and transport generations | `src/host/net.bjs` | 714 |
| browser input registration and teardown | `src/host/input.bjs` | 392 |
| renderer/device-loss lifecycle | `src/host/scene.bjs` | 718 |
| terrain runtime lifecycle | `src/host/terrain-runtime.bjs` | 1,589 |
| terrain session records | `src/host/terrain-session.bjs` | 338 |
| shared wire records | `src/net/protocol.bjs` | 369 |
| character-session UI state/effects | `src/ui/character-session.bjs` | 746 |
| UI signal model | `src/ui/model.bjs` | 252 |
| lobby consumer | `src/ui/character-lobby.bjs` | 352 |
| character-select consumer | `src/ui/character-select.bjs` | 629 |
| escape-menu consumer | `src/ui/escape-menu.bjs` | 160 |
| app/lifecycle tests | `tests/character-app.test.mjs` | 534 |
| session tests | `tests/character-session.test.mjs` | 345 |
| readiness tests | `tests/world-readiness.test.mjs` | 87 |
| reconnect tests | `tests/reconnect.test.mjs` | 150 |
| prediction tests | `tests/prediction.test.mjs` | 205 |
| UI tests | `tests/ui.test.mjs` | 179 |
| browser world-render acceptance | `acceptance/world-render.browser.test.mjs` | 412 |
| browser readiness acceptance | `acceptance/world-readiness.browser.test.mjs` | 103 |
| renderer retry acceptance | `acceptance/renderer-retry.browser.test.mjs` | 88 |
| character focus acceptance | `acceptance/character-focus.browser.test.mjs` | 92 |
| world-render browser fixture | `acceptance/fixtures/world-render-browser.mjs` | 834 |
| readiness browser fixture | `acceptance/fixtures/world-readiness-browser.mjs` | 101 |
| planned pure lifecycle core | `src/client/session-state.bjs` | absent at HEAD |
| planned effect boundary | `src/client/session-effects.bjs` | absent at HEAD |
| planned coordinator | `src/client/session-coordinator.bjs` | absent at HEAD |
| planned pure-core tests | `tests/client-session-state.test.mjs` | absent at HEAD |

The current atom graph is concentrated in `src/app/main.bjs:59-104`, with
world-entry admission at `:548-875`, prediction/frame state at `:1170-1789`,
world activation and renderer teardown at `:1813-1980`, character/service
callbacks at `:1988-2110`, renderer startup at `:2113-2189`, and logout/death
callbacks at `:2200-2324`. These are the rebuild’s migration anchors, not a
promise that each enclosing function survives.

## Target contract [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

The new lifecycle state must represent at least these phases:

`boot/loading`, `lobby/creator`, `entry-pending`, `world-starting`,
`world-ready`, `world-active`, `reconnecting`, `logout-countdown`, `death`,
`detached/logged-out`, and `terminal-error`.

The pure state module owns legal transitions, the current session identity, a
monotonic revision, and the world-entry generation. An effect admission token
contains the session identity, revision, effect kind, and captured world-entry
generation where applicable. Admission returns either an accepted command or a
typed stale/duplicate rejection. Completion may mutate UI, transport, terrain,
renderer, prediction, or storage only after the coordinator proves that the
token still matches. A phase change increments revision and invalidates old
roster, enter, renderer, terrain, reconnect, logout, death, and character-action
effects together.

The coordinator is the only lifecycle authority. Existing transport, terrain,
renderer, prediction, and UI modules remain consumers behind adapters. A late
callback is ignored or recorded as a stale-effect result; it never reopens a
prior world, replaces a newer roster, resurrects input, publishes an old
renderer, or overwrites a newer UI route.

## Ordered commit plan [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

Each commit is coherent and independently checked. The lane may touch only the
paths named for that commit and the W9 owned set in “Disjointness”. No commit
edits `greywrought:main` directly.

1. **Pure lifecycle model.** Add `src/client/session-state.bjs` and
   `tests/client-session-state.test.mjs`. Implement phases, legal transitions,
   revision increments, identity/revision/generation tokens, stale and
   duplicate completion rejection, and teardown invalidation with no browser,
   network, renderer, timer, or signal dependency. Run the pure-core gate.
2. **Effect boundary and coordinator.** Add
   `src/client/session-effects.bjs` and `src/client/session-coordinator.bjs`;
   migrate `src/app/main.bjs` boot, roster, create, delete, enter, and death
   flows. Keep `host/character-service.bjs` APIs and wire shapes unchanged.
   Every promise completion and registered callback must enter through the
   captured admission token. Run the app/session/reconnect focused gate.
3. **World and connection lifecycle.** Migrate world activation, renderer
   start/retry/device-loss, terrain start/stop, reconnect, readiness, logout,
   disconnect, and error flows in `src/app/main.bjs`. Preserve the existing
   transport and terrain generation fences, Native-only authority, input pause
   before teardown, and teardown-before-callback rule. `host/net.bjs`,
   `host/scene.bjs`, `host/input.bjs`, `host/terrain-runtime.bjs`,
   `game/world-readiness.bjs`, and `game/reconnect.bjs` remain stable consumers
   unless a focused gate demonstrates a boundary defect. Run the world,
   prediction, terrain-runtime, and scene lifecycle focused checks.
4. **UI projection and atom removal.** Make `ui/character-session.bjs` and
   `ui/model.bjs` consume coordinator state; retain lobby, select, and escape
   components as projections and action emitters. Route frame/render/input and
   prediction projections through admitted state, then remove duplicate
   lifecycle atoms and direct callback mutations from `app/main.bjs`. Run the
   UI focused checks and the non-W0 browser acceptance tests.
5. **Acceptance closure.** Update only the W9-owned focused tests and browser
   fixtures that do not belong to W0. Prove no gameplay rule or wire-byte
   change, run the complete B2 bar, commit the coherent W9 range, and record the
   landed revision in the handoff. Do not fold F1, W0 shape, W8, or unrelated
   cleanup into this range.

## Focused acceptance gates [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

Run these from the implementation lane, with the lane revision printed before
each gate. Stop the affected commit on the first failure and preserve its
output/artifacts.

1. **Path and source gate:** clean status relative to the lane base; changed
   paths are a subset of the W9 owned set; the pure model has no browser,
   network, renderer, timer, or signal import.
2. **Pure model gate:**

   ```sh
   bun test tests/client-session-state.test.mjs
   ```

   It must cover every phase transition, monotonic revision, session identity
   mismatch, stale generation, duplicate completion, and teardown invalidation.
3. **B2 focused unit gate:**

   ```sh
   bun test tests/character-app.test.mjs tests/character-session.test.mjs \
     tests/world-readiness.test.mjs tests/reconnect.test.mjs \
     tests/prediction.test.mjs tests/ui.test.mjs \
     tests/client-session-state.test.mjs
   ```

   The tests must exercise late roster/enter/death/logout/reconnect results,
   renderer retry after device loss, world-entry readiness fencing, UI route
   projection, and prediction reset without changing gameplay assertions.
4. **Compile gate:**

   ```sh
   bun run build
   ```

5. **Browser and world-render gates:**

   ```sh
   bun run test:browser-acceptance
   bun run test:world-render
   ```

   The world-render command is the repository’s existing named world-render
   acceptance; it is not a substitute for the complete browser acceptance.
6. **Landing gate:** run the repository’s existing `bun run test` after the
   focused B2 bar, then require clean status and an exact changed-path review.
   Remote CI is asynchronous confirmation, never a landing gate.

The B2 bar is gates 2–5 plus the invariants that no gameplay rule, Native
authority decision, wire byte, or generation fence changed. A green compile
alone is insufficient.

## Disjointness set [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

The W9 exclusive edit set is:

```text
src/app/main.bjs
src/client/session-state.bjs
src/client/session-effects.bjs
src/client/session-coordinator.bjs
src/game/world-readiness.bjs
src/game/reconnect.bjs
src/host/net.bjs
src/host/character-service.bjs
src/host/input.bjs
src/host/scene.bjs
src/host/terrain-runtime.bjs
src/ui/character-session.bjs
src/ui/model.bjs
tests/client-session-state.test.mjs
tests/character-app.test.mjs
tests/character-session.test.mjs
tests/world-readiness.test.mjs
tests/reconnect.test.mjs
tests/prediction.test.mjs
tests/ui.test.mjs
acceptance/world-readiness.browser.test.mjs
acceptance/renderer-retry.browser.test.mjs
acceptance/character-focus.browser.test.mjs
acceptance/fixtures/world-readiness-browser.mjs
```

The following live F1 paths are excluded and must remain disjoint:

```text
src/server/main.bjs
src/server/authority-admission.bjs
src/server/authority-candidates.bjs
src/server/authority-ingress.bjs
src/server/authority-lifecycle.bjs
src/server/authority-publication.bjs
src/server/authority-scheduler.bjs
src/server/authority-state.bjs
```

The following W0-shape paths are excluded and must remain disjoint. W0 shape
landed in the measured main commit as a 27-path change; the list below is that
landed path set:

```text
QUIET-TAIL-VERIFY.md
acceptance/fixtures/stage-5-demo-receipt.mjs
acceptance/fixtures/world-render-browser.mjs
acceptance/stage-5-demo.test.mjs
acceptance/world-render.browser.test.mjs
src/host/native-terrain-candidate-worker.bjs
src/host/native-terrain-candidate.bjs
src/host/native-terrain-stream.bjs
src/game/core.bjs
src/game/replay-contract.bjs
src/game/terrain-collision.bjs
src/tests/sim-test.bjs
tests/authority-journal.test.mjs
tests/autoattack-roundtrip.test.mjs
tests/collision.test.mjs
tests/combat.test.mjs
tests/core-abi.test.mjs
tests/fixtures/stage-4/failure-receipt.json
tests/fixtures/stage-4/real-history-receipt.json
tests/shadow-engine.test.mjs
tests/sim-beagle.test.mjs
tests/native-terrain-stream.test.mjs
tests/terrain-collision.test.mjs
tools/authority-journal.mjs
tools/content-addressed-store.mjs
tools/shadow-engine.mjs
tools/stage-5-demo.mjs
```

The W9 lane also excludes `src/server/**`, `src/native/**`, `tools/**` except
for the explicitly listed W0 files, `deploy/**`, `src/net/terrain-codec.bjs`,
`src/game/terrain-volume.bjs`, terrain worker/generation sources, and all
other acceptance/test paths. If W0 changes a path in the W9 set, or F1 changes
an imported client/server contract, the order is not dispatchable until this
set and the gates are remeasured.

## Rebase-check register [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

After F1 lands, measure the new `src/server/main.bjs` and authority module
paths, compare the W9 set against the landed F1 commit, and rerun the hostile
client or browser seam gate if the callback contract changed. F1 must not be
treated as disjoint merely because its current files are server-owned.

W0 shape landed as the measured `862a4ab…` main commit while this order was
being written. Close this rebase check by treating that landed tree as the
source of truth, rechecking `src/host/native-terrain-stream.bjs`, terrain
generation imports, and both world-render acceptance paths. Do not use the
stale `w0-shape` checkout. If a follow-up W0 change lands, repeat the same
survey; if the landed tree is later rejected, record that decision and restore
the current Stage/journal/shadow behavior before dispatch.

After W8/B1 lands, rerun the client terrain import and acceptance survey. W9
must not absorb B1’s terrain mirror or edit its files. W3 or any other quality
wave that changes a W9 import similarly requires a path comparison and one
focused gate rerun before dispatch.

## Rollback rule [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

Record the exact pre-W9 main commit immediately before creating the lane. If a
focused test, build, browser acceptance, world-render acceptance, path review,
or invariant fails, stop the affected lane and do not land it. For an unlanded
lane, reset only that lane to its recorded base. For a landed defect, revert
the entire W9 commit range as one coherent rollback and restore the recorded
pre-W9 revision; do not mix a partial state machine with the old atom graph.

Never roll back F1, W0 shape, W8, or unrelated landed work as part of this
rule. Preserve the first failing artifact. A retry starts by rebasing the W9
order and implementation onto the current main, repeating the F1/W0/W8
disjointness checks, not by adding compatibility aliases or shims.

## Completion evidence [REBASE-CHECK:F1] [REBASE-CHECK:W0-SHAPE]

The order is ready for dispatch only after its F1/W0/W8 rebase checks are
terminal, the W9 lane is disjoint, the ordered commits are landed, the B2 bar
and `bun run test` pass, the main checkout is clean, and the post-landing main
revision is recorded in the handoff. Reap the implementation lane only after
that evidence is durable.

PLAN-B2C-DONE — refreshed against Greywrought main 862a4ab0b2583ba611860a868bf18b6526b6c7f2 with F1 pending and W0-shape landing checks recorded.
