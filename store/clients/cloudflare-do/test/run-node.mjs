// SPDX-License-Identifier: MIT OR Apache-2.0
// The durability half of the harness, in plain Node over the memory storage:
// what a lost isolate, a rejected commit, and a shrinking object leave behind.
//
//   node test/run-node.mjs WASM PACKETS-DIR
import { readFileSync } from "node:fs";
import {
  ChunkedRange,
  DurableStoreStore,
  StoreDurableObjectBase,
  StoreRequestError,
  StoreInstance,
  MemoryStorage,
  inspectStoreRpcRequest,
  storeAdminEntrypoint,
  storeDataPlaneEntrypoint,
} from "../src/adapter.mjs";

const [wasmPath, packetsDir] = process.argv.slice(2);
const SPACE = "store-wasm-embed";
const module = new WebAssembly.Module(readFileSync(wasmPath));
const packet = (name) => new Uint8Array(readFileSync(`${packetsDir}/${name}`));
const objectState = (storage, spaceId = SPACE) => ({
  storage,
  id: { name: spaceId },
});

const failures = [];
const notes = [];

function check(condition, detail) {
  if (condition) {
    notes.push(`  ok   ${detail}`);
  } else {
    failures.push(detail);
    notes.push(`  FAIL ${detail}`);
  }
}

async function open(store) {
  const instance = await StoreInstance.instantiate(module, {
    store,
    nowMs: () => 1700000000000,
    arena: { initialPages: 8 },
  });
  const opened = await instance.open(SPACE, "in-memory");
  if (opened.status !== 0) {
    throw new Error(`open failed ${opened.status} ${opened.message}`);
  }
  return instance;
}

const durableLog = (storage) =>
  new ChunkedRange(storage, { prefix: "storelog/" }).load();

function samePrefix(shorter, longer) {
  return shorter.every((byte, index) => byte === longer[index]);
}

function sameBytes(left, right) {
  return left.length === right.length && samePrefix(left, right);
}

const durableImage = (storage) =>
  new ChunkedRange(storage, { prefix: "storeimage/" }).load();

