# `@tompassarelli/fram-cloudflare-do`

Run the Fram engine *inside* a Cloudflare Durable Object. The engine is
`lib/libfram.wasm`, built by `bin/fram-native-build --host wasm-embed`; this
package is the host half of that seam — it answers all nine `fram_host_v1`
imports out of DurableObjectStorage, so a Durable Object becomes a Fram
database with no server, no socket, and no shim in front of it.

This is a library an application embeds, not a deployment. Nothing here is
deployed on its own; `wrangler.example.toml` shows the shape your Worker needs.

For a Worker that talks to a Fram *server* over FRAMRPC, use
`clients/bun` behind a shim instead — that is a different regime with
different guarantees.

## Build the engine module

```console
$ export FRAM_WASI_CC=/path/to/wasm32-unknown-wasi-clang
$ scripts/build-wasm.sh
build-wasm: lib/libfram.wasm <- <artifact-address> (<bytes> bytes, sha256 <hash>)
```

`scripts/build-wasm.sh` copies `lib/libfram.wasm` out of a content-addressed
`fram-native-build` artifact and writes `lib/provenance.json` beside it, which
pins the source mode and commit, the native-build input-manifest digest, the
artifact address, and the Wasm's SHA-256. Both files are build outputs and are
not tracked; `scripts/check-seams.mjs` re-derives the hash and refuses a Wasm
that does not match its own provenance.

## Use it

```js
import {
  FramDurableObjectBase,
  framDataPlaneEntrypoint,
  framDurableObjectTransport,
} from '@tompassarelli/fram-cloudflare-do';
import { framClient } from '@tompassarelli/framrpc/core';
import { DurableObject, WorkerEntrypoint } from 'cloudflare:workers';
import framModule from '../lib/libfram.wasm';

const SPACE = 'wiki.greywrought.com';

// Raw storage owner in a backend Worker. Never bind FRAM into the wiki Worker.
export class FramLog extends DurableObject {
  #fram;

  constructor(state, env) {
    super(state, env);
    this.#fram = new FramDurableObjectBase(
      state, env, framModule, { spaceId: SPACE },
    );
  }

  exchange(frame, options) {
    return this.#fram.exchange(frame, options);
  }

  exportFramlog() {
    return this.#fram.exportFramlog();
  }

  restoreFramlog(backup, options) {
    return this.#fram.restoreFramlog(backup, options);
  }
}

// The backend Worker's public service entrypoint delegates only exchange.
export class DataPlane extends WorkerEntrypoint {
  exchange(frame, options) {
    return framDataPlaneEntrypoint(this.env.FRAM, SPACE)
      .exchange(frame, options);
  }
}

// The wiki Worker receives DATA_PLANE as a service binding, not env.FRAM.
export function client(DATA_PLANE) {
  return framClient({
    space: SPACE,
    transport: framDurableObjectTransport(DATA_PLANE),
  });
}
```

The raw storage-owning object takes a canonical FRAMRPC v2 request frame and
answers with one response frame only after any write is durable:

| method | validates | dispatches |
| --- | --- | --- |
| `exchange(frame, { entry, space })` | frame bound and envelope, exact SpaceId, closed operation, operation/entry agreement | `fram_query`, `fram_transact`, or `fram_snapshot` |

Only the backend Worker holds the raw namespace. Its data WorkerEntrypoint
resolves the object with `env.FRAM.getByName(SPACE)` and delegates only
`exchange`; the wiki Worker receives only that service binding. A separately
protected admin entrypoint may delegate export/restore to the same object, so
both capabilities still address one store. Frame encoding and result decoding
come from `@tompassarelli/framrpc/core`; the same official application client
therefore works over TCP or a Durable Object.

The Worker compatibility date must be `2026-03-15` or newer. The raw object
requires `state.id.name === spaceId`; unnamed and string-reconstructed object
IDs fail closed. This deployment regime therefore limits SpaceIds to 1,024
UTF-8 bytes, Cloudflare's maximum for exposing the stable object name, even
though FRAMRPC itself allows 4,096.

