# `@tompassarelli/beagle-store-rpc`

The official client for Beagle Store's binary FRAMRPC v2 data plane. It is an ES
module with no runtime dependencies. The root entry point binds Bun TCP; the
portable `./core` entry point accepts an exact-frame transport. Both expose
the same thirteen frozen data operations.

Use this client for application and builder traffic that needs exact recursive
Terms, atomic batches, optimistic versions, occurrence replay, or pinned
pagination. `beagle-store-mcp` remains the narrower agent-facing JSON-RPC surface.

## Install

Every tagged Beagle Store release attaches a reproducible
`tompassarelli-beagle-store-rpc-<package-version>.tgz` and its
`store-bun-release-receipt/v2` file. The receipt binds the tarball hash and
declared package version to the exact annotated Beagle Store release tag object and
source commit. Once the tarball is downloaded, installation needs no registry
or network access:

```console
$ bun add --offline /path/to/tompassarelli-beagle-store-rpc-0.5.0.tgz
```

The client package version is independent of the containing Beagle Store release tag;
use the receipt when provenance matters. A checkout remains directly
installable for development:

```console
$ bun add /path/to/store/clients/bun
```

Bun 1.3.13 or newer is required.

The runtime-neutral `@tompassarelli/beagle-store-rpc/core` entry point exposes the same
client over an injected exact-frame transport and has no TCP or Node builtin
dependency. It is the supported route for Workers and embedded hosts:

```js
import { storeClient } from '@tompassarelli/beagle-store-rpc/core';
import { storeDurableObjectTransport } from '@tompassarelli/store-cloudflare-do';

const space = 'wiki.greywrought.com';
const store = storeClient({
  space,
  // DATA_PLANE is an exchange-only service binding. The raw Durable Object
  // namespace remains private to the backend Worker.
  transport: storeDurableObjectTransport(env.DATA_PLANE),
});
```

The transport accepts and returns canonical FRAMRPC bytes. It does not change
the operation set or engine ABI. A timeout after dispatch is ambiguous for a
mutation; recover by reading the application's idempotency receipt and never
blindly retry it.

## Connect

```js
import { storeClient, keywordTerm } from '@tompassarelli/beagle-store-rpc';

const store = storeClient({
  host: process.env.BEAGLE_STORE_SERVER_CONNECT || '127.0.0.1',
  port: Number(process.env.BEAGLE_STORE_SERVER_PORT || 7977),
  space: process.env.BEAGLE_STORE_SPACE_ID,
});

const version = await store.version();

const actions = [
  {
    op: 'assert',
    t1: '@document-1',
    t2: keywordTerm('title'),
    t3: 'Running with Wolves',
  },
  {
    op: 'assert',
    t1: '@document-1',
    t2: keywordTerm('kind'),
    t3: keywordTerm('note'),
  },
];
const preflight = store.preflightBatch(actions, {
  expectedVersion: version.servedVersion,
});
await store.batch(actions, {
  expectedVersion: version.servedVersion,
  preflight,
});
```

Every response includes the exact `servedVersion`, optional page metadata, the
decoded operation result, and the original typed payload:

```js
{
  space,
  operation,
  servedVersion, // bigint
  page,          // { ordinal, nextCursor, done } or null
  result,        // operation-specific decoded result
  payload        // exact recursive Term
}
```

## Structured queries

`query` accepts the same structured query object as Beagle Store's public `ask`
boundary. Constants use the typed Term constructors when their type is not a
String, Int, Float, or Bool.

```js
const response = await store.query({
  find: 'matches',
  rules: [{
    head: { rel: 'matches', args: [{ var: 'entity' }] },
    body: [{
      rel: 'text-match',
      args: [{ var: 'entity' }, keywordTerm('title'), 'running'],
    }],
  }],
}, {
  timeoutMs: 5000,
  page: { limit: 100 },
});

for (const row of response.result) console.log(row);
```

Pass `asOf` for an immutable historical snapshot or `since` for an occurrence
window:

```js
await store.query(query, { asOf: 42n });
await store.query(query, { since: { lowerExclusive: 10n, upper: 42n } });
```

Continue a page by returning its cursor unchanged with the same request:

```js
let cursor;
do {
  const page = await store.scan(
    { t2: keywordTerm('title') },
    { page: { limit: 200, ...(cursor ? { cursor } : {}) } },
  );
  consume(page.result);
  cursor = page.page.done ? null : page.page.nextCursor;
} while (cursor);
```

