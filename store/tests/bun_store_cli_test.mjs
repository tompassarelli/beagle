// SPDX-License-Identifier: MIT OR Apache-2.0
import { afterAll, beforeAll, expect, test } from 'bun:test';
import { StoreRpcError } from '../clients/bun/store-rpc-core.mjs';

const checkoutRuntime = new URL('../../beagle-lib/lib/', import.meta.url);
Bun.plugin({
  name: 'beagle-checkout-runtime-test',
  setup(build) {
    build.onResolve({ filter: /^beagle\// }, ({ path }) => ({
      path: new URL(path, checkoutRuntime).pathname,
    }));
  },
});

beforeAll(() => {
  globalThis.host_call = (bridge, operation, arguments_) =>
    bridge.call(operation, arguments_);
  globalThis.host_get = (value, key) => value?.[key];
  globalThis.host_error_field = (error, field) => String(error?.[field] ?? '');
  globalThis.host_store_rpc_error_p = error => error instanceof StoreRpcError;
});

afterAll(() => {
  delete globalThis.host_call;
  delete globalThis.host_get;
  delete globalThis.host_error_field;
  delete globalThis.host_store_rpc_error_p;
});

test('typed Store CLI parses documented EDN and renders query rows', async () => {
  const calls = [];
  const output = [];
  const bridge = {
    async call(operation, payload) {
      calls.push({ operation, payload });
      return {
        result: [[['string', 'alice'], ['string', 'alice@example.test']]],
      };
    },
    keywordTerm(spelling) { return ['keyword', spelling]; },
    integerTerm(value) { return ['integer', String(value)]; },
    integerValue(value) { return Number(value[1]); },
    fail(message) { throw new Error(message); },
    out(message) { output.push(message); },
  };
  const { run } = await import('../bin/beagle-store-cli.js');
  const query = '{:find "emails" :rules [{:head {:rel "emails" :args [{:var "who"} {:var "email"}]} :body [{:rel "triple" :args [{:var "who"} :contactable_at {:var "email"}]} {:rel "triple" :args ["$kw:literal" "$atom:true" {:var "email"}]}]}]}';

  expect(await run(bridge, ['query', query])).toBe(0);
  expect(calls).toEqual([{
    operation: 'query',
    payload: {
      find: 'emails',
      rules: [{
        head: { rel: 'emails', args: [{ var: 'who' }, { var: 'email' }] },
        body: [{
          rel: 'triple',
          args: [{ var: 'who' }, ['keyword', 'contactable_at'], { var: 'email' }],
        }, {
          rel: 'triple',
          args: ['$kw:literal', '$atom:true', { var: 'email' }],
        }],
      }],
    },
  }]);
  expect(output).toEqual(['  [alice alice@example.test]']);
});

function conflictError({ name = 'StoreRpcError', code = 'rpc/conflict', retryable = true } = {}) {
  if (name === 'StoreRpcError') {
    return new StoreRpcError({
      space: 'cli-test',
      operation: 'rpc/assert',
      servedVersion: 1n,
      error: {
        code,
        retryable,
        message: 'the Store advanced',
        detail: undefined,
      },
    });
  }
  const error = new Error('the Store advanced');
  error.name = name;
  error.code = code;
  error.retryable = retryable;
  return error;
}

function mutationBridge(call, output = []) {
  return {
    call,
    stringTerm(value) { return ['string', value]; },
    keywordTerm(value) { return ['keyword', value]; },
    booleanTerm(value) { return ['boolean', value]; },
    integerTerm(value) { return ['integer', String(value)]; },
    floatTerm(value) { return ['float64', value]; },
    tripleTerm(t1, t2, t3) { return ['triple', t1, t2, t3]; },
    instantTerm(seconds, nanos) { return ['instant', seconds, nanos]; },
    floatValue(value) { return Number(value[1]); },
    fail(message) { throw new Error(message); },
    out(message) { output.push(message); },
  };
}

test('typed Store CLI retries OCC conflicts with a fresh version and mutation', async () => {
  const calls = [];
  const output = [];
  const versions = [7n, 8n, 9n];
  let mutationAttempt = 0;
  const bridge = mutationBridge(async (operation, payload) => {
    calls.push({ operation, payload });
    if (operation === 'version') return { servedVersion: versions.shift() };
    mutationAttempt += 1;
    if (mutationAttempt < 3) throw conflictError();
    return {
      servedVersion: 10n,
      result: [{ stateChanged: true, occurrence: ['string', 'occurrence-10-0'] }],
    };
  }, output);
  const { run } = await import('../bin/beagle-store-cli.js');

  expect(await run(bridge, ['tell', 'document', ':title', '"$kw:literal"'])).toBe(0);
  expect(calls.map(call => call.operation)).toEqual([
    'version', 'assert', 'version', 'assert', 'version', 'assert',
  ]);
  const mutations = calls.filter(call => call.operation === 'assert').map(call => call.payload);
  expect(mutations.map(request => request.expectedVersion)).toEqual([7n, 8n, 9n]);
  expect(new Set(mutations).size).toBe(3);
  expect(mutations[2].t3).toEqual(['string', '$kw:literal']);
  expect(output).toEqual([
    'committed via server (v10): @document :title = $kw:literal [input 0, occurrence occurrence-10-0]',
  ]);
});

test('typed Store CLI stops after five OCC mutation attempts', async () => {
  const calls = [];
  let version = 20n;
  const bridge = mutationBridge(async (operation, payload) => {
    calls.push({ operation, payload });
    if (operation === 'version') {
      const servedVersion = version;
      version += 1n;
      return { servedVersion };
    }
    throw conflictError();
  });
  const { run } = await import('../bin/beagle-store-cli.js');

  let rejection;
  try {
    await run(bridge, ['retract', 'document', ':title', '"$atom:true"']);
  } catch (error) {
    rejection = error;
  }
  expect(rejection).toMatchObject({
    name: 'StoreRpcError',
    code: 'rpc/conflict',
    retryable: true,
  });
  const mutations = calls.filter(call => call.operation === 'retract');
  expect(mutations).toHaveLength(5);
  expect(mutations.map(call => call.payload.expectedVersion)).toEqual([20n, 21n, 22n, 23n, 24n]);
  expect(calls).toHaveLength(10);
});

test('typed Store CLI retries only typed retryable OCC conflicts', async () => {
  const rejections = [
    conflictError({ name: 'Error' }),
    conflictError({ retryable: false }),
    conflictError({ code: 'rpc/subject-not-found' }),
  ];
  const { run } = await import('../bin/beagle-store-cli.js');

  for (const rejection of rejections) {
    const calls = [];
    const bridge = mutationBridge(async (operation, payload) => {
      calls.push({ operation, payload });
      if (operation === 'version') return { servedVersion: 30n };
      throw rejection;
    });
    let observed;
    try {
      await run(bridge, ['tell', 'document', ':title', 'value']);
    } catch (error) {
      observed = error;
    }
    expect(observed).toBe(rejection);
    expect(calls.map(call => call.operation)).toEqual(['version', 'assert']);
  }
});