async function sha256(bytes) {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function backupWithBytes(backup, bytes) {
  return {
    ...backup,
    byteLength: bytes.length,
    sha256: await sha256(bytes),
    bytes,
  };
}

class FailPostPublishStorage extends MemoryStorage {
  constructor() {
    super();
    this.failNextMarkerClear = false;
  }

  async transaction(body) {
    if (this.failNextMarkerClear && this.map.has("storerestore/pending")) {
      this.failNextMarkerClear = false;
      throw new Error("restore marker delete said no");
    }
    return super.transaction(body);
  }
}

// -- 1. a lost isolate leaves a SHORT log, never a torn one ------------------
{
  const storage = new MemoryStorage();
  let store = await open(new DurableStoreStore(storage));
  await store.transact(packet("03-assert-unicode.bin"));
  await store.transact(packet("04-batch-mixed.bin"));
  const landed = await durableLog(storage);

  // The isolate is "dead": the guest still sees storage_sync return 0 and
  // appends into host memory, but no commit is ever acknowledged.
  const doomed = new DurableStoreStore(storage);
  doomed.commit = () => Promise.resolve();
  store = await open(doomed);
  const lost = await store.transact(packet("12-retract.bin"));
  const believed = store.log.length;
  const after = await durableLog(storage);

  check(lost.status === 0, "the guest was answered by the doomed isolate");
  check(
    after.length === landed.length && samePrefix(after, landed),
    `the durable log is unchanged at ${after.length} bytes ` +
      `(the guest believed ${believed})`,
  );

  const reborn = await open(new DurableStoreStore(storage));
  const status = await reborn.query(packet("02-status.bin"));
  const scan = await reborn.query(packet("13-scan-after.bin"));
  const closed = await reborn.close();
  check(
    status.status === 0 && scan.status === 0 && closed.status === 0,
    "a fresh instance reopened the short log and answered",
  );
}

// -- 2. a rejected commit fences the instance and the object drops it --------
{
  const storage = new MemoryStorage();
  const state = { storage, id: { name: SPACE } };
  const object = new StoreDurableObjectBase(state, {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await object.transact(packet("03-assert-unicode.bin"));
  const landed = await durableLog(storage);
  const first = await object.store();

  let refuse = true;
  const inner = storage.transaction.bind(storage);
  storage.transaction = async (body) => {
    if (refuse) throw new Error("storage said no");
    return inner(body);
  };

  let raised = null;
  try {
    await object.transact(packet("04-batch-mixed.bin"));
  } catch (error) {
    raised = error;
  }
  check(
    raised !== null && raised.name === "StoreStorageError",
    `the rejected commit surfaced as ${raised && raised.name}`,
  );
  check(first.poisoned !== null, "the instance that saw it is fenced");
  check(
    first.log.dirty && Number.isFinite(first.log.lowWater),
    `the dirty range came back (low water ${first.log.lowWater})`,
  );
  let reused = null;
  try {
    await first.query(packet("02-status.bin"));
  } catch (error) {
    reused = error;
  }
  check(reused !== null, "the fenced instance refuses further calls");

  const stillThere = await durableLog(storage);
  check(
    stillThere.length === landed.length && samePrefix(stillThere, landed),
    `the durable log kept its ${landed.length} acked bytes`,
  );

  refuse = false;
  const second = await object.store();
  check(second !== first, "the object reopened from the durable bytes");
  const answered = await object.query(packet("02-status.bin"));
  check(answered.status === 0, "the reopened object answers again");
  const replayed = await durableLog(storage);
  check(
    replayed.length === landed.length,
    `the reopened log is the acked one, ${replayed.length} bytes`,
  );
}

// -- 3. one boot however many callers race for it ----------------------------
{
  const storage = new MemoryStorage();
  storage.latencyMs = 2; // every storage touch yields, so the race is real
  const object = new StoreDurableObjectBase(
    { storage, id: { name: SPACE } }, {}, module, {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  const settled = await Promise.all(
    Array.from({ length: 8 }, () => object.store()),
  );
  check(
    new Set(settled).size === 1,
    `8 racing callers booted ${new Set(settled).size} instance(s)`,
  );
  const answers = await Promise.all(
    Array.from({ length: 8 }, () => object.query(packet("02-status.bin"))),
  );
  check(
    answers.every((one) => one.status === 0),
    "8 concurrent calls on one instance all answered",
  );
  storage.latencyMs = 0;
}

// -- 4. a >64 KiB log: multi-chunk commit, torn tail, stale-chunk delete -----
{
  const storage = new MemoryStorage();
  const store = new DurableStoreStore(storage);
  const store = await open(store);
  const bulk = [
    "30-batch-bulk-a.bin",
    "30-batch-bulk-b.bin",
    "30-batch-bulk-c.bin",
  ].map(packet);
  let rounds = 0;
  while (store.log.length < 96 * 1024 && rounds < 400) {
    const result = await store.transact(bulk[rounds % bulk.length]);
    if (result.status !== 0) break;
    rounds += 1;
  }
  const big = await durableLog(storage);
  check(
    big.length > 65536,
    `the durable log spans chunks at ${big.length} bytes (${rounds} rounds)`,
  );
  const chunkKeys = [...storage.map.keys()].filter(
    (key) => key.startsWith("storelog/") && !key.endsWith("meta"),
  );
  check(
    chunkKeys.length === Math.ceil(big.length / 65536),
    `${chunkKeys.length} chunk keys for ${big.length} bytes`,
  );
  check(
    samePrefix(store.logBytes(), big) && store.log.length === big.length,
    "the durable bytes equal the bytes the guest holds",
  );

  // The tail transaction is lost with the isolate: the last chunk must stay
  // exactly as acked rather than half-rewritten.
  const doomed = new DurableStoreStore(storage);
  doomed.commit = () => Promise.resolve();
  const dying = await open(doomed);
  await dying.transact(packet("30-batch-bulk-a.bin"));
  const afterTear = await durableLog(storage);
  check(
    afterTear.length === big.length && samePrefix(afterTear, big),
    `the torn tail left the ${big.length}-byte log byte-identical`,
  );
  const survivor = await open(new DurableStoreStore(storage));
  const answered = await survivor.query(packet("40-query-bulk-at-limit.bin"));
  check(
    answered.status === 0,
    "the multi-chunk log reopened after the lost tail",
  );
  await survivor.close();
}

// -- 5. the checked exact-packet data plane ----------------------------------
{
  const storage = new MemoryStorage();
  const object = new StoreDurableObjectBase(
    { storage, id: { name: SPACE } }, {}, module, {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  const statusPacket = packet("02-status.bin");
  const inspected = inspectStoreRpcRequest(statusPacket);
  check(
    inspected.space === SPACE && inspected.operation === "rpc/status",
    "the request boundary inspects the canonical SpaceId and operation",
  );
  const response = await object.exchange(statusPacket, {
    entry: "query",
    space: SPACE,
  });
  check(
    response instanceof Uint8Array && response.length > 26,
    `checked exchange returned ${response.length} canonical response bytes`,
  );

  let wrongEntry;
  try {
    await object.exchange(packet("03-assert-unicode.bin"), {
      entry: "query",
      space: SPACE,
    });
  } catch (error) {
    wrongEntry = error;
  }
  check(
    wrongEntry instanceof StoreRequestError
      && wrongEntry.code === "request/entry-mismatch",
    "a mutation cannot be routed through the query entry",
  );

  let wrongSpace;
  try {
    await object.exchange(statusPacket, { entry: "query", space: "other" });
  } catch (error) {
    wrongSpace = error;
  }
  check(
    wrongSpace instanceof StoreRequestError
      && wrongSpace.code === "request/space-mismatch",
    "the caller and packet SpaceIds must both belong to the object",
  );

  const inconsistent = statusPacket.slice();
  new DataView(
    inconsistent.buffer,
    inconsistent.byteOffset,
    inconsistent.byteLength,
  ).setUint32(14, inconsistent.length, true);
  let badLength;
  try {
    inspectStoreRpcRequest(inconsistent);
  } catch (error) {
    badLength = error;
  }
  check(
    badLength instanceof StoreRequestError
      && badLength.code === "request/truncated",
    "an inconsistent declared body length fails before guest entry",
  );

  let checkpoint;
  try {
    await object.exchange(packet("27-checkpoint.bin"), {
      entry: "transact",
      space: SPACE,
    });
  } catch (error) {
    checkpoint = error;
  }
  check(
    checkpoint instanceof StoreRequestError
      && checkpoint.code === "request/operator-capability",
    "the data plane cannot exercise the checkpoint operator capability",
  );

  let identity;
  try {
    new StoreDurableObjectBase(
      { storage: new MemoryStorage(), id: { name: "other" } }, {}, module,
      { spaceId: SPACE },
    );
  } catch (error) {
    identity = error;
  }
  check(
    identity instanceof StoreRequestError
      && identity.code === "request/object-identity-mismatch",
    "the raw storage owner's stable object name must equal its SpaceId",
  );

  let requestedName;
  const dataPlane = storeDataPlaneEntrypoint({
    getByName(name) {
      requestedName = name;
      return object;
    },
  }, SPACE);
  const publicMethods = Object.keys(dataPlane);
  check(
    publicMethods.length === 1 && publicMethods[0] === "exchange",
    `the service-binding data-plane capability exposes only ${publicMethods.join(",")}`,
  );
  const dataResponse = await dataPlane.exchange(statusPacket, {
    entry: "query",
    space: SPACE,
  });
  check(
    dataResponse instanceof Uint8Array && dataResponse.length > 26,
    "the exchange-only capability answers through the raw backend object",
  );
  check(
    requestedName === SPACE,
    "the data-plane facade resolves the raw object only by exact SpaceId name",
  );

  let adminName;
  const admin = storeAdminEntrypoint({
    getByName(name) {
      adminName = name;
      return object;
    },
  }, SPACE);
  check(
    Object.keys(admin).join(",") === "exportStoreLog,restoreStoreLog",
    "the separate admin capability exposes only STORELOG export and restore",
  );
  const adminBackup = await admin.exportStoreLog();
  check(
    adminName === SPACE && adminBackup.spaceId === SPACE,
    "the admin facade resolves the same raw object by exact SpaceId name",
  );
}

// -- 6. the stale-chunk delete path -----------------------------------------
{
  const storage = new MemoryStorage();
  const store = new DurableStoreStore(storage);
  await store.load("log");
  const wide = new Uint8Array(200 * 1024).fill(7);
  await store.commit([
    { which: "log", bytes: wide, length: wide.length, lowWater: 0 },
  ]);
  const before = [...storage.map.keys()].filter((key) =>
    key.startsWith("storelog/0"),
  ).length;
  await store.commit([
    { which: "log", bytes: wide, length: 40 * 1024, lowWater: 0 },
  ]);
  const after = [...storage.map.keys()].filter((key) =>
    key.startsWith("storelog/0"),
  ).length;
  const reread = await durableLog(storage);
  check(before === 4 && after === 1, `chunk keys went ${before} -> ${after}`);
  check(
    reread.length === 40 * 1024 && reread.every((byte) => byte === 7),
    `the shrunk object reads back as ${reread.length} bytes`,
  );

  // The two ranges are published in one transaction, so a reader never sees a
  // log that its image does not cover.
  const both = new DurableStoreStore(new MemoryStorage());
  await both.load("log");
  await both.load("image");
  await both.commit([
    { which: "log", bytes: wide, length: 70 * 1024, lowWater: 0 },
    { which: "image", bytes: wide, length: 3 * 1024, lowWater: 0 },
  ]);
  check(
    both.commits === 1 && both.stats().log.chunks === 2,
    `one transaction published both ranges (${both.stats().log.chunks} log ` +
      `chunks, ${both.stats().image.chunks} image chunk)`,
  );

  // Cloudflare accepts at most 128 keys in one delete call. Exercise more
  // than one full batch against a storage double that enforces that bound.
  const boundedStorage = new MemoryStorage();
  const deleteBatches = [];
  const transaction = boundedStorage.transaction.bind(boundedStorage);
  boundedStorage.transaction = (body) => transaction(async (txn) => {
    const remove = txn.delete.bind(txn);
    txn.delete = async (keys) => {
      const count = Array.isArray(keys) ? keys.length : 1;
      deleteBatches.push(count);
      if (count > 128) throw new Error(`delete batch has ${count} keys`);
      return remove(keys);
    };
    return body(txn);
  });
  const bounded = new DurableStoreStore(boundedStorage, {
    chunkBytes: 1,
  });
  await bounded.load("log");
  const many = new Uint8Array(130).fill(11);
  await bounded.commit([
    { which: "log", bytes: many, length: many.length, lowWater: 0 },
  ]);
  await bounded.commit([
    { which: "log", bytes: many, length: 0, lowWater: 0 },
  ]);
  check(
    deleteBatches.join(",") === "100,30",
    `130 stale chunks were deleted in bounded batches: ${deleteBatches.join(",")}`,
  );
  check(
    (await durableLog(boundedStorage)).length === 0,
    "the multi-batch shrink reads back as an empty range",
  );

  const foreignStorage = new MemoryStorage(
    new Map([["storeimage/not-a-chunk", new Uint8Array([1])]]),
  );
  let foreignKey = null;
  try {
    await new ChunkedRange(foreignStorage, {
      prefix: "storeimage/",
    }).clearPlan();
  } catch (error) {
    foreignKey = error;
  }
  check(
    /unrecognised storage key/.test(foreignKey?.message) &&
      foreignStorage.map.has("storeimage/not-a-chunk"),
    "a range clear refuses an unrecognised key without deleting it",
  );
}

// -- 6. portable STORELOG export -> empty restore -> semantic equivalence -----
{
  const sourceStorage = new MemoryStorage();
  const source = new StoreDurableObjectBase(objectState(sourceStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await source.transact(packet("03-assert-unicode.bin"));
  await source.transact(packet("04-batch-mixed.bin"));
  const checkpointed = await source.checkpoint(packet("27-checkpoint.bin"));
  check(checkpointed.status === 0, "the backup source wrote a checkpoint image");

  const backup = await source.exportStoreLog();
  const sourceLog = await durableLog(sourceStorage);
  const sourceImage = await durableImage(sourceStorage);
  check(
    backup.format === "store-cloudflare-backup/v1" &&
      backup.spaceId === SPACE &&
      /^(?:0|[1-9][0-9]*)$/.test(backup.servedVersion) &&
      backup.byteLength === sourceLog.length &&
      /^[0-9a-f]{64}$/.test(backup.sha256),
    `export described ${backup.byteLength} bytes as ${backup.sha256}`,
  );
  check(sameBytes(backup.bytes, sourceLog), "export bytes equal the durable STORELOG");
  check(sourceImage.length > 0, `source image has ${sourceImage.length} bytes`);

  const restoredStorage = new MemoryStorage();
  const restored = new StoreDurableObjectBase(
    objectState(restoredStorage),
    {},
    module,
    {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  const receipt = await restored.restoreStoreLog(backup);
  const restoredLog = await durableLog(restoredStorage);
  const restoredImage = await durableImage(restoredStorage);
  check(
    receipt.sha256 === backup.sha256 &&
      receipt.servedVersion === backup.servedVersion &&
      receipt.replaced === false,
    "empty-target restore returned the exported checksum and served version",
  );
  check(
    sameBytes(restoredLog, sourceLog),
    "empty-target restore landed the STORELOG byte for byte",
  );
  check(restoredImage.length === 0, "restore omitted the derived snapshot image");

  const sourceAnswer = await source.query(packet("20-query-all-final.bin"));
  const restoredAnswer = await restored.query(packet("20-query-all-final.bin"));
  check(
    sourceAnswer.status === restoredAnswer.status &&
      sameBytes(sourceAnswer.response, restoredAnswer.response),
    "restored object answers byte-identically to the source",
  );

  const beforeRefusal = await durableLog(restoredStorage);
  const healthy = await restored.store();
  let nonempty = null;
  try {
    await restored.restoreStoreLog(backup);
  } catch (error) {
    nonempty = error;
  }
  check(
    nonempty?.name === "StoreBackupError" &&
      nonempty.code === "target-not-empty",
    "replace defaults false and refuses a nonempty target",
  );
  check(
    sameBytes(await durableLog(restoredStorage), beforeRefusal),
    "the nonempty-target refusal leaves durable bytes unchanged",
  );
  check(
    (await healthy.query(packet("02-status.bin"))).status === 0,
    "the expected nonempty-target refusal does not fence the live guest",
  );

  const mismatched = new StoreDurableObjectBase(
    objectState(new MemoryStorage(), "another-space"),
    {},
    module,
    { spaceId: "another-space" },
  );
  let wrongSpace = null;
  try {
    await mismatched.restoreStoreLog(backup);
  } catch (error) {
    wrongSpace = error;
  }
  check(
    wrongSpace?.code === "space-mismatch",
    "restore requires the configured SpaceId to equal the backup",
  );

  const damagedBytes = backup.bytes.slice();
  damagedBytes[damagedBytes.length - 1] ^= 1;
  const damagedStorage = new MemoryStorage();
  const damagedTarget = new StoreDurableObjectBase(
    objectState(damagedStorage),
    {},
    module,
    { spaceId: SPACE },
  );
  let damaged = null;
  try {
    await damagedTarget.restoreStoreLog({ ...backup, bytes: damagedBytes });
  } catch (error) {
    damaged = error;
  }
  check(damaged?.code === "verification", "restore rejects a checksum mismatch");
  check(damagedStorage.map.size === 0, "checksum refusal does not touch storage");

  // Beagle Store accepts an incomplete final record by repairing back to the complete
  // prefix during open. A portable restore requires the supplied bytes
  // themselves to be canonical, so a correctly hashed torn suffix still fails.
  const tornBytes = new Uint8Array(backup.bytes.length + 1);
  tornBytes.set(backup.bytes);
  tornBytes[tornBytes.length - 1] = 0xff;
  const tornBackup = await backupWithBytes(backup, tornBytes);
  const tornStorage = new MemoryStorage();
  const tornTarget = new StoreDurableObjectBase(
    objectState(tornStorage),
    {},
    module,
    { spaceId: SPACE },
  );
  let torn = null;
  try {
    await tornTarget.restoreStoreLog(tornBackup);
  } catch (error) {
    torn = error;
  }
  check(
    torn?.code === "invalid-storelog",
    "restore replays and rejects a correctly hashed torn STORELOG suffix",
  );
  check(tornStorage.map.size === 0, "replay refusal does not touch storage");

  const wrongVersionStorage = new MemoryStorage();
  const wrongVersionTarget = new StoreDurableObjectBase(
    objectState(wrongVersionStorage),
    {},
    module,
    { spaceId: SPACE },
  );
  let wrongVersion = null;
  try {
    await wrongVersionTarget.restoreStoreLog({
      ...backup,
      servedVersion: (BigInt(backup.servedVersion) + 1n).toString(),
    });
  } catch (error) {
    wrongVersion = error;
  }
  check(
    wrongVersion?.code === "verification",
    "full replay binds servedVersion to the supplied STORELOG",
  );
  check(
    wrongVersionStorage.map.size === 0,
    "served-version refusal does not touch storage",
  );
}

// -- 7. replacement uses a byte CAS and publishes both ranges atomically ------
{
  const sourceStorage = new MemoryStorage();
  const source = new StoreDurableObjectBase(objectState(sourceStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await source.transact(packet("03-assert-unicode.bin"));
  const backup = await source.exportStoreLog();

  const targetStorage = new MemoryStorage();
  const target = new StoreDurableObjectBase(objectState(targetStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await target.transact(packet("04-batch-mixed.bin"));
  await target.checkpoint(packet("27-checkpoint.bin"));
  const current = await target.exportStoreLog();
  const expectedCurrent = {
    byteLength: current.byteLength,
    sha256: current.sha256,
  };
  const retained = await target.store();
  const oldLog = await durableLog(targetStorage);
  const oldImage = await durableImage(targetStorage);

  const transaction = targetStorage.transaction.bind(targetStorage);
  let reject = true;
  targetStorage.transaction = async (body) => {
    if (reject) throw new Error("restore storage said no");
    return transaction(body);
  };
  let rejected = null;
  try {
    await target.restoreStoreLog(backup, { replace: true, expectedCurrent });
  } catch (error) {
    rejected = error;
  }
  check(rejected?.code === "storage", "a rejected restore transaction is surfaced");
  check(
    sameBytes(await durableLog(targetStorage), oldLog) &&
      sameBytes(await durableImage(targetStorage), oldImage),
    "a rejected restore leaves the old log and image byte-identical",
  );
  let fenced = null;
  try {
    await retained.query(packet("02-status.bin"));
  } catch (error) {
    fenced = error;
  }
  check(
    fenced?.code === "administrative-fence",
    "the guest retained across a restore attempt is fenced",
  );

  check(
    (await target.query(packet("02-status.bin"))).status === 0,
    "a rejected publication reopens the old durable state",
  );

  reject = false;
  const receipt = await target.restoreStoreLog(backup, {
    replace: true,
    expectedCurrent,
  });
  check(receipt.replaced === true, "explicit replacement reports occupied storage");
  check(
    sameBytes(await durableLog(targetStorage), backup.bytes),
    "explicit replacement landed the exported STORELOG exactly",
  );
  check(
    (await durableImage(targetStorage)).length === 0,
    "explicit replacement atomically cleared the old derived image",
  );
  const sourceAnswer = await source.query(packet("20-query-all-final.bin"));
  const targetAnswer = await target.query(packet("20-query-all-final.bin"));
  check(
    sourceAnswer.status === targetAnswer.status &&
      sameBytes(sourceAnswer.response, targetAnswer.response),
    "replacement reopens with the source semantics",
  );

  const missingStorage = new MemoryStorage();
  const missingImageTarget = new StoreDurableObjectBase(
    objectState(missingStorage),
    {},
    module,
    {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  await missingImageTarget.transact(packet("04-batch-mixed.bin"));
  await missingImageTarget.checkpoint(packet("27-checkpoint.bin"));
  const missingCurrent = await missingImageTarget.exportStoreLog();
  const missingChunk = [...missingStorage.map.keys()].find((key) =>
    /^storeimage\/[0-9]{8}$/.test(key)
  );
  missingStorage.map.delete(missingChunk);
  let tornImage = null;
  try {
    await durableImage(missingStorage);
  } catch (error) {
    tornImage = error;
  }
  check(
    missingChunk !== undefined && /chunk .* missing/.test(tornImage?.message),
    "the replacement target begins with a missing derived-image chunk",
  );
  await missingImageTarget.restoreStoreLog(backup, {
    replace: true,
    expectedCurrent: {
      byteLength: missingCurrent.byteLength,
      sha256: missingCurrent.sha256,
    },
  });
  check(
    sameBytes(await durableLog(missingStorage), backup.bytes) &&
      ![...missingStorage.map.keys()].some((key) =>
        key.startsWith("storeimage/")
      ) &&
      !missingStorage.map.has("storerestore/pending"),
    "replacement recovers a missing image chunk and removes its whole range",
  );

  const corruptStorage = new MemoryStorage();
  const corruptImageTarget = new StoreDurableObjectBase(
    objectState(corruptStorage),
    {},
    module,
    {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  await corruptImageTarget.transact(packet("04-batch-mixed.bin"));
  await corruptImageTarget.checkpoint(packet("27-checkpoint.bin"));
  const corruptCurrent = await corruptImageTarget.exportStoreLog();
  corruptStorage.map.set("storeimage/meta", {
    length: 1n,
    chunkBytes: 64 * 1024,
  });
  let corruptImage = null;
  try {
    await durableImage(corruptStorage);
  } catch (error) {
    corruptImage = error;
  }
  check(
    corruptImage instanceof TypeError,
    "the replacement target begins with corrupt derived-image metadata",
  );
  await corruptImageTarget.restoreStoreLog(backup, {
    replace: true,
    expectedCurrent: {
      byteLength: corruptCurrent.byteLength,
      sha256: corruptCurrent.sha256,
    },
  });
  check(
    sameBytes(await durableLog(corruptStorage), backup.bytes) &&
      ![...corruptStorage.map.keys()].some((key) =>
        key.startsWith("storeimage/")
      ) &&
      !corruptStorage.map.has("storerestore/pending"),
    "replacement ignores corrupt image metadata and removes its whole range",
  );
}

// -- 8. a stale replacement cannot overwrite an intervening write ------------
{
  const sourceStorage = new MemoryStorage();
  const source = new StoreDurableObjectBase(objectState(sourceStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await source.transact(packet("04-batch-mixed.bin"));
  const backup = await source.exportStoreLog();

  const targetStorage = new MemoryStorage();
  const target = new StoreDurableObjectBase(objectState(targetStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await target.transact(packet("03-assert-unicode.bin"));
  const observed = await target.exportStoreLog();
  await target.transact(packet("04-batch-mixed.bin"));
  const intervened = await durableLog(targetStorage);

  let conflict = null;
  try {
    await target.restoreStoreLog(backup, {
      replace: true,
      expectedCurrent: {
        byteLength: observed.byteLength,
        sha256: observed.sha256,
      },
    });
  } catch (error) {
    conflict = error;
  }
  check(conflict?.code === "conflict", "a stale replacement CAS is rejected");
  check(
    sameBytes(await durableLog(targetStorage), intervened),
    "the CAS conflict preserves the intervening durable write byte for byte",
  );
  check(
    (await target.query(packet("02-status.bin"))).status === 0,
    "a pre-publication CAS conflict clears the administrative fence",
  );
}

// -- 9. post-publication completion failure is durable and recoverable --------
{
  const sourceStorage = new MemoryStorage();
  const source = new StoreDurableObjectBase(objectState(sourceStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await source.transact(packet("04-batch-mixed.bin"));
  const incoming = await source.exportStoreLog();

  const targetStorage = new FailPostPublishStorage();
  const target = new StoreDurableObjectBase(objectState(targetStorage), {}, module, {
    spaceId: SPACE,
    instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
  });
  await target.transact(packet("03-assert-unicode.bin"));
  await target.checkpoint(packet("27-checkpoint.bin"));
  const previous = await target.exportStoreLog();
  const previousAnswer = await target.query(packet("20-query-all-final.bin"));

  targetStorage.failNextMarkerClear = true;
  let failed = null;
  try {
    await target.restoreStoreLog(incoming, {
      replace: true,
      expectedCurrent: {
        byteLength: previous.byteLength,
        sha256: previous.sha256,
      },
    });
  } catch (error) {
    failed = error;
  }
  check(
    failed?.code === "restore-fenced" &&
      failed.expectedCurrent?.byteLength === incoming.byteLength &&
      failed.expectedCurrent?.sha256 === incoming.sha256,
    "post-publication completion failure returns the exact recovery CAS",
  );
  check(
    sameBytes(await durableLog(targetStorage), incoming.bytes) &&
      (await durableImage(targetStorage)).length === 0,
    "failed restore completion leaves the imported log durably published",
  );
  let dataFence = null;
  try {
    await target.query(packet("02-status.bin"));
  } catch (error) {
    dataFence = error;
  }
  check(
    dataFence?.code === "restore-fenced",
    "data access stays fenced after a failed restore completion",
  );

  const freshTarget = new StoreDurableObjectBase(
    objectState(targetStorage),
    {},
    module,
    {
      spaceId: SPACE,
      instance: { nowMs: () => 1700000000000, arena: { initialPages: 8 } },
    },
  );
  let freshFence = null;
  try {
    await freshTarget.query(packet("02-status.bin"));
  } catch (error) {
    freshFence = error;
  }
  check(
    freshFence?.code === "restore-fenced",
    "the durable pending marker fences a fresh object isolate",
  );

  let recoveryConflict = null;
  try {
    await target.restoreStoreLog(previous, {
      replace: true,
      expectedCurrent: {
        byteLength: previous.byteLength,
        sha256: previous.sha256,
      },
    });
  } catch (error) {
    recoveryConflict = error;
  }
  check(
    recoveryConflict?.code === "conflict",
    "a recovery attempt with the wrong current checksum is rejected",
  );
  let stillFenced = null;
  try {
    await target.query(packet("02-status.bin"));
  } catch (error) {
    stillFenced = error;
  }
  check(
    stillFenced?.code === "restore-fenced",
    "a failed recovery attempt preserves the durable fence",
  );

  const recovered = await target.restoreStoreLog(previous, {
    replace: true,
    expectedCurrent: {
      byteLength: incoming.byteLength,
      sha256: incoming.sha256,
    },
  });
  const recoveredAnswer = await target.query(packet("20-query-all-final.bin"));
  check(
    recovered.sha256 === previous.sha256 &&
      sameBytes(await durableLog(targetStorage), previous.bytes),
    "an explicit verified restore recovers the durable-but-fenced object",
  );
  check(
    recoveredAnswer.status === previousAnswer.status &&
      sameBytes(recoveredAnswer.response, previousAnswer.response),
    "recovery restores the previous semantic state",
  );
}

process.stdout.write(`${notes.join("\n")}\n`);
if (failures.length) {
  process.stdout.write(`run-node: FAIL\n${failures.join("\n")}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`run-node: PASS checks=${notes.length}\n`);
}