The cursor pins the original snapshot; a continuation reports that pinned
`servedVersion` even when newer writes have committed.

## Term representation

Terms use the same exact tagged arrays as Beagle Store's JSON edge:

| Beagle Store type | Bun representation |
|---|---|
| String | `['string', value]` |
| Int | `['integer', canonicalDecimal]` |
| Float | `['float64', ieee754Hex]` |
| Bool | `['boolean', value]` |
| Keyword | `['keyword', spelling]` |
| Instant | `['instant', epochSeconds, nanos]` |
| Triple | `['triple', t1, t2, t3]` |

Use `stringTerm`, `integerTerm`, `float64Term`, `booleanTerm`, `keywordTerm`,
`instantTerm`, and `tripleTerm` to construct them. Plain strings, safe integer
numbers, bigints, non-integer numbers, booleans, and `Date` values are lowered
automatically. Integers decode as canonical decimal strings inside Terms and as
`bigint` in response metadata so no i64 precision is lost.

## Operations

The client exposes exactly the frozen FRAMRPC v2 method set:

- `version`, `status`, `validate`
- `assert`, `retract`, `batch`
- `scan`, `query`, `occurrences`
- `leaseAcquire`, `leaseRenew`, `leaseRelease`, `leaseCheck`

Server errors throw `StoreRpcError` with `code`, `retryable`, `detail`,
`servedVersion`, and operation identity. Transport and malformed-frame errors
use `StoreTransportError` and `StoreProtocolError`.

`FRAMRPC_MAX_BATCH_ACTIONS` is the canonical 247-action mutation-response depth
ceiling. The client rejects a larger batch before transport. Mutation receipts
decode each accepted action as
`{ inputIndex, stateChanged, occurrence }`. `occurrence` is the one exact
occurrence-coordinate Term assigned to that action. This includes an unmatched
retraction: it reports `stateChanged: false` while still advancing the version
and receiving a coordinate. Receipts do not repeat submitted proposition Terms,
so large action Terms do not enlarge the response. Beagle Store still
exact-preflights the response frame before commit because SpaceId size and the
receipt-envelope width determine its encoded bytes.

`occurrences()` returns `{ coordinate, action, proposition }` objects. The
coordinate is validated as
`((space, :kernel/tx-sequence, sequence), :kernel/op-ordinal, ordinal)`, action
is exactly `assert` or `retract`, and proposition is a Triple Term. Retraction
targets are not embedded in this stream; query `withdrawal(retraction,
assertion)` when the exact cancelled assertion matters.

`preflightBatch(actions, options)` is a synchronous, no-send helper over the
exact request encoder. It returns a frozen
`{ actionCount, requestBytes, bodyBytes, termCount, maxTermDepth }` object and
enforces the same frame, Term-node, Term-depth, and action ceilings as the
eventual call. Pass that object back as `batch(..., { preflight })`; the client
re-encodes the request and throws `StoreProtocolError` with
`client/preflight-mismatch` before opening a connection if any metric changed.
This helper is client-side and does not add a fourteenth FRAMRPC operation.

### Native operator checkpoint

`storeNativeCheckpoint(options)` is one separately named, fixed operator
capability used by `bin/beagle-store-backup`. It sends only `rpc/checkpoint`, cannot be
used as a generic operation escape hatch, and is deliberately absent from the
ordinary `storeClient` object. The native server writes its derived snapshot
image and returns the exact durable FRAMLOG watermark, served version,
timestamp, snapshot CRC32, and snapshot byte count. Application and builder
traffic should use `storeClient`; the JVM routes may reject this native-only
operator operation.

## Schema-aware application writes

The optional `@tompassarelli/beagle-store-rpc/schema` entry point builds reusable
application constraints over an injected official client. It adds no FRAMRPC
operation and assigns no domain role to the neutral kernel.