`exchange` refuses `rpc/checkpoint`. Checkpoint, export, and restore are
operator capabilities and must be hosted behind a separately authorized
WorkerEntrypoint; they never appear on the wiki's data-plane service binding.

## Portable FRAMLOG backup and restore

The raw storage owner also implements `exportFramlog()` and
`restoreFramlog(backup, options)`. Expose them only through a separately
authorized admin WorkerEntrypoint using `framAdminEntrypoint(namespace,
spaceId)`; the data-plane facade remains exchange-only. A portable export is
the exact authoritative FRAMLOG plus its SpaceId, served version, byte length,
and lowercase SHA-256. The derived snapshot image is deliberately excluded.

Restore verifies the closed backup envelope, checksum, embedded SpaceId, and
served version, then replays the complete byte string through the real Wasm
engine before writing storage. A replay that repairs or truncates a suffix is
not an acceptable backup. The default restore accepts only an object whose
log, image, and pending-restore marker are all empty. Replacing an existing
object requires the exact observed log identity:

```js
await admin.restoreFramlog(backup, {
  replace: true,
  expectedCurrent: { byteLength, sha256 },
});
```

The replacement transaction publishes the candidate FRAMLOG, clears the
derived image, and writes a durable pending marker atomically. Data exchange
and export fail closed while that marker exists, including after isolate loss.
The adapter then reopens the durable bytes without permitting repair, verifies
byte and served-version identity, and transactionally clears the exact marker
before acknowledging or serving the new state.

If publication is rejected, neither range changes and the next request reopens
the prior durable state. If durable reopen or marker removal fails after
publication, restore throws `FramBackupError` with code `restore-fenced` and an
`expectedCurrent` recovery identity. The candidate remains durable but fenced;
there is no automatic rollback and no success acknowledgement. Recover by
restoring a verified backup explicitly with that `{ byteLength, sha256 }` CAS.

## What it does with storage

One Durable Object owns two chunked key ranges in its own storage:

| range | holds |
| --- | --- |
| `framlog/` | the FRAMLOG, which is the authority |
| `framimage/` | the snapshot image a checkpoint writes |

Both are sliced into 64 KiB chunks under a `meta` key that carries the
authoritative length, because DO caps one value at 128 KiB. A commit rewrites
only the chunks at or after the lowest byte the guest modified, deletes the
chunks a shrinking object left behind, and publishes **both ranges in one
transaction** — fram boots through the image and replays the log tail, so the
pair must never be observed half-published.

Fram's storage hooks must return before the guest call unwinds, and DO storage
is async. So both objects are resident in isolate memory for the duration of a
guest call, and storage is touched only on either side of it: one load at open,
one commit after the call returns.

## Durability, exactly

`storage_sync()` returns 0 to the guest while the bytes are still only in the
isolate's heap. The guarantee is therefore scoped to this client's methods,
not to the engine's own sync:

- **Every exchange awaits the storage commit before it resolves.** A caller
  that awaits `exchange()` before responding cannot ack a commit that is
  not yet durable.
- **Commits are atomic and serialised.** Fram replays the log from byte zero, so
  a torn tail is unrecoverable where a short one is not. An isolate lost after
  `storage_sync` but before the commit lands leaves a *short* log, and the next
  request reopens it and answers.
- **A rejected commit fences the instance.** The dirty range is restored, the
  instance refuses every later call, and the Durable Object drops it, so the
  next request reopens from the bytes that actually landed. Nothing is acked
  from an instance whose relation to storage is unknown.
- **One boot per object, one guest call at a time.** Concurrent requests join a
  single boot rather than building two images over one storage, and calls into
  the guest are serialised because guest pointers live across the awaits inside
  a call.

What this does *not* give you is the local-disk regime's D1: there is no
`force(true)` barrier here, and durability is Cloudflare's storage commit.

A timeout or abort after a mutation has reached the Durable Object is
ambiguous: the commit may have landed even when the caller no longer receives
the response. Applications must recover by reading their idempotency receipt;
they must never blindly retry an ambiguous mutation.

## The seam is checked at startup

