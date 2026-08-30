// SPDX-License-Identifier: MIT OR Apache-2.0
import { afterAll, beforeAll, expect, test } from 'bun:test';

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
});

afterAll(() => {
  delete globalThis.host_call;
  delete globalThis.host_get;
  delete globalThis.host_error_field;
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
    fail(message) { throw new Error(message); },
    out(message) { output.push(message); },
  };
  const { run } = await import('../bin/beagle-store-cli.js');
  const query = '{:find "emails" :rules [{:head {:rel "emails" :args [{:var "who"} {:var "email"}]} :body [{:rel "triple" :args [{:var "who"} :contactable_at {:var "email"}]}]}]}';

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
        }],
      }],
    },
  }]);
  expect(output).toEqual(['  [alice alice@example.test]']);
});