```js
import { storeClient, keywordTerm } from '@tompassarelli/beagle-store-rpc';
import { schemaClient } from '@tompassarelli/beagle-store-rpc/schema';

const store = storeClient({
  space: process.env.BEAGLE_STORE_SPACE_ID,
});
const schema = schemaClient(store, {
  maxConflictRetries: 4,
  queryTimeoutMs: 5000,
});

const page = await schema.upsertUnique({
  subject: '@page-1',
  identity: { predicate: keywordTerm('page/slug'), value: 'home' },
  fields: [
    {
      predicate: keywordTerm('page/title'),
      value: 'Home',
      cardinality: 'single',
    },
    {
      predicate: keywordTerm('page/tag'),
      value: 'wiki',
      cardinality: 'multi',
    },
  ],
});

console.log(page.subject, page.servedVersion, page.changed);

await schema.updateUnique({
  identity: { predicate: keywordTerm('page/slug'), value: 'home' },
  field: {
    predicate: keywordTerm('page/state'),
    values: [keywordTerm('canonical')],
    cardinality: 'single',
    allowedCurrent: [keywordTerm('draft')],
  },
  requireUnique: [{
    subject: '@user-1',
    predicate: keywordTerm('user/email'),
    value: 'editor@example.test',
  }],
});

await schema.updateUniqueMany({
  updates: [
    {
      identity: { predicate: keywordTerm('revision/id'), value: 'rev-1' },
      fields: [{
        predicate: keywordTerm('revision/state'),
        values: [keywordTerm('canonical')],
        cardinality: 'single',
        allowedCurrent: [keywordTerm('draft')],
      }],
    },
    {
      identity: { predicate: keywordTerm('page/slug'), value: 'home' },
      fields: [{
        predicate: keywordTerm('page/canonical-revision'),
        values: ['@revision-1'],
        cardinality: 'single',
        allowedCurrent: [],
      }],
    },
  ],
});

await schema.transactUnique({
  creates: [{
    subject: '@revision-2',
    identity: { predicate: keywordTerm('revision/id'), value: 'rev-2' },
    fields: [{
      predicate: keywordTerm('revision/page'),
      value: '@page-1',
      cardinality: 'single',
    }],
  }],
  updates: [{
    identity: { predicate: keywordTerm('page/slug'), value: 'home' },
    fields: [{
      predicate: keywordTerm('page/temporary-title'),
      values: [],
      cardinality: 'single',
    }],
  }],
  requireUnique: [{
    subject: '@revision-2',
    predicate: keywordTerm('revision/id'),
    value: 'rev-2',
  }],
});
```

The wrapper exposes six mutations:

- `replaceSingle(subject, predicate, value)` retracts every current value and
  asserts the requested value once.
- `createUnique({ subject, identity, fields })` rejects an identity that
  already belongs to any subject, then creates it atomically with its fields.
- `upsertUnique(...)` updates the sole subject owning the identity, or uses the
  supplied subject as the create candidate when no owner exists.
- `updateUnique({ identity, field, requireUnique })` requires one source owner,
  checks optional unique-reference guards, and replaces the whole field in one
  OCC batch.
- `updateUniqueMany({ updates, requireUnique })` resolves every source and
  replaces multiple fields across multiple subjects in one guarded OCC batch.
- `transactUnique({ creates, updates, requireUnique })` combines a create set
  and updates of existing identity owners in one guarded OCC batch.

`fields[].cardinality` defaults to `single`. An update scans every live
occurrence of a single-valued field, including duplicate equal propositions;
`multi` fields append an assertion. Creation asserts every field directly. Do
not repeat the identity predicate in `fields`. Tagged Terms pass through
unchanged, including recursive Triple, Instant, integer, and float
representations.

`updateUnique` accepts zero or one desired `values` entry for `single` and zero
or more for `multi`; zero desired single values clear the cell. Duplicate
desired Terms are asserted once.
Every existing occurrence is retracted, including duplicate equal
propositions. When `allowedCurrent` is present, the current occurrences must
either be absent when the allowed set is empty, represent exactly one distinct
value in a nonempty allowed set for `single`, or equal the complete
order-insensitive distinct Term set for `multi`. `allowedCurrent: []` is
therefore an absence compare-and-set for either cardinality. Duplicate expected
Terms are canonicalized to the same set. An exact single occurrence already
equal to the desired single value is a no-op. Duplicate equal
occurrences still retract in full and collapse to one assertion. The updated
field predicate must differ from the lookup identity predicate, which is
immutable through this operation. Each
`requireUnique` entry is `{ subject, predicate, value }`; its predicate/value
identity must resolve to that subject alone. `createUnique` and `upsertUnique`
accept the same optional guard array.

