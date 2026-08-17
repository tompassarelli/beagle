const MAGIC = Uint8Array.of(0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00);
const HEADER_BYTES = 26;
const MAX_BODY_BYTES = 1024 * 1024;
const MAX_FRAME_BYTES = HEADER_BYTES + MAX_BODY_BYTES;
const MAX_STRING_BYTES = 1024 * 1024;
const MAX_SPACE_BYTES = 4096;
const MAX_TERM_NODES = 65536;
const MAX_TERM_DEPTH = 256;
const MAX_PAGE_LIMIT = 4096;
const I64_MIN = -(1n << 63n);
const I64_MAX = (1n << 63n) - 1n;
const U32_MAX = (1n << 32n) - 1n;
const I64 = /^(?:0|-[1-9][0-9]*|[1-9][0-9]*)$/;
const FLOAT64 = /^[0-9a-f]{16}$/;
const OPERATIONS = new Set([
  'rpc/version', 'rpc/status', 'rpc/validate',
  'rpc/assert', 'rpc/retract', 'rpc/batch',
  'rpc/scan', 'rpc/query', 'rpc/occurrences',
  'rpc/lease-acquire', 'rpc/lease-renew', 'rpc/lease-release',
  'rpc/lease-check',
]);
const NATIVE_OPERATOR_OPERATIONS = new Set(['rpc/checkpoint']);
const PAGED_OPERATIONS = new Set(['rpc/scan', 'rpc/query', 'rpc/occurrences']);
const MUTATION_OPERATIONS = new Set([
  'rpc/assert', 'rpc/retract', 'rpc/batch',
  'rpc/lease-acquire', 'rpc/lease-renew', 'rpc/lease-release',
]);
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder('utf-8', { fatal: true });

