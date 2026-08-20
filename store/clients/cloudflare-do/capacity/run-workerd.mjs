// SPDX-License-Identifier: MIT OR Apache-2.0
// Execute the fixed corpus against actual workerd (through Miniflare).
import {
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { CAPACITY_RUNTIME_CONFIGURATION } from "./config.mjs";
import {
  REQUIRED_VERIFY_RESPONSE_FILENAMES,
  canonicalJson,
  measureBundle,
} from "./receipt.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [bundleArgument, corpusArgument, outputArgument, progressArgument] =
  process.argv.slice(2);
if (!bundleArgument || !corpusArgument || !outputArgument) {
  throw new Error(
    "usage: bun capacity/run-workerd.mjs BUNDLE-DIR CORPUS-DIR " +
      "OUTPUT.json [PROGRESS.json]",
  );
}
const bundle = resolve(bundleArgument);
const corpus = resolve(corpusArgument);
const output = resolve(outputArgument);
const progressOutput = resolve(progressArgument ?? `${output}.progress.json`);
const persistence = resolve(dirname(output), "durable-storage");
mkdirSync(persistence, { recursive: true });
const profile = JSON.parse(readFileSync(`${corpus}/profile.json`, "utf8"));
const deploymentBundle = measureBundle(bundle);
const workerFiles = deploymentBundle.files.filter(
  (file) => file.path === "worker.js",
);
const wasmFiles = deploymentBundle.files.filter((file) =>
  file.path.endsWith(".wasm"),
);
if (
  deploymentBundle.files.length !== 2 ||
  workerFiles.length !== 1 ||
  wasmFiles.length !== 1
) {
  throw new Error(
    "Wrangler bundle must contain exactly worker.js and one compiled Wasm module; " +
      `found ${readdirSync(bundle).sort().join(", ")}`,
  );
}
const workerPath = resolve(bundle, workerFiles[0].path);
const wasmPath = resolve(bundle, wasmFiles[0].path);

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function manifest(name) {
  return readFileSync(`${corpus}/${name}`, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [entry, filename, declared, digest, operation] = line.split(" ");
      const bytes = new Uint8Array(readFileSync(`${corpus}/${filename}`));
      if (bytes.length !== Number(declared)) {
        throw new Error(`${filename}: ${bytes.length} bytes, declared ${declared}`);
      }
      if (sha256(bytes) !== digest) {
        throw new Error(`${filename}: sha256 does not match the manifest`);
      }
      return { entry, filename, operation, bytes };
    });
}

function nonnegativeIntegerFile(path) {
  const value = Number(readFileSync(path, "utf8").trim());
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function processTreeMemory() {
  const locator = process.env.BEAGLE_STORE_CF_CGROUP_LOCATOR;
  if (!locator || !existsSync(locator)) return null;
  const cgroup = readFileSync(locator, "utf8").trim();
  if (!cgroup || !existsSync(`${cgroup}/memory.current`)) return null;
  return {
    currentBytes: nonnegativeIntegerFile(`${cgroup}/memory.current`),
    cumulativePeakBytes: nonnegativeIntegerFile(`${cgroup}/memory.peak`),
  };
}

function processStartTime(pid) {
  const path = `/proc/${pid}/stat`;
  if (!existsSync(path)) return null;
  const stat = readFileSync(path, "utf8").trim();
  const commandEnd = stat.lastIndexOf(")");
  if (commandEnd < 0) return null;
  const fieldsAfterCommand = stat.slice(commandEnd + 1).trim().split(/\s+/);
  const startTime = fieldsAfterCommand[19];
  return /^\d+$/.test(startTime ?? "") ? startTime : null;
}

function cgroupProcesses(cgroup) {
  const path = `${cgroup}/cgroup.procs`;
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map(Number);
}

function runtimeInventory() {
  const inventory = process.env.BEAGLE_STORE_CF_CGROUP_INVENTORY;
  if (!inventory) return null;
  if (!existsSync(inventory)) return [];
  return readFileSync(inventory, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [pid, startTime, cgroup, extra] = line.trim().split(/\s+/);
      if (
        extra !== undefined ||
        !/^\d+$/.test(pid ?? "") ||
        !/^\d+$/.test(startTime ?? "") ||
        !cgroup?.startsWith("/")
      ) {
        throw new Error(`invalid workerd runtime inventory row: ${line}`);
      }
      return { pid: Number(pid), startTime, cgroup };
    });
}

