// Zero-dependency Cloudflare Worker client for the JSON edge representation of
// Store RPC v2. Every data value is one exact tagged Term array; integers stay
// decimal strings and float identity stays IEEE-754 bits across JSON runtimes.

const MAX_JSON_BYTES = 1024 * 1024;
const I64_MIN = -(1n << 63n);
const I64_MAX = (1n << 63n) - 1n;
const U32_MAX = (1n << 32n) - 1n;
const KEYWORD = /^[A-Za-z0-9*+!_?<>=$%&.-]+(?:\/[A-Za-z0-9*+!_?<>=$%&.-]+)?$/;
const I64 = /^(?:0|-[1-9][0-9]*|[1-9][0-9]*)$/;
const FLOAT64 = /^[0-9a-f]{16}$/;

function fail(message) { throw new Error(`Store RPC JSON: ${message}`); }

function exactKeys(value, required, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  for (const key of required) if (!Object.hasOwn(value, key)) fail(`${label}.${key} is required`);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`${label}.${key} is unknown`);
}

function decimal(value, { label = 'integer', min = I64_MIN, max = I64_MAX } = {}) {
  let text;
  if (typeof value === 'bigint') text = value.toString();
  else if (typeof value === 'number' && Number.isSafeInteger(value)) text = String(value);
  else if (typeof value === 'string' && I64.test(value)) text = value;
  else fail(`${label} must be a safe integer, bigint, or canonical decimal string`);
  if (!I64.test(text)) fail(`${label} is not canonical decimal`);
  const parsed = BigInt(text);
  if (parsed < min || parsed > max) fail(`${label} is out of range`);
  return text;
}

function floatBits(value) {
  if (typeof value !== 'number') fail('float64 value must be a number');
  const bytes = new Uint8Array(8);
  new DataView(bytes.buffer).setFloat64(0, value, false);
  let bits = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  if (Number.isNaN(value)) bits = '7ff8000000000000';
  return bits;
}

function canonicalFloatBits(bits) {
  if (typeof bits !== 'string' || !FLOAT64.test(bits)) fail('float64 bits must be 16 lowercase hex digits');
  const raw = BigInt(`0x${bits}`);
  const exponent = (raw >> 52n) & 0x7ffn;
  const fraction = raw & ((1n << 52n) - 1n);
  if (exponent === 0x7ffn && fraction !== 0n && bits !== '7ff8000000000000') {
    fail('float64 NaN bits are not canonical');
  }
  return bits;
}

export const stringTerm = value => {
  if (typeof value !== 'string') fail('string Term requires a string');
  return ['string', value];
};

export const integerTerm = value => ['integer', decimal(value)];
export const float64Term = value => ['float64', floatBits(value)];

export const booleanTerm = value => {
  if (typeof value !== 'boolean') fail('boolean Term requires a boolean');
  return ['boolean', value];
};

export const keywordTerm = value => {
  if (typeof value !== 'string' || !KEYWORD.test(value)) fail('keyword Term is not canonical');
  return ['keyword', value];
};

export const instantTerm = (seconds, nanos) => {
  const ns = decimal(nanos, { label: 'instant nanoseconds', min: 0n, max: 999999999n });
  return ['instant', decimal(seconds, { label: 'instant seconds' }), ns];
};

export const tripleTerm = (t1, t2, t3) =>
  ['triple', term(t1), term(t2), term(t3)];

