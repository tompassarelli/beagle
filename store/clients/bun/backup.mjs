import { constants } from 'fs';
import {
  lstat,
  mkdir,
  open,
  readdir,
  rename,
} from 'fs/promises';
import { basename, dirname, isAbsolute, join, resolve } from 'path';
import { storeNativeCheckpoint } from './store-rpc.mjs';

const LOG_MAGIC = Buffer.from('STORELOG', 'ascii');
const SNAPSHOT_MAGIC = Buffer.from('store-snapshot/v1', 'ascii');
const LOG_FIXED_HEADER_BYTES = 16;
const MAX_SPACE_BYTES = 4096;
const MAX_MANIFEST_BYTES = 1024 * 1024;
const MAX_RECEIPT_BYTES = 64 * 1024;
const MAX_SNAPSHOT_RECORD_BYTES = 1024 * 1024;
const MAX_SNAPSHOT_LOG_LABELS = 64;
const I64_MAX = (1n << 63n) - 1n;
const U32_MAX = (1n << 32n) - 1n;
const SAFE_MAX = BigInt(Number.MAX_SAFE_INTEGER);
const O_NOFOLLOW = constants.O_NOFOLLOW ?? 0;
const BACKUP_FORMAT = 'beagle-store-backup/v1';
const HISTORY_FILE = 'history.storelog';
const ARTIFACT_FILE = 'artifact.READY';
const MANIFEST_FILE = 'manifest.json';
const MANIFEST_DIGEST_FILE = 'manifest.sha256';
const COMPLETE_FILES = Object.freeze([
  ARTIFACT_FILE,
  HISTORY_FILE,
  MANIFEST_FILE,
  MANIFEST_DIGEST_FILE,
]);
const DECIMAL = /^(?:0|[1-9][0-9]*)$/;
const SHA256 = /^[0-9a-f]{64}$/;
const ARTIFACT_RECEIPT = /^beagle-store-native-build\/v1 ([0-9a-f]{64})\n$/;
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

export class StoreBackupError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'StoreBackupError';
    this.code = code;
  }
}

function fail(code, message, options) {
  throw new StoreBackupError(code, message, options);
}

function strictUtf8(value, maximum, label) {
  if (typeof value !== 'string') fail('invalid-input', `${label} must be a string`);
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        fail('invalid-utf8', `${label} contains an unpaired UTF-16 surrogate`);
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      fail('invalid-utf8', `${label} contains an unpaired UTF-16 surrogate`);
    }
  }
  const bytes = Buffer.from(value, 'utf8');
  if (bytes.length === 0) fail('invalid-input', `${label} must be nonempty`);
  if (bytes.length > maximum) fail('limit', `${label} exceeds ${maximum} UTF-8 bytes`);
  return bytes;
}

function canonicalDecimal(value, label, maximum = I64_MAX) {
  const text = typeof value === 'bigint' ? value.toString() : value;
  if (typeof text !== 'string' || !DECIMAL.test(text)) {
    fail('invalid-manifest', `${label} must be a canonical nonnegative decimal string`);
  }
  const parsed = BigInt(text);
  if (parsed > maximum) fail('invalid-manifest', `${label} is out of range`);
  return text;
}

function exactObject(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail('invalid-manifest', `${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail('invalid-manifest', `${label} fields do not match ${expected.join(', ')}`);
  }
  return value;
}

function canonicalJsonValue(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') {
    const encoded = JSON.stringify(value);
    if (typeof encoded !== 'string') fail('invalid-manifest', 'canonical JSON string encoding failed');
    return encoded.replace(/[\u007f-\uffff]/g, character => {
      const code = character.charCodeAt(0);
      return code >= 0xd800 && code <= 0xdfff
        ? character
        : `\\u${code.toString(16).padStart(4, '0')}`;
    });
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJsonValue).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => (
      `${canonicalJsonValue(key)}:${canonicalJsonValue(value[key])}`
    )).join(',')}}`;
  }
  fail('invalid-manifest', 'canonical JSON accepts only null, booleans, strings, arrays, and objects');
}