function bytesEqual(left, right) {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function concatBytes(parts, length = parts.reduce((sum, part) => sum + part.length, 0)) {
  const joined = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

function dataView(bytes) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

export const FRAMRPC_VERSION = Object.freeze({ major: 2, minor: 0 });
export const FRAMRPC_MAX_BATCH_ACTIONS = 247;
export const FRAMRPC_MAX_FRAME_BYTES = MAX_FRAME_BYTES;

export class StoreProtocolError extends Error {
  constructor(message, code = 'client/protocol', options) {
    super(`FRAMRPC: ${message}`, options);
    this.name = 'StoreProtocolError';
    this.code = code;
  }
}

export class StoreTransportError extends Error {
  constructor(message, cause) {
    super(`FRAMRPC transport: ${message}`, cause ? { cause } : undefined);
    this.name = 'StoreTransportError';
  }
}

export class StoreRpcError extends Error {
  constructor(response) {
    super(response.error.message);
    this.name = 'StoreRpcError';
    this.code = response.error.code;
    this.retryable = response.error.retryable;
    this.detail = response.error.detail;
    this.space = response.space;
    this.operation = response.operation;
    this.servedVersion = response.servedVersion;
  }
}

function fail(message, code) {
  throw new StoreProtocolError(message, code);
}

function own(value, key) {
  return Object.hasOwn(value, key);
}

function plainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`, 'client/invalid-input');
  }
  return value;
}

function exactKeys(value, allowed, label) {
  plainObject(value, label);
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) fail(`${label}.${key} is unknown`, 'client/invalid-input');
  }
  return value;
}

function decimal(value, { label = 'integer', min = I64_MIN, max = I64_MAX } = {}) {
  let text;
  if (typeof value === 'bigint') text = value.toString();
  else if (typeof value === 'number' && Number.isSafeInteger(value)) text = String(value);
  else if (typeof value === 'string' && I64.test(value)) text = value;
  else fail(`${label} must be a safe integer, bigint, or canonical decimal string`, 'client/invalid-integer');
  if (!I64.test(text)) fail(`${label} is not canonical decimal`, 'client/invalid-integer');
  const parsed = BigInt(text);
  if (parsed < min || parsed > max) fail(`${label} is out of range`, 'client/integer-range');
  return text;
}

function integerBigInt(value, options) {
  return BigInt(decimal(value, options));
}

function strictUtf8(value, maximum, label) {
  if (typeof value !== 'string') fail(`${label} must be a string`, 'client/invalid-text');
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        fail(`${label} contains an unpaired UTF-16 surrogate`, 'client/invalid-utf8');
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      fail(`${label} contains an unpaired UTF-16 surrogate`, 'client/invalid-utf8');
    }
  }
  const bytes = textEncoder.encode(value);
  if (bytes.length > maximum) fail(`${label} exceeds the UTF-8 byte limit`, 'client/string-limit');
  return bytes;
}

function canonicalFloatBits(bits) {
  if (typeof bits !== 'string' || !FLOAT64.test(bits)) {
    fail('float64 bits must be 16 lowercase hex digits', 'client/invalid-float');
  }
  const raw = BigInt(`0x${bits}`);
  const exponent = (raw >> 52n) & 0x7ffn;
  const fraction = raw & ((1n << 52n) - 1n);
  if (exponent === 0x7ffn && fraction !== 0n && bits !== '7ff8000000000000') {
    fail('float64 NaN bits are not canonical', 'client/invalid-float');
  }
  return bits;
}

function floatBits(value) {
  if (typeof value !== 'number') fail('float64 value must be a number', 'client/invalid-float');
  if (Number.isNaN(value)) return '7ff8000000000000';
  const bytes = new Uint8Array(8);
  new DataView(bytes.buffer).setFloat64(0, value, false);
  return [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

export const stringTerm = value => {
  strictUtf8(value, MAX_STRING_BYTES, 'String atom');
  return ['string', value];
};

export const integerTerm = value => ['integer', decimal(value)];
export const float64Term = value => ['float64', floatBits(value)];

export const booleanTerm = value => {
  if (typeof value !== 'boolean') fail('boolean Term requires a boolean', 'client/invalid-term');
  return ['boolean', value];
};

export const keywordTerm = value => {
  const bytes = strictUtf8(value, MAX_STRING_BYTES, 'Keyword atom');
  if (bytes.length === 0) fail('Keyword atom spelling must be nonempty', 'client/invalid-keyword');
  return ['keyword', value];
};

export const instantTerm = (seconds, nanos) => [
  'instant',
  decimal(seconds, { label: 'instant seconds' }),
  decimal(nanos, { label: 'instant nanoseconds', min: 0n, max: 999999999n }),
];

export const tripleTerm = (t1, t2, t3) => [
  'triple', term(t1), term(t2), term(t3),
];

export function validateTerm(value, depth = 0, budget = { nodes: 0 }) {
  if (depth > MAX_TERM_DEPTH) fail('Term exceeds the nesting limit', 'client/term-depth');
  budget.maxDepth = Math.max(budget.maxDepth ?? 0, depth);
  budget.nodes += 1;
  if (budget.nodes > MAX_TERM_NODES) fail('Term exceeds the node limit', 'client/term-nodes');
  if (!Array.isArray(value) || typeof value[0] !== 'string') {
    fail('Term must be a tagged array', 'client/invalid-term');
  }
  const arity = count => {
    if (value.length !== count) fail(`${value[0]} Term has the wrong arity`, 'client/invalid-term');
  };
  switch (value[0]) {
    case 'string':
      arity(2);
      strictUtf8(value[1], MAX_STRING_BYTES, 'String atom');
      break;
    case 'integer':
      arity(2);
      decimal(value[1]);
      break;
    case 'float64':
      arity(2);
      canonicalFloatBits(value[1]);
      break;
    case 'boolean':
      arity(2);
      if (typeof value[1] !== 'boolean') fail('boolean Term payload must be boolean', 'client/invalid-term');
      break;
    case 'keyword':
      arity(2);
      keywordTerm(value[1]);
      break;
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
    default:
      fail(`unknown Term tag ${JSON.stringify(value[0])}`, 'client/invalid-term');
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
  fail('value is outside Term; use an explicit typed constructor', 'client/invalid-term');
}

export function float64Value(value) {
  validateTerm(value);
  if (value[0] !== 'float64') fail('expected a float64 Term', 'client/invalid-term');
  const bytes = new Uint8Array(8);
  for (let index = 0; index < 8; index += 1) {
    bytes[index] = Number.parseInt(value[1].slice(index * 2, index * 2 + 2), 16);
  }
  return new DataView(bytes.buffer).getFloat64(0, false);
}

export function integerValue(value) {
  validateTerm(value);
  if (value[0] !== 'integer') fail('expected an integer Term', 'client/invalid-term');
  return BigInt(value[1]);
}

function keywordName(value, label = 'value') {
  if (!Array.isArray(value) || value.length !== 2 || value[0] !== 'keyword') {
    fail(`${label} must be a Keyword Term`, 'client/invalid-record');
  }
  return value[1];
}

function stringValue(value, label = 'value') {
  if (!Array.isArray(value) || value.length !== 2 || value[0] !== 'string') {
    fail(`${label} must be a String Term`, 'client/invalid-record');
  }
  return value[1];
}

function boolValue(value, label = 'value') {
  if (!Array.isArray(value) || value.length !== 2 || value[0] !== 'boolean') {
    fail(`${label} must be a Bool Term`, 'client/invalid-record');
  }
  return value[1];
}

function intValue(value, label = 'value') {
  if (!Array.isArray(value) || value.length !== 2 || value[0] !== 'integer') {
    fail(`${label} must be an Int Term`, 'client/invalid-record');
  }
  return BigInt(value[1]);
}

function isKeyword(value, spelling) {
  return Array.isArray(value) && value.length === 2
    && value[0] === 'keyword' && value[1] === spelling;
}

function rawListValues(value) {
  const values = [];
  let cursor = value;
  while (!isKeyword(cursor, 'rpc/list-end')) {
    if (!Array.isArray(cursor) || cursor.length !== 4 || cursor[0] !== 'triple'
        || !isKeyword(cursor[1], 'rpc/list')) {
      fail('RPC list is malformed', 'client/invalid-list');
    }
    values.push(cursor[2]);
    if (values.length > MAX_TERM_NODES) fail('RPC list exceeds the node limit', 'client/invalid-list');
    cursor = cursor[3];
  }
  return values;
}

export function listValues(value) {
  validateTerm(value);
  return rawListValues(value);
}

function rawRecordFields(value, tag, count) {
  if (!Array.isArray(value) || value.length !== 4 || value[0] !== 'triple'
      || !isKeyword(value[1], tag) || !isKeyword(value[3], 'rpc/record')) {
    fail(`expected ${tag} RPC record`, 'client/invalid-record');
  }
  const fields = rawListValues(value[2]);
  if (fields.length !== count) fail(`${tag} RPC record has the wrong field count`, 'client/invalid-record');
  return fields;
}

export function recordFields(value, tag, count) {
  validateTerm(value);
  return rawRecordFields(value, tag, count);
}

function rpcList(values) {
  return values.reduceRight(
    (tail, value) => tripleTerm(keywordTerm('rpc/list'), value, tail),
    keywordTerm('rpc/list-end'),
  );
}

function rpcRecord(tag, fields) {
  return tripleTerm(keywordTerm(tag), rpcList(fields), keywordTerm('rpc/record'));
}

function rpcOption(value) {
  return value === null || value === undefined
    ? keywordTerm('rpc/none')
    : tripleTerm(keywordTerm('rpc/some'), term(value), keywordTerm('rpc/option'));
}

function optionValue(value) {
  if (isKeyword(value, 'rpc/none')) return null;
  if (Array.isArray(value) && value.length === 4 && value[0] === 'triple'
      && isKeyword(value[1], 'rpc/some') && isKeyword(value[3], 'rpc/option')) {
    return value[2];
  }
  fail('RPC option is malformed', 'client/invalid-option');
}

const unit = keywordTerm('rpc/unit');

class Writer {
  constructor() {
    this.parts = [];
    this.length = 0;
  }

  push(bytes) {
    this.parts.push(bytes);
    this.length += bytes.length;
  }

  u8(value) {
    const bytes = new Uint8Array(1);
    new DataView(bytes.buffer).setUint8(0, value);
    this.push(bytes);
  }

  u16(value) {
    const bytes = new Uint8Array(2);
    new DataView(bytes.buffer).setUint16(0, value, true);
    this.push(bytes);
  }

  u32(value) {
    const bytes = new Uint8Array(4);
    new DataView(bytes.buffer).setUint32(0, value, true);
    this.push(bytes);
  }

  i64(value) {
    const bytes = new Uint8Array(8);
    new DataView(bytes.buffer).setBigInt64(0, value, true);
    this.push(bytes);
  }

  u64(value) {
    const bytes = new Uint8Array(8);
    new DataView(bytes.buffer).setBigUint64(0, value, true);
    this.push(bytes);
  }

  finish() {
    return concatBytes(this.parts, this.length);
  }
}

function writeText(writer, value, maximum, label) {
  const bytes = strictUtf8(value, maximum, label);
  writer.u32(bytes.length);
  writer.push(bytes);
}

function writeTermUnchecked(writer, value) {
  switch (value[0]) {
    case 'string':
      writer.u8(1);
      writeText(writer, value[1], MAX_STRING_BYTES, 'String atom');
      break;
    case 'integer':
      writer.u8(2);
      writer.i64(BigInt(value[1]));
      break;
    case 'float64':
      writer.u8(3);
      writer.u64(BigInt(`0x${value[1]}`));
      break;
    case 'boolean':
      writer.u8(value[1] ? 5 : 4);
      break;
    case 'keyword':
      writer.u8(6);
      writeText(writer, value[1], MAX_STRING_BYTES, 'Keyword atom');
      break;
    case 'triple':
      writer.u8(7);
      writeTermUnchecked(writer, value[1]);
      writeTermUnchecked(writer, value[2]);
      writeTermUnchecked(writer, value[3]);
      break;
    case 'instant':
      writer.u8(8);
      writer.i64(BigInt(value[1]));
      writer.u32(Number(BigInt(value[2])));
      break;
    default:
      fail('unsupported Term', 'client/invalid-term');
  }
}

function writeTerm(writer, value, budget = { nodes: 0 }) {
  validateTerm(value, 0, budget);
  writeTermUnchecked(writer, value);
}

class Reader {
  constructor(bytes) {
    this.bytes = bytes;
    this.offset = 0;
    this.nodes = 0;
  }

  ensure(count, context) {
    if (this.offset + count > this.bytes.length) {
      fail(`frame ended inside ${context}`, 'client/truncated');
    }
  }

  u8(context) {
    this.ensure(1, context);
    const value = dataView(this.bytes).getUint8(this.offset);
    this.offset += 1;
    return value;
  }

  u32(context) {
    this.ensure(4, context);
    const value = dataView(this.bytes).getUint32(this.offset, true);
    this.offset += 4;
    return value;
  }

  i64(context) {
    this.ensure(8, context);
    const value = dataView(this.bytes).getBigInt64(this.offset, true);
    this.offset += 8;
    return value;
  }

  u64(context) {
    this.ensure(8, context);
    const value = dataView(this.bytes).getBigUint64(this.offset, true);
    this.offset += 8;
    return value;
  }

  presence(context) {
    const value = this.u8(context);
    if (value !== 0 && value !== 1) fail(`${context} must be 0 or 1`, 'client/invalid-presence');
    return value === 1;
  }

  bool(context) {
    const value = this.u8(context);
    if (value !== 0 && value !== 1) fail(`${context} must be 0 or 1`, 'client/invalid-boolean');
    return value === 1;
  }

  text(maximum, context) {
    const length = this.u32(`${context} length`);
    if (length > maximum) fail(`${context} exceeds the UTF-8 byte limit`, 'client/string-limit');
    this.ensure(length, context);
    const bytes = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    try {
      return textDecoder.decode(bytes);
    } catch (cause) {
      throw new StoreProtocolError(`${context} is not valid UTF-8`, 'client/invalid-utf8', { cause });
    }
  }

  term(depth = 0) {
    if (depth > MAX_TERM_DEPTH) fail('Term exceeds the nesting limit', 'client/term-depth');
    this.nodes += 1;
    if (this.nodes > MAX_TERM_NODES) fail('Term exceeds the node limit', 'client/term-nodes');
    const tag = this.u8('Term tag');
    switch (tag) {
      case 1:
        return ['string', this.text(MAX_STRING_BYTES, 'String atom')];
      case 2:
        return ['integer', this.i64('Int atom').toString()];
      case 3: {
        const bits = this.u64('Float atom').toString(16).padStart(16, '0');
        return ['float64', Number.isNaN(float64Value(['float64', bits]))
          ? '7ff8000000000000' : bits];
      }
      case 4:
        return ['boolean', false];
      case 5:
        return ['boolean', true];
      case 6: {
        const spelling = this.text(MAX_STRING_BYTES, 'Keyword atom');
        if (!spelling) fail('Keyword atom spelling must be nonempty', 'client/invalid-keyword');
        return ['keyword', spelling];
      }
      case 7:
        return ['triple', this.term(depth + 1), this.term(depth + 1), this.term(depth + 1)];
      case 8: {
        const seconds = this.i64('Instant seconds');
        const nanos = this.u32('Instant nanos');
        if (nanos >= 1000000000) fail('Instant nanoseconds are outside the canonical range', 'client/invalid-instant');
        return ['instant', seconds.toString(), String(nanos)];
      }
      default:
        fail(`unknown Term tag ${tag}`, 'client/bad-term-tag');
    }
  }

  done() {
    return this.offset === this.bytes.length;
  }
}

function writePresence(writer, value) {
  writer.u8(value === null || value === undefined ? 0 : 1);
}

function pageRequest(value) {
  const page = plainObject(value, 'page');
  if (!own(page, 'limit')) fail('page.limit is required', 'client/invalid-page');
  for (const key of Object.keys(page)) {
    if (key !== 'limit' && key !== 'cursor') fail(`page.${key} is unknown`, 'client/invalid-page');
  }
  const limit = integerBigInt(page.limit, { label: 'page.limit', min: 1n, max: BigInt(MAX_PAGE_LIMIT) });
  return { limit: Number(limit), cursor: own(page, 'cursor') ? term(page.cursor) : null };
}

function requestControls(operation, options) {
  const opts = options || {};
  plainObject(opts, 'request options');
  const expectedVersion = own(opts, 'expectedVersion')
    ? integerBigInt(opts.expectedVersion, { label: 'expectedVersion', min: 0n }) : null;
  const page = own(opts, 'page') ? pageRequest(opts.page) : null;
  const timeoutMs = own(opts, 'timeoutMs')
    ? Number(integerBigInt(opts.timeoutMs, { label: 'timeoutMs', min: 0n, max: U32_MAX })) : null;
  if (page && !PAGED_OPERATIONS.has(operation)) {
    fail(`${operation} does not accept pagination`, 'client/unexpected-page');
  }
  if (timeoutMs !== null && operation !== 'rpc/query') {
    fail(`${operation} does not accept timeoutMs`, 'client/unexpected-timeout');
  }
  return { expectedVersion, page, timeoutMs };
}

function encodeRequest(requestId, space, operation, payload, options, operations = OPERATIONS) {
  if (typeof space !== 'string' || !space) fail('space must be a nonempty string', 'client/invalid-space');
  strictUtf8(space, MAX_SPACE_BYTES, 'SpaceId');
  if (!operations.has(operation)) fail(`${operation} is outside this FRAMRPC surface`, 'client/unsupported-operation');
  const controls = requestControls(operation, options);
  const body = new Writer();
  const budget = { nodes: 0, maxDepth: 0 };
  writeTerm(body, stringTerm(space), budget);
  writeTerm(body, keywordTerm(operation), budget);
  writePresence(body, controls.expectedVersion);
  if (controls.expectedVersion !== null) body.i64(controls.expectedVersion);
  writePresence(body, controls.page);
  if (controls.page) {
    body.u32(controls.page.limit);
    writePresence(body, controls.page.cursor);
    if (controls.page.cursor) writeTerm(body, controls.page.cursor, budget);
  }
  writePresence(body, controls.timeoutMs);
  if (controls.timeoutMs !== null) body.u32(controls.timeoutMs);
  writeTerm(body, term(payload), budget);
  if (body.length > MAX_BODY_BYTES) fail('request body exceeds 1 MiB', 'client/frame-too-large');

  const header = new Writer();
  header.push(MAGIC);
  header.u16(FRAMRPC_VERSION.major);
  header.u16(FRAMRPC_VERSION.minor);
  header.u8(1);
  header.u8(0);
  header.u32(body.length);
  header.i64(requestId);
  header.push(body.finish());
  return {
    frame: header.finish(),
    bodyBytes: body.length,
    termCount: budget.nodes,
    maxTermDepth: budget.maxDepth,
  };
}

function batchPreflight(encoded, actionCount) {
  return Object.freeze({
    actionCount,
    requestBytes: encoded.frame.length,
    bodyBytes: encoded.bodyBytes,
    termCount: encoded.termCount,
    maxTermDepth: encoded.maxTermDepth,
  });
}

const BATCH_PREFLIGHT_FIELDS = Object.freeze([
  'actionCount',
  'requestBytes',
  'bodyBytes',
  'termCount',
  'maxTermDepth',
]);

function expectedBatchPreflight(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail('batch preflight must be an object', 'client/preflight-mismatch');
  }
  const keys = Object.keys(value);
  if (keys.length !== BATCH_PREFLIGHT_FIELDS.length
      || keys.some(key => !BATCH_PREFLIGHT_FIELDS.includes(key))) {
    fail('batch preflight fields do not match the public contract', 'client/preflight-mismatch');
  }
  for (const field of BATCH_PREFLIGHT_FIELDS) {
    if (!Number.isSafeInteger(value[field]) || value[field] < 0) {
      fail(`batch preflight.${field} must be a nonnegative safe integer`, 'client/preflight-mismatch');
    }
  }
  return value;
}

function requireMatchingPreflight(expected, actual) {
  const supplied = expectedBatchPreflight(expected);
  for (const field of BATCH_PREFLIGHT_FIELDS) {
    if (supplied[field] !== actual[field]) {
      fail(
        `batch preflight ${field} changed from ${supplied[field]} to ${actual[field]}`,
        'client/preflight-mismatch',
      );
    }
  }
}

function responsePage(reader) {
  const ordinal = reader.u32('page ordinal');
  const nextCursor = reader.presence('next cursor presence') ? reader.term() : null;
  const done = reader.bool('page done');
  return { ordinal, nextCursor, done };
}

function responseError(reader) {
  const code = keywordName(reader.term(), 'error code');
  const retryable = reader.bool('error retryable');
  const message = stringValue(reader.term(), 'error message');
  const detail = reader.presence('error detail presence') ? reader.term() : null;
  return { code, retryable, message, detail };
}

function decodeResponseFrame(frame, expected) {
  if (!(frame instanceof Uint8Array)) {
    fail('response frame must be a Uint8Array', 'client/invalid-frame');
  }
  if (frame.length < HEADER_BYTES) fail('response ended inside its header', 'client/truncated');
  if (frame.length > MAX_FRAME_BYTES) fail('response exceeds the frame limit', 'client/frame-too-large');
  if (!bytesEqual(frame.subarray(0, MAGIC.length), MAGIC)) {
    fail('response magic does not match', 'client/invalid-magic');
  }
  const view = dataView(frame);
  const major = view.getUint16(8, true);
  const minor = view.getUint16(10, true);
  const kind = view.getUint8(12);
  const flags = view.getUint8(13);
  const bodyLength = view.getUint32(14, true);
  const requestId = view.getBigInt64(18, true);
  if (major !== FRAMRPC_VERSION.major || minor !== FRAMRPC_VERSION.minor) {
    fail('response protocol version is unsupported', 'client/unsupported-version');
  }
  if (kind !== 2) fail('request expected a response frame', 'client/invalid-kind');
  if (flags !== 0) fail('response flags must be zero', 'client/invalid-flags');
  if (bodyLength > MAX_BODY_BYTES) fail('response body exceeds 1 MiB', 'client/frame-too-large');
  if (frame.length !== HEADER_BYTES + bodyLength) fail('response body length is inconsistent', 'client/truncated');
  if (requestId !== expected.requestId) fail('response request id does not match', 'client/identity-mismatch');

  const reader = new Reader(frame.subarray(HEADER_BYTES));
  const space = stringValue(reader.term(), 'response space');
  const operation = keywordName(reader.term(), 'response operation');
  const servedVersion = reader.i64('served version');
  const page = reader.presence('response page presence') ? responsePage(reader) : null;
  const error = reader.presence('response error presence') ? responseError(reader) : null;
  const payload = reader.presence('response payload presence') ? reader.term() : null;
  if (!reader.done()) fail('response body has trailing bytes', 'client/trailing-bytes');
  if (space !== expected.space || operation !== expected.operation) {
    fail('response identity does not match the request', 'client/identity-mismatch');
  }
  return { space, operation, servedVersion, page, error, payload };
}

export function storeRpcDeclaredFrameBytes(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    fail('frame must be a Uint8Array', 'client/invalid-frame');
  }
  if (bytes.length < HEADER_BYTES) return null;
  if (!bytesEqual(bytes.subarray(0, MAGIC.length), MAGIC)) {
    fail('response magic does not match', 'client/invalid-magic');
  }
  const bodyLength = dataView(bytes).getUint32(14, true);
  if (bodyLength > MAX_BODY_BYTES) fail('response body exceeds 1 MiB', 'client/frame-too-large');
  return HEADER_BYTES + bodyLength;
}

function queryName(value, label) {
  if (typeof value !== 'string' || !value) fail(`${label} must be a nonempty string`, 'client/query-syntax');
  return value;
}

function queryOperation(value, label) {
  const name = queryName(value, label);
  return name.startsWith(':') ? name.slice(1) : name;
}

function required(value, key, label = 'query') {
  plainObject(value, label);
  if (!own(value, key)) fail(`${label}.${key} is required`, 'client/query-syntax');
  return value[key];
}

function queryTerm(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)
      && Object.keys(value).length === 1 && own(value, 'var')) {
    return rpcRecord('query/var', [stringTerm(queryName(value.var, 'query variable'))]);
  }
  return rpcRecord('query/const', [term(value)]);
}

function queryHead(value) {
  return rpcRecord('query/head', [
    stringTerm(queryName(required(value, 'rel', 'query head'), 'query relation')),
    rpcList(required(value, 'args', 'query head').map(queryTerm)),
  ]);
}

function queryClause(value) {
  plainObject(value, 'query clause');
  if (own(value, 'rel')) {
    exactKeys(value, ['rel', 'args', 'neg'], 'query relation clause');
    const negated = Boolean(value.neg);
    return rpcRecord('query/relation', [
      stringTerm(queryName(value.rel, 'query relation')),
      rpcList(required(value, 'args', 'query clause').map(queryTerm)),
      booleanTerm(negated),
    ]);
  }
  if (own(value, 'pred')) {
    const args = required(value, 'args', 'query predicate');
    if (!Array.isArray(args) || args.length !== 2) {
      fail('query predicate requires exactly two arguments', 'client/query-syntax');
    }
    return rpcRecord('query/predicate', [
      keywordTerm(queryOperation(value.pred, 'query predicate')),
      queryTerm(args[0]), queryTerm(args[1]),
    ]);
  }
  if (own(value, 'fn')) {
    return rpcRecord('query/function', [
      keywordTerm(queryOperation(value.fn, 'query function')),
      rpcList(required(value, 'args', 'query function').map(queryTerm)),
      stringTerm(queryName(required(value, 'bind', 'query function'), 'query binding')),
    ]);
  }
  fail('query clause must be relation, predicate, or function', 'client/query-syntax');
}

function queryRule(value) {
  return rpcRecord('query/rule', [
    queryHead(required(value, 'head', 'query rule')),
    rpcList(required(value, 'body', 'query rule').map(queryClause)),
  ]);
}

function queryFind(value) {
  if (typeof value === 'string') {
    return rpcRecord('query/find-relation', [stringTerm(queryName(value, 'find relation'))]);
  }
  plainObject(value, 'aggregate find');
  const grouping = (value.group || []).map(index => integerTerm(index));
  const aggregates = required(value, 'agg', 'aggregate find').map(aggregate => {
    plainObject(aggregate, 'aggregate');
    return rpcRecord('query/aggregate', [
      keywordTerm(queryOperation(required(aggregate, 'op', 'aggregate'), 'aggregate operation')),
      rpcOption(own(aggregate, 'arg') ? integerTerm(aggregate.arg) : null),
    ]);
  });
  const having = (value.having || []).map(clause => {
    plainObject(clause, 'having clause');
    return rpcRecord('query/having', [
      keywordTerm(queryOperation(required(clause, 'op', 'having clause'), 'having comparison')),
      integerTerm(required(clause, 'agg', 'having clause')),
      term(required(clause, 'val', 'having clause')),
    ]);
  });
  return rpcRecord('query/find-aggregate', [
    stringTerm(queryName(required(value, 'rel', 'aggregate find'), 'aggregate relation')),
    rpcList(grouping), rpcList(aggregates), rpcList(having),
  ]);
}

export function lowerQueryPlan(value) {
  plainObject(value, 'query');
  const hasRules = own(value, 'rules');
  const hasStrata = own(value, 'strata');
  if (hasRules === hasStrata) fail('query requires exactly one of rules or strata', 'client/query-syntax');
  const strata = hasRules ? [value.rules] : value.strata;
  if (!Array.isArray(strata) || !strata.every(Array.isArray)) {
    fail('query strata must be arrays of rules', 'client/query-syntax');
  }
  const orderBy = own(value, 'orderBy') ? value.orderBy : [];
  if (!Array.isArray(orderBy)) fail('query.orderBy must be an array', 'client/query-syntax');
  const order = orderBy.map(clause => {
    exactKeys(clause, ['column', 'direction'], 'query order clause');
    const column = integerBigInt(required(clause, 'column', 'query order clause'), {
      label: 'query order column', min: 0n,
    });
    const direction = required(clause, 'direction', 'query order clause');
    if (direction !== 'asc' && direction !== 'desc') {
      fail('query order direction must be asc or desc', 'client/query-syntax');
    }
    return rpcRecord('query/order', [integerTerm(column), keywordTerm(direction)]);
  });
  const limit = own(value, 'limit')
    ? integerBigInt(value.limit, { label: 'query limit', min: 1n, max: 100000n })
    : null;
  return rpcRecord('query/plan', [
    queryFind(required(value, 'find')),
    rpcList(strata.map(rules => rpcRecord('query/stratum', [rpcList(rules.map(queryRule))]))),
    rpcList(order),
    rpcOption(limit),
  ]);
}

export function tripleQuery(pattern = {}) {
  exactKeys(pattern, ['t1', 't2', 't3'], 'triple pattern');
  const { t1, t2, t3 } = pattern;
  const supplied = [t1, t2, t3];
  const names = ['t1', 't2', 't3'];
  const variables = [];
  const args = supplied.map((value, index) => {
    if (value === null || value === undefined) {
      variables.push(names[index]);
      return rpcRecord('query/var', [stringTerm(names[index])]);
    }
    return rpcRecord('query/const', [term(value)]);
  });
  const headTerms = variables.length
    ? variables.map(name => rpcRecord('query/var', [stringTerm(name)])) : args;
  const head = rpcRecord('query/head', [stringTerm('out'), rpcList(headTerms)]);
  const relation = rpcRecord('query/relation', [stringTerm('triple'), rpcList(args), booleanTerm(false)]);
  const rule = rpcRecord('query/rule', [head, rpcList([relation])]);
  const stratum = rpcRecord('query/stratum', [rpcList([rule])]);
  return rpcRecord('query/plan', [
    rpcRecord('query/find-relation', [stringTerm('out')]),
    rpcList([stratum]),
    rpcList([]),
    rpcOption(null),
  ]);
}

function querySnapshot(options) {
  const hasAsOf = own(options, 'asOf');
  const hasSince = own(options, 'since');
  if (hasAsOf && hasSince) fail('query accepts asOf or since, not both', 'client/query-syntax');
  if (hasAsOf) return rpcRecord('query/as-of', [integerTerm(options.asOf)]);
  if (!hasSince) return keywordTerm('query/current');
  const since = typeof options.since === 'object' && options.since !== null
    ? options.since : { lowerExclusive: options.since };
  const lower = required(since, 'lowerExclusive', 'since selector');
  const upper = !own(since, 'upper') || since.upper === 'current'
    ? keywordTerm('query/current')
    : rpcRecord('query/as-of', [integerTerm(since.upper)]);
  return rpcRecord('query/since', [integerTerm(lower), upper]);
}

function policy(existing) {
  return keywordTerm(existing ? 'rpc/subject-existing' : 'rpc/subject-any');
}

function writePayload(proposition, options) {
  return rpcRecord('rpc/write', [proposition, policy(options.existing), rpcOption(options.fence)]);
}

function actionPayload(action) {
  exactKeys(action, ['op', 'proposition', 't1', 't2', 't3', 'existing'], 'batch action');
  const operation = action.op === 'assert' ? 'rpc/assert'
    : action.op === 'retract' ? 'rpc/retract' : null;
  if (!operation) fail("batch action op must be 'assert' or 'retract'", 'client/invalid-action');
  const proposition = own(action, 'proposition')
    ? term(action.proposition)
    : tripleTerm(action.t1, action.t2, action.t3);
  if (proposition[0] !== 'triple') fail('batch proposition must be a Triple', 'client/invalid-action');
  return rpcRecord('rpc/action', [keywordTerm(operation), proposition, policy(action.existing)]);
}

function instantValue(value, label) {
  if (!Array.isArray(value) || value.length !== 3 || value[0] !== 'instant') {
    fail(`${label} must be an Instant Term`, 'client/invalid-record');
  }
  return { epochSeconds: BigInt(value[1]), nanos: Number(value[2]) };
}

function transactionCoordinate(value, label) {
  if (!Array.isArray(value) || value.length !== 4 || value[0] !== 'triple') {
    fail(`${label} must be a transaction-coordinate Triple`, 'client/invalid-occurrence');
  }
  const space = stringValue(value[1], `${label} space`);
  if (!space) fail(`${label} space must be nonempty`, 'client/invalid-occurrence');
  if (!isKeyword(value[2], 'kernel/tx-sequence')) {
    fail(`${label} predicate must be kernel/tx-sequence`, 'client/invalid-occurrence');
  }
  const sequence = intValue(value[3], `${label} sequence`);
  if (sequence < 0n) fail(`${label} sequence must be nonnegative`, 'client/invalid-occurrence');
  return value;
}

function occurrenceCoordinate(value, label = 'occurrence coordinate') {
  if (!Array.isArray(value) || value.length !== 4 || value[0] !== 'triple') {
    fail(`${label} must be an occurrence-coordinate Triple`, 'client/invalid-occurrence');
  }
  transactionCoordinate(value[1], `${label} transaction`);
  if (!isKeyword(value[2], 'kernel/op-ordinal')) {
    fail(`${label} predicate must be kernel/op-ordinal`, 'client/invalid-occurrence');
  }
  const ordinal = intValue(value[3], `${label} ordinal`);
  if (ordinal < 0n) fail(`${label} ordinal must be nonnegative`, 'client/invalid-occurrence');
  return value;
}

function occurrenceResult(value) {
  const [coordinate, actionTerm, proposition] = rawRecordFields(value, 'rpc/occurrence', 3);
  occurrenceCoordinate(coordinate);
  const action = keywordName(actionTerm, 'occurrence action');
  if (action !== 'assert' && action !== 'retract') {
    fail('occurrence action must be assert or retract', 'client/invalid-occurrence');
  }
  if (!Array.isArray(proposition) || proposition.length !== 4 || proposition[0] !== 'triple') {
    fail('occurrence proposition must be a Triple Term', 'client/invalid-occurrence');
  }
  return { coordinate, action, proposition };
}

function mutationResult(payload) {
  const [results] = rawRecordFields(payload, 'rpc/mutation-result', 1);
  return rawListValues(results).map(value => {
    const [inputIndex, stateChanged, occurrence] = rawRecordFields(value, 'rpc/action-result', 3);
    const index = intValue(inputIndex, 'action input index');
    if (index < 0n || index > BigInt(Number.MAX_SAFE_INTEGER)) {
      fail('action input index is outside the safe nonnegative range', 'client/integer-range');
    }
    return {
      inputIndex: Number(index),
      stateChanged: boolValue(stateChanged, 'action state changed'),
      occurrence: occurrenceCoordinate(occurrence, 'action occurrence coordinate'),
    };
  });
}

function queryRows(payload) {
  const [rows] = rawRecordFields(payload, 'query/rows', 1);
  return rawListValues(rows).map(row => {
    const [values] = rawRecordFields(row, 'query/row', 1);
    return rawListValues(values);
  });
}

function statusResult(payload) {
  const [state, liveCount, engine, cache] = rawRecordFields(payload, 'rpc/status', 4);
  const [hits, misses, bytes, evictions] = rawRecordFields(cache, 'rpc/result-cache', 4);
  return {
    state: keywordName(state, 'status state'),
    liveCount: intValue(liveCount, 'status live count'),
    engine: keywordName(engine, 'status engine'),
    cache: {
      hits: intValue(hits, 'cache hits'),
      misses: intValue(misses, 'cache misses'),
      bytes: intValue(bytes, 'cache bytes'),
      evictions: intValue(evictions, 'cache evictions'),
    },
  };
}

function validationResult(payload) {
  const [valid, violations] = rawRecordFields(payload, 'rpc/validation', 2);
  return {
    valid: boolValue(valid, 'validation valid'),
    violations: rawListValues(violations).map(value => {
      const [code, detail] = rawRecordFields(value, 'rpc/violation', 2);
      return { code: keywordName(code, 'violation code'), detail };
    }),
  };
}

function operationResult(operation, payload) {
  if (payload === null) return null;
  switch (operation) {
    case 'rpc/version':
      if (!isKeyword(payload, 'rpc/unit')) fail('version payload is not rpc/unit', 'client/invalid-record');
      return null;
    case 'rpc/status':
      return statusResult(payload);
    case 'rpc/validate':
      return validationResult(payload);
    case 'rpc/assert':
    case 'rpc/retract':
    case 'rpc/batch':
      return mutationResult(payload);
    case 'rpc/scan': {
      const [triples] = rawRecordFields(payload, 'rpc/triples', 1);
      return rawListValues(triples);
    }
    case 'rpc/query':
      return queryRows(payload);
    case 'rpc/occurrences': {
      const [occurrences] = rawRecordFields(payload, 'rpc/occurrences', 1);
      return rawListValues(occurrences).map(occurrenceResult);
    }
    case 'rpc/lease-acquire':
    case 'rpc/lease-renew': {
      const [fence, expires] = rawRecordFields(payload, 'lease/grant', 2);
      return { fence, expires: instantValue(expires, 'lease expiry') };
    }
    case 'rpc/lease-release': {
      const [released] = rawRecordFields(payload, 'lease/released', 1);
      return { released: boolValue(released, 'lease released') };
    }
    case 'rpc/lease-check': {
      const [valid, expires] = rawRecordFields(payload, 'lease/check', 2);
      const expiry = optionValue(expires);
      return {
        valid: boolValue(valid, 'lease valid'),
        expires: expiry === null ? null : instantValue(expiry, 'lease expiry'),
      };
    }
    default:
      fail(`${operation} has no response decoder`, 'client/unsupported-operation');
  }
}

function publicResponse(response) {
  if (response.error) throw new StoreRpcError(response);
  return {
    space: response.space,
    operation: response.operation,
    servedVersion: response.servedVersion,
    page: response.page,
    result: operationResult(response.operation, response.payload),
    payload: response.payload,
  };
}

function checkpointResult(response) {
  if (response.error) throw new StoreRpcError(response);
  if (response.page !== null || response.payload === null) {
    fail('checkpoint response has an invalid envelope', 'client/invalid-record');
  }
  const fields = rawRecordFields(response.payload, 'rpc/checkpoint', 5);
  const values = fields.map((value, index) => intValue(value, `checkpoint field ${index}`));
  if (values.some(value => value < 0n)) {
    fail('checkpoint fields must be nonnegative', 'client/invalid-record');
  }
  if (values[0] !== response.servedVersion) {
    fail('checkpoint payload version disagrees with its envelope', 'client/invalid-record');
  }
  if (values[3] > U32_MAX) {
    fail('checkpoint snapshot CRC32 is outside u32', 'client/invalid-record');
  }
  return Object.freeze({
    space: response.space,
    operation: response.operation,
    servedVersion: response.servedVersion,
    watermarkBytes: values[1],
    createdAtUnixMs: values[2],
    snapshotCrc32: values[3],
    snapshotBytes: values[4],
  });
}

function operationEntry(operation, options) {
  if (operation === 'rpc/checkpoint' || MUTATION_OPERATIONS.has(operation)) {
    return 'transact';
  }
  if (operation === 'rpc/occurrences'
      || (operation === 'rpc/query' && (own(options, 'asOf') || own(options, 'since')))) {
    return 'snapshot';
  }
  return 'query';
}

async function exchangeWithTransport({
  transport, frame, expected, entry, timeoutMs, signal,
}) {
  if (signal !== undefined
      && (!signal || typeof signal !== 'object'
          || typeof signal.aborted !== 'boolean'
          || typeof signal.addEventListener !== 'function'
          || typeof signal.removeEventListener !== 'function')) {
    fail('signal must be an AbortSignal', 'client/invalid-signal');
  }
  if (signal?.aborted) throw new StoreTransportError('request aborted');

  const controller = new globalThis.AbortController();
  let rejectControl;
  let timeout;
  const control = new Promise((_, reject) => { rejectControl = reject; });
  const abort = () => {
    const error = new StoreTransportError('request aborted');
    rejectControl(error);
    controller.abort(error);
  };
  signal?.addEventListener('abort', abort, { once: true });
  timeout = setTimeout(() => {
    const error = new StoreTransportError(`request exceeded ${timeoutMs}ms`);
    rejectControl(error);
    controller.abort(error);
  }, timeoutMs);

  const request = Object.freeze({
    frame,
    entry,
    operation: expected.operation,
    space: expected.space,
    requestId: expected.requestId,
    timeoutMs,
    signal: controller.signal,
  });
  try {
    const response = await Promise.race([
      Promise.resolve().then(() => transport(request)),
      control,
    ]);
    return decodeResponseFrame(response, expected);
  } catch (error) {
    if (error instanceof StoreTransportError || error instanceof StoreProtocolError) {
      throw error;
    }
    throw new StoreTransportError(error?.message ?? String(error), error);
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener('abort', abort);
  }
}

// Operator-only fixed capability. It is deliberately absent from storeClient,
// cannot select another operation, and leaves the thirteen-operation data
// surface closed. A host may use the returned watermark as a backup cutoff.
export async function storeTransportCheckpoint({
  transport, space, requestTimeoutMs = 15000,
} = {}) {
  if (typeof transport !== 'function') {
    fail('transport must be a function', 'client/invalid-transport');
  }
  if (typeof space !== 'string' || !space) fail('space must be a nonempty string', 'client/invalid-space');
  strictUtf8(space, MAX_SPACE_BYTES, 'SpaceId');
  if (!Number.isSafeInteger(requestTimeoutMs) || requestTimeoutMs < 1) {
    fail('requestTimeoutMs must be a positive safe integer', 'client/invalid-timeout');
  }
  const operation = 'rpc/checkpoint';
  const requestId = 1n;
  const encoded = encodeRequest(
    requestId,
    space,
    operation,
    unit,
    {},
    NATIVE_OPERATOR_OPERATIONS,
  );
  const response = await exchangeWithTransport({
    transport,
    frame: encoded.frame,
    expected: { requestId, space, operation },
    entry: 'transact',
    timeoutMs: requestTimeoutMs,
  });
  return checkpointResult(response);
}

function prepareBatch(actions, options, allowPreflight) {
  if (!Array.isArray(actions) || actions.length === 0) {
    fail('batch requires at least one action', 'client/invalid-action');
  }
  if (actions.length > FRAMRPC_MAX_BATCH_ACTIONS) {
    fail(
      `batch accepts at most ${FRAMRPC_MAX_BATCH_ACTIONS} actions`,
      'client/action-limit',
    );
  }
  exactKeys(
    options,
    allowPreflight
      ? ['expectedVersion', 'signal', 'fence', 'preflight']
      : ['expectedVersion', 'signal', 'fence'],
    'batch options',
  );
  const requestOptions = {};
  if (own(options, 'expectedVersion')) requestOptions.expectedVersion = options.expectedVersion;
  if (own(options, 'signal')) requestOptions.signal = options.signal;
  return {
    actionCount: actions.length,
    payload: rpcRecord('rpc/batch', [
      rpcList(actions.map(actionPayload)), rpcOption(options.fence),
    ]),
    requestOptions,
    preflight: allowPreflight && own(options, 'preflight')
      ? options.preflight
      : null,
  };
}

export function storeClient({
  transport, space,
  requestTimeoutMs = 15000,
} = {}) {
  if (typeof transport !== 'function') {
    fail('transport must be a function', 'client/invalid-transport');
  }
  if (typeof space !== 'string' || !space) fail('space must be a nonempty string', 'client/invalid-space');
  strictUtf8(space, MAX_SPACE_BYTES, 'SpaceId');
  if (!Number.isSafeInteger(requestTimeoutMs) || requestTimeoutMs < 1) {
    fail('requestTimeoutMs must be a positive safe integer', 'client/invalid-timeout');
  }
  let nextRequestId = 1n;

  async function call(
    operation,
    payload,
    options = {},
    preflight = null,
    actionCount = 0,
  ) {
    const requestId = nextRequestId;
    nextRequestId = nextRequestId === I64_MAX ? 1n : nextRequestId + 1n;
    const encoded = encodeRequest(requestId, space, operation, payload, options);
    if (preflight !== null) {
      requireMatchingPreflight(preflight, batchPreflight(encoded, actionCount));
    }
    const queryTimeout = own(options, 'timeoutMs') ? Number(options.timeoutMs) + 1000 : 0;
    const response = await exchangeWithTransport({
      transport,
      frame: encoded.frame,
      expected: { requestId, space, operation },
      entry: operationEntry(operation, options),
      timeoutMs: Math.max(requestTimeoutMs, queryTimeout),
      signal: options.signal,
    });
    return publicResponse(response);
  }

  return Object.freeze({
    version: options => call('rpc/version', unit, options),
    status: options => call('rpc/status', unit, options),
    validate: options => call('rpc/validate', unit, options),
    occurrences: options => call('rpc/occurrences', unit, options),
    scan: (pattern = {}, options = {}) => {
      exactKeys(pattern, ['t1', 't2', 't3'], 'scan pattern');
      return call('rpc/scan', rpcRecord('rpc/triple-pattern', [
        rpcOption(pattern.t1),
        rpcOption(pattern.t2),
        rpcOption(pattern.t3),
      ]), options);
    },
    query: (query, options = {}) => {
      const plan = Array.isArray(query) ? term(query) : lowerQueryPlan(query);
      rawRecordFields(plan, 'query/plan', 4);
      return call('rpc/query', rpcRecord('query/request', [plan, querySnapshot(options)]), options);
    },
    assert: (t1, t2, t3, options = {}) => call(
      'rpc/assert', writePayload(tripleTerm(t1, t2, t3), options), options,
    ),
    retract: (t1, t2, t3, options = {}) => call(
      'rpc/retract', writePayload(tripleTerm(t1, t2, t3), options), options,
    ),
    preflightBatch: (actions, options = {}) => {
      const prepared = prepareBatch(actions, options, false);
      const encoded = encodeRequest(
        0n,
        space,
        'rpc/batch',
        prepared.payload,
        prepared.requestOptions,
      );
      return batchPreflight(encoded, prepared.actionCount);
    },
    batch: (actions, options = {}) => {
      const prepared = prepareBatch(actions, options, true);
      return call(
        'rpc/batch',
        prepared.payload,
        prepared.requestOptions,
        prepared.preflight,
        prepared.actionCount,
      );
    },
    leaseAcquire: (resource, holder, ttlMs, options = {}) => call(
      'rpc/lease-acquire', rpcRecord('lease/acquire', [
        term(resource), term(holder), integerTerm(ttlMs),
      ]), options,
    ),
    leaseRenew: (fence, ttlMs, options = {}) => call(
      'rpc/lease-renew', rpcRecord('lease/renew', [term(fence), integerTerm(ttlMs)]), options,
    ),
    leaseRelease: (fence, options = {}) => call('rpc/lease-release', term(fence), options),
    leaseCheck: (fence, options = {}) => call('rpc/lease-check', term(fence), options),
  });
}
