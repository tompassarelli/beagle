import { test } from 'bun:test';
import assert from 'node:assert/strict';
import {
  STORERPC_MAX_PACKET_BYTES,
  StoreProtocolError,
  StoreRpcError,
  StoreTransportError,
  booleanTerm,
  float64Term,
  storeClient,
  integerTerm,
  keywordTerm,
  stringTerm,
  tripleQuery,
  tripleTerm,
  storeTransportCheckpoint,
} from '../clients/bun/store-rpc-core.mjs';

const encoder = new TextEncoder();
const MAGIC = Uint8Array.of(0x53, 0x54, 0x4f, 0x52, 0x45, 0x52, 0x50, 0x43);

function concat(parts) {
  const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return bytes;
}

function integer(width, write, value) {
  const bytes = new Uint8Array(width);
  new DataView(bytes.buffer)[write](0, value, true);
  return bytes;
}

const u8 = value => integer(1, 'setUint8', value);
const u16 = value => integer(2, 'setUint16', value);
const u32 = value => integer(4, 'setUint32', value);
const i64 = value => integer(8, 'setBigInt64', value);

function textTerm(tag, text) {
  const bytes = encoder.encode(text);
  return concat([u8(tag), u32(bytes.length), bytes]);
}

function wireTerm(value) {
  switch (value[0]) {
    case 'string':
      return textTerm(1, value[1]);
    case 'integer':
      return concat([u8(2), i64(BigInt(value[1]))]);
    case 'boolean':
      return u8(value[1] ? 5 : 4);
    case 'keyword':
      return textTerm(6, value[1]);
    case 'triple':
      return concat([u8(7), wireTerm(value[1]), wireTerm(value[2]), wireTerm(value[3])]);
    default:
      throw new Error(`unsupported response fixture Term ${value[0]}`);
  }
}

function rpcList(values) {
  return values.reduceRight(
    (tail, value) => tripleTerm(keywordTerm('rpc/list'), value, tail),
    keywordTerm('rpc/list-end'),
  );
}

function rpcPacket(tag, fields) {
  return tripleTerm(keywordTerm(tag), rpcList(fields), keywordTerm('rpc/record'));
}

function successResponse(request, payload, { major = 2, minor = 0 } = {}) {
  const body = concat([
    textTerm(1, request.space),
    textTerm(6, request.operation),
    i64(1n),
    u8(0), // no page
    u8(0), // no error
    u8(1), // payload present
    wireTerm(payload),
  ]);
  return concat([
    MAGIC,
    u16(major),
    u16(minor),
    u8(2),
    u8(0),
    u32(body.length),
    i64(request.requestId),
    body,
  ]);
}

function rejectedResponse(request, requestId = request.requestId) {
  const body = concat([
    textTerm(1, request.space),
    textTerm(6, request.operation),
    i64(0n),
    u8(0), // no page
    u8(1), // error present
    textTerm(6, 'test/rejected'),
    u8(0),
    textTerm(1, 'expected transport test response'),
    u8(0), // no error detail
    u8(0), // no payload
  ]);
  return concat([
    MAGIC,
    u16(2),
    u16(0),
    u8(2),
    u8(0),
    u32(body.length),
    i64(requestId),
    body,
  ]);
}

async function expectRemoteRejection(promise) {
  await assert.rejects(
    promise,
    error => error instanceof StoreRpcError && error.code === 'test/rejected',
  );
}