export function canonicalManifestBytes(manifest) {
  return Buffer.from(`${canonicalJsonValue(manifest)}\n`, 'utf8');
}

function sha256(bytes) {
  return new Bun.CryptoHasher('sha256').update(bytes).digest('hex');
}

async function openRegular(path, label) {
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | O_NOFOLLOW);
    const stat = await handle.stat({ bigint: true });
    if (!stat.isFile()) fail('unsafe-path', `${label} is not a regular file`);
    return { handle, stat };
  } catch (error) {
    await handle?.close().catch(() => {});
    if (error instanceof StoreBackupError) throw error;
    fail('file-open', `cannot open ${label} ${path}: ${error.message}`, { cause: error });
  }
}

async function readHandleExact(handle, size, label, maximum) {
  if (size > BigInt(maximum) || size > SAFE_MAX) fail('limit', `${label} is too large`);
  const bytes = Buffer.alloc(Number(size));
  let offset = 0;
  while (offset < bytes.length) {
    const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset);
    if (bytesRead === 0) fail('file-changed', `${label} ended while it was being read`);
    offset += bytesRead;
  }
  return bytes;
}

async function readAtExact(handle, position, count, label) {
  if (!Number.isSafeInteger(position) || position < 0
      || !Number.isSafeInteger(count) || count < 0) {
    fail('limit', `${label} offset is outside the host file API range`);
  }
  const bytes = Buffer.alloc(count);
  let offset = 0;
  while (offset < count) {
    const { bytesRead } = await handle.read(bytes, offset, count - offset, position + offset);
    if (bytesRead === 0) fail('file-changed', `${label} ended while it was being read`);
    offset += bytesRead;
  }
  return bytes;
}

async function readRegular(path, label, maximum) {
  const { handle, stat } = await openRegular(path, label);
  try {
    return await readHandleExact(handle, stat.size, label, maximum);
  } finally {
    await handle.close();
  }
}

