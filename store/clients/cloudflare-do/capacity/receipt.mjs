// SPDX-License-Identifier: MIT OR Apache-2.0
import { createHash } from "node:crypto";
import {
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import { gzipSync } from "node:zlib";
import { relative, resolve } from "node:path";
import { CAPACITY_RUNTIME_CONFIGURATION } from "./config.mjs";

export const RAW_BUNDLE_LIMIT_BYTES = 64 * 1024 * 1024;
export const COMPRESSED_LIMIT_BYTES = Object.freeze({
  free: 3 * 1024 * 1024,
  paid: 10 * 1024 * 1024,
});
export const ISOLATE_MEMORY_LIMIT_BYTES = 128 * 1024 * 1024;
export const REQUIRED_VERIFY_RESPONSE_FILENAMES = Object.freeze([
  "verify-title.bin",
  "verify-ordered-title.bin",
  "verify-bound-title-text.bin",
]);
export const REQUIRED_CORPUS_PROFILE = Object.freeze({
  schema: "store-wiki-capacity-corpus/v1",
  profile: "wiki-shaped-256x3-2k-v1",
  interpretation: "fixed structural workload, not a traffic forecast",
  decision: "launch-blocking capacity floor",
  articles: 256,
  revisionsPerArticle: 3,
  linksPerRevision: 4,
  bodyBytes: 2048,
  actionsPerBatch: 240,
  expectedFacts: 6912,
  spaceId: "store-wiki-capacity-v1",
  batches: 29,
  loadFrames: 29,
  verifyFrames: 4,
});

export function canonicalJson(value) {
  const normalize = (one) => {
    if (Array.isArray(one)) return one.map(normalize);
    if (one && typeof one === "object") {
      return Object.fromEntries(
        Object.keys(one)
          .sort()
          .map((key) => [key, normalize(one[key])]),
      );
    }
    return one;
  };
  return `${JSON.stringify(normalize(value), null, 2)}\n`;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function filesUnder(root, at = root) {
  return readdirSync(at, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap((entry) => {
      const path = resolve(at, entry.name);
      return entry.isDirectory() ? filesUnder(root, path) : [path];
    });
}

export function measureBundle(bundleDirectory) {
  const root = resolve(bundleDirectory);
  const files = filesUnder(root)
    .filter((path) => {
      const name = relative(root, path).replaceAll("\\", "/");
      return name !== "README.md" && !name.endsWith(".map");
    })
    .map((path) => {
      const bytes = readFileSync(path);
      return {
        path: relative(root, path).replaceAll("\\", "/"),
        bytes: bytes.length,
        gzipBytes: gzipSync(bytes, { level: 9, mtime: 0 }).length,
        sha256: sha256(bytes),
      };
    });
  return {
    files,
    emittedBytes: files.reduce((sum, file) => sum + file.bytes, 0),
    conservativeGzipBytes: files.reduce(
      (sum, file) => sum + file.gzipBytes,
      0,
    ),
  };
}

function unitBytes(value, unit) {
  const scale = { B: 1, KiB: 1024, MiB: 1024 * 1024 }[unit];
  if (!scale) throw new Error(`unsupported Wrangler size unit: ${unit}`);
  return Math.round(Number(value) * scale);
}

export function parseWranglerUpload(text) {
  const match = text.match(
    /Total Upload:\s*([0-9.]+)\s*(B|KiB|MiB)\s*\/\s*gzip:\s*([0-9.]+)\s*(B|KiB|MiB)/i,
  );
  if (!match) throw new Error("Wrangler output omitted Total Upload / gzip");
  return {
    reportedRawBytes: unitBytes(match[1], match[2]),
    reportedGzipBytes: unitBytes(match[3], match[4]),
    note: "Wrangler CLI values are converted from its displayed rounded units",
  };
}

export function parseProperties(text) {
  return Object.fromEntries(
    text
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        const at = line.indexOf("=");
        if (at <= 0) throw new Error(`invalid capacity property row: ${line}`);
        return [line.slice(0, at), line.slice(at + 1)];
      }),
  );
}

function integerProperty(properties, name) {
  const value = Number(properties[name]);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`capacity property ${name} is not a non-negative integer`);
  }
  return value;
}

function runtimeConfigurationMatches(configuration) {
  return (
    configuration?.observedAtRuntime === true &&
    Object.entries(CAPACITY_RUNTIME_CONFIGURATION).every(
      ([name, value]) => configuration[name] === value,
    )
  );
}