test('data client and operator checkpoint cover the exact fourteen server operations', async () => {
  const observed = [];
  const transport = request => {
    observed.push(request);
    return rejectedResponse(request);
  };
  const store = storeClient({ space: 'worker-space', transport });
  const fence = tripleTerm(keywordTerm('rpc/fence'), 'holder', 1);

  await expectRemoteRejection(store.version());
  await expectRemoteRejection(store.status());
  await expectRemoteRejection(store.validate());
  await expectRemoteRejection(store.occurrences());
  await expectRemoteRejection(store.scan({ t1: 'subject' }));
  await expectRemoteRejection(store.query(tripleQuery()));
  await expectRemoteRejection(store.assert('subject', 'predicate', 'object'));
  await expectRemoteRejection(store.retract('subject', 'predicate', 'object'));
  await expectRemoteRejection(store.batch([
    { op: 'assert', t1: 'subject', t2: 'predicate', t3: 'object' },
  ]));
  await expectRemoteRejection(store.leaseAcquire('resource', 'holder', 1000));
  await expectRemoteRejection(store.leaseRenew(fence, 1000));
  await expectRemoteRejection(store.leaseRelease(fence));
  await expectRemoteRejection(store.leaseCheck(fence));

  assert.equal(store.checkpoint, undefined);
  assert.equal(observed.length, 13);
  assert.deepEqual(
    observed.map(request => request.operation),
    [
      'rpc/version', 'rpc/status', 'rpc/validate', 'rpc/occurrences',
      'rpc/scan', 'rpc/query', 'rpc/assert', 'rpc/retract', 'rpc/batch',
      'rpc/lease-acquire', 'rpc/lease-renew', 'rpc/lease-release',
      'rpc/lease-check',
    ],
  );
  assert.equal(new Set(observed.map(request => request.operation)).size, 13);
  assert.deepEqual(
    observed.map(request => request.entry),
    [
      'query', 'query', 'query', 'snapshot', 'query', 'query',
      'transact', 'transact', 'transact', 'transact', 'transact',
      'transact', 'query',
    ],
  );
  for (const request of observed) {
    assert.equal(Object.isFrozen(request), true);
    assert.equal(request.space, 'worker-space');
    assert(request.packet instanceof Uint8Array);
    assert(request.packet.length <= STORERPC_MAX_PACKET_BYTES);
    assert(request.signal instanceof AbortSignal);
  }

  await expectRemoteRejection(storeTransportCheckpoint({
    space: 'operator-space',
    transport,
  }));
  const checkpoint = observed.at(-1);
  assert.equal(observed.length, 14);
  assert.equal(checkpoint.operation, 'rpc/checkpoint');
  assert.equal(checkpoint.entry, 'transact');
  assert.equal(checkpoint.space, 'operator-space');
  assert.equal(Object.isFrozen(checkpoint), true);
  assert(checkpoint.packet instanceof Uint8Array);
  assert(checkpoint.packet.length <= STORERPC_MAX_PACKET_BYTES);
  assert(checkpoint.signal instanceof AbortSignal);
  assert.equal(new Set(observed.map(request => request.operation)).size, 14);
});

test('transport responses retain exact protocol identity checks', async () => {
  const store = storeClient({
    space: 'worker-space',
    transport: request => rejectedResponse(request, request.requestId + 1n),
  });
  await assert.rejects(
    store.version(),
    error => error instanceof StoreProtocolError
      && error.code === 'client/identity-mismatch',
  );
});

test('STORERPC v1 response packets are rejected at the v2 client boundary', async () => {
  const store = storeClient({
    space: 'worker-space',
    transport: request => successResponse(request, keywordTerm('rpc/unit'), { major: 1 }),
  });
  await assert.rejects(
    store.version(),
    error => error instanceof StoreProtocolError
      && error.code === 'client/unsupported-version',
  );
});

