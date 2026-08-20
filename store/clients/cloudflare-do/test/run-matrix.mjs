// SPDX-License-Identifier: MIT OR Apache-2.0
// The workers-runtime half of the harness: workerd through miniflare, over real
// DurableObjectStorage. Prints the same transcript as the native oracle so the
// two can be compared byte for byte.
//
//   node test/run-matrix.mjs OUT-DIR [ORACLE-TRANSCRIPT] [DEPTH-ORACLE]
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import {
  storeClient,
  keywordTerm,
} from "../../bun/store-rpc-core.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const [outDirArgument, oraclePath, depthOraclePath] = process.argv.slice(2);
const outDir = outDirArgument ?? `${here}/out`;
const budgetMs = Number(process.env.BEAGLE_STORE_DO_BUDGET_MS ?? 600000);

mkdirSync(outDir, { recursive: true });

const watchdog = setTimeout(() => {
  process.stderr.write(`run-matrix: no verdict within ${budgetMs} ms\n`);
  process.exit(3);
}, budgetMs);

const mf = new Miniflare(convertV4MiniflareOptions({
  modulesRoot: root,
  modules: [
    { type: "ESModule", path: `${root}/test/worker/worker.mjs` },
    { type: "ESModule", path: `${root}/src/adapter.mjs` },
    { type: "ESModule", path: `${root}/src/seams.mjs` },
    { type: "CompiledWasm", path: `${root}/lib/libstore.wasm` },
    { type: "Data", path: `${root}/test/bundle/packets.bin` },
    { type: "Text", path: `${root}/test/bundle/packets.json` },
  ],
  scriptPath: `${root}/test/worker/worker.mjs`,
  // No cf metadata fetch: this row must run with no network and leave no
  // .wrangler cache in the checkout.
  cf: false,
  compatibilityDate: "2026-03-15",
  compatibilityFlags: ["nodejs_compat"],
  durableObjects: {
    BEAGLE_STORE_WARM: { className: "StoreWarm", useSQLite: true },
    BEAGLE_STORE_MATRIX: { className: "StoreMatrix", useSQLite: true },
    BEAGLE_STORE_RESTORED: { className: "StoreRestored", useSQLite: true },
    BEAGLE_STORE_DEPTH: { className: "StoreDepth", useSQLite: true },
    BEAGLE_STORE_MULTICHUNK: { className: "StoreMultichunk", useSQLite: true },
    BEAGLE_STORE_RACE: { className: "StoreRace", useSQLite: true },
    BEAGLE_STORE_CLIENT: { className: "StoreClient", useSQLite: true },
  },
}));

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

function sameBytes(left, right) {
  if (left.length !== right.length) return false;
  return left.every((byte, index) => byte === right[index]);
}

async function call(path, id, extra = "") {
  const response = await mf.dispatchFetch(
    `http://localhost${path}?id=${id}${extra}`,
  );
  const body = await response.json();
  if (body.fatal) throw new Error(`${path}[${id}]: ${body.fatal}`);
  return body;
}