function corpusProfileMatches(corpus) {
  return Object.entries(REQUIRED_CORPUS_PROFILE).every(
    ([name, value]) => corpus?.[name] === value,
  );
}

function bundleExecutionMatches(measured, executed) {
  return (
    executed !== null &&
    executed !== undefined &&
    canonicalJson(executed) === canonicalJson(measured)
  );
}

function exactVerificationResponsesMatch(responses) {
  if (responses === null || typeof responses !== "object") return false;
  const names = Object.keys(responses).sort();
  if (
    canonicalJson(names) !==
    canonicalJson([...REQUIRED_VERIFY_RESPONSE_FILENAMES].sort())
  ) {
    return false;
  }
  return REQUIRED_VERIFY_RESPONSE_FILENAMES.every((filename) => {
    const response = responses[filename];
    return (
      response !== null &&
      typeof response === "object" &&
      /^[0-9a-f]{64}$/.test(response.expectedSha256) &&
      response.observedSha256 === response.expectedSha256
    );
  });
}

export function makeReceipt({
  plan,
  bundle,
  wrangler,
  functional,
  cgroup,
  wasm,
}) {
  const compressedLimit = COMPRESSED_LIMIT_BYTES[plan];
  if (!compressedLimit) throw new Error(`unknown Cloudflare plan: ${plan}`);
  const memoryPeakBytes = integerProperty(cgroup, "MemoryPeak");
  const memoryMaxBytes = integerProperty(cgroup, "MemoryMax");
  const memorySwapMaxBytes = integerProperty(cgroup, "MemorySwapMax");
  const loadMemoryPeakBytes = integerProperty(cgroup, "LoadMemoryPeak");
  const reopenMemoryPeakBytes = integerProperty(cgroup, "ReopenMemoryPeak");
  const runtimeCount = integerProperty(cgroup, "RuntimeCount");
  const ownedPidsExited = integerProperty(cgroup, "OwnedPidsExited");
  const runtimeLimitsExact = integerProperty(cgroup, "RuntimeLimitsExact");
  const controllerExitStatus = integerProperty(
    cgroup,
    "ControllerExitStatus",
  );
  const memoryOomKills = integerProperty(cgroup, "MemoryOomKills");
  const processesRemainingAfterController = integerProperty(
    cgroup,
    "ProcessesRemainingAfterController",
  );
  const guestLinearMemoryMeasured =
    Number.isSafeInteger(functional.guestLinearMemoryHighWaterBytes) &&
    functional.guestLinearMemoryHighWaterBytes > 0;
  const runtimeConfigurationObserved = runtimeConfigurationMatches(
    functional.runtimeConfiguration,
  );
  const loadedGuestLinearMemoryMeasured =
    Number.isSafeInteger(functional.loadedGuestLinearMemoryBytes) &&
    functional.loadedGuestLinearMemoryBytes > 0;
  const reopenedGuestLinearMemoryMeasured =
    Number.isSafeInteger(functional.reopenedGuestLinearMemoryBytes) &&
    functional.reopenedGuestLinearMemoryBytes > 0;
  const conservativeRecycleReopenLinearBytes =
    loadedGuestLinearMemoryMeasured && reopenedGuestLinearMemoryMeasured
      ? functional.loadedGuestLinearMemoryBytes +
        functional.reopenedGuestLinearMemoryBytes
      : null;
  const conservativeRecycleReopenLinearMeasured =
    conservativeRecycleReopenLinearBytes !== null &&
    functional.conservativeLoadedPlusReopenedGuestLinearBytes ===
      conservativeRecycleReopenLinearBytes;
  const guestLinearMemoryHighWaterConsistent =
    guestLinearMemoryMeasured &&
    loadedGuestLinearMemoryMeasured &&
    reopenedGuestLinearMemoryMeasured &&
    functional.guestLinearMemoryHighWaterBytes ===
      Math.max(
        functional.loadedGuestLinearMemoryBytes,
        functional.reopenedGuestLinearMemoryBytes,
      );
  const phasePeakAtLoaded =
    functional.workerdProcessTreeCumulativePeakAtLoadedBytes;
  const phasePeakAfterReopen =
    functional.workerdProcessTreeCumulativePeakAfterReopenBytes;
  const processTreePhasePeaksMeasured =
    Number.isSafeInteger(phasePeakAtLoaded) &&
    phasePeakAtLoaded > 0 &&
    phasePeakAtLoaded <= loadMemoryPeakBytes &&
    Number.isSafeInteger(phasePeakAfterReopen) &&
    phasePeakAfterReopen > 0 &&
    phasePeakAfterReopen <= reopenMemoryPeakBytes &&
    loadMemoryPeakBytes > 0 &&
    reopenMemoryPeakBytes > 0 &&
    memoryPeakBytes === Math.max(loadMemoryPeakBytes, reopenMemoryPeakBytes);
  const workerdProcessReplacementVerified =
    cgroup.Lifecycle === "process-replacement" &&
    runtimeCount === 2 &&
    ownedPidsExited === 1 &&
    runtimeLimitsExact === 1 &&
    functional.workerdLifecycle === "process-replacement" &&
    functional.runtimeCount === 2 &&
    functional.loadRuntimeExitedBeforeReopen === true &&
    functional.reopenRuntimeExited === true &&
    functional.processIdentityVerified === true &&
    functional.durableStorageReusedAcrossProcesses === true;
  const currentSourceArtifact =
    wasm.sourceMode === "built-current-tree" &&
    wasm.sourceTreeClean === true &&
    /^[0-9a-f]{40}$/.test(wasm.sourceCommit) &&
    /^[0-9a-f]{64}$/.test(wasm.artifactInputManifestSha256) &&
    wasm.artifactAddress === wasm.artifactInputManifestSha256 &&
    wasm.host === "wasm-embed" &&
    wasm.abi === "wasm32" &&
    Number.isSafeInteger(wasm.wasmBytes) &&
    wasm.wasmBytes > 0 &&
    /^[0-9a-f]{64}$/.test(wasm.wasmSha256);
  const fixedCorpusProfileObserved = corpusProfileMatches(functional.corpus);
  const deploymentBundleExecuted = bundleExecutionMatches(
    bundle,
    functional.deploymentBundle,
  );
  const bundledWasm = bundle.files.filter((file) => file.path.endsWith(".wasm"));
  const bundleCarriesProvenancedWasm =
    bundledWasm.length === 1 &&
    bundledWasm[0].bytes === wasm.wasmBytes &&
    bundledWasm[0].sha256 === wasm.wasmSha256;
  const fullCorpusExecutionPassed =
    functional.pass === true &&
    functional.loadFrames === REQUIRED_CORPUS_PROFILE.loadFrames &&
    functional.verifyFrames === REQUIRED_CORPUS_PROFILE.verifyFrames &&
    Number.isSafeInteger(functional.responseBytes) &&
    functional.responseBytes > 0;
  const durableRecycleReopenVerified =
    functional.reopenedFromDurableStorage === true &&
    functional.durableStorageReusedAcrossProcesses === true &&
    Number.isSafeInteger(functional.durableLogBytes) &&
    functional.durableLogBytes > 0 &&
    Number.isSafeInteger(functional.storageCommits) &&
    functional.storageCommits >= REQUIRED_CORPUS_PROFILE.loadFrames &&
    /^[0-9a-f]{64}$/.test(functional.reopenedTitleResponseSha256);
  const querySemanticsVerifiedAfterReopen =
    exactVerificationResponsesMatch(functional.reopenedVerificationResponses) &&
    functional.reopenedVerificationResponses["verify-title.bin"]
      .observedSha256 === functional.reopenedTitleResponseSha256;
  const checks = {
    cgroupLimitIs128MiB: memoryMaxBytes === ISOLATE_MEMORY_LIMIT_BYTES,
    everyRuntimeLimitIsExact: runtimeLimitsExact === 1,
    memoryScopeIsWorkerdProcessTreeOnly:
      cgroup.Scope === "workerd-process-tree-only",
    controllerSucceeded: controllerExitStatus === 0,
    controllerReapedWorkerd:
      processesRemainingAfterController === 0 && ownedPidsExited === 1,
    workerdProcessReplacementVerified,
    workerdProcessTreeNotOomKilled:
      cgroup.MemoryResult === "not-oom-killed" && memoryOomKills === 0,
    cgroupSwapDisabled: memorySwapMaxBytes === 0,
    emittedRawWithinWranglerLimit:
      bundle.emittedBytes <= RAW_BUNDLE_LIMIT_BYTES,
    deploymentBundleExecuted,
    bundleCarriesProvenancedWasm,
    fixedCorpusProfileObserved,
    fullCorpusExecutionPassed,
    durableRecycleReopenVerified,
    querySemanticsVerifiedAfterReopen,
    runtimeConfigurationObserved,
    currentSourceArtifact,
    guestLinearMemoryMeasured,
    guestLinearMemoryHighWaterConsistent,
    guestLinearMemoryWithin128MiB:
      guestLinearMemoryMeasured &&
      functional.guestLinearMemoryHighWaterBytes <= ISOLATE_MEMORY_LIMIT_BYTES,
    loadedAndReopenedGuestLinearMemoryMeasured:
      conservativeRecycleReopenLinearMeasured,
    conservativeRecycleReopenGuestLinearWithin128MiB:
      conservativeRecycleReopenLinearMeasured &&
      conservativeRecycleReopenLinearBytes <= ISOLATE_MEMORY_LIMIT_BYTES,
    workerdProcessTreePhasePeaksMeasured: processTreePhasePeaksMeasured,
    workerdPhaseProcessTreesWithin128MiB:
      loadMemoryPeakBytes <= ISOLATE_MEMORY_LIMIT_BYTES &&
      reopenMemoryPeakBytes <= ISOLATE_MEMORY_LIMIT_BYTES,
    workerdProcessTreePeakWithin128MiB:
      memoryPeakBytes <= ISOLATE_MEMORY_LIMIT_BYTES,
    wranglerCompressedWithinPlanLimit:
      wrangler.reportedGzipBytes <= compressedLimit &&
      bundle.conservativeGzipBytes <= compressedLimit,
    wranglerRawWithinLimit:
      wrangler.reportedRawBytes <= RAW_BUNDLE_LIMIT_BYTES,
  };
  return {
    schema: "store-cloudflare-capacity/v2",
    evidenceKind: "capacity-only-not-release-proof",
    pass: Object.values(checks).every(Boolean),
    checks,
    dependencies: {
      miniflare: {
        version: "5.20260804.1-alpha",
        sourceRevision: "15fc56824836570ca291aa148be72d2d62f59566",
      },
      workerd: {
        version: "1.20260804.1",
        sourceRevision: "abd3d71c2d9a3bd6f27072091d9368fd18ca02e6",
      },
      wrangler: {
        version: "4.121.0",
        sourceRevision: "15fc56824836570ca291aa148be72d2d62f59566",
      },
    },
    bundle: {
      cloudflarePlan: plan,
      wranglerRawBundleLimitBytes: RAW_BUNDLE_LIMIT_BYTES,
      platformCompressedBundleLimitBytes: compressedLimit,
      wranglerReportedRawBytes: wrangler.reportedRawBytes,
      wranglerReportedGzipBytes: wrangler.reportedGzipBytes,
      wranglerReportNote: wrangler.note,
      emittedModuleBytes: bundle.emittedBytes,
      conservativePerModuleGzipBytes: bundle.conservativeGzipBytes,
      files: bundle.files,
    },
    functional: {
      corpus: functional.corpus,
      loadFrames: functional.loadFrames,
      verifyFrames: functional.verifyFrames,
      responseBytes: functional.responseBytes,
      deploymentBundle: functional.deploymentBundle ?? null,
      reopenedFromDurableStorage: functional.reopenedFromDurableStorage,
      durableStorageReusedAcrossProcesses:
        functional.durableStorageReusedAcrossProcesses ?? false,
      workerdLifecycle: functional.workerdLifecycle ?? null,
      runtimeCount: functional.runtimeCount ?? null,
      loadRuntimeExitedBeforeReopen:
        functional.loadRuntimeExitedBeforeReopen ?? false,
      reopenRuntimeExited: functional.reopenRuntimeExited ?? false,
      processIdentityVerified: functional.processIdentityVerified ?? false,
      durableLogBytes: functional.durableLogBytes,
      durableImageBytes: functional.durableImageBytes,
      storageCommits: functional.storageCommits,
      reopenedTitleResponseSha256: functional.reopenedTitleResponseSha256,
      reopenedVerificationResponses:
        functional.reopenedVerificationResponses ?? null,
      failure: functional.failure ?? null,
    },
    memory: {
      cloudflareDocumentedIsolateLimitBytes: ISOLATE_MEMORY_LIMIT_BYTES,
      controllerProcesses: "Bun and Miniflare excluded",
      relationshipToProduction:
        "conservative whole-workerd-runtime proxy for one workload, not isolate accounting",
      engineMemoryBudgetBytes:
        functional.runtimeConfiguration?.engineMemoryBudgetBytes ?? null,
      guestArenaInitialPages:
        functional.runtimeConfiguration?.guestArenaInitialPages ?? null,
      guestArenaGrowPages:
        functional.runtimeConfiguration?.guestArenaGrowPages ?? null,
      runtimeConfigurationObserved,
      guestLinearMemory: {
        metric:
          "WebAssembly.Memory byteLength; reserved linear memory, not RSS",
        highWaterBytes: functional.guestLinearMemoryHighWaterBytes,
        loadedBytes: functional.loadedGuestLinearMemoryBytes,
        reopenedBytes: functional.reopenedGuestLinearMemoryBytes,
        conservativeLoadedPlusReopenedBytes:
          conservativeRecycleReopenLinearBytes,
        arenaPeakLiveBytes: functional.guestArenaPeakLiveBytes,
      },
      workerdProcessTreeMemory: {
        metric:
          "Linux cgroup-v2 charged memory for workerd and descendants; not isolate-only RSS",
        enforcement: "linux-cgroup-v2",
        scope: cgroup.Scope,
        memoryResult: cgroup.MemoryResult,
        oomKills: memoryOomKills,
        controllerExitStatus,
        processesRemainingAfterController,
        lifecycle: cgroup.Lifecycle ?? null,
        runtimeCount,
        ownedPidsExited: ownedPidsExited === 1,
        everyRuntimeLimitExact: runtimeLimitsExact === 1,
        limitBytes: memoryMaxBytes,
        peakBytes: memoryPeakBytes,
        loadRuntimePeakBytes: loadMemoryPeakBytes,
        reopenRuntimePeakBytes: reopenMemoryPeakBytes,
        swapMaxBytes: memorySwapMaxBytes,
        cumulativePeakAtLoadedBytes:
          phasePeakAtLoaded ?? null,
        cumulativePeakAfterReopenBytes:
          phasePeakAfterReopen ?? null,
      },
      recycleReopenOverlap: {
        measuredDirectly: false,
        conservativeGuestLinearBytes: conservativeRecycleReopenLinearBytes,
        reason:
          "load and reopen use non-overlapping workerd processes; the gate retains their loaded-plus-reopened guest-linear sum as an additional conservative ceiling",
      },
      productionIsolatePeakMeasured: false,
      proxyNote:
        "The cgroup includes the full workerd runtime subtree; Cloudflare production isolate-only accounting is not locally observable.",
    },
    wasm: {
      abi: wasm.abi,
      artifactAddress: wasm.artifactAddress,
      artifactInputManifestSha256: wasm.artifactInputManifestSha256,
      host: wasm.host,
      sourceCommit: wasm.sourceCommit,
      sourceMode: wasm.sourceMode,
      sourceTreeClean: wasm.sourceTreeClean,
      wasmBytes: wasm.wasmBytes,
      wasmSha256: wasm.wasmSha256,
    },
    exclusions: {
      accessIdentityAdminAndDeploymentProofMeasured: false,
      backupPeakMeasured: false,
      backupPeakReason:
        "The capacity corpus does not invoke the separate export or restore capability.",
      productionIsolatePeakMeasured: false,
      releaseProof: false,
    },
  };
}

export function loadReceiptInputs({
  plan,
  bundleDirectory,
  wranglerLog,
  functionalResult,
  cgroupProperties,
  wasmProvenance,
}) {
  for (const path of [wranglerLog, functionalResult, cgroupProperties,
    wasmProvenance]) {
    if (!statSync(path).isFile()) throw new Error(`not a file: ${path}`);
  }
  return makeReceipt({
    plan,
    bundle: measureBundle(bundleDirectory),
    wrangler: parseWranglerUpload(readFileSync(wranglerLog, "utf8")),
    functional: JSON.parse(readFileSync(functionalResult, "utf8")),
    cgroup: parseProperties(readFileSync(cgroupProperties, "utf8")),
    wasm: JSON.parse(readFileSync(wasmProvenance, "utf8")),
  });
}