test('occurrence and mutation packets decode to strict typed objects', async () => {
  const coordinate = tripleTerm(
    tripleTerm('worker-space', keywordTerm('kernel/tx-sequence'), integerTerm(1)),
    keywordTerm('kernel/op-ordinal'),
    integerTerm(0),
  );
  const proposition = tripleTerm('subject', keywordTerm('predicate'), 'object');
  const occurrencePacket = rpcPacket('rpc/occurrence', [
    coordinate,
    keywordTerm('assert'),
    proposition,
  ]);
  const occurrences = storeClient({
    space: 'worker-space',
    transport: request => successResponse(
      request,
      rpcPacket('rpc/occurrences', [rpcList([occurrencePacket])]),
    ),
  });
  assert.deepEqual((await occurrences.occurrences()).result, [{
    coordinate,
    action: 'assert',
    proposition,
  }]);

  const mutation = storeClient({
    space: 'worker-space',
    transport: request => successResponse(
      request,
      rpcPacket('rpc/mutation-result', [rpcList([
        rpcPacket('rpc/action-result', [integerTerm(0), booleanTerm(false), coordinate]),
      ])]),
    ),
  });
  assert.deepEqual((await mutation.retract('missing', 'predicate', 'object')).result, [{
    inputIndex: 0,
    stateChanged: false,
    occurrence: coordinate,
  }]);
});

test('occurrence decoding rejects malformed coordinates, actions, and propositions', async () => {
  const coordinate = tripleTerm(
    tripleTerm('worker-space', keywordTerm('kernel/tx-sequence'), integerTerm(1)),
    keywordTerm('kernel/op-ordinal'),
    integerTerm(0),
  );
  const proposition = tripleTerm('subject', keywordTerm('predicate'), 'object');
  const invalidFields = [
    [
      tripleTerm(
        tripleTerm('worker-space', keywordTerm('kernel/wrong'), integerTerm(1)),
        keywordTerm('kernel/op-ordinal'),
        integerTerm(0),
      ),
      keywordTerm('assert'),
      proposition,
    ],
    [coordinate, keywordTerm('replace'), proposition],
    [coordinate, keywordTerm('retract'), stringTerm('not-a-proposition')],
  ];

  for (const fields of invalidFields) {
    const store = storeClient({
      space: 'worker-space',
      transport: request => successResponse(
        request,
        rpcPacket('rpc/occurrences', [rpcList([rpcPacket('rpc/occurrence', fields)])]),
      ),
    });
    await assert.rejects(
      store.occurrences(),
      error => error instanceof StoreProtocolError
        && error.code === 'client/invalid-occurrence',
    );
  }
});

test('transport deadline stays bounded and distinct from query execution', async () => {
  const observed = [];
  const store = storeClient({
    space: 'worker-space',
    transport: request => {
      observed.push(request);
      return rejectedResponse(request);
    },
  });

  await expectRemoteRejection(store.version());
  await expectRemoteRejection(store.query(tripleQuery(), { timeoutMs: 5000 }));
  await expectRemoteRejection(store.query(tripleQuery(), { timeoutMs: 60000 }));
  const tightStore = storeClient({
    space: 'worker-space',
    requestTimeoutMs: 5,
    transport: request => {
      observed.push(request);
      return rejectedResponse(request);
    },
  });
  await expectRemoteRejection(tightStore.query(tripleQuery(), { timeoutMs: 0 }));

  assert.deepEqual(
    observed.map(request => request.timeoutMs),
    [60000, 60000, 61000, 1000],
  );
});

test('transport timeout and caller abort are bounded', async () => {
  const waiting = storeClient({
    space: 'worker-space',
    requestTimeoutMs: 5,
    transport: () => new Promise(() => {}),
  });
  await assert.rejects(
    waiting.version(),
    error => error instanceof StoreTransportError && /exceeded 5ms/.test(error.message),
  );

  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    waiting.status({ signal: controller.signal }),
    error => error instanceof StoreTransportError && /aborted/.test(error.message),
  );
});

test('portable codec has no Buffer dependency', () => {
  const saved = globalThis.Buffer;
  try {
    globalThis.Buffer = undefined;
    assert.deepEqual(stringTerm('portable'), ['string', 'portable']);
    assert.deepEqual(float64Term(1.5), ['float64', '3ff8000000000000']);
  } finally {
    globalThis.Buffer = saved;
  }
});
