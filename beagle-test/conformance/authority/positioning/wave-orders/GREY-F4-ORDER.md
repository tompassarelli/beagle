# Greywrought F4 / W6 dispatch order

## Scope and dispatch point

Implement finding F4 from `beagle:beagle-test/conformance/authority/positioning/GREY-QUALITY-PLAN.md`: split the content codecs, journal adapter, and filesystem Store backend while preserving canonical bytes, descriptor identity, lock recovery, quotas, and poison-on-filesystem-failure behavior. This is one worker and one exclusive seam. This order authorizes no source edit, worktree, or landing.

The read-only baseline is `greywrought` main at `e64289ba4ab7cc7901c0cccb1d5dff450bf1cae0`, clean and equal to its branch tracking state. The plan text says `56fe195`; that is stale relative to the current checkout and is not an implementation base.

## Exact current seam inventory

`wc -l` reality at the baseline:

| Current path | Lines | Role |
|---|---:|---|
| `greywrought:tools/content-addressed-store.mjs` | 3,559 | mixed codecs, descriptor/policy validation, filesystem CAS, leases, recovery, quotas |
| `greywrought:tools/terrain-radix-store.mjs` | 833 | terrain-radix codec/store adapter |
| `greywrought:tools/authority-journal.mjs` | 524 | journal value codec, invariants, history/blob adapter |
| `greywrought:tools/authority-checkpoint.mjs` | 1,452 | checkpoint producer/consumer of CAS descriptors and bytes |
| `greywrought:tools/authority-terrain.mjs` | 912 | terrain-radix authority consumer |
| `greywrought:tools/authority-terrain-service.mjs` | 1,248 | terrain service persistence consumer |
| `greywrought:tools/fram-authority-runtime.mjs` | 2,053 | runtime checkpoint/recovery consumer |
| `greywrought:tools/authority-host.mjs` | 1,740 | Store/radix/runtime composition |
| `greywrought:tools/world-checkpoint-v1-v2-migration.mjs` | 1,200 | retired checkpoint migration consumer |
| `greywrought:tests/content-addressed-store.test.mjs` | 2,005 | codec, descriptor, CAS, crash, lease, quota, poison behavior |
| `greywrought:tests/terrain-radix-store.test.mjs` | 468 | terrain codec/radix behavior |
| `greywrought:tests/authority-journal.test.mjs` | 251 | journal codec/adapter |
| `greywrought:tests/authority-checkpoint.test.mjs` | 1,036 | checkpoint persistence/CAS contract |
| `greywrought:tests/authority-terrain.test.mjs` | 793 | terrain authority/radix |
| `greywrought:tests/authority-terrain-service.test.mjs` | 1,445 | terrain service persistence/restart |
| `greywrought:tests/fram-authority-runtime.test.mjs` | 1,695 | runtime checkpoint/recovery |
| `greywrought:tests/native-fram-restart.test.mjs` | 957 | filesystem CAS/native restart |
| `greywrought:tests/world-checkpoint-v1-v2-migration.test.mjs` | 536 | checkpoint migration/restart |

Current journal consumers that are conditional on the W0/W2 decision are `greywrought:tools/stage-5-demo.mjs` (881), `greywrought:tools/shadow-engine.mjs` (447), and `greywrought:tests/shadow-engine.test.mjs` (428). Current composed-boundary consumers also include `greywrought:tests/authority-host.test.mjs` (1,766), `greywrought:tests/authority-domain.test.mjs` (1,005), and `greywrought:tests/authority-game-adapter.test.mjs` (990). Rerun the inventory immediately before implementation because the W0/W2 decision can remove paths.

Baseline inventory command:

```sh
cd greywrought:
git status --short --branch
git rev-parse HEAD
wc -l tools/content-addressed-store.mjs tools/terrain-radix-store.mjs tools/authority-journal.mjs tools/authority-checkpoint.mjs tools/authority-terrain.mjs tools/authority-terrain-service.mjs tools/fram-authority-runtime.mjs tools/authority-host.mjs tools/world-checkpoint-v1-v2-migration.mjs tests/content-addressed-store.test.mjs tests/terrain-radix-store.test.mjs tests/authority-journal.test.mjs tests/authority-checkpoint.test.mjs tests/authority-terrain.test.mjs tests/authority-terrain-service.test.mjs tests/fram-authority-runtime.test.mjs tests/native-fram-restart.test.mjs tests/world-checkpoint-v1-v2-migration.test.mjs
rg -n "content-addressed-store|terrain-radix-store|authority-journal" tools tests src package.json
```

## Split/rebuild map

Make dependency direction one-way:

```text
codec primitives / descriptor identity
  +--> world-checkpoint-codec
  +--> terrain-radix-codec
  +--> authority-journal-codec
  +--> content-addressed-store (filesystem backend)
             +--> terrain-radix-store adapter
             +--> authority-journal adapter
             +--> checkpoint/runtime consumers
```

Use explicit modules under `greywrought:tools/` (names may change only for a clearer equivalent ownership):

1. Extract shared descriptor validation, policy/limit constants, canonical byte helpers, and descriptor identity into `tools/content-codecs.mjs`.
2. Extract world v2 and retired v1 checkpoint validation/encoding/decoding into `tools/world-checkpoint-codec.mjs`; keep migration-only v1 behavior explicit.
3. Extract terrain node/brick byte validation and descriptor rules into `tools/terrain-radix-codec.mjs`; leave `terrain-radix-store.mjs` as the bounded tree/update adapter.
4. Extract journal canonical value and entry codec rules into `tools/authority-journal-codec.mjs`; leave `authority-journal.mjs` as head/append/as-of adapter over `history` and `blobs` interfaces.
5. Reduce `content-addressed-store.mjs` to path security, shard layout, atomic publication, leases, crash cutpoints, quarantine/poison behavior, quotas, batch writes, and descriptor-addressed I/O.
6. Migrate every listed consumer and test atomically. No aliases, duplicate codecs, catch-all `shared` module, or compatibility shim.