export function validateTerm(value, depth = 0, budget = { nodes: 0 }) {
  if (depth > 256) fail('Term exceeds the nesting limit');
  if (++budget.nodes > 65536) fail('Term exceeds the node limit');
  if (!Array.isArray(value) || typeof value[0] !== 'string') fail('Term must be a tagged array');
  const arity = n => { if (value.length !== n) fail(`${value[0]} Term has the wrong arity`); };
  switch (value[0]) {
    case 'string': arity(2); if (typeof value[1] !== 'string') fail('string Term payload must be a string'); break;
    case 'integer': arity(2); decimal(value[1]); break;
    case 'float64': arity(2); canonicalFloatBits(value[1]); break;
    case 'boolean': arity(2); if (typeof value[1] !== 'boolean') fail('boolean Term payload must be boolean'); break;
    case 'keyword': arity(2); if (typeof value[1] !== 'string' || !KEYWORD.test(value[1])) fail('keyword Term is not canonical'); break;
    case 'instant':
      arity(3);
      decimal(value[1], { label: 'instant seconds' });
      decimal(value[2], { label: 'instant nanoseconds', min: 0n, max: 999999999n });
      break;
    case 'triple':
      arity(4);
      validateTerm(value[1], depth + 1, budget);
      validateTerm(value[2], depth + 1, budget);
      validateTerm(value[3], depth + 1, budget);
      break;
    default: fail(`unknown Term tag ${JSON.stringify(value[0])}`);
  }
  return value;
}

export function term(value) {
  if (Array.isArray(value)) return validateTerm(value);
  if (typeof value === 'string') return stringTerm(value);
  if (typeof value === 'bigint') return integerTerm(value);
  if (typeof value === 'number') return Number.isSafeInteger(value) ? integerTerm(value) : float64Term(value);
  if (typeof value === 'boolean') return booleanTerm(value);
  if (value instanceof Date) {
    const millis = BigInt(value.getTime());
    const seconds = millis >= 0n ? millis / 1000n : (millis - 999n) / 1000n;
    const nanos = (millis - seconds * 1000n) * 1000000n;
    return instantTerm(seconds, nanos);
  }
  fail('value is outside Term; use an explicit typed constructor');
}

const list = values => values.reduceRight(
  (tail, value) => tripleTerm(keywordTerm('rpc/list'), value, tail),
  keywordTerm('rpc/list-end'));
const record = (tag, fields) => tripleTerm(keywordTerm(tag), list(fields), keywordTerm('rpc/record'));
const option = value => value === null || value === undefined
  ? keywordTerm('rpc/none')
  : tripleTerm(keywordTerm('rpc/some'), term(value), keywordTerm('rpc/option'));
const unit = keywordTerm('rpc/unit');

export function listValues(value) {
  validateTerm(value);
  const values = [];
  let cursor = value;
  while (!(cursor[0] === 'keyword' && cursor[1] === 'rpc/list-end')) {
    if (cursor[0] !== 'triple'
        || cursor[1][0] !== 'keyword' || cursor[1][1] !== 'rpc/list') {
      fail('RPC list is malformed');
    }
    values.push(cursor[2]);
    cursor = cursor[3];
  }
  return values;
}

export function recordFields(value, tag, count) {
  validateTerm(value);
  if (value[0] !== 'triple'
      || value[1][0] !== 'keyword' || value[1][1] !== tag
      || value[3][0] !== 'keyword' || value[3][1] !== 'rpc/record') {
    fail(`expected ${tag} RPC record`);
  }
  const fields = listValues(value[2]);
  if (fields.length !== count) fail(`${tag} RPC record has the wrong field count`);
  return fields;
}

const queryVar = name => record('query/var', [stringTerm(name)]);
const queryConst = value => record('query/const', [term(value)]);

// Build the native typed query plan for a single Triple pattern. Omitted Terms
// become variables and are returned in tuple order.
export function tripleQuery(pattern = {}) {
  exactKeys(pattern, [], ['t1', 't2', 't3'], 'triple pattern');
  const { t1, t2, t3 } = pattern;
  const supplied = [t1, t2, t3];
  const names = ['t1', 't2', 't3'];
  const variables = [];
  const args = supplied.map((value, index) => {
    if (value === null || value === undefined) {
      variables.push(names[index]);
      return queryVar(names[index]);
    }
    return queryConst(value);
  });
  const headTerms = variables.length ? variables.map(queryVar) : args;
  const head = record('query/head', [stringTerm('out'), list(headTerms)]);
  const relation = record('query/relation', [stringTerm('triple'), list(args), booleanTerm(false)]);
  const rule = record('query/rule', [head, list([relation])]);
  const stratum = record('query/stratum', [list([rule])]);
  return record('query/plan', [record('query/find-relation', [stringTerm('out')]), list([stratum])]);
}

