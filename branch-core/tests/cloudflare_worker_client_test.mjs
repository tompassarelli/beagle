import assert from 'node:assert/strict';
import * as client from '../deploy/cloudflare/worker-client.js';

const checks = [];
const check = (label, fn) => checks.push(Promise.resolve().then(fn)
  .then(() => console.log(`  [PASS] ${label}`)));

const responseFor = request => new Response(JSON.stringify({
  space: request.space,
  op: request.op,
  servedVersion: '12',
  payload: ['keyword', 'rpc/unit'],
}), { headers: { 'content-type': 'application/json; charset=utf-8' } });

check('all Atom tags and recursive Triples are exact and canonical', () => {
  const values = [
    client.stringTerm('Alice'),
    client.integerTerm(-42n),
    client.float64Term(1.5),
    client.float64Term(Number.NaN),
    client.booleanTerm(true),
    client.keywordTerm('kernel/type'),
    client.instantTerm(-2, 3),
    client.tripleTerm(
      'Alice',
      client.keywordTerm('contactable_at'),
      'alice@example.com',
    ),
  ];
  for (const value of values) assert.equal(client.validateTerm(value), value);
  assert.deepEqual(values[1], ['integer', '-42']);
  assert.deepEqual(values[2], ['float64', '3ff8000000000000']);
  assert.deepEqual(values[3], ['float64', '7ff8000000000000']);
  assert.equal(values[7][0], 'triple');
});

check('noncanonical typed values are rejected locally', () => {
  assert.throws(() => client.validateTerm(['integer', '01']), /canonical/);
  assert.throws(() => client.validateTerm(['float64', '7ff0000000000001']), /canonical/);
  assert.throws(() => client.validateTerm(['keyword', ':bad']), /canonical/);
  assert.throws(() => client.validateTerm(['triple', ['string', 'a']]), /arity/);
  assert.throws(() => client.integerTerm(Number.MAX_SAFE_INTEGER + 1), /safe integer/);
});

check('client requires an explicit SpaceId and closed input keys', () => {
  assert.throws(() => client.framClient({ token: 'secret' }), /space required/);
  assert.throws(() => client.tripleQuery({ unexpected: 'value' }), /unknown/);
});

check('version request is the exact JSON FRAMRPC envelope', async () => {
  let observed;
  const fram = client.framClient({
    url: 'https://shim.test/', token: 'secret', space: 'space-a',
    fetch: async (url, init) => {
      observed = { url, init, body: JSON.parse(init.body) };
      return responseFor(observed.body);
    },
  });
  const response = await fram.version({ expectedVersion: 11n });
  assert.equal(observed.url, 'https://shim.test/q');
  assert.deepEqual(observed.body, {
    space: 'space-a', op: 'rpc/version', expectedVersion: '11',
    payload: ['keyword', 'rpc/unit'],
  });
  assert.equal(observed.init.headers['content-type'], 'application/json');
  assert.equal(observed.init.headers.accept, 'application/json');
  assert.equal(response.servedVersion, '12');
});

check('assert lowers directly to a typed recursive write record', async () => {
  let request;
  const fram = client.framClient({
    token: 'secret', space: 'space-a',
    fetch: async (_url, init) => { request = JSON.parse(init.body); return responseFor(request); },
  });
  await fram.assert(client.tripleTerm('file', client.keywordTerm('page'), 1),
    client.keywordTerm('title'), 'Door Schedule', { expectedVersion: 11 });
  assert.equal(request.op, 'rpc/assert');
  assert.equal(request.expectedVersion, '11');
  const [proposition, policy, fence] = client.recordFields(request.payload, 'rpc/write', 3);
  assert.equal(proposition[0], 'triple');
  assert.deepEqual(policy, ['keyword', 'rpc/subject-any']);
  assert.deepEqual(fence, ['keyword', 'rpc/none']);
});

check('typed query plans and pagination contain no untyped JSON data', async () => {
  let request;
  const fram = client.framClient({
    token: 'secret', space: 'space-a',
    fetch: async (_url, init) => { request = JSON.parse(init.body); return responseFor(request); },
  });
  await fram.query(client.tripleQuery({ t2: client.keywordTerm('title') }),
    { asOf: 9, timeoutMs: 5000, page: { limit: 100 } });
  assert.equal(request.op, 'rpc/query');
  assert.deepEqual(request.page, { limit: '100' });
  assert.equal(request.timeoutMs, '5000');
  const [plan, snapshot] = client.recordFields(request.payload, 'query/request', 2);
  client.recordFields(plan, 'query/plan', 2);
  assert.deepEqual(client.recordFields(snapshot, 'query/as-of', 1)[0], ['integer', '9']);

  await fram.query(client.tripleQuery({ t2: client.keywordTerm('title') }),
    { since: { lowerExclusive: 9, upper: 12 } });
  const [_sincePlan, sinceSnapshot] = client.recordFields(request.payload, 'query/request', 2);
  const [lower, upper] = client.recordFields(sinceSnapshot, 'query/since', 2);
  assert.deepEqual(lower, ['integer', '9']);
  assert.deepEqual(client.recordFields(upper, 'query/as-of', 1)[0], ['integer', '12']);
});

check('the closed client exposes every public operation', async () => {
  const requests = [];
  const fram = client.framClient({
    token: 'secret', space: 'space-a',
    fetch: async (url, init) => {
      const request = JSON.parse(init.body);
      requests.push([new URL(url).pathname, request.op]);
      return responseFor(request);
    },
  });
  const fence = client.tripleTerm(client.keywordTerm('rpc/fence'), 'holder', 1);
  await fram.version(); await fram.status(); await fram.validate(); await fram.occurrences();
  await fram.scan({ t1: 'a' }); await fram.query(client.tripleQuery());
  await fram.assert('a', 'p', 'r'); await fram.retract('a', 'p', 'r');
  await fram.batch([{ op: 'assert', t1: 'a', t2: 'p', t3: 'r' }]);
  await fram.leaseAcquire('resource', 'holder', 1000);
  await fram.leaseRenew(fence, 1000); await fram.leaseRelease(fence); await fram.leaseCheck(fence);
  assert.equal(requests.length, 13);
  assert.equal(requests.filter(([path]) => path === '/q').length, 7);
  assert.equal(requests.filter(([path]) => path === '/assert').length, 6);
});

check('unknown response fields and noncanonical versions fail closed', async () => {
  const bad = client.framClient({
    token: 'secret', space: 'space-a',
    fetch: async () => new Response(JSON.stringify({
      space: 'space-a', op: 'rpc/version', servedVersion: '01', extra: true,
    }), { headers: { 'content-type': 'application/json' } }),
  });
  await assert.rejects(bad.version(), /unknown/);
});

check('shim HTTP errors stay structured JSON', async () => {
  const fram = client.framClient({
    token: 'wrong', space: 'space-a',
    fetch: async () => new Response(JSON.stringify({
      error: { code: 'shim/unauthorized', retryable: false, message: 'unauthorized' },
    }), { status: 401, headers: { 'content-type': 'application/json' } }),
  });
  await assert.rejects(fram.version(), error => error.status === 401
    && error.body.error.code === 'shim/unauthorized');
});

await Promise.all(checks);
console.log(`\ncloudflare worker client: ${checks.length}/${checks.length} PASS`);