`updateUniqueMany` requires a nonempty `updates` array and at least one field
per update. Its `subjects` result is aligned with `updates`. Duplicate resolved
`(subject, predicate)` targets are rejected, including aliases that select the
same subject, and no update may replace any lookup identity used for that
subject. Source identities, command-level `requireUnique` guards, current
field values, and every generated retraction all come from one pinned snapshot.
One failed guard prevents the entire command from writing.

`transactUnique` requires at least one create or update. Every planned create
declares one identity, and duplicate planned identities or subjects are
rejected before I/O. A create field or update value cannot separately assert a
planned identity. Create identities must be absent and update identities must
resolve to existing subjects at the attempt's pinned snapshot. A
`requireUnique` entry may name a planned create: it is satisfied by that exact
planned subject after the complete create set passes its absence checks, which
permits mutual and cyclic references in the same batch. Other guards are
resolved from the live snapshot. A request/idempotency reservation is therefore
an ordinary planned create with a unique identity. After an OCC conflict the
whole plan is rebuilt, and a reservation won by another attempt becomes the typed
`schema/identity-exists` result before a second write is sent. If a resolved
update and a create target the same subject/predicate cell, the command is
rejected instead of relying on action order.

Each attempt reads a version, resolves identity with a structured query at that
exact snapshot, and accepts current scans only when they serve the same version.
It then submits one batch with that `expectedVersion`. A current scan that races
ahead causes a fresh no-write attempt. The only remote error retried is a typed,
retryable `StoreRpcError` whose code is `rpc/conflict`; the default is four
retries after the initial attempt and the configurable hard ceiling is 32.
Duplicate identity owners are never selected arbitrarily.

Schema batches are capped at 247 actions, the FRAMRPC v2 mutation-response depth
ceiling exported by the base client. Before sending, the schema client calls
`preflightBatch` with the exact actions and expected version and attaches the
result to `batch`, so a changed request is rejected locally. Beagle Store also
exact-preflights the encoded mutation response size and may reject a
long-SpaceId or wide receipt envelope atomically before commit. Submitted
action Terms are absent from that response. The depth cap applies to each
complete `updateUniqueMany` or `transactUnique` command and it is never split.
Inputs are
bounded before any Beagle Store call: unique creation accepts at most 246 fields because
its identity is also an action, updates accept at most 247 targets, fields,
desired values, or `allowedCurrent` entries, and `requireUnique` accepts at most
247 entries. Identity and current-field reads
run at most eight at a time. Each read accepts at most two 128-row pages, which
is enough to observe the 248th occurrence that proves an action-limit failure;
unfinished pages with repeated cursors are rejected. These fixed
limits are exported as `SCHEMA_MAX_BATCH_ACTIONS`,
`SCHEMA_MAX_REQUIRE_UNIQUE`, `SCHEMA_MAX_GUARD_CONCURRENCY`, and
`SCHEMA_MAX_READ_PAGES`. Constraint failures throw `SchemaConstraintError`
with one of these stable codes:

- `schema/invalid-input`
- `schema/invalid-response`
- `schema/identity-exists`
- `schema/identity-missing`
- `schema/duplicate-identity`
- `schema/duplicate-create-subject`
- `schema/duplicate-update-target`
- `schema/required-identity-missing`
- `schema/current-value-rejected`
- `schema/action-limit`
- `schema/conflict-exhausted`

Single-subject methods return
`{ subject, created, changed, servedVersion, result }`.
`subject` is the exact selected Term and `result` is the official batch action
receipt array. A mutation needing no batch returns an empty result at its pinned
version. `updateUniqueMany` instead returns
`{ subjects, changed, servedVersion, result }`. `transactUnique` returns
`{ createdSubjects, updatedSubjects, changed, servedVersion, result, preflight }`;
the subject arrays align with the input create and update arrays, and
`preflight` is null only when an update-only plan needs no batch.

FRAMRPC v2 serves one request per TCP connection. The client follows that
contract directly without HTTP, JSON, MCP, or a Clojure shim. The server socket
is plaintext and unauthenticated; keep it on loopback or a private network, or
put an authenticated TLS boundary in front of it.

## License

Licensed under either the [MIT License](LICENSE-MIT) or the
[Apache License, Version 2.0](LICENSE-APACHE), at your option. See the
[license chooser](LICENSE).