function responsePage(value) {
  exactKeys(value, ['ordinal', 'done'], ['ordinal', 'done', 'nextCursor'], 'response.page');
  decimal(value.ordinal, { label: 'response.page.ordinal', min: 0n, max: U32_MAX });
  if (typeof value.done !== 'boolean') fail('response.page.done must be boolean');
  if (Object.hasOwn(value, 'nextCursor')) validateTerm(value.nextCursor);
}

function responseError(value) {
  exactKeys(value, ['code', 'retryable', 'message'], ['code', 'retryable', 'message', 'detail'], 'response.error');
  if (typeof value.code !== 'string' || !KEYWORD.test(value.code)) fail('response.error.code is not canonical');
  if (typeof value.retryable !== 'boolean') fail('response.error.retryable must be boolean');
  if (typeof value.message !== 'string') fail('response.error.message must be a string');
  if (Object.hasOwn(value, 'detail')) validateTerm(value.detail);
}

function validateResponse(value, space, op) {
  exactKeys(value, ['space', 'op', 'servedVersion'],
    ['space', 'op', 'servedVersion', 'page', 'error', 'payload'], 'response');
  if (value.space !== space || value.op !== op) fail('response identity does not match request');
  decimal(value.servedVersion, { label: 'response.servedVersion', min: 0n });
  if (Object.hasOwn(value, 'page')) responsePage(value.page);
  if (Object.hasOwn(value, 'error')) responseError(value.error);
  if (Object.hasOwn(value, 'payload')) validateTerm(value.payload);
  return value;
}

function policy(existing) { return keywordTerm(existing ? 'rpc/subject-existing' : 'rpc/subject-any'); }
function writePayload(proposition, opts = {}) {
  return record('rpc/write', [proposition, policy(opts.existing), option(opts.fence)]);
}
function actionPayload(action) {
  exactKeys(action, ['op'], ['op', 'proposition', 't1', 't2', 't3', 'existing'], 'batch action');
  const operation = action.op === 'retract' ? 'rpc/retract' : action.op === 'assert' ? 'rpc/assert' : null;
  if (!operation) fail("batch action op must be 'assert' or 'retract'");
  const proposition = action.proposition
    ? term(action.proposition)
    : tripleTerm(action.t1, action.t2, action.t3);
  return record('rpc/action', [keywordTerm(operation), proposition, policy(action.existing)]);
}

function scanPayload(pattern) {
  exactKeys(pattern, [], ['t1', 't2', 't3'], 'scan pattern');
  return record('rpc/triple-pattern', [
    option(pattern.t1), option(pattern.t2), option(pattern.t3),
  ]);
}

function querySnapshot(opts) {
  const hasAsOf = Object.hasOwn(opts, 'asOf');
  const hasSince = Object.hasOwn(opts, 'since');
  if (hasAsOf && hasSince) fail('query accepts asOf or since, not both');
  if (hasAsOf) return record('query/as-of', [integerTerm(opts.asOf)]);
  if (!hasSince) return keywordTerm('query/current');
  const since = typeof opts.since === 'object' && opts.since !== null
    ? opts.since : { lowerExclusive: opts.since };
  exactKeys(since, ['lowerExclusive'], ['lowerExclusive', 'upper'], 'since selector');
  const upper = !Object.hasOwn(since, 'upper') || since.upper === 'current'
    ? keywordTerm('query/current')
    : record('query/as-of', [integerTerm(since.upper)]);
  return record('query/since', [integerTerm(since.lowerExclusive), upper]);
}