The refactor is accepted only when codecs work against an in-memory store interface and the filesystem backend works with opaque bytes plus validated descriptors. Canonical output bytes, hashes/lengths, expected-descriptor conflicts, lock takeover/recovery, and poison-on-write/publish failure remain compatible.

## Migration order

1. Freeze the inventory and add characterization assertions where vectors are not explicit.
2. Extract shared primitives and world codecs; migrate checkpoint and v1-v2 migration consumers.
3. Extract terrain rules; migrate radix and authority-terrain consumers, preserving traversal/update ordering and root identity.
4. Extract journal rules; migrate the adapter. Reconcile W0/W2 survivors before touching Stage/shadow consumers.
5. Reduce the Store to the filesystem backend; migrate host, runtime, checkpoint, terrain, and remaining consumers.
6. Remove old mixed definitions and stale imports atomically, then run the focused gates, build, and full test.

## Lowest-layer verification

Run from `greywrought:` or the implementation lane; stop on first failure and preserve output.

| Step | Command |
|---|---|
| characterization | `bun test tests/content-addressed-store.test.mjs tests/terrain-radix-store.test.mjs tests/authority-journal.test.mjs` |
| checkpoint codecs | `bun test tests/content-addressed-store.test.mjs tests/authority-checkpoint.test.mjs tests/world-checkpoint-v1-v2-migration.test.mjs` |
| terrain codecs | `bun test tests/terrain-radix-store.test.mjs tests/authority-terrain.test.mjs tests/authority-terrain-service.test.mjs` |
| journal adapter | `bun test tests/authority-journal.test.mjs tests/authority-checkpoint.test.mjs`; if retained after W0/W2, also `bun test tests/shadow-engine.test.mjs` |
| backend/recovery | `bun test tests/content-addressed-store.test.mjs tests/fram-authority-runtime.test.mjs tests/native-fram-restart.test.mjs` |
| composed W6 gate | `bun test tests/content-addressed-store.test.mjs tests/terrain-radix-store.test.mjs tests/authority-journal.test.mjs tests/authority-checkpoint.test.mjs tests/authority-terrain.test.mjs tests/authority-terrain-service.test.mjs tests/fram-authority-runtime.test.mjs tests/native-fram-restart.test.mjs tests/world-checkpoint-v1-v2-migration.test.mjs` |

After the focused gate, run `bun run build`. The plan's final landing gate is the existing `bun run test), exactly once on the final commit, preceded by the focused W6 gate. Remote CI is not a landing gate.

## Landing bar

Land only when the focused W6 set passes (content-addressed-store, terrain-radix, journal, authority-runtime, and restart tests), `bun run build` passes, and `bun run test` passes on the exact commit to land. Tracked-tree search must find no old mixed implementation, stale imports, or compatibility aliases; only explicitly documented external wire identities may remain. Status must be clean and the diff W6-only. Land with `safe-push --to main` from the lane, fast-forward pull, exact-head verification, lane removal, and branch removal.

## Disjointness and barrier preconditions

1. W0 is not cleared. The parked playable lane is `greywrought:worktrees/playable`, detached at `45d60a0f60b8bf6f294bf52b613e4a50f30a00a9), with untracked `PLAY.md` and `playable-server.log`; current main is `e64289ba4ab7cc7901c0cccb1d5dff450bf1cae0`. Its 45-path diff overlaps `tools/content-addressed-store.mjs`, `tools/authority-journal.mjs`, `tools/authority-host.mjs`, `tools/authority-terrain-service.mjs), and overlapping tests. W0 must be adjudicated land-or-reject, with its focused authority/build/native checks rerun if the lane changes; green PLAY.md evidence alone is insufficient.
2. If W0 lands, rerun the plan token survey against landed main and wait for W2 removal verification before assuming journal/stage/shadow paths exist. If W0 is rejected, W2's semantic rename must land before F4/W6; F4 then starts from that post-W2 tree and retains the current journal seam.
3. The native-only cutover lane `greywrought:worktrees/native-only` must land or be explicitly rejected and its dependent R2 receipt lane reconciled before F4. Its banked candidate is `f0e17f5675f69130376b09142a155855752c641f`; its recorded full-suite bar is not green. Do not base F4 on or edit that lane.
4. The R1 vocabulary lane `greywrought:worktrees/quality-r1`, commit `71c67c9`, must be rebased and landed or rejected first because it changes Store vocabulary in helpers/tests and may alter import names and token-search exceptions. Resolve overlap by migration, never aliases.
5. W4 and W5 authority-refactor landings must precede F4 whenever they touch `authority-host.mjs`, authority helpers, runtime composition, or shared tests. F4 owns its listed paths exclusively and never merges around an unlanded lane.
6. At dispatch, run `git diff --name-only <current-main>..<every-live-lane>` and reject dispatch if any live lane intersects the W6 owned set. Create F4 from the then-current clean main, never this stale baseline.

## Rollback

Before landing, delete the unlanded F4 lane and branch after preserving its commit and check artifacts; main remains untouched. If a landed commit fails a post-landing focused or full gate, stop later waves, record the exact failing commit, and revert that single commit through a new lane using `safe-push`. Restore the prior Store surface and rerun focused W6, build, and full test. Do not restore the mixed file with aliases or leave both codec implementations live. Existing content-addressed data is not rewritten by this refactor, so rollback must preserve all blobs and descriptors byte-for-byte.

PLAN-F4-DONE — dispatch order written from the current read-only tree
