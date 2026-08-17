// SPDX-License-Identifier: MIT OR Apache-2.0
//
// fram_host_v1 over an async, Durable-Object-shaped storage API.
//
// fram's storage hooks must return an i32 before the guest call unwinds and DO
// storage is async, so both storage objects are resident in host memory for the
// duration of a guest call and the store is touched only on either side of it.

import { assertSeams } from "./seams.mjs";

const PAGE_BYTES = 65536;
const FRAM_ABI_VERSION = 1;
const FRAMLOG_BACKUP_FORMAT = "fram-cloudflare-backup/v1";
const FRAMLOG_RESTORE_FORMAT = "fram-cloudflare-restore/v1";
const FRAMLOG_RESTORE_KEY = "framrestore/pending";
const FRAMLOG_FIXED_HEADER_BYTES = 16;
const FRAMLOG_MAX_SPACE_BYTES = 4096;
const FRAMLOG_MAGIC = Uint8Array.of(
  0x46, 0x52, 0x41, 0x4d, 0x4c, 0x4f, 0x47, 0x00,
);
const SHA256 = /^[0-9a-f]{64}$/;
const FRAMRPC_MAGIC = Uint8Array.of(
  0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00,
);
const FRAMRPC_HEADER_BYTES = 26;
const FRAMRPC_MAX_BODY_BYTES = 1024 * 1024;
export const FRAMRPC_MAX_FRAME_BYTES =
  FRAMRPC_HEADER_BYTES + FRAMRPC_MAX_BODY_BYTES;
const FRAMRPC_MAX_SPACE_BYTES = 4096;
const FRAM_DO_MAX_NAMED_SPACE_BYTES = 1024;
const textDecoder = new TextDecoder("utf-8", { fatal: true });
const textEncoder = new TextEncoder();

const FRAMRPC_OPERATIONS = new Set([
  "rpc/version", "rpc/status", "rpc/validate",
  "rpc/assert", "rpc/retract", "rpc/batch",
  "rpc/scan", "rpc/query", "rpc/occurrences",
  "rpc/lease-acquire", "rpc/lease-renew", "rpc/lease-release",
  "rpc/lease-check", "rpc/checkpoint",
]);
const FRAMRPC_MUTATIONS = new Set([
  "rpc/assert", "rpc/retract", "rpc/batch",
  "rpc/lease-acquire", "rpc/lease-renew", "rpc/lease-release",
]);

export class FramRequestError extends Error {
  constructor(message, code = "request/invalid-frame", options) {
    super(`Fram request: ${message}`, options);
    this.name = "FramRequestError";
    this.code = code;
  }
}

function requestFail(message, code) {
  throw new FramRequestError(message, code);
}

function sameBytes(left, right) {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

class RequestReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.offset = 0;
  }

  ensure(length, label) {
    if (this.offset + length > this.bytes.length) {
      requestFail(`frame ended inside ${label}`, "request/truncated");
    }
  }

  u8(label) {
    this.ensure(1, label);
    const value = this.view.getUint8(this.offset);
    this.offset += 1;
    return value;
  }

  u32(label) {
    this.ensure(4, label);
    const value = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return value;
  }

  text(maximum, label) {
    const length = this.u32(`${label} length`);
    if (length > maximum) {
      requestFail(`${label} exceeds its UTF-8 byte limit`, "request/string-limit");
    }
    this.ensure(length, label);
    const bytes = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    try {
      return textDecoder.decode(bytes);
    } catch (cause) {
      throw new FramRequestError(
        `${label} is not valid UTF-8`,
        "request/invalid-utf8",
        { cause },
      );
    }
  }

  stringTerm(label) {
    if (this.u8(`${label} tag`) !== 1) {
      requestFail(`${label} is not a String Term`, "request/invalid-record");
    }
    return this.text(FRAMRPC_MAX_SPACE_BYTES, label);
  }

  keywordTerm(label) {
    if (this.u8(`${label} tag`) !== 6) {
      requestFail(`${label} is not a Keyword Term`, "request/invalid-record");
    }
    const value = this.text(FRAMRPC_MAX_BODY_BYTES, label);
    if (!value) requestFail(`${label} is empty`, "request/invalid-record");
    return value;
  }
}

/**
 * Parse only the fixed FRAMRPC v2 envelope fields an embedder must authorize.
 * The engine remains the authority for the complete recursive payload codec.
 */
export function inspectFramRpcRequest(frame) {
  if (!(frame instanceof Uint8Array)) {
    requestFail("frame must be a Uint8Array", "request/invalid-type");
  }
  if (frame.length < FRAMRPC_HEADER_BYTES) {
    requestFail("frame ended inside its header", "request/truncated");
  }
  if (frame.length > FRAMRPC_MAX_FRAME_BYTES) {
    requestFail("frame exceeds 1 MiB body limit", "request/frame-too-large");
  }
  if (!sameBytes(frame.subarray(0, FRAMRPC_MAGIC.length), FRAMRPC_MAGIC)) {
    requestFail("magic does not match", "request/invalid-magic");
  }
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const major = view.getUint16(8, true);
  const minor = view.getUint16(10, true);
  const kind = view.getUint8(12);
  const flags = view.getUint8(13);
  const bodyBytes = view.getUint32(14, true);
  const requestId = view.getBigInt64(18, true);
  if (major !== 2 || minor !== 0) {
    requestFail("protocol version is unsupported", "request/unsupported-version");
  }
  if (kind !== 1) requestFail("frame is not a request", "request/invalid-kind");
  if (flags !== 0) requestFail("flags must be zero", "request/invalid-flags");
  if (bodyBytes > FRAMRPC_MAX_BODY_BYTES) {
    requestFail("body exceeds 1 MiB", "request/frame-too-large");
  }
  if (frame.length !== FRAMRPC_HEADER_BYTES + bodyBytes) {
    requestFail("body length is inconsistent", "request/truncated");
  }
  const body = new RequestReader(frame.subarray(FRAMRPC_HEADER_BYTES));
  const space = body.stringTerm("SpaceId");
  const operation = body.keywordTerm("operation");
  if (!space || textEncoder.encode(space).length > FRAMRPC_MAX_SPACE_BYTES) {
    requestFail("SpaceId is empty or too large", "request/invalid-space");
  }
  if (!FRAMRPC_OPERATIONS.has(operation)) {
    requestFail("operation is outside FRAMRPC v2", "request/unsupported-operation");
  }
  return Object.freeze({
    space,
    operation,
    requestId,
    frameBytes: frame.length,
    bodyBytes,
  });
}

export function framRpcEntry(operation) {
  if (operation === "rpc/checkpoint") return "operator";
  if (FRAMRPC_MUTATIONS.has(operation)) return "transact";
  if (operation === "rpc/occurrences") return "snapshot";
  return "query";
}

function entryAccepts(operation, entry) {
  if (operation === "rpc/query") return entry === "query" || entry === "snapshot";
  return framRpcEntry(operation) === entry;
}

export function framDurableObjectTransport(stub) {
  if (!stub || (typeof stub !== "object" && typeof stub !== "function")) {
    throw new TypeError("Fram Durable Object service binding is required");
  }
  return ({ frame, entry, space }) => stub.exchange(frame, { entry, space });
}

// wasm32 layouts of the public ABI structs (native/fram.h under -m32).
export const OPTIONS_SIZE = 32; // abi, size, space, path, host, pad, budget u64
export const ERROR_SIZE = 516; // code i32 + message[512]
export const BUFFER_SIZE = 16; // data, length, release_context, release
const ERROR_MESSAGE_OFFSET = 4;
const OPTIONS_BUDGET_OFFSET = 24;

// fram_wasm_host.c discriminates the two storage objects by context alone.
export const LOG_CONTEXT = 0;
export const IMAGE_CONTEXT = 1;

const WASI_ENOSYS = 52;

function backupFailure(code, message, options) {
  throw new FramBackupError(code, message, options);
}

