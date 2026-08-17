// SPDX-License-Identifier: MIT OR Apache-2.0
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  COMPRESSED_LIMIT_BYTES,
  ISOLATE_MEMORY_LIMIT_BYTES,
  RAW_BUNDLE_LIMIT_BYTES,
  REQUIRED_CORPUS_PROFILE,
  canonicalJson,
  makeReceipt,
  parseWranglerUpload,
} from "./receipt.mjs";
import { CAPACITY_RUNTIME_CONFIGURATION } from "./config.mjs";

function fixture(overrides = {}) {
  const bundle = {
    emittedBytes: 700,
    conservativeGzipBytes: 400,
    files: [
      {
        path: `${"1".repeat(32)}-libstore.wasm`,
        bytes: 123,
        gzipBytes: 100,
        sha256: "0".repeat(64),
      },
      {
        path: "worker.js",
        bytes: 577,
        gzipBytes: 300,
        sha256: "3".repeat(64),
      },
    ],
  };
  return {
    plan: "free",
    bundle,
    wrangler: {
      reportedRawBytes: 700,
      reportedGzipBytes: 400,
      note: "fixture",
    },
    functional: {
      pass: true,
      corpus: { ...REQUIRED_CORPUS_PROFILE },
      deploymentBundle: structuredClone(bundle),
      loadFrames: 29,
      verifyFrames: 4,
      responseBytes: 3,
      runtimeConfiguration: {
        ...CAPACITY_RUNTIME_CONFIGURATION,
        observedAtRuntime: true,
      },
      reopenedFromDurableStorage: true,
      durableStorageReusedAcrossProcesses: true,
      workerdLifecycle: "process-replacement",
      runtimeCount: 2,
      loadRuntimeExitedBeforeReopen: true,
      reopenRuntimeExited: true,
      processIdentityVerified: true,
      durableLogBytes: 4,
      durableImageBytes: 0,
      storageCommits: 29,
      reopenedTitleResponseSha256: "2".repeat(64),
      reopenedVerificationResponses: {
        "verify-title.bin": {
          expectedSha256: "2".repeat(64),
          observedSha256: "2".repeat(64),
        },
        "verify-ordered-title.bin": {
          expectedSha256: "4".repeat(64),
          observedSha256: "4".repeat(64),
        },
        "verify-bound-title-text.bin": {
          expectedSha256: "5".repeat(64),
          observedSha256: "5".repeat(64),
        },
      },
      guestLinearMemoryHighWaterBytes: 4 * 1024 * 1024,
      loadedGuestLinearMemoryBytes: 4 * 1024 * 1024,
      reopenedGuestLinearMemoryBytes: 3 * 1024 * 1024,
      conservativeLoadedPlusReopenedGuestLinearBytes: 7 * 1024 * 1024,
      workerdProcessTreeCumulativePeakAtLoadedBytes: 48 * 1024 * 1024,
      workerdProcessTreeCumulativePeakAfterReopenBytes: 64 * 1024 * 1024,
      guestArenaPeakLiveBytes: 1024,
    },
    cgroup: {
      Scope: "workerd-process-tree-only",
      Lifecycle: "process-replacement",
      RuntimeCount: "2",
      OwnedPidsExited: "1",
      RuntimeLimitsExact: "1",
      MemoryResult: "not-oom-killed",
      MemoryOomKills: "0",
      ControllerExitStatus: "0",
      ProcessesRemainingAfterController: "0",
      MemoryPeak: `${64 * 1024 * 1024}`,
      LoadMemoryPeak: `${48 * 1024 * 1024}`,
      ReopenMemoryPeak: `${64 * 1024 * 1024}`,
      MemoryMax: `${ISOLATE_MEMORY_LIMIT_BYTES}`,
      MemorySwapMax: "0",
    },
    wasm: {
      abi: "wasm32",
      artifactAddress: "1".repeat(64),
      artifactInputManifestSha256: "1".repeat(64),
      host: "wasm-embed",
      sourceCommit: "0".repeat(40),
      sourceMode: "built-current-tree",
      sourceTreeClean: true,
      wasmBytes: 123,
      wasmSha256: "0".repeat(64),
    },
    ...overrides,
  };
}

