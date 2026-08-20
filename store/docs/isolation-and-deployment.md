# Isolation, wire, and deployment

This document specifies the source-head database trust domain, the server bind and Store RPC boundary, the three supported deployment shapes, and the contract an embedder faces.

## Trust domain and bind

Beagle Store has no engine accounts, authorization, or tenant policy. One [SpaceId](glossary.md#storage-and-query), one Store transaction log, one writer, and one private network boundary form a trust domain. Separate personal, client, and public-tooling data across all four; ontology fields are not tenant isolation. What makes the writer sole is regime-specific and is stated under [deployment shapes](#deployment-shapes).

Logical identity never supplies that isolation. Two trust domains may contain
structurally equal Terms or receipts without sharing writer authority, secrets,
or permission to execute. Content identity is not trust, and semantic
unification across Beagle does not collapse Store spaces, processes,
deployments, or security boundaries.

`bin/beagle-store-server` launches native by default and fails closed unless `BEAGLE_STORE_NATIVE_ARTIFACT_DIR` names a READY artifact containing `bin/beagle-store-server-native`. `BEAGLE_STORE_SERVER_RUNTIME=graal` selects the transitional self-contained server at the absolute `BEAGLE_STORE_GRAAL_ARTIFACT` path without presenting it as a native program artifact. `jvm-oracle` selects the sealed packaged JVM differential oracle; `jvm-dev` selects the checkout-only Clojure development route. None is an automatic fallback. The server binds `127.0.0.1` by default. `BEAGLE_STORE_BIND` changes the listener intentionally, `BEAGLE_STORE_SERVER_PORT` selects its port, and `BEAGLE_STORE_SERVER_CONNECT` selects the client host. New databases require `BEAGLE_STORE_SPACE_ID`; every request carries the same identity or is rejected. `BEAGLE_STORE_LISTEN_FD` may pass an operator-owned INET listener without changing codec, operations, or writer authority.

The native host admits a bounded number of concurrent clients, each served by one worker thread. `BEAGLE_STORE_MAX_ACTIVE_CLIENTS` sets that bound and `BEAGLE_STORE_CONNECTION_WORKERS` is honored as its deployment-facing name; the default is 64. The bound must stay below every task limit the supervisor imposes — systemd `TasksMax`, cgroup `pids.max`, `RLIMIT_NPROC` — or the cgroup refuses the worker thread before the host's graceful over-cap refusal can engage. Over-cap connections are closed without a response; transient thread or memory pressure refuses the connection and keeps accepting rather than abandoning the listener. `BEAGLE_STORE_CLIENT_IO_TIMEOUT_MS` bounds how long a worker may block on a peer socket (default 15000; 0 removes the bound), so a client that connects and never sends, or vanishes mid-packet, releases its slot instead of holding it open. A connection that reaches the front of the accept queue already at end-of-file is closed without spending a worker at all. A request that arrives complete is always dispatched: Store RPC clients may half-close after sending, and a half-close is indistinguishable from a disconnect, so the host never abandons a request it has finished reading. Worker threads can read their sockets concurrently, but native production holds one `dispatch_mutex` across the dispatch of each fully read request; the client admission count is not a non-convoying-read guarantee.

When `NOTIFY_SOCKET` is set, the native host sends `READY=1` once the store has booted and replayed and the accept loop is running, and `STOPPING=1` when it begins draining. Readiness deliberately does not mean "listening": under socket activation the listener exists before the process does, so a unit that gates on the socket learns nothing. Outside a service manager `NOTIFY_SOCKET` is unset and the notification is a no-op; the host links no libsystemd.

The Cloudflare server image carries one statically linked musl native artifact
on `scratch`, packaged from its READY receipt rather than compiled in the image;
the authenticated HTTP shim remains a separate Babashka container.

The listener is plaintext. Remote deployments keep it private and terminate TLS, authentication, tenant routing, request limits, and public audit policy at a gateway or sidecar.

## Store RPC v2

Store RPC v2 (wire version 2.0) is a bounded binary protocol. Version 2.0 is
exact: a mismatch in either the major or minor version is rejected. Every packet
has a 26-byte header carrying magic, version, packet kind, flags, body length,
and request id; its body is at most 1,048,576 bytes, so the complete packet is at
most 1,048,602 bytes. A request body carries a SpaceId of at most 4,096 UTF-8
bytes, one operation tag, typed controls, and one closed payload. A response
body carries SpaceId, operation, served version, and optional page, error, and
payload fields. Terms use the recursive tagged codec linked from the
[glossary](glossary.md#semantic-kernel); triples are positional tagged arrays,
so `t1`/`t2`/`t3` never appear on the wire.

Version 2 is intentionally incompatible with version 1. Occurrence responses
carry explicit `coordinate`, `action`, and `proposition` fields, and each
mutation action result carries one occurrence coordinate rather than a list of
manufactured history Terms. Clients and servers reject every version other
than 2.0 instead of translating or negotiating it.

The JVM codec models all four packet kinds: request, response, cancel, and event.
A cancel packet still carries the header and request id but requires a zero-byte
body. The native boundary is deliberately directional: its decoder accepts only
request packets and its encoder emits only response packets. Shared canonical
request/response bytes do not imply an identical host codec surface.

Unknown operation, record, field, and Term tags, trailing bytes, or over-limit nesting are rejected. Store RPC is not EDN, JSON, HTTP, or MCP.

The data surface is exactly thirteen operations:

- metadata: `rpc/version`, `rpc/status`, `rpc/validate`;
- mutation: `rpc/assert`, `rpc/retract`, `rpc/batch`;
- read: `rpc/scan`, `rpc/query`, `rpc/occurrences`;
- fencing: `rpc/lease-acquire`, `rpc/lease-renew`, `rpc/lease-release`, `rpc/lease-check`.

Query, scan, and occurrences accept page requests, with operation-specific
cursors; only query accepts a timeout. On native, an unpaged query above 248
rows refuses `:term-depth-exceeded`; scan allows at most 200 rows per page,
refuses a larger unpaged result with `:rpc/native-page-required`, and emits a
native scan cursor; unpaged `rpc/occurrences` silently returns only its first 248
rows. Paginate every nontrivial read.

Every one of the thirteen data operations accepts an expected logical version,
which is enforced before operation-specific handling; a stale or future value
returns `:rpc/conflict`. Reads report served version, and status reports
ordered-result-cache counters. There is no Store RPC pull, import/export,
graph-edit, deployment, or cutover operation; those local or sealed controls do
not enlarge Store RPC.

The native engine answers one operation beyond that data surface: `rpc/checkpoint`
takes `:rpc/unit`, refuses a page cursor, writes the
[snapshot image](glossary.md#storage-and-query) to the second storage object,
appends nothing to the Store transaction log, changes no store state, and answers sequence,
watermark, stamp, fingerprint, and image byte count. It is an operator and
embedder control, not application traffic: the JVM oracle route, the Bun
`storeClient` object, the shim, and `bin/beagle store` all stay at the thirteen data
operations. The Bun module exposes only one separately named fixed operator
helper, `storeNativeCheckpoint`, for `bin/beagle-store-backup`; it cannot select a raw
operation and is not a method on the data client.
[`../tests/store_snapshot_boot_test.sh`](../tests/store_snapshot_boot_test.sh)
gates the operation and the boot route it feeds.

The official zero-dependency [`clients/bun/store-rpc.mjs`](../clients/bun/store-rpc.mjs) client requires Bun 1.3.13 or newer, connects directly, and exposes all thirteen data operations with recursive Terms, batches, versions, snapshots, paging, replay, and leases.

## Capability profiles

Store can fill a storage-shaped responsibility inside a brownfield system
without becoming a separate product. A profile narrows the same kernel; it
does not acquire independent semantics:

- **Embedded native or Wasm.** Link `native/store.h` or instantiate
  `lib/libstore.wasm`, supply storage and clock capabilities, and exchange one
  exact Store RPC packet per typed entry point. There is no listener and no
  compiler frontend in the runtime artifact.
- **Private sidecar or service.** Run the native server beside the application
  and use the official Bun client over Store RPC. TLS, authentication, tenant
  selection, and public policy remain at the application edge.
- **Cache-shaped policy.** Store live values, expiry, and materialization
  provenance as ordinary propositions; reject expired values at read time and
  retract them on replacement or invalidation. The transaction log retains the
  history, and the snapshot remains derived restart acceleration. This adds no
  cache-specific operation, storage engine, or identity rule.

[`../examples/embedded-c.c`](../examples/embedded-c.c),
[`../examples/rpc-sidecar.mjs`](../examples/rpc-sidecar.mjs), and
[`../examples/cache-profile.mjs`](../examples/cache-profile.mjs) are the
minimal runnable examples. Published native/Wasm artifacts and the Bun client
package are sufficient; rebuilding them is the only path that needs Beagle's
compiler toolchain.

Store records data supplied through these capabilities; it does not execute an
external plan merely because the plan or its content is present. In Beagle's
system direction, planning stays pure, an external host checks an explicit
target capability before execution, and the resulting receipt returns as a new
record. A subsequent observation, with its own provenance, is what can support
a claim about external reality.

The boundary is closed at the lowest deterministic layers:

| Claim | Authority and gate |
|---|---|
| Native embedding ABI and export set | `native/store.h`; `tests/store_native_generated_adapter_smoke.sh` |
| Wasm imports and exports | `native/wasm-embed.seams`; `tests/store_wasm_embed_smoke.sh` |
| Store RPC data operations stay closed | `tests/native_rpc_boundary_ratchet_test.clj` |
| Bun client stays typed and package-complete | `clients/bun/store-rpc.d.ts`; `tests/bun_package_types_test.mjs` |
| Examples remain executable without a network service | `tests/store_capability_examples_smoke.sh` |

## Deployment shapes

Three shapes serve the same engine. They differ in who owns the process, who
owns the log bytes, and what makes the writer sole.

| Shape | Engine | Log bytes | Exclusivity |
|---|---|---|---|
| Host-managed server | `bin/beagle-store-server` running `bin/beagle-store-server-native` | POSIX file, `history.storelog` | `flock(LOCK_EX\|LOCK_NB)` on the log descriptor, taken at boot |
| Container | the same static musl artifact on `scratch` | container volume, `/data/history.storelog` | the same flock, inside one container |
| Embedded in an isolate | `lib/libstore.wasm`, linked `--host wasm-embed` | whatever the embedder's storage hooks write | the embedder's: a Durable Object id, a lease, or another single-instance grant |

The first two are one process holding a socket and speaking Store RPC. The third
has no socket and no process of its own: the embedder instantiates the module
and calls `store_transact`, `store_query`, or `store_snapshot` with one canonical
Store RPC v2 request packet in linear memory, receiving one canonical response
packet. The accepted request and emitted response envelope, operations, and
refusals are shared subject to the directional native codec restriction above.
The wasm engine answers byte-for-byte what the native embed library answers on
the same accepted request packets — including the Store transaction-log bytes both write
([`../tests/store_wasm_embed_smoke.sh`](../tests/store_wasm_embed_smoke.sh)).

Exclusivity per regime:

- **POSIX storage** (both server shapes): the engine takes the lock itself. A
  second server on the same log fails closed with `canonical Store transaction-log writer
  authority is unavailable`.
- **Host storage table** (`store_open` with a host, native or wasm): a successful
  open transfers storage-*close* responsibility to Beagle Store, but exclusivity stays
  the embedder's obligation. A wasi build cannot take the lock at all —
  wasi-libc declares `flock` and links no implementation — so the guard stands
  down there rather than pretending.
- **Durable Object**: the platform runs one instance per object id, so the id
  is the exclusivity. The supported backend resolves the raw storage owner only
  with `getByName(SpaceId)` and never binds that namespace into an application
  Worker. Its data WorkerEntrypoint facade exposes only `exchange`: the raw
  object checks the bounded Store RPC envelope and operation/entry agreement, and
  refuses the checkpoint operator capability. A separately protected admin
  entrypoint may address the same raw object for export/restore. One named id,
  one database, one writer; bypassing these bindings is a deployment error the
  engine cannot detect.

The engine's `expected-version` OCC check and lease fencing are unchanged in
every regime; neither substitutes for sole-writer exclusivity.

## Edge and process shape

```text
client -- HTTPS/closed JSON --> authenticated Worker or shim
       -- private Store RPC --> active Beagle Store server
       -- append --> database (SpaceId + Store transaction log)
```

The edge selects one SpaceId and maps tagged JSON to closed Store RPC records; it never forwards EDN or arbitrary server records. Cloudflare setup and probes live in [`../deploy/cloudflare/PROCEDURE.md`](../deploy/cloudflare/PROCEDURE.md).

- `bin/beagle-store-server` is the native-first launcher for the single active server. Native production exposes no standby-serving mode. It rebuilds state at boot by installing a valid snapshot image and replaying the tail past its watermark, or by folding the whole Store transaction log when there is no usable image.
- `bin/beagle store` is the local CLI and Store RPC client.
- `bin/beagle-store-mcp` is the five-tool JSON-RPC-over-stdio edge.
- The Cloudflare shim/Worker is an optional authenticated JSON edge.

The native route consumes only a linked executable promoted behind the native artifact's READY marker. The Graal route consumes the absolute executable named by `BEAGLE_STORE_GRAAL_ARTIFACT`; it is not a native program artifact, and it is no longer a deployment route — the container image is built from the native artifact and Graal survives only as the differential oracle for native selfcheck. Raw Beagle projection output is not executable runtime input. Compiled Clojure under `out/` remains available only through the explicit JVM routes. QBE remains the direct-native cross-check.

## The wasm embed contract

`bin/beagle-store-native-build --host wasm-embed --abi wasm32` links the engine into a
wasm32 reactor, `lib/libstore.wasm`. The module is the whole contract: no
socket, no filesystem, no ambient capability. Everything it needs, an embedder
supplies as named imports.

[`../native/wasm-embed.seams`](../native/wasm-embed.seams) is the authority. It
pins every import with its resolved signature and every export of the linked
module; the build compares each link against it and dies on any difference, and
`--regen-wasm-seams` is the only way to move it. A new line there is a new
capability demand on every embedder and must be argued in the comments the
regeneration preserves.

**Host hooks.** Module `store_host_v1` carries nine imports, one per
`store_host_v1` field in [`../native/store.h`](../native/store.h), each named for
its field and typed by the wasm32 lowering of its prototype:

```text
allocate  deallocate                     memory for response buffers
clock_milliseconds                       the engine's wall clock
storage_size  storage_read  storage_truncate
storage_append  storage_sync  storage_close
```

Two storage objects ride those same storage hooks under a storage-context
argument: context `0` is the Store transaction log, context `1` is the snapshot image. An
embedder that offers no image simply never sees context `1`, and the engine
folds the whole log instead of installing one. An import reports failure by
returning nonzero; a *trapping* import unwinds the guest uncleaned, so a trap
is instance-fatal.

**WASI.** Seven `wasi_snapshot_preview1` imports are linked; two are live.
`clock_time_get` backs the engine's monotonic query clock, and
`environ_sizes_get` backs its `getenv` — wasi-libc calls `_Exit(71)` if the
sizes call is refused, so answer it with an empty environment. The remaining
five (`environ_get`, `fd_write`, `fd_close`, `fd_seek`, `proc_exit`) are
wasi-libc stdio and abort residue. The smoke test measures this rather than
asserting it: over the full packet matrix those five record zero calls.

**Exports.** Nine ABI functions plus `_initialize` and `memory`:
`store_abi_version`, `store_open`, `store_transact`, `store_query`,
`store_snapshot`, `store_close`, `store_buffer_release`, `store_wasm_alloc`,
`store_wasm_free`. `store_wasm_alloc`/`store_wasm_free` stage embedder-owned
request packets, options, and error structs; they never free a response, which
is released only through `store_buffer_release`. Identity is the instance: one
instance binds one database, and host contexts are the storage-object numbers
above.

**Budget.** `store_open_options_v1.memory_budget_bytes` derives arena growth,
compaction increment, and generation count from one number; zero leaves every
engine limit at its default, and a boot that names a budget reports the limits
it derived. The budget tunes compaction cadence — it does not soften
exhaustion. Running out of arena is a trap, never a typed response: the embed
boundary registers a trap reporter that writes one
`store: engine trap code=… status=…` line to file descriptor 2 before the abort
lands, naming `BEAGLE_STORE_OUT_OF_MEMORY` for arena exhaustion and `BEAGLE_STORE_HOST_ERROR`
for host I/O. It is a report, not a recovery — the instance is gone, and an
embedder that answers no `fd_write` sees only the trap. Size the store to the
budget.

## Durable state, backup, and restore

`history.storelog` is the authority. The adjacent snapshot image is derived
restart acceleration, not backup authority. `bin/beagle-store-backup` is the supported
live POSIX/native backup path:

```sh
bin/beagle-store-backup create \
  --output /srv/backups/store-2026-08-12T0900Z \
  --log /var/lib/store/history.storelog \
  --artifact-receipt "$BEAGLE_STORE_NATIVE_ARTIFACT_DIR/READY" \
  --space-id "$BEAGLE_STORE_SPACE_ID" \
  --host "${BEAGLE_STORE_SERVER_CONNECT:-127.0.0.1}" \
  --port "${BEAGLE_STORE_SERVER_PORT:-7977}"

bin/beagle-store-backup verify \
  --backup /srv/backups/store-2026-08-12T0900Z \
  --space-id "$BEAGLE_STORE_SPACE_ID"
```

The output path must be absolute and absent. Create opens the supplied Store transaction log
as a non-symlink regular file before asking the native server for a checkpoint.
It verifies the log header SpaceId and the newly written adjacent snapshot
sidecar against the checkpoint receipt; this binds the cutoff to the supplied
server storage path. It then copies exactly the durable prefix through the
returned watermark. Later appends may continue and are not part of that
backup.

A complete backup contains exactly `history.storelog`, `artifact.READY`,
`manifest.json`, and `manifest.sha256`. The manifest uses canonical UTF-8 JSON
with decimal strings for every i64 or byte count and records the SpaceId,
served version, cutoff, checkpoint metadata, SHA-256 of the exact history
prefix, SHA-256 of the exact READY receipt, and its native build closure hash.
`manifest.json` is the backup commit point and is installed last by atomic
rename after the other files and directory have been synced. A failed create
may leave an output directory without that commit point; verification refuses
it. The snapshot is intentionally absent because restore can fold canonical
history and regenerate derived state.

Restore is a gate, not a second storage subsystem:

```sh
backup=/srv/backups/store-2026-08-12T0900Z
restore=/var/lib/store-restored
bin/beagle-store-backup verify --backup "$backup" --space-id "$BEAGLE_STORE_SPACE_ID"
test ! -e "$restore/history.storelog"
mkdir -p "$restore"
cp "$backup/history.storelog" "$restore/history.storelog"
cmp "$backup/artifact.READY" "$BEAGLE_STORE_NATIVE_ARTIFACT_DIR/READY"
BEAGLE_STORE_SPACE_ID="$BEAGLE_STORE_SPACE_ID" bin/beagle-store-server serve \
  "${BEAGLE_STORE_SERVER_PORT:-7977}" "$restore/history.storelog"
```

Use fresh target storage and the exact artifact receipt carried by the backup.
A different SpaceId fails closed during boot before mutation. Native systemd readiness is
emitted only after the restored log has folded/replayed; the first
`rpc/version` must equal `manifest.json`'s `servedVersion`. Only then admit
writes. The recovery gate writes once, restarts again, and proves that the new
write survived. Inspect history through scan, query, occurrences, and validate,
never text scraping.

Source head exposes no deployment-control operation. Runtime publication uses
systemd socket activation and a generation symlink outside the data protocol.

Deployment worktrees stay pristine. Controller markers live in controller state, never the source tree being validated.

## Growth and retention — what the application owns

The log never deletes: every assertion and retraction is appended forever, and
that history is the product. Until compaction ships (tracked in
[guarantees](guarantees.md#profiles) as not yet gated), growth control belongs
to the application, on three measured facts:

- One operation costs ~26 bytes of packet envelope plus **every atom's bytes verbatim,
  every time it appears** — the log carries no string dictionary. A fact whose
  subject is a 100-character identifier pays those 100 bytes on each of its
  occurrences; measured: 1,000 assertions under one 10-character subject are
  36 KB, under one 100-character subject 126 KB. A generation created with
  `{:deflate? true}` compresses each packet (measured 17.8× on a repeated-long-id
  corpus, write and fold time unchanged); the flag is per-generation and set at
  `create-triple-log!`.
- Re-asserting a corpus appends all of it again, exactly linearly: a 15k-fact
  corpus measured 1.2 MB per generation and 12.2 MB after ten identical
  rebuilds. A rebuild-from-source lifecycle multiplies the log by the number
  of rebuilds and records rebuilds, not revisions.
- A reference saves bytes only when its token is shorter than what it
  replaces; pointing many facts at a long string id costs more than inlining.

The patterns that keep growth proportional to change:

1. **Supersede, don't rebuild.** Incremental updates from a change cursor keep
   history meaningful and the log linear in edits, not in rebuilds.
2. **One SpaceId per rebuild** when a full rebuild is genuinely needed: a new
   space is a new log file, and retiring the old one is ordinary file
   management.
3. **Short identity tokens.** Minted transaction coordinates (`txn/mint!`) are
   compact Terms; long human-readable identifiers belong in one asserted name
   fact, not in every subject position.
4. **Seal epochs** for ranges you must keep but will not touch.

## Probes

- [`../tests/store_rpc_v2_test.clj`](../tests/store_rpc_v2_test.clj): recursive Term records and codec.
- [`../tests/native_rpc_server_test.clj`](../tests/native_rpc_server_test.clj):
  the JVM listener route despite its historical filename.
- [`../tests/bun_store_rpc_client_test.mjs`](../tests/bun_store_rpc_client_test.mjs):
  the official client against the selected server runtime.
- [`../tests/native_rpc_boundary_ratchet_test.clj`](../tests/native_rpc_boundary_ratchet_test.clj): closed operation boundary.
- [`../tests/writer_authority_test.clj`](../tests/writer_authority_test.clj): writer-authority and JVM-oracle compatibility behavior.
- [`../tests/store_wasm_embed_smoke.sh`](../tests/store_wasm_embed_smoke.sh): the wasm host-import regime end to end — pinned seams, native/wasm response and Store transaction-log byte identity, the snapshot image, the unpaged codec bound, and the WASI call tally.
- [`../tests/store_snapshot_boot_test.sh`](../tests/store_snapshot_boot_test.sh): `rpc/checkpoint`, snapshot boot, and the degrade-to-fold path for a damaged image.
- [`../tests/store_backup_restore_test.sh`](../tests/store_backup_restore_test.sh): live cutoff backup, canonical hash verification, fresh-storage restore, wrong-SpaceId refusal, and a post-restore write across another restart.