function exactObject(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    backupFailure("invalid-backup", `${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    backupFailure(
      "invalid-backup",
      `${label} fields must be exactly ${expected.join(", ")}`,
    );
  }
  return value;
}

function parseFramlogHeader(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    backupFailure("invalid-backup", "backup.bytes must be a Uint8Array");
  }
  if (bytes.length < FRAMLOG_FIXED_HEADER_BYTES) {
    backupFailure("invalid-framlog", "FRAMLOG header is truncated");
  }
  if (FRAMLOG_MAGIC.some((byte, index) => bytes[index] !== byte)) {
    backupFailure("invalid-framlog", "FRAMLOG magic does not match");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = view.getUint16(8, true);
  const flags = view.getUint16(10, true);
  if (version !== 1 || flags !== 0) {
    backupFailure(
      "invalid-framlog",
      `FRAMLOG version or flags are unsupported (${version}, ${flags})`,
    );
  }
  const spaceBytes = view.getUint32(12, true);
  if (spaceBytes === 0 || spaceBytes > FRAMLOG_MAX_SPACE_BYTES) {
    backupFailure("invalid-framlog", "FRAMLOG SpaceId length is invalid");
  }
  if (bytes.length < FRAMLOG_FIXED_HEADER_BYTES + spaceBytes) {
    backupFailure("invalid-framlog", "FRAMLOG header is truncated inside SpaceId");
  }
  let spaceId;
  try {
    spaceId = new TextDecoder("utf-8", { fatal: true }).decode(
      bytes.subarray(
        FRAMLOG_FIXED_HEADER_BYTES,
        FRAMLOG_FIXED_HEADER_BYTES + spaceBytes,
      ),
    );
  } catch (error) {
    backupFailure("invalid-framlog", "FRAMLOG SpaceId is not valid UTF-8", {
      cause: error,
    });
  }
  if (!spaceId) {
    backupFailure("invalid-framlog", "FRAMLOG SpaceId is empty");
  }
  return spaceId;
}

async function sha256Hex(bytes) {
  if (!globalThis.crypto?.subtle) {
    backupFailure("crypto-unavailable", "Web Crypto SHA-256 is unavailable");
  }
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function textBytes(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    backupFailure("engine", `${label} must be a nonempty string`);
  }
  const bytes = new TextEncoder().encode(value);
  let decoded;
  try {
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (error) {
    backupFailure("engine", `${label} is not valid UTF-8`, { cause: error });
  }
  if (decoded !== value) {
    backupFailure("engine", `${label} contains an unpaired UTF-16 surrogate`);
  }
  return bytes;
}

function statusFrame(spaceId) {
  const space = textBytes(spaceId, "SpaceId");
  const operation = textBytes("rpc/status", "status operation");
  const unit = textBytes("rpc/unit", "status payload");
  const bodyLength =
    1 + 4 + space.length +
    1 + 4 + operation.length +
    3 +
    1 + 4 + unit.length;
  const frame = new Uint8Array(FRAMRPC_HEADER_BYTES + bodyLength);
  frame.set(FRAMRPC_MAGIC, 0);
  const view = new DataView(frame.buffer);
  view.setUint16(8, 2, true);
  view.setUint16(10, 0, true);
  view.setUint8(12, 1); // request
  view.setUint8(13, 0);
  view.setUint32(14, bodyLength, true);
  view.setBigInt64(18, 0n, true);
  let offset = FRAMRPC_HEADER_BYTES;
  const term = (tag, bytes) => {
    view.setUint8(offset, tag);
    offset += 1;
    view.setUint32(offset, bytes.length, true);
    offset += 4;
    frame.set(bytes, offset);
    offset += bytes.length;
  };
  term(1, space);
  term(6, operation);
  view.setUint8(offset++, 0); // expected version
  view.setUint8(offset++, 0); // page
  view.setUint8(offset++, 0); // timeout
  term(6, unit);
  return frame;
}

function decodeStatusServedVersion(frame, expectedSpaceId) {
  if (!(frame instanceof Uint8Array) || frame.length < FRAMRPC_HEADER_BYTES) {
    backupFailure("engine", "status response ended inside its header");
  }
  if (FRAMRPC_MAGIC.some((byte, index) => frame[index] !== byte)) {
    backupFailure("engine", "status response magic does not match");
  }
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  if (
    view.getUint16(8, true) !== 2 ||
    view.getUint16(10, true) !== 0 ||
    view.getUint8(12) !== 2 ||
    view.getUint8(13) !== 0 ||
    view.getBigInt64(18, true) !== 0n
  ) {
    backupFailure("engine", "status response header is not canonical");
  }
  const bodyLength = view.getUint32(14, true);
  if (frame.length !== FRAMRPC_HEADER_BYTES + bodyLength) {
    backupFailure("engine", "status response body length is inconsistent");
  }
  let offset = FRAMRPC_HEADER_BYTES;
  const textTerm = (tag, label) => {
    if (offset + 5 > frame.length || view.getUint8(offset) !== tag) {
      backupFailure("engine", `status response ${label} has the wrong Term tag`);
    }
    offset += 1;
    const length = view.getUint32(offset, true);
    offset += 4;
    if (offset + length > frame.length) {
      backupFailure("engine", `status response ended inside ${label}`);
    }
    let value;
    try {
      value = new TextDecoder("utf-8", { fatal: true }).decode(
        frame.subarray(offset, offset + length),
      );
    } catch (error) {
      backupFailure("engine", `status response ${label} is not valid UTF-8`, {
        cause: error,
      });
    }
    offset += length;
    return value;
  };
  const spaceId = textTerm(1, "SpaceId");
  const operation = textTerm(6, "operation");
  if (spaceId !== expectedSpaceId || operation !== "rpc/status") {
    backupFailure("engine", "status response identity does not match its request");
  }
  if (offset + 11 > frame.length) {
    backupFailure("engine", "status response ended before its controls");
  }
  const servedVersion = view.getBigInt64(offset, true);
  offset += 8;
  const pagePresent = view.getUint8(offset++);
  const errorPresent = view.getUint8(offset++);
  const payloadPresent = view.getUint8(offset++);
  if (
    servedVersion < 0n ||
    pagePresent !== 0 ||
    errorPresent !== 0 ||
    payloadPresent !== 1 ||
    offset >= frame.length
  ) {
    backupFailure("engine", "status response reports an error or invalid controls");
  }
  return servedVersion.toString();
}

function captureBackup(backup) {
  exactObject(
    backup,
    ["byteLength", "bytes", "format", "servedVersion", "sha256", "spaceId"],
    "backup",
  );
  const suppliedBytes = backup.bytes;
  return Object.freeze({
    byteLength: backup.byteLength,
    bytes:
      suppliedBytes instanceof Uint8Array ? suppliedBytes.slice() : suppliedBytes,
    format: backup.format,
    servedVersion: backup.servedVersion,
    sha256: backup.sha256,
    spaceId: backup.spaceId,
  });
}

async function verifiedBackup(backup, configuredSpaceId) {
  const format = backup.format;
  const spaceId = backup.spaceId;
  const byteLength = backup.byteLength;
  const servedVersion = backup.servedVersion;
  const expectedSha256 = backup.sha256;
  const suppliedBytes = backup.bytes;
  if (format !== FRAMLOG_BACKUP_FORMAT) {
    backupFailure(
      "invalid-backup",
      `backup.format must be ${FRAMLOG_BACKUP_FORMAT}`,
    );
  }
  if (typeof spaceId !== "string" || spaceId.length === 0) {
    backupFailure("invalid-backup", "backup.spaceId must be a nonempty string");
  }
  if (spaceId !== configuredSpaceId) {
    backupFailure(
      "space-mismatch",
      `backup belongs to SpaceId ${JSON.stringify(spaceId)}, not ` +
        JSON.stringify(configuredSpaceId),
    );
  }
  if (!Number.isSafeInteger(byteLength) || byteLength < 0) {
    backupFailure(
      "invalid-backup",
      "backup.byteLength must be a nonnegative safe integer",
    );
  }
  if (
    typeof servedVersion !== "string" ||
    !/^(?:0|[1-9][0-9]*)$/.test(servedVersion) ||
    BigInt(servedVersion) > (1n << 63n) - 1n
  ) {
    backupFailure(
      "invalid-backup",
      "backup.servedVersion must be a canonical nonnegative i64 decimal string",
    );
  }
  if (typeof expectedSha256 !== "string" || !SHA256.test(expectedSha256)) {
    backupFailure("invalid-backup", "backup.sha256 must be lowercase SHA-256");
  }
  if (!(suppliedBytes instanceof Uint8Array)) {
    backupFailure("invalid-backup", "backup.bytes must be a Uint8Array");
  }
  if (suppliedBytes.length !== byteLength) {
    backupFailure(
      "verification",
      `backup has ${suppliedBytes.length} bytes, not ${byteLength}`,
    );
  }

  // captureBackup owned this copy before the restore entered its asynchronous
  // operation queue, so hashing and landing observe the same byte string.
  const bytes = suppliedBytes;
  const headerSpaceId = parseFramlogHeader(bytes);
  if (headerSpaceId !== spaceId) {
    backupFailure(
      "space-mismatch",
      `FRAMLOG belongs to SpaceId ${JSON.stringify(headerSpaceId)}, not ` +
        JSON.stringify(spaceId),
    );
  }
  const digest = await sha256Hex(bytes);
  if (digest !== expectedSha256) {
    backupFailure(
      "verification",
      `backup FRAMLOG SHA-256 is ${digest}, not ${expectedSha256}`,
    );
  }
  return Object.freeze({ bytes, digest, servedVersion });
}

function validateExpectedCurrent(expected) {
  exactObject(expected, ["byteLength", "sha256"], "expectedCurrent");
  if (!Number.isSafeInteger(expected.byteLength) || expected.byteLength < 0) {
    backupFailure(
      "invalid-backup",
      "expectedCurrent.byteLength must be a nonnegative safe integer",
    );
  }
  if (typeof expected.sha256 !== "string" || !SHA256.test(expected.sha256)) {
    backupFailure(
      "invalid-backup",
      "expectedCurrent.sha256 must be lowercase SHA-256",
    );
  }
  return Object.freeze({
    byteLength: expected.byteLength,
    sha256: expected.sha256,
  });
}

function restoreFence(marker, cause) {
  const expectedCurrent =
    marker &&
    typeof marker === "object" &&
    Number.isSafeInteger(marker.byteLength) &&
    marker.byteLength >= 0 &&
    typeof marker.sha256 === "string" &&
    SHA256.test(marker.sha256)
      ? Object.freeze({
          byteLength: marker.byteLength,
          sha256: marker.sha256,
        })
      : null;
  const recovery = expectedCurrent
    ? " Recover with another verified restore using { replace: true, " +
      `expectedCurrent: ${JSON.stringify(expectedCurrent)} }.`
    : " Recover with an explicit verified replacement after inspecting the " +
      "current FRAMLOG identity.";
  const error = new FramBackupError(
    "restore-fenced",
    "a FRAMLOG restore is durably pending; data access remains fenced." + recovery,
    cause ? { cause } : undefined,
  );
  error.expectedCurrent = expectedCurrent;
  return error;
}

// ---------------------------------------------------------------------------
// The async store
// ---------------------------------------------------------------------------

/**
 * One storage object as chunked values in a DurableObjectStorage-shaped KV.
 *
 * DO caps a single value at 128 KiB and a single put() batch at 128 keys, so
 * the object is sliced into fixed chunks and only the chunks at or after the
 * lowest modified byte are rewritten. `meta` carries the authoritative length:
 * a chunk may legally hold stale bytes past it after a truncate.
 */
export class ChunkedRange {
  constructor(storage, options = {}) {
    this.storage = storage;
    this.prefix = options.prefix ?? "framlog/";
    this.chunkBytes = options.chunkBytes ?? 64 * 1024;
    this.batchKeys = Math.min(options.batchKeys ?? 100, 128);
    this.metaKey = `${this.prefix}meta`;
    this.chunkCount = null; // unknown until load()
    this.puts = 0;
    this.gets = 0;
    this.deletes = 0;
    this.bytesWritten = 0;
    this.bytesRead = 0;
  }

  #chunkKey(index) {
    // Zero-padded so a list() is lexicographically ordered.
    return `${this.prefix}${String(index).padStart(8, "0")}`;
  }

  async load() {
    const meta = await this.storage.get(this.metaKey);
    this.gets += 1;
    if (!meta) {
      this.chunkCount = 0;
      return new Uint8Array(0);
    }
    // The written chunk size wins: a range written under another configuration
    // still reads back at its own boundaries.
    if (meta.chunkBytes) this.chunkBytes = meta.chunkBytes;
    const length = meta.length;
    const chunks = Math.ceil(length / this.chunkBytes);
    this.chunkCount = chunks;
    const image = new Uint8Array(length);
    for (let base = 0; base < chunks; base += this.batchKeys) {
      const keys = [];
      for (let i = base; i < Math.min(base + this.batchKeys, chunks); i++) {
        keys.push(this.#chunkKey(i));
      }
      const got = await this.storage.get(keys);
      this.gets += 1;
      for (let i = base; i < base + keys.length; i++) {
        const value = got.get(this.#chunkKey(i));
        if (value === undefined) {
          throw new Error(
            `${this.prefix} chunk ${i} is missing; the object is torn`,
          );
        }
        const bytes = new Uint8Array(
          value.buffer ?? value,
          value.byteOffset ?? 0,
          value.byteLength ?? value.length,
        );
        const at = i * this.chunkBytes;
        image.set(bytes.subarray(0, Math.min(bytes.length, length - at)), at);
        this.bytesRead += bytes.length;
      }
    }
    return image;
  }

  /**
   * The writes that publish `bytes[0..length)`, rewriting only chunks at or
   * after `lowWater`. Slices eagerly: the plan owns its copies, so the caller
   * may keep appending while the transaction is still queued.
   */
  plan(bytes, length, lowWater) {
    if (this.chunkCount === null) {
      throw new Error(`${this.prefix} was never loaded; stale chunks unknown`);
    }
    const first = Math.floor(lowWater / this.chunkBytes);
    const chunks = Math.ceil(length / this.chunkBytes);
    const writes = [];
    for (let i = first; i < chunks; i++) {
      const at = i * this.chunkBytes;
      const end = Math.min(at + this.chunkBytes, length);
      writes.push([this.#chunkKey(i), bytes.slice(at, end)]);
    }
    const stale = [];
    for (let i = chunks; i < this.chunkCount; i++) stale.push(this.#chunkKey(i));
    return { writes, stale, chunks, length, publishMeta: true };
  }

  /**
   * Inventory this range without interpreting its meta or payload values.
   * Restore may discard a derived image even when those values are torn, but
   * it must not turn a broad prefix delete into authority over unknown keys.
   */
  async clearPlan() {
    const stale = [];
    let startAfter;
    for (;;) {
      const options = { prefix: this.prefix, limit: this.batchKeys };
      if (startAfter !== undefined) options.startAfter = startAfter;
      const listed = await this.storage.list(options);
      if (!(listed instanceof Map)) {
        throw new Error(`${this.prefix} key inventory is not a Map`);
      }
      const keys = [...listed.keys()].sort();
      for (const key of keys) {
        const suffix = typeof key === "string" && key.startsWith(this.prefix)
          ? key.slice(this.prefix.length)
          : "";
        if (suffix !== "meta" && !/^[0-9]{8}$/.test(suffix)) {
          throw new Error(
            `${this.prefix} contains an unrecognised storage key: ${String(key)}`,
          );
        }
        if (startAfter !== undefined && key <= startAfter) {
          throw new Error(`${this.prefix} key inventory did not advance`);
        }
        stale.push(key);
      }
      if (keys.length < this.batchKeys) break;
      startAfter = keys[keys.length - 1];
    }
    return {
      writes: [],
      stale,
      chunks: 0,
      length: 0,
      publishMeta: false,
    };
  }

  async applyTo(txn, plan) {
    for (let base = 0; base < plan.writes.length; base += this.batchKeys) {
      const batch = plan.writes.slice(base, base + this.batchKeys);
      await txn.put(Object.fromEntries(batch));
      this.puts += 1;
      for (const [, value] of batch) this.bytesWritten += value.length;
    }
    for (let base = 0; base < plan.stale.length; base += this.batchKeys) {
      await txn.delete(plan.stale.slice(base, base + this.batchKeys));
      this.deletes += 1;
    }
    if (plan.publishMeta) {
      await txn.put(this.metaKey, {
        length: plan.length,
        chunkBytes: this.chunkBytes,
      });
      this.puts += 1;
    }
  }

  /** Adopt the plan's chunk count; only a landed transaction may call this. */
  settle(plan) {
    this.chunkCount = plan.chunks;
  }
}

/**
 * The FRAMLOG and the snapshot image as two key ranges in one DO storage.
 *
 * Commits are serialised and atomic across both ranges: fram replays the log
 * from byte zero and boots through the image when one is present, so the pair
 * must never be observed half-published.
 */
export class DurableFramStore {
  constructor(storage, options = {}) {
    const shared = {
      chunkBytes: options.chunkBytes,
      batchKeys: options.batchKeys,
    };
    this.storage = storage;
    this.ranges = {
      log: new ChunkedRange(storage, {
        ...shared,
        prefix: options.logPrefix ?? "framlog/",
      }),
      image: new ChunkedRange(storage, {
        ...shared,
        prefix: options.imagePrefix ?? "framimage/",
      }),
    };
    this.commits = 0;
    this.queue = Promise.resolve();
  }

  load(which = "log") {
    return this.ranges[which].load();
  }

  clearPlan(which) {
    return this.ranges[which].clearPlan();
  }

  /** parts: [{ which, bytes, length, lowWater }] */
  commit(parts) {
    const staged = parts.map(({ which, bytes, length, lowWater }) => {
      const range = this.ranges[which];
      return { range, plan: range.plan(bytes, length, lowWater) };
    });
    const run = async () => {
      await this.storage.transaction(async (txn) => {
        for (const { range, plan } of staged) await range.applyTo(txn, plan);
      });
      for (const { range, plan } of staged) range.settle(plan);
      this.commits += 1;
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** Publish replacement bytes, preplanned clears, and a marker atomically. */
  replace(parts, marker) {
    const staged = parts.map(({ which, bytes, length, lowWater, plan }) => {
      const range = this.ranges[which];
      return { range, plan: plan ?? range.plan(bytes, length, lowWater) };
    });
    const run = async () => {
      await this.storage.transaction(async (txn) => {
        for (const { range, plan } of staged) await range.applyTo(txn, plan);
        await txn.put(FRAMLOG_RESTORE_KEY, marker);
      });
      for (const { range, plan } of staged) range.settle(plan);
      this.commits += 1;
    };
    const result = this.queue.then(run, run);
    this.queue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  useStorage(storage) {
    this.storage = storage;
    for (const range of Object.values(this.ranges)) range.storage = storage;
  }

  stats() {
    const of = (range) => ({
      puts: range.puts,
      gets: range.gets,
      deletes: range.deletes,
      bytesWritten: range.bytesWritten,
      bytesRead: range.bytesRead,
      chunks: range.chunkCount,
    });
    return {
      commits: this.commits,
      log: of(this.ranges.log),
      image: of(this.ranges.image),
    };
  }
}

/** The same interface over a plain Map, for a runtime with no DO storage. */
export class MemoryStorage {
  constructor(map = new Map()) {
    this.map = map;
    this.latencyMs = 0;
  }

  async #tick() {
    if (this.latencyMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, this.latencyMs));
    }
  }

  async get(keyOrKeys) {
    await this.#tick();
    if (Array.isArray(keyOrKeys)) {
      const out = new Map();
      for (const key of keyOrKeys) {
        if (this.map.has(key)) out.set(key, this.map.get(key));
      }
      return out;
    }
    return this.map.get(keyOrKeys);
  }

  async list(options = {}) {
    await this.#tick();
    const prefix = options.prefix ?? "";
    const startAfter = options.startAfter;
    const limit = options.limit ?? Infinity;
    const keys = [...this.map.keys()]
      .filter(
        (key) =>
          key.startsWith(prefix) &&
          (startAfter === undefined || key > startAfter),
      )
      .sort()
      .slice(0, limit);
    return new Map(keys.map((key) => [key, this.map.get(key)]));
  }

  async put(keyOrEntries, value) {
    await this.#tick();
    if (typeof keyOrEntries === "object" && value === undefined) {
      for (const [key, item] of Object.entries(keyOrEntries)) {
        this.map.set(key, item);
      }
      return;
    }
    this.map.set(keyOrEntries, value);
  }

  async delete(keyOrKeys) {
    await this.#tick();
    for (const key of Array.isArray(keyOrKeys) ? keyOrKeys : [keyOrKeys]) {
      this.map.delete(key);
    }
  }

  // Atomic like the real one: a throwing body publishes nothing.
  async transaction(body) {
    const staging = new MemoryStorage(new Map(this.map));
    staging.latencyMs = this.latencyMs;
    const result = await body(staging);
    this.map = staging.map;
    return result;
  }
}

// ---------------------------------------------------------------------------
// The synchronous side: host memory image + guest-memory allocator
// ---------------------------------------------------------------------------

/**
 * One storage object as the synchronous hooks see it. Reads are served from it,
 * appends land in it, and `lowWater` remembers the earliest byte a commit must
 * rewrite.
 */
class HostImage {
  constructor(bytes) {
    this.bytes = bytes;
    this.capacity = bytes.length;
    this.length = bytes.length;
    this.lowWater = Number.POSITIVE_INFINITY;
    this.dirty = false;
    this.syncs = 0;
  }

  #reserve(extra) {
    if (this.length + extra <= this.capacity) return;
    let capacity = Math.max(this.capacity * 2, 64 * 1024);
    while (capacity < this.length + extra) capacity *= 2;
    const grown = new Uint8Array(capacity);
    grown.set(this.bytes.subarray(0, this.length));
    this.bytes = grown;
    this.capacity = capacity;
  }

  append(chunk) {
    this.#reserve(chunk.length);
    this.bytes.set(chunk, this.length);
    this.lowWater = Math.min(this.lowWater, this.length);
    this.length += chunk.length;
    this.dirty = true;
  }

  truncate(length) {
    if (length > this.length) return false;
    this.lowWater = Math.min(this.lowWater, length);
    this.length = length;
    this.dirty = true;
    return true;
  }

  read(offset, length) {
    if (offset + length > this.length) return null;
    return this.bytes.subarray(offset, offset + length);
  }

  takeCommit() {
    const low = Number.isFinite(this.lowWater) ? this.lowWater : 0;
    this.lowWater = Number.POSITIVE_INFINITY;
    this.dirty = false;
    return low;
  }

  // A rejected commit published nothing, so the range it covered is dirty again.
  restoreCommit(low) {
    this.lowWater = Math.min(this.lowWater, low);
    this.dirty = true;
  }
}

/**
 * fram's general allocator, living in a host-owned partition of guest memory.
 *
 * fram_host_v1.allocate is not only for responses: the engine's own long-lived
 * structures come through it, so a bump arena leaks the index on every open.
 * deallocate carries no size, so each block gets a 16-byte header and freed
 * blocks return to a power-of-two size-class free list.
 */
class GuestArena {
  static HEADER = 16;

  constructor(memory, options = {}) {
    this.memory = memory;
    this.initialPages = options.initialPages ?? 128; // 8 MiB
    this.growPages = options.growPages ?? 128;
    this.base = 0;
    this.next = 0;
    this.end = 0;
    this.free = new Map();
    this.allocations = 0;
    this.deallocations = 0;
    this.reuses = 0;
    this.grows = 0;
    this.liveBytes = 0;
    this.peakLiveBytes = 0;
  }

  reserve() {
    const before = this.memory.grow(this.initialPages);
    if (before < 0) throw new Error("cannot reserve the host arena");
    this.base = before * PAGE_BYTES;
    this.next = this.base;
    this.end = this.base + this.initialPages * PAGE_BYTES;
  }

  #view() {
    return new DataView(this.memory.buffer);
  }

  static #classOf(size) {
    let cls = 32;
    while (cls < size) cls *= 2;
    return cls;
  }

  allocate(size) {
    this.allocations += 1;
    const cls = GuestArena.#classOf(size);
    const bucket = this.free.get(cls);
    if (bucket && bucket.length) {
      this.reuses += 1;
      const pointer = bucket.pop();
      this.liveBytes += cls;
      this.peakLiveBytes = Math.max(this.peakLiveBytes, this.liveBytes);
      return pointer;
    }
    const need = GuestArena.HEADER + cls;
    let header = (this.next + 15) & ~15;
    if (header + need > this.end) {
      // The arena is contiguous with the top of linear memory only while
      // nothing else has grown it; restart the bump pointer if it moved.
      const pages = Math.max(this.growPages, Math.ceil(need / PAGE_BYTES));
      const before = this.memory.grow(pages);
      if (before < 0) return 0; // NULL -> fram surfaces FRAM_OUT_OF_MEMORY
      this.grows += 1;
      const fresh = before * PAGE_BYTES;
      if (fresh !== this.end) this.next = fresh;
      this.end = fresh + pages * PAGE_BYTES;
      header = (this.next + 15) & ~15;
      if (header + need > this.end) return 0;
    }
    this.next = header + need;
    const view = this.#view();
    view.setUint32(header, cls, true);
    view.setUint32(header + 4, 0x4652414d, true); // 'FRAM'
    this.liveBytes += cls;
    this.peakLiveBytes = Math.max(this.peakLiveBytes, this.liveBytes);
    return header + GuestArena.HEADER;
  }

  deallocate(pointer) {
    this.deallocations += 1;
    if (!pointer) return;
    const header = pointer - GuestArena.HEADER;
    const view = this.#view();
    if (view.getUint32(header + 4, true) !== 0x4652414d) {
      throw new Error(`deallocate(${pointer}) is not a host arena block`);
    }
    const cls = view.getUint32(header, true);
    let bucket = this.free.get(cls);
    if (!bucket) this.free.set(cls, (bucket = []));
    bucket.push(pointer);
    this.liveBytes -= cls;
  }

  get reservedBytes() {
    return this.end - this.base;
  }
}

// ---------------------------------------------------------------------------
// The instance
// ---------------------------------------------------------------------------

/** A malformed, mismatched, unsafe, or uncommitted portable backup. */
export class FramBackupError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = "FramBackupError";
    this.code = code;
  }
}

/** A rejected storage commit fences the instance that raised it. */
export class FramStorageError extends Error {
  constructor(cause) {
    super(`the storage commit was rejected: ${cause.message}`, { cause });
    this.name = "FramStorageError";
  }
}

/** A wasm-embed entry point failed before it could produce a FRAMRPC reply. */
export class FramExchangeError extends Error {
  constructor(status, message) {
    super(`Fram exchange failed with status ${status}: ${message}`);
    this.name = "FramExchangeError";
    this.status = status;
  }
}

export class FramInstance {
  /**
   * @param {WebAssembly.Module} module libfram.wasm, host=wasm-embed
   * @param {object} options
   *   store  - DurableFramStore-shaped: load(which), commit(parts)
   *   nowMs  - () => epoch milliseconds; defaults to Date.now
   *   arena  - GuestArena options
   *   memoryBudgetBytes - fram_open_options_v1.memory_budget_bytes; 0 = default
   */
  static async instantiate(module, options = {}) {
    const instance = new FramInstance(options);
    await instance.#boot(module);
    return instance;
  }

  constructor(options = {}) {
    this.store = options.store;
    this.nowMs = options.nowMs ?? (() => Date.now());
    this.arenaOptions = options.arena ?? {};
    this.memoryBudgetBytes = BigInt(options.memoryBudgetBytes ?? 0);
    this.hostCalls = Object.create(null);
    this.wasiCalls = Object.create(null);
    this.wasiRefused = Object.create(null);
    this.commits = 0;
    this.log = null;
    this.image = null;
    this.opened = false;
    this.closed = false;
    this.poisoned = null;
    this.spaceId = null;
    this.gate = Promise.resolve();
  }

  #tick(table, name) {
    table[name] = (table[name] ?? 0) + 1;
  }

  #bytes() {
    return new Uint8Array(this.memory.buffer);
  }

  #view() {
    return new DataView(this.memory.buffer);
  }

  #object(context) {
    return context === IMAGE_CONTEXT ? this.image : this.log;
  }

  #imports() {
    const self = this;
    const fram_host_v1 = {
      clock_milliseconds(_context, outPointer) {
        self.#tick(self.hostCalls, "clock_milliseconds");
        self.#view().setBigInt64(outPointer, BigInt(self.nowMs()), true);
        return 0;
      },
      storage_size(context, outPointer) {
        self.#tick(self.hostCalls, "storage_size");
        const object = self.#object(context);
        self.#view().setBigUint64(outPointer, BigInt(object.length), true);
        return 0;
      },
      storage_read(context, offset, destination, length) {
        self.#tick(self.hostCalls, "storage_read");
        const slice = self.#object(context).read(Number(offset), length);
        if (slice === null) return 1;
        self.#bytes().set(slice, destination);
        return 0;
      },
      storage_truncate(context, length) {
        self.#tick(self.hostCalls, "storage_truncate");
        return self.#object(context).truncate(Number(length)) ? 0 : 1;
      },
      storage_append(context, pointer, length) {
        self.#tick(self.hostCalls, "storage_append");
        self
          .#object(context)
          .append(self.#bytes().subarray(pointer, pointer + length));
        return 0;
      },
      // The commit the guest believes in happens here; the commit Cloudflare
      // believes in happens in #commit(), after the guest call unwinds.
      storage_sync(context) {
        self.#tick(self.hostCalls, "storage_sync");
        self.#object(context).syncs += 1;
        self.syncPending = true;
        return 0;
      },
      storage_close(_context) {
        self.#tick(self.hostCalls, "storage_close");
        self.syncPending = true;
        return 0;
      },
      allocate(_context, size) {
        self.#tick(self.hostCalls, "allocate");
        return self.arena.allocate(size);
      },
      deallocate(_context, pointer) {
        self.#tick(self.hostCalls, "deallocate");
        self.arena.deallocate(pointer);
      },
    };

    const refuse =
      (name) =>
      (..._arguments) => {
        self.#tick(self.wasiRefused, name);
        return WASI_ENOSYS;
      };
    const wasi_snapshot_preview1 = {
      // The Beagle shim's monotonic clock and getenv have no fram_host_v1
      // field, so these three are the capabilities the regime still takes from
      // WASI. Everything else is counted and refused.
      clock_time_get(_id, _precision, outPointer) {
        self.#tick(self.wasiCalls, "clock_time_get");
        self.#view().setBigUint64(
          outPointer,
          BigInt(Math.round(self.nowMs())) * 1000000n,
          true,
        );
        return 0;
      },
      environ_sizes_get(countPointer, sizePointer) {
        self.#tick(self.wasiCalls, "environ_sizes_get");
        const view = self.#view();
        view.setUint32(countPointer, 0, true);
        view.setUint32(sizePointer, 0, true);
        return 0;
      },
      environ_get(_environ, _buffer) {
        self.#tick(self.wasiCalls, "environ_get");
        return 0;
      },
      fd_close: refuse("fd_close"),
      fd_seek: refuse("fd_seek"),
      fd_write: refuse("fd_write"),
      proc_exit(code) {
        self.#tick(self.wasiRefused, "proc_exit");
        throw new Error(`the guest called proc_exit(${code})`);
      },
    };

    return { fram_host_v1, wasi_snapshot_preview1 };
  }

  async #boot(module) {
    const started = nowHiRes();
    const imports = this.#imports();
    assertSeams(module, imports);
    const instance = await WebAssembly.instantiate(module, imports);
    this.exports = instance.exports;
    this.memory = this.exports.memory;
    this.exports._initialize();
    this.arena = new GuestArena(this.memory, this.arenaOptions);
    this.arena.reserve();
    this.instantiateMs = nowHiRes() - started;
  }

  // -- guest memory helpers -------------------------------------------------

  alloc(size) {
    const pointer = this.exports.fram_wasm_alloc(size);
    if (!pointer) throw new Error(`fram_wasm_alloc(${size}) returned NULL`);
    this.#bytes().fill(0, pointer, pointer + size);
    return pointer;
  }

  free(pointer) {
    this.exports.fram_wasm_free(pointer);
  }

  write(pointer, payload) {
    this.#bytes().set(payload, pointer);
  }

  read(pointer, length) {
    return this.#bytes().slice(pointer, pointer + length);
  }

  readCString(pointer, limit) {
    const bytes = this.#bytes();
    let end = pointer;
    while (end < pointer + limit && bytes[end] !== 0) end += 1;
    return new TextDecoder().decode(bytes.subarray(pointer, end));
  }

  putCString(text) {
    const raw = new TextEncoder().encode(`${text}\0`);
    const pointer = this.alloc(raw.length);
    this.write(pointer, raw);
    return pointer;
  }

  // -- the public database surface ------------------------------------------

  /**
   * Load both storage objects and open the database over them. Resolves only
   * after the open's own writes are durable.
   */
  open(spaceId, logLabel = "in-memory") {
    return this.#serialise(async () => {
      if (this.opened) throw new Error("this instance is already open");
      // The whole synchronous illusion starts here: two awaits, then both
      // objects are resident and every storage hook can answer without yielding.
      this.log = new HostImage(await this.store.load("log"));
      this.image = new HostImage(await this.store.load("image"));
      this.syncPending = false;

      const options = this.alloc(OPTIONS_SIZE);
      const view = this.#view();
      view.setUint32(options + 0, FRAM_ABI_VERSION, true);
      view.setUint32(options + 4, OPTIONS_SIZE, true);
      view.setUint32(options + 8, this.putCString(spaceId), true);
      view.setUint32(options + 12, this.putCString(logLabel), true);
      view.setUint32(options + 16, 0, true); // host == NULL selects the imports
      this.#view().setBigUint64(
        options + OPTIONS_BUDGET_OFFSET,
        this.memoryBudgetBytes,
        true,
      );
      const databaseOut = this.alloc(4);
      const error = this.alloc(ERROR_SIZE);

      const status = this.exports.fram_open(options, databaseOut, error);
      const message = this.readCString(
        error + ERROR_MESSAGE_OFFSET,
        ERROR_SIZE - ERROR_MESSAGE_OFFSET,
      );
      await this.#commit();
      if (status === 0) {
        this.database = this.#view().getUint32(databaseOut, true);
        this.spaceId = spaceId;
        this.opened = true;
      }
      return { status, message };
    });
  }

  /** entry: "q" | "t" | "s" */
  call(entry, frame) {
    return this.#serialise(() => this.#callNow(entry, frame));
  }

  query(frame) {
    return this.call("q", frame);
  }

  transact(frame) {
    return this.call("t", frame);
  }

  snapshot(frame) {
    return this.call("s", frame);
  }

  /**
   * Take a checkpoint: FRAME is a canonical `:rpc/checkpoint` request, which
   * fram answers by rewriting the snapshot image. Resolves once both the image
   * and the log are durable.
   */
  checkpoint(frame) {
    return this.#serialise(async () => {
      const result = await this.#callNow("t", frame);
      return { ...result, imageBytes: this.image.length };
    });
  }

  close() {
    return this.#serialise(async () => {
      const error = this.alloc(ERROR_SIZE);
      const status = this.exports.fram_close(this.database, error);
      const message = this.readCString(
        error + ERROR_MESSAGE_OFFSET,
        ERROR_SIZE - ERROR_MESSAGE_OFFSET,
      );
      this.free(error);
      await this.#commit();
      this.closed = true;
      this.opened = false;
      return { status, message };
    });
  }

  /** Bind one stable FRAMLOG copy to the logical version it contains. */
  portableFramlog() {
    return this.#serialise(async () => {
      const response = await this.#callNow("q", statusFrame(this.spaceId));
      if (response.status !== 0) {
        backupFailure(
          "engine",
          `cannot read served version: ${response.status} ${response.message}`,
        );
      }
      return Object.freeze({
        bytes: this.logBytes(),
        servedVersion: decodeStatusServedVersion(response.response, this.spaceId),
      });
    });
  }

  /**
   * Put an administrative fence behind every call already admitted. A caller
   * retaining this instance cannot write through it after its storage is
   * replaced, even though FramDurableObjectBase has dropped its own reference.
   */
  fence(error) {
    const run = async () => {
      if (!this.poisoned) this.poisoned = error;
      return this.poisoned;
    };
    const result = this.gate.then(run, run);
    this.gate = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  async #callNow(entry, frame) {
    const entryPoint =
      entry === "t"
        ? this.exports.fram_transact
        : entry === "s"
          ? this.exports.fram_snapshot
          : this.exports.fram_query;

    const requestPointer = this.alloc(frame.length);
    this.write(requestPointer, frame);
    const slice = this.alloc(8);
    const view = this.#view();
    view.setUint32(slice + 0, requestPointer, true);
    view.setUint32(slice + 4, frame.length, true);
    const buffer = this.alloc(BUFFER_SIZE);
    const error = this.alloc(ERROR_SIZE);

    const status = entryPoint(this.database, slice, buffer, error);

    const after = this.#view();
    const data = after.getUint32(buffer + 0, true);
    const length = after.getUint32(buffer + 4, true);
    const response = length ? this.read(data, length) : new Uint8Array(0);
    const message = this.readCString(
      error + ERROR_MESSAGE_OFFSET,
      ERROR_SIZE - ERROR_MESSAGE_OFFSET,
    );

    // release is a table index; only the guest can call it.
    this.exports.fram_buffer_release(buffer);
    const cleared = this.#view();
    const released =
      cleared.getUint32(buffer + 0, true) === 0 &&
      cleared.getUint32(buffer + 4, true) === 0 &&
      cleared.getUint32(buffer + 12, true) === 0;

    this.free(requestPointer);
    this.free(slice);
    this.free(buffer);
    this.free(error);

    await this.#commit();
    return { status, message, response, released };
  }

  /**
   * One guest call at a time. The guest is single-threaded and its pointers
   * live across the awaits inside a call, so two overlapping requests on one
   * instance would interleave allocations into each other's frames.
   */
  #serialise(body) {
    const run = async () => {
      this.#assertUsable();
      return body();
    };
    const result = this.gate.then(run, run);
    this.gate = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  #assertUsable() {
    if (this.poisoned) throw this.poisoned;
    if (this.closed) throw new Error("this fram instance is closed");
  }

  async #commit() {
    if (!this.syncPending && !this.log.dirty && !this.image.dirty) return;
    this.syncPending = false;
    const parts = [];
    for (const [which, object] of [
      ["log", this.log],
      ["image", this.image],
    ]) {
      if (object.dirty) {
        parts.push({
          which,
          object,
          bytes: object.bytes,
          length: object.length,
          lowWater: object.takeCommit(),
        });
      }
    }
    if (!parts.length) return;
    try {
      await this.store.commit(parts);
    } catch (error) {
      // Nothing landed, so the ranges are dirty again; this instance is fenced
      // because it can no longer tell the guest's bytes from the durable ones.
      for (const part of parts) part.object.restoreCommit(part.lowWater);
      this.poisoned = new FramStorageError(error);
      throw this.poisoned;
    }
    this.commits += 1;
  }

  /** The log as the guest currently sees it (host memory, not yet durable). */
  logBytes() {
    return this.log.bytes.slice(0, this.log.length);
  }

  /** The snapshot image as the guest currently sees it. */
  imageBytes() {
    return this.image.bytes.slice(0, this.image.length);
  }

  stats() {
    return {
      instantiateMs: this.instantiateMs,
      linearMemoryBytes: this.memory.buffer.byteLength,
      arenaReservedBytes: this.arena.reservedBytes,
      arenaPeakLiveBytes: this.arena.peakLiveBytes,
      arenaLiveBytes: this.arena.liveBytes,
      arenaAllocations: this.arena.allocations,
      arenaDeallocations: this.arena.deallocations,
      arenaReuses: this.arena.reuses,
      arenaGrows: this.arena.grows,
      commits: this.commits,
      logBytes: this.log ? this.log.length : 0,
      imageBytes: this.image ? this.image.length : 0,
      poisoned: this.poisoned ? this.poisoned.message : null,
      hostCalls: { ...this.hostCalls },
      wasiCalls: { ...this.wasiCalls },
      wasiRefused: { ...this.wasiRefused },
    };
  }
}

/**
 * A Durable Object that owns one FRAMLOG and its snapshot image.
 *
 * The instance is created lazily per isolate and kept for the object's
 * lifetime: instantiation is the expensive step and the state it holds is
 * exactly what the DO already guarantees single-writer access to.
 */
export class FramDurableObjectBase {
  constructor(state, env, module, options = {}) {
    if (typeof options.spaceId !== "string" || !options.spaceId) {
      throw new TypeError("Fram Durable Object spaceId must be a nonempty string");
    }
    if (textEncoder.encode(options.spaceId).length > FRAM_DO_MAX_NAMED_SPACE_BYTES) {
      throw new TypeError("Fram Durable Object spaceId exceeds 1024 UTF-8 bytes");
    }
    if (state?.id?.name !== options.spaceId) {
      throw new FramRequestError(
        "Durable Object name must exactly equal its SpaceId; use getByName(spaceId)",
        "request/object-identity-mismatch",
      );
    }
    this.state = state;
    this.env = env;
    this.module = module;
    this.spaceId = options.spaceId;
    this.logLabel = options.logLabel ?? "in-memory";
    this.storeOptions = options.store ?? {};
    this.instanceOptions = options.instance ?? {};
    this.instance = null;
    this.store = null;
    this.booting = null;
    this.administrativeFence = null;
    this.operations = Promise.resolve();
  }

  /** The open instance, booting it at most once however many requests race. */
  fram() {
    if (this.administrativeFence) {
      return Promise.reject(this.administrativeFence);
    }
    if (this.instance) return Promise.resolve(this.instance);
    // Assigned before the first await: a second caller in the same turn joins
    // this boot instead of building a second image over the same storage.
    if (!this.booting) {
      this.booting = this.#bootData().then(
        (instance) => {
          this.instance = instance;
          this.booting = null;
          return instance;
        },
        (error) => {
          this.booting = null;
          throw error;
        },
      );
    }
    return this.booting;
  }

  async #bootData() {
    const pending = await this.state.storage.get(FRAMLOG_RESTORE_KEY);
    if (pending !== undefined) {
      const fenced = restoreFence(pending);
      this.administrativeFence = fenced;
      throw fenced;
    }
    return this.#boot();
  }

  async #boot() {
    const store = new DurableFramStore(this.state.storage, this.storeOptions);
    const instance = await FramInstance.instantiate(this.module, {
      ...this.instanceOptions,
      store,
    });
    const opened = await instance.open(this.spaceId, this.logLabel);
    this.openResult = opened;
    if (opened.status !== 0) {
      throw new Error(`fram_open failed: ${opened.status} ${opened.message}`);
    }
    this.store = store;
    return instance;
  }

  async #bootForRestore() {
    const durableStore = new DurableFramStore(
      this.state.storage,
      this.storeOptions,
    );
    const readOnlyStore = {
      load: (which) => durableStore.load(which),
      async commit(parts) {
        if (parts.length !== 0) {
          backupFailure(
            "verification",
            "post-publication replay tried to repair durable FRAM bytes",
          );
        }
      },
    };
    const instance = await FramInstance.instantiate(this.module, {
      ...this.instanceOptions,
      store: readOnlyStore,
    });
    const opened = await instance.open(this.spaceId, this.logLabel);
    this.openResult = opened;
    if (opened.status !== 0) {
      throw new Error(`fram_open failed: ${opened.status} ${opened.message}`);
    }
    durableStore.useStorage(this.state.storage);
    instance.store = durableStore;
    this.store = durableStore;
    return instance;
  }

  query(frame) {
    return this.#use((instance) => instance.query(frame));
  }

  transact(frame) {
    return this.#use((instance) => instance.transact(frame));
  }

  snapshot(frame) {
    return this.#use((instance) => instance.snapshot(frame));
  }

  checkpoint(frame) {
    return this.#use((instance) => instance.checkpoint(frame));
  }

  /**
   * Runtime-neutral data plane for the official FRAMRPC client.
   *
   * This is safe to expose as a Durable Object RPC method: it validates the
   * exact frame bound, protocol envelope, SpaceId, and operation/entry pairing
   * before entering the guest. It resolves only after the adapter has durably
   * committed every write performed by the call.
   */
  async exchange(frame, options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      requestFail("exchange options must be an object", "request/invalid-options");
    }
    for (const key of Object.keys(options)) {
      if (key !== "entry" && key !== "space") {
        requestFail(`exchange option ${key} is unknown`, "request/invalid-options");
      }
    }
    if (options.entry !== "query"
        && options.entry !== "transact"
        && options.entry !== "snapshot") {
      requestFail("entry must be query, transact, or snapshot", "request/invalid-entry");
    }
    if (typeof options.space !== "string" || !options.space) {
      requestFail("space must be a nonempty string", "request/invalid-space");
    }
    const inspected = inspectFramRpcRequest(frame);
    if (inspected.operation === "rpc/checkpoint") {
      requestFail(
        "checkpoint is an operator capability, not a data-plane operation",
        "request/operator-capability",
      );
    }
    if (options.space !== this.spaceId || inspected.space !== this.spaceId) {
      requestFail("SpaceId does not belong to this object", "request/space-mismatch");
    }
    if (!entryAccepts(inspected.operation, options.entry)) {
      requestFail(
        `${inspected.operation} cannot use ${options.entry}`,
        "request/entry-mismatch",
      );
    }

    const result = options.entry === "transact"
      ? await this.transact(frame)
      : options.entry === "snapshot"
        ? await this.snapshot(frame)
        : await this.query(frame);
    if (result.status !== 0) {
      throw new FramExchangeError(result.status, result.message);
    }
    if (!(result.response instanceof Uint8Array)) {
      throw new FramExchangeError(result.status, "guest response is not bytes");
    }
    if (result.response.length > FRAMRPC_MAX_FRAME_BYTES) {
      throw new FramExchangeError(result.status, "guest response exceeds 1 MiB");
    }
    if (!result.released) {
      throw new FramExchangeError(result.status, "guest response buffer was not released");
    }
    return result.response;
  }

  /** Export the exact authoritative FRAMLOG after all earlier writes landed. */
  exportFramlog() {
    return this.#serialiseOperation(async () => {
      const instance = await this.fram();
      const point = await instance.portableFramlog();
      const { bytes } = point;
      const spaceId = parseFramlogHeader(bytes);
      if (spaceId !== this.spaceId) {
        backupFailure(
          "space-mismatch",
          `FRAMLOG belongs to SpaceId ${JSON.stringify(spaceId)}, not ` +
            JSON.stringify(this.spaceId),
        );
      }
      const sha256 = await sha256Hex(bytes);
      return Object.freeze({
        format: FRAMLOG_BACKUP_FORMAT,
        spaceId,
        servedVersion: point.servedVersion,
        byteLength: bytes.length,
        sha256,
        bytes,
      });
    });
  }

  /**
   * Atomically install one verified canonical FRAMLOG and discard the derived
   * image. The default accepts only storage with neither log nor image bytes;
   * replacing an existing database must be explicit.
   */
  restoreFramlog(backup, options = {}) {
    const captured = captureBackup(backup);
    const restore = this.#restoreOptions(options);
    return this.#serialiseOperation(async () => {
      const verified = await verifiedBackup(captured, this.spaceId);
      await this.#preflightFramlog(verified.bytes, verified.servedVersion);

      // A normal restore must be observationally harmless when the target is
      // already occupied. This first read avoids fencing a healthy live guest
      // merely to return the expected refusal. The final check after fencing
      // remains authoritative against a retained-instance race.
      if (!restore.replace) {
        const peek = await this.#loadTarget("inspect the restore target");
        if (
          peek.log.length !== 0 ||
          peek.imageOccupied ||
          peek.pending !== undefined
        ) {
          backupFailure(
            "target-not-empty",
            "restore target is not empty; replacement must be explicit",
          );
        }
      }

      await this.#fenceLiveForRestore();
      const previousFence = this.administrativeFence;
      let target;
      try {
        target = await this.#loadTarget("load the restore target");
        const occupied =
          target.log.length !== 0 ||
          target.imageOccupied ||
          target.pending !== undefined;
        if (occupied && !restore.replace) {
          backupFailure(
            "target-not-empty",
            "restore target became nonempty before publication",
          );
        }
        if (restore.replace) {
          const currentSha256 = await sha256Hex(target.log);
          if (
            target.log.length !== restore.expectedCurrent.byteLength ||
            currentSha256 !== restore.expectedCurrent.sha256
          ) {
            backupFailure(
              "conflict",
              "restore target changed after its replacement precondition was read",
            );
          }
        }
      } catch (error) {
        this.administrativeFence = previousFence?.code === "restore-fenced"
          ? previousFence
          : null;
        this.#drop();
        throw error;
      }

      try {
        await target.store.replace([
          {
            which: "log",
            bytes: verified.bytes,
            length: verified.bytes.length,
            lowWater: 0,
          },
          {
            which: "image",
            plan: target.imageClearPlan,
          },
        ], {
          format: FRAMLOG_RESTORE_FORMAT,
          spaceId: this.spaceId,
          servedVersion: verified.servedVersion,
          byteLength: verified.bytes.length,
          sha256: verified.digest,
        });
      } catch (error) {
        this.administrativeFence = previousFence?.code === "restore-fenced"
          ? previousFence
          : null;
        this.#drop();
        backupFailure(
          "storage",
          `the restore transaction was rejected: ${error.message}`,
          { cause: error },
        );
      }

      // Publication is now durable and cannot be rolled back safely. Keep the
      // object fenced until the exact bytes replay from DurableObjectStorage
      // and report the version declared by the backup.
      const marker = Object.freeze({
        format: FRAMLOG_RESTORE_FORMAT,
        spaceId: this.spaceId,
        servedVersion: verified.servedVersion,
        byteLength: verified.bytes.length,
        sha256: verified.digest,
      });
      const expectedCurrent = Object.freeze({
        byteLength: marker.byteLength,
        sha256: marker.sha256,
      });
      let reopened = null;
      try {
        reopened = await this.#bootForRestore();
        const point = await reopened.portableFramlog();
        if (!sameBytes(point.bytes, verified.bytes)) {
          backupFailure(
            "verification",
            "the published FRAMLOG did not reopen byte for byte",
          );
        }
        if (point.servedVersion !== verified.servedVersion) {
          backupFailure(
            "verification",
            "the published FRAMLOG reopened at an unexpected served version",
          );
        }
        await this.state.storage.transaction(async (txn) => {
          const pending = await txn.get(FRAMLOG_RESTORE_KEY);
          if (pending === undefined) return;
          if (!this.#sameRestoreMarker(pending, marker)) {
            backupFailure(
              "verification",
              "the pending restore marker changed before it could be cleared",
            );
          }
          await txn.delete(FRAMLOG_RESTORE_KEY);
        });
      } catch (error) {
        const fenced = restoreFence(marker, error);
        this.administrativeFence = fenced;
        if (reopened) await reopened.fence(fenced);
        this.#drop();
        throw fenced;
      }

      this.instance = reopened;
      this.administrativeFence = null;

      return Object.freeze({
        format: FRAMLOG_BACKUP_FORMAT,
        spaceId: this.spaceId,
        servedVersion: verified.servedVersion,
        byteLength: verified.bytes.length,
        sha256: verified.digest,
        replaced:
          target.log.length !== 0 ||
          target.imageOccupied ||
          target.pending !== undefined,
      });
    });
  }

  #restoreOptions(options) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      backupFailure("invalid-backup", "restore options must be an object");
    }
    const replace = options.replace ?? false;
    if (typeof replace !== "boolean") {
      backupFailure("invalid-backup", "restore options.replace must be boolean");
    }
    if (!replace) {
      exactObject(
        options,
        Object.hasOwn(options, "replace") ? ["replace"] : [],
        "restore options",
      );
      return { replace: false, expectedCurrent: null };
    }
    exactObject(options, ["expectedCurrent", "replace"], "restore options");
    return {
      replace: true,
      expectedCurrent: validateExpectedCurrent(options.expectedCurrent),
    };
  }

  async #preflightFramlog(bytes, expectedServedVersion) {
    const preflightStore = {
      async load(which) {
        return which === "log" ? bytes : new Uint8Array(0);
      },
      async commit(_parts) {},
    };
    let instance = null;
    try {
      instance = await FramInstance.instantiate(this.module, {
        ...this.instanceOptions,
        store: preflightStore,
      });
      const opened = await instance.open(this.spaceId, "restore-preflight");
      if (opened.status !== 0) {
        backupFailure(
          "invalid-framlog",
          `FRAMLOG replay failed: ${opened.status} ${opened.message}`,
        );
      }
      const point = await instance.portableFramlog();
      if (!sameBytes(point.bytes, bytes)) {
        backupFailure(
          "invalid-framlog",
          "FRAMLOG replay repaired or truncated the supplied byte string",
        );
      }
      if (point.servedVersion !== expectedServedVersion) {
        backupFailure(
          "verification",
          `backup servedVersion is ${expectedServedVersion}, but replay reports ` +
            point.servedVersion,
        );
      }
    } catch (error) {
      if (error instanceof FramBackupError) throw error;
      backupFailure(
        "engine",
        `cannot replay the backup through fram: ${error.message}`,
        { cause: error },
      );
    } finally {
      if (instance) {
        await instance.fence(
          new FramBackupError(
            "administrative-fence",
            "this Fram instance belonged to restore preflight",
          ),
        );
      }
    }
  }

  async #loadTarget(action) {
    const store = new DurableFramStore(this.state.storage, this.storeOptions);
    try {
      const log = await store.load("log");
      const imageClearPlan = await store.clearPlan("image");
      const pending = await this.state.storage.get(FRAMLOG_RESTORE_KEY);
      return {
        store,
        log,
        imageClearPlan,
        imageOccupied: imageClearPlan.stale.length !== 0,
        pending,
      };
    } catch (error) {
      backupFailure("storage", `cannot ${action}: ${error.message}`, {
        cause: error,
      });
    }
  }

  #sameRestoreMarker(left, right) {
    return (
      left &&
      typeof left === "object" &&
      left.format === right.format &&
      left.spaceId === right.spaceId &&
      left.servedVersion === right.servedVersion &&
      left.byteLength === right.byteLength &&
      left.sha256 === right.sha256 &&
      Object.keys(left).length === 5
    );
  }

  async #fenceLiveForRestore() {
    const fenced = new FramBackupError(
      "administrative-fence",
      "this Fram instance was fenced for a FRAMLOG restore",
    );
    const existingFence = this.administrativeFence;
    this.administrativeFence = existingFence ?? fenced;
    let live = this.instance;
    if (!live && this.booting) {
      try {
        live = await this.booting;
      } catch (_error) {
        // A failed boot has no live guest to retain. Restore is the recovery
        // path for storage whose current bytes cannot open.
      }
    }
    if (live) await live.fence(this.administrativeFence);
    this.#drop();
  }

  #serialiseOperation(body) {
    const result = this.operations.then(body, body);
    this.operations = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  #use(body) {
    return this.#serialiseOperation(async () => {
      const instance = await this.fram();
      try {
        return await body(instance);
      } catch (error) {
        // A fenced instance holds bytes no one can place against storage; drop it
        // so the next request reopens from what is actually durable.
        if (instance.poisoned) this.#drop();
        throw error;
      }
    });
  }

  #drop() {
    this.instance = null;
    this.booting = null;
    this.store = null;
  }

  /** Drop the guest without touching storage; the next call reopens from it. */
  recycle() {
    return this.#serialiseOperation(async () => {
      const instance = this.instance;
      this.#drop();
      if (instance && !instance.closed && !instance.poisoned) {
        return instance.close();
      }
      return null;
    });
  }
}

/**
 * A WorkerEntrypoint/service-binding facade whose public surface is exactly
 * `exchange`. Pass the backend Worker's private raw DO namespace; never bind
 * that namespace into an application Worker.
 */
export function framDataPlaneEntrypoint(namespace, spaceId) {
  if (!namespace || (typeof namespace !== "object"
      && typeof namespace !== "function")) {
    throw new TypeError("Fram data plane requires a Durable Object namespace");
  }
  if (typeof spaceId !== "string" || !spaceId) {
    throw new TypeError("Fram data plane spaceId must be a nonempty string");
  }
  if (textEncoder.encode(spaceId).length > FRAM_DO_MAX_NAMED_SPACE_BYTES) {
    throw new TypeError("Fram data plane spaceId exceeds 1024 UTF-8 bytes");
  }
  const object = () => namespace.getByName(spaceId);
  return Object.freeze({
    exchange(frame, options) {
      return object().exchange(frame, options);
    },
  });
}

/**
 * Administrative service-binding facade for the same storage-owning object.
 * Bind this separately from the exchange-only data plane and enforce the
 * application's administrator policy before invoking either method.
 */
export function framAdminEntrypoint(namespace, spaceId) {
  if (!namespace || (typeof namespace !== "object"
      && typeof namespace !== "function")) {
    throw new TypeError("Fram administration requires a Durable Object namespace");
  }
  if (typeof spaceId !== "string" || !spaceId) {
    throw new TypeError("Fram administration spaceId must be a nonempty string");
  }
  if (textEncoder.encode(spaceId).length > FRAM_DO_MAX_NAMED_SPACE_BYTES) {
    throw new TypeError("Fram administration spaceId exceeds 1024 UTF-8 bytes");
  }
  const object = () => namespace.getByName(spaceId);
  return Object.freeze({
    exportFramlog() {
      return object().exportFramlog();
    },
    restoreFramlog(backup, options) {
      return object().restoreFramlog(backup, options);
    },
  });
}

export function nowHiRes() {
  // Local workerd advances this during pure CPU; deployed Workers documents a
  // clock that only moves at I/O, so in-isolate deltas are not portable.
  return typeof performance !== "undefined" && performance.now
    ? performance.now()
    : Date.now();
}

export function hex(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}