describe("Cloudflare capacity receipt", () => {
  test("pins the full representative wiki-shaped profile", () => {
    const corpus = JSON.parse(
      readFileSync(new URL("./corpus.json", import.meta.url), "utf8"),
    );
    const expected =
      corpus.articles *
      (3 + corpus.revisionsPerArticle * (4 + corpus.linksPerRevision));
    const generatedNames = new Set([
      "spaceId",
      "batches",
      "loadFrames",
      "verifyFrames",
    ]);
    const requiredSourceProfile = Object.fromEntries(
      Object.entries(REQUIRED_CORPUS_PROFILE).filter(
        ([name]) => !generatedNames.has(name),
      ),
    );
    expect(corpus).toEqual(requiredSourceProfile);
    expect(corpus.expectedFacts).toBe(expected);
  });

  test("parses Wrangler's displayed upload units", () => {
    expect(
      parseWranglerUpload("Total Upload: 1.50 MiB / gzip: 200.25 KiB"),
    ).toMatchObject({
      reportedRawBytes: 1572864,
      reportedGzipBytes: 205056,
    });
  });

  test("passes only when every bundle, functional, and cgroup check passes", () => {
    const receipt = makeReceipt(fixture());
    expect(receipt.pass).toBe(true);
    expect(receipt.bundle.wranglerRawBundleLimitBytes).toBe(
      RAW_BUNDLE_LIMIT_BYTES,
    );
    expect(receipt.bundle.platformCompressedBundleLimitBytes).toBe(
      COMPRESSED_LIMIT_BYTES.free,
    );
    expect(receipt.memory.productionIsolatePeakMeasured).toBe(false);
    expect(receipt.memory.workerdProcessTreeMemory.scope).toBe(
      "workerd-process-tree-only",
    );
    expect(receipt.memory.workerdProcessTreeMemory.lifecycle).toBe(
      "process-replacement",
    );
    expect(receipt.memory.workerdProcessTreeMemory.runtimeCount).toBe(2);
    expect(receipt.checks.workerdProcessReplacementVerified).toBe(true);
    expect(receipt.memory.controllerProcesses).toBe(
      "Bun and Miniflare excluded",
    );
    expect(receipt.memory.engineMemoryBudgetBytes).toBe(64 * 1024 * 1024);
    expect(receipt.memory.runtimeConfigurationObserved).toBe(true);
    expect(
      receipt.memory.guestLinearMemory.conservativeLoadedPlusReopenedBytes,
    ).toBe(7 * 1024 * 1024);
    expect(receipt.memory.recycleReopenOverlap.measuredDirectly).toBe(false);
    expect(receipt.exclusions.backupPeakMeasured).toBe(false);
    expect(receipt.exclusions.releaseProof).toBe(false);
  });

  test("fails at a process peak above the enforced ceiling", () => {
    const input = fixture();
    input.cgroup.MemoryPeak = `${ISOLATE_MEMORY_LIMIT_BYTES + 1}`;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.workerdProcessTreePeakWithin128MiB).toBe(false);
  });

  test("fails if either runtime lacks the exact memory and swap limits", () => {
    const input = fixture();
    input.cgroup.RuntimeLimitsExact = "0";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.everyRuntimeLimitIsExact).toBe(false);
    expect(receipt.checks.workerdProcessReplacementVerified).toBe(false);
  });

  test("fails if either phase process tree exceeds 128 MiB", () => {
    const input = fixture();
    input.cgroup.ReopenMemoryPeak = `${ISOLATE_MEMORY_LIMIT_BYTES + 1}`;
    input.cgroup.MemoryPeak = input.cgroup.ReopenMemoryPeak;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.workerdPhaseProcessTreesWithin128MiB).toBe(false);
  });

  test("fails if the launch-blocking corpus is shrunk", () => {
    const input = fixture();
    input.functional.corpus.articles = 32;
    input.functional.corpus.expectedFacts = 864;
    input.functional.corpus.batches = 4;
    input.functional.corpus.loadFrames = 4;
    input.functional.loadFrames = 4;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.fixedCorpusProfileObserved).toBe(false);
    expect(receipt.checks.fullCorpusExecutionPassed).toBe(false);
  });

  test("fails without durable recycle and reopen evidence", () => {
    const input = fixture();
    input.functional.reopenedFromDurableStorage = false;
    input.functional.reopenedTitleResponseSha256 = null;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.durableRecycleReopenVerified).toBe(false);
  });

  test("fails when a post-reopen query response differs from its exact oracle", () => {
    const input = fixture();
    input.functional.reopenedVerificationResponses[
      "verify-ordered-title.bin"
    ].observedSha256 = "6".repeat(64);
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.querySemanticsVerifiedAfterReopen).toBe(false);
  });

  test("fails when phase-level process-tree peaks are absent", () => {
    const input = fixture();
    input.functional.workerdProcessTreeCumulativePeakAtLoadedBytes = null;
    input.functional.workerdProcessTreeCumulativePeakAfterReopenBytes = null;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.workerdProcessTreePhasePeaksMeasured).toBe(false);
  });

  test("fails without two distinct workerd runtime lifecycles", () => {
    const input = fixture();
    input.functional.runtimeCount = 1;
    input.functional.loadRuntimeExitedBeforeReopen = false;
    input.cgroup.RuntimeCount = "1";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.workerdProcessReplacementVerified).toBe(false);
  });

  test("fails without exact process-exit evidence", () => {
    const input = fixture();
    input.functional.processIdentityVerified = false;
    input.cgroup.OwnedPidsExited = "0";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.controllerReapedWorkerd).toBe(false);
    expect(receipt.checks.workerdProcessReplacementVerified).toBe(false);
  });

  test("fails when a phase cgroup peak does not cover its observation", () => {
    const input = fixture();
    input.cgroup.ReopenMemoryPeak = `${32 * 1024 * 1024}`;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.workerdProcessTreePhasePeaksMeasured).toBe(false);
  });

  test("fails when the controller reports a workerd failure", () => {
    const input = fixture();
    input.cgroup.ControllerExitStatus = "1";
    input.cgroup.MemoryResult = "oom-kill";
    input.cgroup.MemoryOomKills = "1";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.controllerSucceeded).toBe(false);
    expect(receipt.checks.workerdProcessTreeNotOomKilled).toBe(false);
  });

  test("fails when the controller leaves workerd running", () => {
    const input = fixture();
    input.cgroup.ProcessesRemainingAfterController = "1";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.controllerReapedWorkerd).toBe(false);
  });

  test("does not call missing guest telemetry within budget", () => {
    const input = fixture();
    input.functional.pass = false;
    input.functional.guestLinearMemoryHighWaterBytes = null;
    input.functional.loadedGuestLinearMemoryBytes = null;
    input.functional.reopenedGuestLinearMemoryBytes = null;
    input.functional.conservativeLoadedPlusReopenedGuestLinearBytes = null;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.guestLinearMemoryMeasured).toBe(false);
    expect(receipt.checks.guestLinearMemoryWithin128MiB).toBe(false);
    expect(receipt.checks.loadedAndReopenedGuestLinearMemoryMeasured).toBe(
      false,
    );
  });

  test("fails when loaded plus reopened linear memory exceeds the ceiling", () => {
    const input = fixture();
    input.functional.guestLinearMemoryHighWaterBytes = 70 * 1024 * 1024;
    input.functional.loadedGuestLinearMemoryBytes = 70 * 1024 * 1024;
    input.functional.reopenedGuestLinearMemoryBytes = 70 * 1024 * 1024;
    input.functional.conservativeLoadedPlusReopenedGuestLinearBytes =
      140 * 1024 * 1024;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(
      receipt.checks.conservativeRecycleReopenGuestLinearWithin128MiB,
    ).toBe(false);
  });

  test("rejects the obsolete controller-inclusive memory scope", () => {
    const input = fixture();
    input.cgroup.Scope = "controller-and-workerd";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.memoryScopeIsWorkerdProcessTreeOnly).toBe(false);
  });

  test("fails when the runtime configuration was not observed", () => {
    const input = fixture();
    input.functional.runtimeConfiguration.observedAtRuntime = false;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.runtimeConfigurationObserved).toBe(false);
  });

  test("fails when the Wasm was supplied instead of built from current source", () => {
    const input = fixture();
    input.wasm.sourceMode = "supplied-artifact";
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.currentSourceArtifact).toBe(false);
  });

  test("fails when the native artifact address does not bind its input manifest", () => {
    const input = fixture();
    input.wasm.artifactAddress = "2".repeat(64);
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.currentSourceArtifact).toBe(false);
  });

  test("fails when the selected plan's compressed upload is too large", () => {
    const input = fixture();
    input.wrangler.reportedGzipBytes = COMPRESSED_LIMIT_BYTES.free + 1;
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.wranglerCompressedWithinPlanLimit).toBe(false);
  });

  test("fails when workerd did not execute the measured Wrangler bundle", () => {
    const input = fixture();
    input.functional.deploymentBundle.files[1].sha256 = "4".repeat(64);
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.deploymentBundleExecuted).toBe(false);
  });

  test("fails when Wrangler bundled Wasm outside current-source provenance", () => {
    const input = fixture();
    input.bundle.files[0].sha256 = "5".repeat(64);
    input.functional.deploymentBundle = structuredClone(input.bundle);
    const receipt = makeReceipt(input);
    expect(receipt.pass).toBe(false);
    expect(receipt.checks.bundleCarriesProvenancedWasm).toBe(false);
  });

  test("canonical JSON sorts recursively and ends in one newline", () => {
    expect(canonicalJson({ z: { b: 2, a: 1 }, a: 0 })).toBe(
      '{\n  "a": 0,\n  "z": {\n    "a": 1,\n    "b": 2\n  }\n}\n',
    );
  });
});
