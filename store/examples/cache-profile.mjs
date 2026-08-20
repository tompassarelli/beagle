// SPDX-License-Identifier: MIT OR Apache-2.0
import {
  integerValue,
  keywordTerm,
  storeClient,
} from '../clients/bun/store-rpc.mjs';

const VALUE = keywordTerm('cache/value');
const EXPIRES_AT = keywordTerm('cache/expires-at-unix-ms');
const MATERIALIZED_FROM = keywordTerm('cache/materialized-from');

function sameTerm(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function valuesFor(rows, predicate) {
  return rows
    .filter((row) => sameTerm(row[2], predicate))
    .map((row) => row[3]);
}

export function storeCache(store, {
  namespace = 'default',
  now = () => Date.now(),
} = {}) {
  const subject = (key) => `cache/${namespace}/${key}`;

  async function get(key) {
    const response = await store.scan(
      { t1: subject(key) },
      { page: { limit: 16 } },
    );
    const values = valuesFor(response.result, VALUE);
    const expiries = valuesFor(response.result, EXPIRES_AT);
    if (values.length !== 1 || expiries.length !== 1) return null;
    if (integerValue(expiries[0]) <= BigInt(now())) return null;
    return values[0];
  }

  async function put(key, value, { ttlMs, materializedFrom }) {
    if (!Number.isSafeInteger(ttlMs) || ttlMs <= 0) {
      throw new TypeError('ttlMs must be a positive safe integer');
    }
    const entry = subject(key);
    const current = await store.scan(
      { t1: entry },
      { page: { limit: 16 } },
    );
    const actions = current.result.map((triple) => ({
      op: 'retract',
      proposition: triple,
    }));
    actions.push(
      { op: 'assert', t1: entry, t2: VALUE, t3: value },
      {
        op: 'assert',
        t1: entry,
        t2: EXPIRES_AT,
        t3: BigInt(now() + ttlMs),
      },
    );
    if (materializedFrom !== undefined) {
      actions.push({
        op: 'assert',
        t1: entry,
        t2: MATERIALIZED_FROM,
        t3: materializedFrom,
      });
    }
    const preflight = store.preflightBatch(actions, {
      expectedVersion: current.servedVersion,
    });
    return store.batch(actions, {
      expectedVersion: current.servedVersion,
      preflight,
    });
  }

  async function invalidate(key) {
    const entry = subject(key);
    const current = await store.scan(
      { t1: entry },
      { page: { limit: 16 } },
    );
    if (current.result.length === 0) return current;
    const actions = current.result.map((triple) => ({
      op: 'retract',
      proposition: triple,
    }));
    const preflight = store.preflightBatch(actions, {
      expectedVersion: current.servedVersion,
    });
    return store.batch(actions, {
      expectedVersion: current.servedVersion,
      preflight,
    });
  }

  return Object.freeze({ get, put, invalidate });
}

if (import.meta.main) {
  const space = process.env.BEAGLE_STORE_SPACE_ID;
  if (!space) throw new Error('BEAGLE_STORE_SPACE_ID is required');
  const store = storeClient({
    host: process.env.BEAGLE_STORE_SERVER_CONNECT || '127.0.0.1',
    port: Number(process.env.BEAGLE_STORE_SERVER_PORT || 7977),
    space,
  });
  const cache = storeCache(store, { namespace: 'example' });
  await cache.put('greeting', 'hello', {
    ttlMs: 60_000,
    materializedFrom: 'example-input-v1',
  });
  console.log(await cache.get('greeting'));
}