async function exportStoreLog(id) {
  const response = await mf.dispatchFetch(
    `http://localhost/admin/export?id=${id}`,
  );
  if (!response.ok) {
    throw new Error(`/export-storelog[${id}]: ${await response.text()}`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  return {
    format: response.headers.get("x-beagle-store-backup-format"),
    spaceId: response.headers.get("x-store-space-id"),
    servedVersion: response.headers.get("x-store-served-version"),
    byteLength: Number(response.headers.get("x-store-byte-length")),
    sha256: response.headers.get("x-store-sha256"),
    bytes,
  };
}

async function restoreStoreLog(id, backup) {
  const response = await mf.dispatchFetch(
    `http://localhost/admin/restore?id=${id}`,
    {
      method: "POST",
      headers: {
        "content-type": "application/octet-stream",
        "x-beagle-store-backup-format": backup.format,
        "x-store-byte-length": String(backup.byteLength),
        "x-store-served-version": backup.servedVersion,
        "x-store-sha256": backup.sha256,
        "x-store-space-id": backup.spaceId,
      },
      body: backup.bytes,
    },
  );
  const receipt = await response.json();
  if (!response.ok || receipt.fatal) {
    throw new Error(`/restore-storelog[${id}]: ${receipt.fatal}`);
  }
  return receipt;
}

// A packet's status is the oracle's business, so a nonzero one is only checked
// here when no oracle transcript is supplied to compare against.
async function transcript(id, passes, oracle) {
  const lines = [];
  for (const [label, manifest] of passes) {
    const body = await call("/pass", id, `&label=${label}&manifest=${manifest}`);
    lines.push(...body.out);
    if (oracle) {
      notes.push(`  note ${id} pass ${label}: ${body.failures} nonzero packets`);
    } else {
      check(
        body.failures === 0,
        `${id} pass ${label}: ${body.failures} packet failures`,
      );
    }
  }
  const log = new Uint8Array(
    await (await mf.dispatchFetch(`http://localhost/dump?id=${id}&range=log`))
      .arrayBuffer(),
  );
  const image = new Uint8Array(
    await (await mf.dispatchFetch(`http://localhost/dump?id=${id}&range=image`))
      .arrayBuffer(),
  );
  lines.push(`log ${log.length}`, `image ${image.length}`);
  return { text: `${lines.join("\n")}\n`, log, image };
}

function compare(name, produced, oracle) {
  if (!oracle) {
    notes.push(`  skip ${name}: no oracle transcript supplied`);
    return;
  }
  const expected = readFileSync(oracle, "utf8");
  if (expected === produced) {
    notes.push(`  ok   ${name} is identical to the native oracle`);
    return;
  }
  failures.push(`${name} diverges from the native oracle`);
  const wanted = expected.split("\n");
  const found = produced.split("\n");
  for (let i = 0; i < Math.max(wanted.length, found.length); i++) {
    if (wanted[i] !== found[i]) {
      notes.push(`  FAIL ${name} line ${i + 1}`);
      notes.push(`    native  ${String(wanted[i]).slice(0, 120)}`);
      notes.push(`    workerd ${String(found[i]).slice(0, 120)}`);
      break;
    }
  }
}

try {
  await (await mf.dispatchFetch("http://localhost/ready?id=warm")).json();

  // 1. The packet matrix, three passes, against the native oracle.
  const matrix = await transcript(
    "matrix",
    [
      ["open", "manifest.txt"],
      ["reopen", "manifest-reopen.txt"],
      ["image", "manifest-image.txt"],
    ],
    oraclePath,
  );
  writeFileSync(`${outDir}/workerd.transcript`, matrix.text);
  writeFileSync(`${outDir}/workerd.storelog`, matrix.log);
  writeFileSync(`${outDir}/workerd.storeimage`, matrix.image);
  compare("matrix transcript", matrix.text, oraclePath);
  check(
    matrix.image.length > 0,
    `the checkpoint wrote ${matrix.image.length} bytes to the image range`,
  );

  // 2. A portable export crosses object identity without changing bytes or
  // semantics. The snapshot image is derived and intentionally rebuilt later.
  const backup = await exportStoreLog("matrix");
  check(
    backup.byteLength === matrix.log.length &&
      sameBytes(backup.bytes, matrix.log) &&
      /^(?:0|[1-9][0-9]*)$/.test(backup.servedVersion) &&
      /^[0-9a-f]{64}$/.test(backup.sha256),
    `portable export bound ${backup.byteLength} bytes at version ` +
      backup.servedVersion,
  );
  check(
    !sameBytes(backup.bytes, new Uint8Array(0)),
    "the source admin namespace contains the matrix STORELOG",
  );
  const restoreReceipt = await restoreStoreLog("matrix-restored", backup);
  const restoredLog = new Uint8Array(
    await (
      await mf.dispatchFetch(
        "http://localhost/dump?id=matrix-restored&range=log",
      )
    ).arrayBuffer(),
  );
  const restoredImage = new Uint8Array(
    await (
      await mf.dispatchFetch(
        "http://localhost/dump?id=matrix-restored&range=image",
      )
    ).arrayBuffer(),
  );
  check(
    restoreReceipt.sha256 === backup.sha256 &&
      restoreReceipt.servedVersion === backup.servedVersion &&
      restoreReceipt.replaced === false,
    "fresh-object restore returned the portable export identity",
  );
  check(
    sameBytes(restoredLog, matrix.log),
    "fresh-object restore reproduced the source STORELOG byte for byte",
  );
  check(
    restoredImage.length === 0,
    "fresh-object restore did not copy the derived snapshot image",
  );
  check(
    sameBytes(await exportStoreLog("matrix-restored").then((one) => one.bytes), backup.bytes),
    "distinct source and restored admin namespaces export identical STORELOG bytes",
  );
  const sourceSemantics = await call(
    "/pass",
    "matrix",
    "&label=backup&manifest=manifest-image.txt",
  );
  const restoredSemantics = await call(
    "/pass",
    "matrix-restored",
    "&label=backup&manifest=manifest-image.txt",
  );
  check(
    sourceSemantics.failures === 0 &&
      restoredSemantics.failures === 0 &&
      JSON.stringify(sourceSemantics.out) === JSON.stringify(restoredSemantics.out),
    "source and restored objects answer the same workerd packet matrix",
  );

  // 3. The unpaged-bound matrix, same three-pass shape.
  const depth = await transcript(
    "depth",
    [
      ["open", "manifest-depth.txt"],
      ["reopen", "manifest-depth-reopen.txt"],
      ["image", "manifest-depth-image.txt"],
    ],
    depthOraclePath,
  );
  writeFileSync(`${outDir}/workerd-depth.transcript`, depth.text);
  writeFileSync(`${outDir}/workerd-depth.storelog`, depth.log);
  compare("depth transcript", depth.text, depthOraclePath);

  // 4. Multi-chunk coverage: a log past one 64 KiB chunk, read back whole.
  const target = 96 * 1024;
  const grown = await call("/grow", "multichunk", `&bytes=${target}`);
  check(
    grown.reached && grown.failures === 0,
    `grew the log to ${grown.guestLogBytes} bytes in ${grown.rounds} rounds`,
  );
  const inventory = await call("/keys", "multichunk", "&prefix=storelog/");
  const chunkKeys = inventory.keys.filter((key) => !key.endsWith("meta"));
  const expectedChunks = Math.ceil(inventory.meta.length / 65536);
  check(
    inventory.meta.length > 65536,
    `the durable log is ${inventory.meta.length} bytes, past one chunk`,
  );
  check(
    chunkKeys.length === expectedChunks && expectedChunks > 1,
    `${chunkKeys.length} chunk keys for ${inventory.meta.length} bytes ` +
      `(expected ${expectedChunks})`,
  );
  // Queries only: a checkpoint over this much bulk state grows guest linear
  // memory past the wasm32 ceiling, which is an engine budget question rather
  // than a chunking one. The image range is covered by the two matrices above.
  const reread = await transcript("multichunk", [
    ["reopen", "manifest-depth-image.txt"],
  ]);
  check(
    reread.log.length >= inventory.meta.length,
    `the multi-chunk log reopened at ${reread.log.length} bytes ` +
      `(was ${inventory.meta.length})`,
  );
  const rechecked = await call("/keys", "multichunk", "&prefix=storelog/");
  check(
    rechecked.keys.filter((key) => !key.endsWith("meta")).length ===
      Math.ceil(rechecked.meta.length / 65536),
    `the chunk inventory still matches the length after reopen`,
  );
  check(
    reread.log.length === inventory.meta.length,
    `the reopened multi-chunk log is unchanged by a read-only pass`,
  );

  // 5. Concurrent boot: many demands in one turn, one instance.
  const raced = await call("/concurrent-boot", "race", "&width=8");
  check(
    raced.identical && raced.distinct === 1,
    `8 concurrent boots produced ${raced.distinct} instance(s)`,
  );
  check(
    raced.statuses.every((status) => status === 0),
    `every racer answered a status packet: ${raced.statuses.join(",")}`,
  );

  const deleted = await call("/delete-batches", "race", "&chunks=130");
  check(
    deleted.before === 131 &&
      deleted.after === 1 &&
      deleted.deleteCalls === 2 &&
      deleted.reread === 0,
    `workerd deleted 130 stale chunks in ${deleted.deleteCalls} calls`,
  );

  // 6. The official client semantics over a non-TCP Worker/DO transport.
  const entries = [];
  const space = "store-wasm-embed";
  const transport = async ({ packet, entry, space: requestSpace }) => {
    entries.push(entry);
    const response = await mf.dispatchFetch(
      "http://localhost/rpc",
      {
        method: "POST",
        headers: {
          "content-type": "application/vnd.storerpc",
          "x-store-entry": entry,
          "x-store-space": requestSpace,
        },
        body: packet,
      },
    );
    if (!response.ok) throw new Error(await response.text());
    return new Uint8Array(await response.arrayBuffer());
  };
  const client = storeClient({ transport, space, requestTimeoutMs: 30000 });
  const initial = await client.version();
  const asserted = await client.assert(
    "worker-client-subject",
    keywordTerm("worker-client/predicate"),
    "worker-client-value",
    { expectedVersion: initial.servedVersion },
  );
  const scanned = await client.scan({ t1: "worker-client-subject" });
  const occurred = await client.occurrences();
  check(
    asserted.result[0].stateChanged && scanned.result.length === 1,
    "the official client wrote and read through Worker -> Durable Object -> Beagle Store/wasm",
  );
  check(
    occurred.result.length > 0,
    "the official client decoded an occurrence snapshot response",
  );
  check(
    entries.join(",") === "query,transact,query,snapshot",
    `the client selected exact embed entries: ${entries.join(",")}`,
  );

  process.stdout.write(`${notes.join("\n")}\n`);
  if (failures.length) {
    process.stdout.write(`run-matrix: FAIL\n${failures.join("\n")}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write(
      `run-matrix: PASS matrix-log=${matrix.log.length} ` +
        `matrix-image=${matrix.image.length} depth-log=${depth.log.length}\n`,
    );
  }
} catch (error) {
  process.stdout.write(`${notes.join("\n")}\n`);
  process.stdout.write(`run-matrix: FAIL ${error.stack ?? error.message}\n`);
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  await mf.dispose();
}