async function waitForRuntimeIdentity(index) {
  if (!process.env.BEAGLE_STORE_CF_CGROUP_INVENTORY) return null;
  let lastObservation = "inventory row absent";
  for (let attempt = 0; attempt < 500; attempt += 1) {
    try {
      const identity = runtimeInventory()?.[index];
      if (identity) {
        const currentStartTime = processStartTime(identity.pid);
        const processes = cgroupProcesses(identity.cgroup);
        if (
          currentStartTime === identity.startTime &&
          processes?.includes(identity.pid)
        ) {
          return identity;
        }
        lastObservation =
          `pid=${identity.pid} start=${currentStartTime ?? "absent"} ` +
          `cgroup-processes=${canonicalJson(processes)}`;
      }
    } catch (error) {
      lastObservation = error.message;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(
    `workerd runtime ${index + 1} identity was not observed: ${lastObservation}`,
  );
}

async function waitForRuntimeExit(identity, label) {
  if (!identity) return;
  let lastObservation = "runtime still present";
  for (let attempt = 0; attempt < 500; attempt += 1) {
    const currentStartTime = processStartTime(identity.pid);
    const processes = cgroupProcesses(identity.cgroup);
    if (currentStartTime !== identity.startTime && processes?.length === 0) {
      return;
    }
    lastObservation =
      `pid=${identity.pid} start=${currentStartTime ?? "absent"} ` +
      `cgroup-processes=${canonicalJson(processes)}`;
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`${label} workerd did not exit exactly: ${lastObservation}`);
}

const load = manifest("manifest-load.txt");
const verify = manifest("manifest-verify.txt");
const expectedVerifyResponses = JSON.parse(
  readFileSync(`${corpus}/expected-verify-responses.json`, "utf8"),
);
for (const filename of REQUIRED_VERIFY_RESPONSE_FILENAMES) {
  if (!verify.some((row) => row.filename === filename)) {
    throw new Error(`verification manifest omitted ${filename}`);
  }
  if (typeof expectedVerifyResponses[filename] !== "string") {
    throw new Error(`expected response map omitted ${filename}`);
  }
}
let progress = {
  schema: "store-cloudflare-workerd-progress/v1",
  phase: "starting",
  lastCompletedPhase: "not-started",
  completedLoadPackets: 0,
  totalLoadPackets: load.length,
  completedVerifyPackets: 0,
  totalVerifyPackets: verify.length,
  loadedGuestLinearMemoryBytes: null,
  reopenedGuestLinearMemoryBytes: null,
  runtimeConfigurationObserved: false,
  deploymentBundle,
  processTreeMemory: null,
  processTreeCumulativePeakAtLoadedBytes: null,
  processTreeCumulativePeakAfterReopenBytes: null,
  workerdLifecycle: "process-replacement",
  runtimeCount: 0,
  loadRuntimeExitedBeforeReopen: false,
  reopenRuntimeExited: false,
  processIdentityVerified: false,
};

function recordProgress(update) {
  const memory = processTreeMemory();
  progress = {
    ...progress,
    ...update,
    processTreeMemory: memory,
  };
  if (update.phase === "loaded") {
    progress.processTreeCumulativePeakAtLoadedBytes =
      memory?.cumulativePeakBytes ?? null;
  }
  if (update.phase === "reopened") {
    progress.processTreeCumulativePeakAfterReopenBytes =
      memory?.cumulativePeakBytes ?? null;
  }
  mkdirSync(dirname(progressOutput), { recursive: true });
  const temporary = `${progressOutput}.tmp`;
  writeFileSync(temporary, canonicalJson(progress));
  renameSync(temporary, progressOutput);
  process.stdout.write(
    `capacity-progress: phase=${progress.phase} ` +
      `load=${progress.completedLoadPackets}/${progress.totalLoadPackets} ` +
      `verify=${progress.completedVerifyPackets}/${progress.totalVerifyPackets}\n`,
  );
  return progress;
}

recordProgress({});

async function requestJson(mf, path, init = undefined) {
  const response = await mf.dispatchFetch(`http://localhost${path}`, init);
  const body = await response.json();
  if (!response.ok) throw new Error(`${path}: ${body.error ?? response.status}`);
  return body;
}

async function exchange(mf, row) {
  const body = await requestJson(mf, "/exchange", {
    method: "POST",
    headers: { "x-store-entry": row.entry },
    body: row.bytes,
  });
  if (body.status !== 0 || body.released !== true || body.responseBytes <= 0) {
    throw new Error(
      `${row.filename}: status=${body.status} released=${body.released} ` +
        `responseBytes=${body.responseBytes} message=${body.message}`,
    );
  }
  if (body.responseHex.length !== body.responseBytes * 2) {
    throw new Error(`${row.filename}: response hex length is inconsistent`);
  }
  return { bytes: body.responseBytes, sha256: sha256(Buffer.from(body.responseHex, "hex")) };
}

function createRuntime() {
  return new Miniflare(convertV4MiniflareOptions({
    modulesRoot: bundle,
    modules: [
      { type: "ESModule", path: workerPath },
      { type: "CompiledWasm", path: wasmPath },
    ],
    scriptPath: workerPath,
    cf: false,
    compatibilityDate: "2026-08-01",
    durableObjects: { BEAGLE_STORE: { className: "CapacityStore", useSQLite: true } },
    resourcePersistencePath: persistence,
  }));
}

let mf = null;
let loadRuntimeIdentity = null;
let reopenRuntimeIdentity = null;

try {
  mf = createRuntime();
  await mf.ready;
  loadRuntimeIdentity = await waitForRuntimeIdentity(0);
  recordProgress({ phase: "load-runtime-ready", runtimeCount: 1 });
  let responseBytes = 0;
  for (const [index, row] of load.entries()) {
    recordProgress({ phase: "load-in-flight" });
    responseBytes += (await exchange(mf, row)).bytes;
    recordProgress({
      phase: "load",
      lastCompletedPhase: "load",
      completedLoadPackets: index + 1,
    });
  }
  const loaded = await requestJson(mf, "/stats");
  if (
    canonicalJson(loaded.runtimeConfiguration) !==
    canonicalJson(CAPACITY_RUNTIME_CONFIGURATION)
  ) {
    throw new Error(
      "Worker runtime configuration did not match the capacity profile",
    );
  }
  const loadedProgress = recordProgress({
    phase: "loaded",
    lastCompletedPhase: "loaded",
    loadedGuestLinearMemoryBytes: loaded.engine.linearMemoryBytes,
    runtimeConfigurationObserved: true,
  });
  recordProgress({ phase: "recycle-in-flight" });
  const recycled = await requestJson(mf, "/recycle", { method: "POST" });
  if (recycled.closed?.status !== 0) {
    throw new Error(`first recycle failed: ${recycled.closed?.message}`);
  }
  recordProgress({ phase: "recycled", lastCompletedPhase: "recycled" });
  await mf.dispose();
  await waitForRuntimeExit(loadRuntimeIdentity, "load");
  mf = null;
  recordProgress({
    phase: "load-runtime-exited",
    lastCompletedPhase: "load-runtime-exited",
    loadRuntimeExitedBeforeReopen: true,
  });

  mf = createRuntime();
  await mf.ready;
  reopenRuntimeIdentity = await waitForRuntimeIdentity(1);
  if (
    loadRuntimeIdentity &&
    reopenRuntimeIdentity &&
    (loadRuntimeIdentity.cgroup === reopenRuntimeIdentity.cgroup ||
      (loadRuntimeIdentity.pid === reopenRuntimeIdentity.pid &&
        loadRuntimeIdentity.startTime === reopenRuntimeIdentity.startTime))
  ) {
    throw new Error("reopen reused the load workerd process or cgroup");
  }
  recordProgress({
    phase: "reopen-runtime-ready",
    runtimeCount: 2,
    processIdentityVerified:
      loadRuntimeIdentity !== null && reopenRuntimeIdentity !== null,
  });
  let titleResponseSha256 = null;
  const reopenedVerificationResponses = {};
  for (const [index, row] of verify.entries()) {
    recordProgress({ phase: "reopen-in-flight" });
    const result = await exchange(mf, row);
    responseBytes += result.bytes;
    const expectedSha256 = expectedVerifyResponses[row.filename];
    if (expectedSha256 && result.sha256 !== expectedSha256) {
      throw new Error(
        `${row.filename}: expected response sha256 ${expectedSha256}, ` +
          `got ${result.sha256}`,
      );
    }
    if (expectedSha256) {
      reopenedVerificationResponses[row.filename] = {
        expectedSha256,
        observedSha256: result.sha256,
      };
    }
    if (row.filename === "verify-title.bin") titleResponseSha256 = result.sha256;
    recordProgress({
      phase: "reopen-verify",
      lastCompletedPhase: "reopen-verify",
      completedVerifyPackets: index + 1,
    });
  }
  const expectedTitleResponseSha256 = readFileSync(
    `${corpus}/expected-title-response.sha256`,
    "utf8",
  ).trim();
  if (titleResponseSha256 !== expectedTitleResponseSha256) {
    throw new Error(
      `reopened title scan mismatch: expected ${expectedTitleResponseSha256}, ` +
        `got ${titleResponseSha256}`,
    );
  }
  const reopened = await requestJson(mf, "/stats");
  if (
    canonicalJson(reopened.runtimeConfiguration) !==
      canonicalJson(CAPACITY_RUNTIME_CONFIGURATION)
  ) {
    throw new Error(
      "Worker runtime configuration did not match the capacity profile",
    );
  }
  const reopenedProgress = recordProgress({
    phase: "reopened",
    lastCompletedPhase: "reopened",
    reopenedGuestLinearMemoryBytes: reopened.engine.linearMemoryBytes,
  });
  recordProgress({ phase: "final-recycle-in-flight" });
  const finalRecycle = await requestJson(mf, "/recycle", { method: "POST" });
  if (finalRecycle.closed?.status !== 0) {
    throw new Error(`final recycle failed: ${finalRecycle.closed?.message}`);
  }
  recordProgress({
    phase: "final-recycled",
    lastCompletedPhase: "final-recycled",
  });
  await mf.dispose();
  await waitForRuntimeExit(reopenRuntimeIdentity, "reopen");
  mf = null;
  recordProgress({
    phase: "reopen-runtime-exited",
    lastCompletedPhase: "reopen-runtime-exited",
    reopenRuntimeExited: true,
  });

  const engineSamples = [loaded.engine, recycled.before, reopened.engine,
    finalRecycle.before].filter(Boolean);
  const highWater = Math.max(...engineSamples.map((one) => one.linearMemoryBytes));
  const arenaPeak = Math.max(...engineSamples.map((one) => one.arenaPeakLiveBytes));
  if (loaded.engine.logBytes <= 0 || reopened.engine.logBytes !== loaded.engine.logBytes) {
    throw new Error(
      `durable reopen mismatch: loaded=${loaded.engine.logBytes}, ` +
        `reopened=${reopened.engine.logBytes}`,
    );
  }
  const result = {
    schema: "store-cloudflare-workerd-functional/v1",
    pass: true,
    corpus: profile,
    loadPackets: load.length,
    verifyPackets: verify.length,
    responseBytes,
    deploymentBundle,
    runtimeConfiguration: {
      ...CAPACITY_RUNTIME_CONFIGURATION,
      observedAtRuntime: true,
    },
    guestLinearMemoryHighWaterBytes: highWater,
    loadedGuestLinearMemoryBytes: loaded.engine.linearMemoryBytes,
    reopenedGuestLinearMemoryBytes: reopened.engine.linearMemoryBytes,
    conservativeLoadedPlusReopenedGuestLinearBytes:
      loaded.engine.linearMemoryBytes + reopened.engine.linearMemoryBytes,
    workerdProcessTreeCumulativePeakAtLoadedBytes:
      loadedProgress.processTreeCumulativePeakAtLoadedBytes,
    workerdProcessTreeCumulativePeakAfterReopenBytes:
      reopenedProgress.processTreeCumulativePeakAfterReopenBytes,
    guestArenaPeakLiveBytes: arenaPeak,
    durableLogBytes: reopened.engine.logBytes,
    durableImageBytes: reopened.engine.imageBytes,
    storageCommits: loaded.storage.commits,
    reopenedFromDurableStorage: true,
    durableStorageReusedAcrossProcesses: true,
    workerdLifecycle: "process-replacement",
    runtimeCount: 2,
    loadRuntimeExitedBeforeReopen: true,
    reopenRuntimeExited: true,
    processIdentityVerified:
      loadRuntimeIdentity !== null && reopenRuntimeIdentity !== null,
    reopenedTitleResponseSha256: titleResponseSha256,
    reopenedVerificationResponses,
  };
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, canonicalJson(result));
  recordProgress({ phase: "complete", lastCompletedPhase: "complete" });
  process.stdout.write(
    `run-workerd: PASS ${profile.expectedFacts} facts, ` +
      `linear-memory-high-water=${highWater} bytes\n`,
  );
} finally {
  if (mf !== null) await mf.dispose();
}