`FramInstance.instantiate` compares the module's real import and export lists
against `src/seams.mjs`, which mirrors `native/wasm-embed.seams` line for line,
and refuses a module that demands anything else. `scripts/check-seams.mjs` runs
the same comparison against the ledger at build time, where signatures are
visible too. A tenth host hook cannot reach this adapter silently.

## Test it

```console
$ bun install                        # pinned Miniflare/workerd toolchain
$ scripts/build-wasm.sh
$ bun test/pack-frames.mjs
$ bun run test:bun                   # durability, fencing, multi-chunk
$ bun run test:workerd               # the frame matrix inside workerd
```

`tests/fram_do_client_smoke.sh` is the same harness as one CI row: it builds
the wasm and the native lp64 oracle, runs both halves, and compares the
transcript and the FRAMLOG bytes the Durable Object wrote against the oracle's.
It SKIPs cleanly when Bun, Miniflare, or the wasi compiler is absent.

## Cloudflare capacity gate

`capacity/run-gate.sh` builds the current `libfram.wasm`, makes Wrangler emit
the deployment-shaped Worker bundle, and loads that exact emitted bundle with
the fixed wiki-shaped corpus through workerd. It refuses a supplied
`FRAM_DO_WASM_ARTIFACT` and a dirty
source tree, so its receipt binds the exact source commit, native-build input
manifest, and emitted Wasm digest. The functional process trees run in two
Linux cgroups, each with an exact 128 MiB memory ceiling and swap disabled.
The Bun/Miniflare controller stays outside both cgroups. The load phase runs in
workerd A, closes FRAM, and persists the Durable Object; the gate then proves
A's exact PID and process tree have exited before starting workerd B against
the same persistence directory for all four cold-reopen checks. Each workerd
and all of its descendants are confined to its own cgroup:

```sh
$ bun run capacity
```

The default checks the stricter Free-plan 3 MiB compressed Worker limit. Set
`FRAM_CF_CAPACITY_PLAN=paid` to check the Paid-plan 10 MiB limit. Both plans
also enforce Wrangler's 64 MiB pre-compression limit.

The deterministic receipt is `capacity/out/receipt.json`. It reports Wrangler's
displayed upload totals, hashes and exact byte sizes for emitted modules, guest
linear-memory high-water, and the kernel's peak for the whole workerd runtime
process tree. The receipt binds the bundle executed by workerd to the bundle
measured for upload and binds its Wasm bytes to current-source native
provenance. It keeps Wasm linear-memory capacity separate from
kernel cgroup-charged process-tree memory; neither is mislabeled as production
isolate RSS. It records the loaded and reopened Wasm sizes and independent
workerd process-tree peaks separately. Although process replacement prevents
actual overlap in this gate, it retains the loaded-plus-reopened Wasm sum as an
additional conservative ceiling. The Worker also reports the exact FRAM engine
memory budget and guest-arena sizing it observed at runtime. The tracked profile
uses a 64 MiB engine budget and eight-page arena growth so FRAM compacts before
an allocation spike can consume the isolate ceiling. That budget is an engine
control, not evidence that the Worker fits: the full cgroup row must still pass.
The process-tree row is deliberately stricter than an
isolate-only limit, but it is not a measurement of Cloudflare production
isolate accounting. The receipt is capacity evidence only: it does not prove a
release, Access policy, production identity, an admin path, or backup/restore
peak memory.

The tracked corpus is a launch-blocking capacity floor with a fixed
representative wiki shape, not a forecast of Greywrought traffic: 256 articles,
three revisions per article, 2,048-byte deterministic bodies, four links per
revision, and 6,912 facts total. Each article contributes three article facts
plus `3 × (4 revision facts + 4 link facts)`, or 27 facts. The full profile is
deliberate: if it exceeds 128 MiB, the gate fails instead of silently shrinking
the workload. After replacing the load workerd, the gate also compares exact
response bytes for a durable title scan, ordered top-K query, and bound-attribute
text query; the text corpus deliberately puts the same token in an unrelated
attribute. Change `capacity/corpus.json` only with the profile contract test and
an explicit capacity decision.