export function storeClient({ url, host, port, token, space, fetch: fetchImpl } = {}) {
  if (!token) throw new Error('storeClient: token required');
  if (typeof space !== 'string' || !space.trim()) throw new Error('storeClient: space required');
  const base = (url || `http://${host || '127.0.0.1'}:${port || 8787}`).replace(/\/+$/, '');
  const doFetch = fetchImpl || fetch;

  async function send(path, op, payload, opts = {}) {
    const request = { space, op, payload: term(payload) };
    if (opts.expectedVersion !== undefined) {
      request.expectedVersion = decimal(opts.expectedVersion, { label: 'expectedVersion', min: 0n });
    }
    if (opts.page !== undefined) {
      exactKeys(opts.page, ['limit'], ['limit', 'cursor'], 'page');
      request.page = { limit: decimal(opts.page.limit, { label: 'page.limit', min: 1n, max: U32_MAX }) };
      if (opts.page.cursor !== undefined) request.page.cursor = term(opts.page.cursor);
    }
    if (opts.timeoutMs !== undefined) {
      request.timeoutMs = decimal(opts.timeoutMs, { label: 'timeoutMs', min: 0n, max: U32_MAX });
    }
    const response = await doFetch(base + path, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        accept: 'application/json',
      },
      body: JSON.stringify(request),
    });
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > MAX_JSON_BYTES) fail('response exceeds 1 MiB');
    const contentType = (response.headers?.get?.('content-type') || '').split(';', 1)[0].trim().toLowerCase();
    if (contentType !== 'application/json') {
      const error = new Error(`store shim returned ${contentType || 'no content-type'}, expected application/json`);
      error.status = response.status;
      throw error;
    }
    let decoded;
    try { decoded = JSON.parse(text); }
    catch (cause) {
      const error = new Error('store shim returned invalid JSON', { cause });
      error.status = response.status;
      throw error;
    }
    if (!response.ok) {
      const error = new Error(`store shim HTTP ${response.status}: ${decoded?.error?.message || 'request failed'}`);
      error.status = response.status;
      error.body = decoded;
      throw error;
    }
    return validateResponse(decoded, space, op);
  }

  return {
    version: opts => send('/q', 'rpc/version', unit, opts),
    status: opts => send('/q', 'rpc/status', unit, opts),
    validate: opts => send('/q', 'rpc/validate', unit, opts),
    occurrences: opts => send('/q', 'rpc/occurrences', unit, opts),
    scan: (pattern = {}, opts) => send('/q', 'rpc/scan', scanPayload(pattern), opts),
    query: (plan, opts = {}) => send('/q', 'rpc/query',
      record('query/request', [term(plan), querySnapshot(opts)]), opts),
    assert: (t1, t2, t3, opts = {}) => send('/assert', 'rpc/assert',
      writePayload(tripleTerm(t1, t2, t3), opts), opts),
    retract: (t1, t2, t3, opts = {}) => send('/assert', 'rpc/retract',
      writePayload(tripleTerm(t1, t2, t3), opts), opts),
    batch: (actions, opts = {}) => send('/assert', 'rpc/batch',
      record('rpc/batch', [list(actions.map(actionPayload)), option(opts.fence)]), opts),
    leaseAcquire: (resource, holder, ttlMs, opts) => send('/assert', 'rpc/lease-acquire',
      record('lease/acquire', [term(resource), term(holder), integerTerm(ttlMs)]), opts),
    leaseRenew: (fence, ttlMs, opts) => send('/assert', 'rpc/lease-renew',
      record('lease/renew', [term(fence), integerTerm(ttlMs)]), opts),
    leaseRelease: (fence, opts) => send('/assert', 'rpc/lease-release', term(fence), opts),
    leaseCheck: (fence, opts) => send('/q', 'rpc/lease-check', term(fence), opts),
  };
}