async function writeSynced(path, bytes, mode = 0o600) {
  const handle = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, mode);
  try {
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset, offset);
      if (bytesWritten === 0) fail('file-write', `write made no progress for ${path}`);
      offset += bytesWritten;
    }
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function syncDirectory(path) {
  const handle = await open(path, constants.O_RDONLY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function copyPrefix(source, target, count) {
  if (count > SAFE_MAX) fail('limit', 'checkpoint cutoff exceeds the host file API range');
  const targetHandle = await open(
    target,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
    0o600,
  );
  const digest = new Bun.CryptoHasher('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const total = Number(count);
  let offset = 0;
  try {
    while (offset < total) {
      const wanted = Math.min(buffer.length, total - offset);
      const { bytesRead } = await source.read(buffer, 0, wanted, offset);
      if (bytesRead === 0) fail('file-changed', 'Store transaction log ended before the checkpoint cutoff');
      let written = 0;
      while (written < bytesRead) {
        const result = await targetHandle.write(buffer, written, bytesRead - written, offset + written);
        if (result.bytesWritten === 0) fail('file-write', `write made no progress for ${target}`);
        written += result.bytesWritten;
      }
      digest.update(buffer.subarray(0, bytesRead));
      offset += bytesRead;
    }
    await targetHandle.sync();
  } finally {
    await targetHandle.close();
  }
  return digest.digest('hex');
}

async function parseLogHeader(handle, size, label) {
  if (size < BigInt(LOG_FIXED_HEADER_BYTES)) fail('invalid-log', `${label} has a truncated header`);
  const fixed = await readHandleExact(handle, BigInt(LOG_FIXED_HEADER_BYTES), `${label} header`, LOG_FIXED_HEADER_BYTES);
  if (!fixed.subarray(0, 8).equals(LOG_MAGIC)) fail('invalid-log', `${label} magic does not match STORELOG`);
  if (fixed.readUInt16LE(8) !== 1 || fixed.readUInt16LE(10) !== 0) {
    fail('invalid-log', `${label} version or flags are unsupported`);
  }
  const length = fixed.readUInt32LE(12);
  if (length === 0 || length > MAX_SPACE_BYTES) fail('invalid-log', `${label} SpaceId length is invalid`);
  const headerBytes = BigInt(LOG_FIXED_HEADER_BYTES + length);
  if (size < headerBytes) fail('invalid-log', `${label} is truncated inside SpaceId`);
  const spaceBytes = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const { bytesRead } = await handle.read(spaceBytes, offset, length - offset, LOG_FIXED_HEADER_BYTES + offset);
    if (bytesRead === 0) fail('file-changed', `${label} ended inside SpaceId`);
    offset += bytesRead;
  }
  let spaceId;
  try {
    spaceId = utf8Decoder.decode(spaceBytes);
  } catch (error) {
    fail('invalid-log', `${label} SpaceId is not valid UTF-8`, { cause: error });
  }
  if (!spaceId) fail('invalid-log', `${label} SpaceId is empty`);
  return { spaceId, headerBytes };
}

function snapshotI64(bytes, offset, label) {
  const value = bytes.readBigInt64LE(offset);
  if (value < 0n) fail('checkpoint-mismatch', `${label} is negative`);
  return value;
}

async function verifyCheckpointSnapshot(logPath, point, spaceId) {
  const snapshotPath = `${logPath}.snapshot`;
  const snapshot = await openRegular(snapshotPath, 'checkpoint snapshot');
  try {
    if (snapshot.stat.size !== point.snapshotBytes || snapshot.stat.size > SAFE_MAX) {
      fail('checkpoint-mismatch', 'checkpoint snapshot byte count does not match its receipt');
    }
    const fixed = await readAtExact(snapshot.handle, 0, 24, 'checkpoint snapshot header');
    if (!fixed.subarray(0, 16).equals(SNAPSHOT_MAGIC)
        || fixed.readUInt16LE(16) !== 1 || fixed.readUInt16LE(18) !== 0) {
      fail('checkpoint-mismatch', 'checkpoint snapshot header is unsupported');
    }
    const spaceLength = fixed.readUInt32LE(20);
    if (spaceLength === 0 || spaceLength > MAX_SPACE_BYTES) {
      fail('checkpoint-mismatch', 'checkpoint snapshot SpaceId length is invalid');
    }
    const variable = await readAtExact(
      snapshot.handle,
      24,
      spaceLength + 8,
      'checkpoint snapshot identity',
    );
    let snapshotSpace;
    try {
      snapshotSpace = utf8Decoder.decode(variable.subarray(0, spaceLength));
    } catch (error) {
      fail('checkpoint-mismatch', 'checkpoint snapshot SpaceId is not valid UTF-8', { cause: error });
    }
    const nextSequence = variable.readBigInt64LE(spaceLength);
    if (snapshotSpace !== spaceId || nextSequence !== point.servedVersion + 1n) {
      fail('checkpoint-mismatch', 'checkpoint snapshot identity or version does not match its receipt');
    }
    const imageStart = 24 + spaceLength + 8;
    let position = imageStart;
    let trailerPosition = -1;
    let trailer = null;
    while (BigInt(position) < snapshot.stat.size) {
      const lengthBytes = await readAtExact(snapshot.handle, position, 4, 'snapshot record length');
      const length = lengthBytes.readUInt32LE(0);
      if (length === 0 || length > MAX_SNAPSHOT_RECORD_BYTES) {
        fail('checkpoint-mismatch', 'checkpoint snapshot record length is invalid');
      }
      const end = position + 4 + length + 4;
      if (!Number.isSafeInteger(end) || BigInt(end) > snapshot.stat.size) {
        fail('checkpoint-mismatch', 'checkpoint snapshot record crosses end of file');
      }
      if (BigInt(end) === snapshot.stat.size) {
        trailerPosition = position;
        trailer = await readAtExact(snapshot.handle, position + 4, length + 4, 'snapshot trailer');
      }
      position = end;
    }
    if (BigInt(position) !== snapshot.stat.size || trailerPosition < 0 || trailer === null) {
      fail('checkpoint-mismatch', 'checkpoint snapshot has no complete final record');
    }
    const payload = trailer.subarray(0, trailer.length - 4);
    if (Bun.hash.crc32(payload) !== trailer.readUInt32LE(trailer.length - 4)) {
      fail('checkpoint-mismatch', 'checkpoint snapshot trailer CRC does not match');
    }
    let offset = 0;
    const take = (count, label) => {
      if (offset + count > payload.length) fail('checkpoint-mismatch', `snapshot trailer ended inside ${label}`);
      const start = offset;
      offset += count;
      return start;
    };
    if (payload.readUInt8(take(1, 'record kind')) !== 5) {
      fail('checkpoint-mismatch', 'checkpoint snapshot final record is not its sidecar');
    }
    const sequence = snapshotI64(payload, take(8, 'sequence'), 'snapshot sequence');
    const watermark = snapshotI64(payload, take(8, 'watermark'), 'snapshot watermark');
    const labelCount = payload.readUInt32LE(take(4, 'log label count'));
    if (labelCount !== 1 || labelCount > MAX_SNAPSHOT_LOG_LABELS) {
      fail('checkpoint-mismatch', 'checkpoint snapshot does not name one canonical log');
    }
    const labelLength = payload.readUInt32LE(take(4, 'log label length'));
    if (labelLength === 0 || labelLength > MAX_SPACE_BYTES) {
      fail('checkpoint-mismatch', 'checkpoint snapshot log label length is invalid');
    }
    let logLabel;
    try {
      const start = take(labelLength, 'log label');
      logLabel = utf8Decoder.decode(payload.subarray(start, start + labelLength));
    } catch (error) {
      fail('checkpoint-mismatch', 'checkpoint snapshot log label is not valid UTF-8', { cause: error });
    }
    const declaredImageStart = snapshotI64(payload, take(8, 'image start'), 'snapshot image start');
    const declaredImageEnd = snapshotI64(payload, take(8, 'image end'), 'snapshot image end');
    const stamp = snapshotI64(payload, take(8, 'stamp'), 'snapshot stamp');
    const fingerprint = payload.readUInt32LE(take(4, 'fingerprint'));
    if (offset !== payload.length
        || sequence !== point.servedVersion
        || watermark !== point.watermarkBytes
        || logLabel !== spaceId
        || declaredImageStart !== BigInt(imageStart)
        || declaredImageEnd !== BigInt(trailerPosition)
        || stamp !== point.createdAtUnixMs
        || BigInt(fingerprint) !== point.snapshotCrc32) {
      fail('checkpoint-mismatch', 'checkpoint snapshot sidecar does not match its receipt or supplied STORELOG path');
    }
  } finally {
    await snapshot.handle.close();
  }
}

function artifactReceipt(bytes) {
  let text;
  try {
    text = utf8Decoder.decode(bytes);
  } catch (error) {
    fail('artifact-receipt', 'artifact receipt is not valid UTF-8', { cause: error });
  }
  const match = ARTIFACT_RECEIPT.exec(text);
  if (!match) fail('artifact-receipt', 'artifact receipt is not a canonical beagle-store-native-build/v1 READY receipt');
  return { format: 'beagle-store-native-build/v1', closureSha256: match[1] };
}

function validateManifest(manifest) {
  exactObject(manifest, ['artifactReceipt', 'checkpoint', 'format', 'history', 'servedVersion', 'spaceId'], 'manifest');
  if (manifest.format !== BACKUP_FORMAT) fail('invalid-manifest', `manifest.format must be ${BACKUP_FORMAT}`);
  strictUtf8(manifest.spaceId, MAX_SPACE_BYTES, 'manifest.spaceId');
  canonicalDecimal(manifest.servedVersion, 'manifest.servedVersion');
  exactObject(manifest.history, ['bytes', 'file', 'sha256'], 'manifest.history');
  if (manifest.history.file !== HISTORY_FILE) fail('invalid-manifest', `history.file must be ${HISTORY_FILE}`);
  canonicalDecimal(manifest.history.bytes, 'manifest.history.bytes');
  if (!SHA256.test(manifest.history.sha256)) fail('invalid-manifest', 'manifest.history.sha256 is invalid');
  exactObject(
    manifest.checkpoint,
    ['createdAtUnixMs', 'snapshotBytes', 'snapshotCrc32', 'watermarkBytes'],
    'manifest.checkpoint',
  );
  canonicalDecimal(manifest.checkpoint.createdAtUnixMs, 'manifest.checkpoint.createdAtUnixMs');
  canonicalDecimal(manifest.checkpoint.snapshotBytes, 'manifest.checkpoint.snapshotBytes');
  canonicalDecimal(manifest.checkpoint.snapshotCrc32, 'manifest.checkpoint.snapshotCrc32', U32_MAX);
  canonicalDecimal(manifest.checkpoint.watermarkBytes, 'manifest.checkpoint.watermarkBytes');
  if (manifest.checkpoint.watermarkBytes !== manifest.history.bytes) {
    fail('invalid-manifest', 'checkpoint watermark does not equal history byte count');
  }
  exactObject(
    manifest.artifactReceipt,
    ['bytes', 'closureSha256', 'file', 'format', 'sha256'],
    'manifest.artifactReceipt',
  );
  if (manifest.artifactReceipt.file !== ARTIFACT_FILE) {
    fail('invalid-manifest', `artifactReceipt.file must be ${ARTIFACT_FILE}`);
  }
  if (manifest.artifactReceipt.format !== 'beagle-store-native-build/v1') {
    fail('invalid-manifest', 'artifactReceipt.format is unsupported');
  }
  canonicalDecimal(manifest.artifactReceipt.bytes, 'manifest.artifactReceipt.bytes');
  if (!SHA256.test(manifest.artifactReceipt.closureSha256)
      || !SHA256.test(manifest.artifactReceipt.sha256)) {
    fail('invalid-manifest', 'artifactReceipt hashes are invalid');
  }
  return manifest;
}

async function hashRegular(path, label, expectedBytes, maximum = SAFE_MAX) {
  const { handle, stat } = await openRegular(path, label);
  try {
    if (stat.size !== expectedBytes) fail('verification', `${label} byte count does not match the manifest`);
    if (stat.size > maximum || stat.size > SAFE_MAX) fail('limit', `${label} is too large to verify`);
    const digest = new Bun.CryptoHasher('sha256');
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    let offset = 0n;
    while (offset < stat.size) {
      const wanted = Number(stat.size - offset > BigInt(buffer.length) ? BigInt(buffer.length) : stat.size - offset);
      const { bytesRead } = await handle.read(buffer, 0, wanted, Number(offset));
      if (bytesRead === 0) fail('file-changed', `${label} ended while it was being hashed`);
      digest.update(buffer.subarray(0, bytesRead));
      offset += BigInt(bytesRead);
    }
    return { digest: digest.digest('hex'), handle, stat };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

export async function createBackup(options) {
  const output = resolve(options.output);
  const logPath = resolve(options.log);
  const receiptPath = resolve(options.artifactReceipt);
  const spaceId = options.spaceId;
  strictUtf8(spaceId, MAX_SPACE_BYTES, 'SpaceId');
  if (output === logPath || output === receiptPath) fail('unsafe-path', 'backup output must differ from every input');
  try {
    await lstat(output);
    fail('output-exists', `backup output already exists: ${output}`);
  } catch (error) {
    if (error instanceof StoreBackupError) throw error;
    if (error.code !== 'ENOENT') fail('file-open', `cannot inspect backup output ${output}: ${error.message}`);
  }

  const source = await openRegular(logPath, 'Store transaction log');
  let outputCreated = false;
  try {
    const header = await parseLogHeader(source.handle, source.stat.size, 'Store transaction log');
    if (header.spaceId !== spaceId) {
      fail('space-mismatch', `Store transaction log belongs to SpaceId ${JSON.stringify(header.spaceId)}, not ${JSON.stringify(spaceId)}`);
    }
    const receiptBytes = await readRegular(receiptPath, 'artifact receipt', MAX_RECEIPT_BYTES);
    const receipt = artifactReceipt(receiptBytes);
    const point = await storeNativeCheckpoint({
      host: options.host,
      port: options.port,
      space: spaceId,
      requestTimeoutMs: options.timeoutMs,
    });
    try {
      await verifyCheckpointSnapshot(logPath, point, spaceId);
    } catch (error) {
      if (error instanceof StoreBackupError) throw error;
      fail('checkpoint-mismatch', `cannot verify checkpoint snapshot: ${error.message}`, { cause: error });
    }
    const afterCheckpoint = await source.handle.stat({ bigint: true });
    if (!afterCheckpoint.isFile() || point.watermarkBytes < header.headerBytes
        || point.watermarkBytes > afterCheckpoint.size) {
      fail('checkpoint-mismatch', 'checkpoint cutoff is outside the supplied Store transaction log');
    }

    try {
      await mkdir(output, { mode: 0o700 });
    } catch (error) {
      if (error.code === 'EEXIST') fail('output-exists', `backup output already exists: ${output}`);
      fail('file-write', `cannot create backup output ${output}: ${error.message}`, { cause: error });
    }
    outputCreated = true;
    const historySha256 = await copyPrefix(
      source.handle,
      join(output, HISTORY_FILE),
      point.watermarkBytes,
    );
    const finalSource = await source.handle.stat({ bigint: true });
    if (!finalSource.isFile() || finalSource.size < point.watermarkBytes) {
      fail('file-changed', 'Store transaction log changed below the checkpoint cutoff during backup');
    }
    await writeSynced(join(output, ARTIFACT_FILE), receiptBytes);

    const manifest = validateManifest({
      artifactReceipt: {
        bytes: String(receiptBytes.length),
        closureSha256: receipt.closureSha256,
        file: ARTIFACT_FILE,
        format: receipt.format,
        sha256: sha256(receiptBytes),
      },
      checkpoint: {
        createdAtUnixMs: point.createdAtUnixMs.toString(),
        snapshotBytes: point.snapshotBytes.toString(),
        snapshotCrc32: point.snapshotCrc32.toString(),
        watermarkBytes: point.watermarkBytes.toString(),
      },
      format: BACKUP_FORMAT,
      history: {
        bytes: point.watermarkBytes.toString(),
        file: HISTORY_FILE,
        sha256: historySha256,
      },
      servedVersion: point.servedVersion.toString(),
      spaceId,
    });
    const manifestBytes = canonicalManifestBytes(manifest);
    const manifestSha256 = sha256(manifestBytes);
    await writeSynced(
      join(output, MANIFEST_DIGEST_FILE),
      Buffer.from(`${manifestSha256}  ${MANIFEST_FILE}\n`, 'ascii'),
    );
    await syncDirectory(output);
    const temporaryManifest = join(output, `.${MANIFEST_FILE}.${process.pid}.tmp`);
    await writeSynced(temporaryManifest, manifestBytes);
    await rename(temporaryManifest, join(output, MANIFEST_FILE));
    await syncDirectory(output);
    await syncDirectory(dirname(output));
    return Object.freeze({
      format: 'beagle-store-backup/create-receipt/v1',
      output,
      manifestSha256,
      spaceId,
      servedVersion: manifest.servedVersion,
      historyBytes: manifest.history.bytes,
      historySha256,
    });
  } catch (error) {
    if (outputCreated) {
      const suffix = `; incomplete output was left at ${output}`;
      if (error instanceof StoreBackupError) {
        throw new StoreBackupError(error.code, `${error.message}${suffix}`, { cause: error });
      }
      throw new StoreBackupError('backup-failed', `${error.message}${suffix}`, { cause: error });
    }
    if (error instanceof StoreBackupError) throw error;
    throw new StoreBackupError('backup-failed', error.message, { cause: error });
  } finally {
    await source.handle.close();
  }
}

export async function verifyBackup(options) {
  const backup = resolve(options.backup);
  let entries;
  try {
    entries = await readdir(backup, { withFileTypes: true });
  } catch (error) {
    fail('file-open', `cannot read backup directory ${backup}: ${error.message}`, { cause: error });
  }
  const names = entries.map(entry => entry.name).sort();
  if (names.length !== COMPLETE_FILES.length
      || names.some((name, index) => name !== COMPLETE_FILES[index])) {
    fail('verification', `backup files do not match ${COMPLETE_FILES.join(', ')}`);
  }
  if (entries.some(entry => !entry.isFile())) fail('verification', 'every backup entry must be a regular file');
  const manifestBytes = await readRegular(join(backup, MANIFEST_FILE), 'manifest', MAX_MANIFEST_BYTES);
  let manifest;
  try {
    manifest = JSON.parse(utf8Decoder.decode(manifestBytes));
  } catch (error) {
    fail('invalid-manifest', `manifest is not strict UTF-8 JSON: ${error.message}`, { cause: error });
  }
  validateManifest(manifest);
  if (!manifestBytes.equals(canonicalManifestBytes(manifest))) {
    fail('invalid-manifest', 'manifest is not in canonical JSON form');
  }
  const manifestSha256 = sha256(manifestBytes);
  const digestBytes = await readRegular(join(backup, MANIFEST_DIGEST_FILE), 'manifest digest', 256);
  const expectedDigestBytes = Buffer.from(`${manifestSha256}  ${MANIFEST_FILE}\n`, 'ascii');
  if (!digestBytes.equals(expectedDigestBytes)) fail('verification', 'manifest.sha256 does not match manifest.json');
  if (options.spaceId !== undefined && options.spaceId !== manifest.spaceId) {
    fail('space-mismatch', `backup belongs to SpaceId ${JSON.stringify(manifest.spaceId)}, not ${JSON.stringify(options.spaceId)}`);
  }

  const historyBytes = BigInt(manifest.history.bytes);
  const history = await hashRegular(join(backup, HISTORY_FILE), 'backup Store transaction log', historyBytes);
  try {
    if (history.digest !== manifest.history.sha256) fail('verification', 'backup Store transaction log hash does not match the manifest');
    const header = await parseLogHeader(history.handle, history.stat.size, 'backup Store transaction log');
    if (header.spaceId !== manifest.spaceId) fail('space-mismatch', 'backup Store transaction log SpaceId does not match the manifest');
  } finally {
    await history.handle.close();
  }

  const receiptBytes = BigInt(manifest.artifactReceipt.bytes);
  const receipt = await hashRegular(
    join(backup, ARTIFACT_FILE),
    'artifact receipt',
    receiptBytes,
    BigInt(MAX_RECEIPT_BYTES),
  );
  try {
    if (receipt.digest !== manifest.artifactReceipt.sha256) {
      fail('verification', 'artifact receipt hash does not match the manifest');
    }
    const bytes = await readHandleExact(receipt.handle, receipt.stat.size, 'artifact receipt', MAX_RECEIPT_BYTES);
    const parsed = artifactReceipt(bytes);
    if (parsed.closureSha256 !== manifest.artifactReceipt.closureSha256) {
      fail('verification', 'artifact closure hash does not match the manifest');
    }
  } finally {
    await receipt.handle.close();
  }

  return Object.freeze({
    format: 'beagle-store-backup/verify-receipt/v1',
    backup,
    manifestSha256,
    spaceId: manifest.spaceId,
    servedVersion: manifest.servedVersion,
    historyBytes: manifest.history.bytes,
    historySha256: manifest.history.sha256,
  });
}

const HELP = `Usage:
  beagle-store-backup create --output DIR --log FILE --artifact-receipt FILE --space-id SPACE [options]
  beagle-store-backup verify --backup DIR [--space-id SPACE]

Create options:
  --host HOST          Beagle Store server host (default: BEAGLE_STORE_SERVER_CONNECT or 127.0.0.1)
  --port PORT          Beagle Store server port (default: BEAGLE_STORE_SERVER_PORT or 7977)
  --timeout-ms MS      Checkpoint timeout (default: 15000)

The create command copies the exact durable Store transaction log prefix returned by the
native rpc/checkpoint operator operation. manifest.json is the atomic commit
point. The snapshot image is derived state and is intentionally not backed up.
`;

function commandOptions(args, allowed) {
  const values = {};
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (!flag.startsWith('--') || !allowed.includes(flag)) fail('usage', `unknown option ${flag}`);
    if (Object.hasOwn(values, flag)) fail('usage', `option ${flag} was provided more than once`);
    const value = args[++index];
    if (value === undefined || value.startsWith('--')) fail('usage', `option ${flag} requires a value`);
    values[flag] = value;
  }
  return values;
}

function requiredOption(values, flag) {
  if (!Object.hasOwn(values, flag) || values[flag] === '') fail('usage', `${flag} is required`);
  return values[flag];
}

function pathOption(value, flag) {
  if (!isAbsolute(value)) fail('usage', `${flag} must be an absolute path`);
  if (basename(value) === '' || value === '/') fail('unsafe-path', `${flag} must not name the filesystem root`);
  return value;
}

function integerOption(value, flag, minimum, maximum) {
  if (!DECIMAL.test(value)) fail('usage', `${flag} must be a canonical decimal integer`);
  const parsed = BigInt(value);
  if (parsed < BigInt(minimum) || parsed > BigInt(maximum)) fail('usage', `${flag} is out of range`);
  return Number(parsed);
}

function printReceipt(receipt) {
  process.stdout.write(canonicalManifestBytes(receipt));
}

export async function runCli(args = process.argv.slice(2), environment = process.env) {
  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    process.stdout.write(HELP);
    return;
  }
  const command = args[0];
  if (command === 'create') {
    const values = commandOptions(args.slice(1), [
      '--output', '--log', '--artifact-receipt', '--space-id', '--host', '--port', '--timeout-ms',
    ]);
    const spaceId = values['--space-id'] ?? environment.BEAGLE_STORE_SPACE_ID;
    if (!spaceId) fail('usage', '--space-id or BEAGLE_STORE_SPACE_ID is required');
    const receipt = await createBackup({
      output: pathOption(requiredOption(values, '--output'), '--output'),
      log: pathOption(requiredOption(values, '--log'), '--log'),
      artifactReceipt: pathOption(requiredOption(values, '--artifact-receipt'), '--artifact-receipt'),
      spaceId,
      host: values['--host'] ?? environment.BEAGLE_STORE_SERVER_CONNECT ?? '127.0.0.1',
      port: integerOption(values['--port'] ?? environment.BEAGLE_STORE_SERVER_PORT ?? '7977', '--port', 1, 65535),
      timeoutMs: integerOption(values['--timeout-ms'] ?? '15000', '--timeout-ms', 1, 600000),
    });
    printReceipt(receipt);
    return;
  }
  if (command === 'verify') {
    const values = commandOptions(args.slice(1), ['--backup', '--space-id']);
    const receipt = await verifyBackup({
      backup: pathOption(requiredOption(values, '--backup'), '--backup'),
      spaceId: values['--space-id'],
    });
    printReceipt(receipt);
    return;
  }
  fail('usage', `unknown command ${command}`);
}
