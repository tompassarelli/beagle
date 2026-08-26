import assert from "assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";

import {
  PlanContractError,
  canonicalJson,
  executeCanonicalPlan,
  runSupervised,
  validatePlan,
  validateReceipt,
} from "./executor.mjs";
import { resolveRunBounded } from "./run-bounded.mjs";

let checks = 0;

function check(label, thunk) {
  try {
    thunk();
    checks += 1;
    console.log(`PASS ${label}`);
  } catch (error) {
    console.error(`FAIL ${label}: ${error.stack || error}`);
    process.exitCode = 1;
  }
}

async function checkAsync(label, thunk) {
  try {
    await thunk();
    checks += 1;
    console.log(`PASS ${label}`);
  } catch (error) {
    console.error(`FAIL ${label}: ${error.stack || error}`);
    process.exitCode = 1;
  }
}

function repoPath(relative) {
  return { _tag: "RepoPathV1", relative };
}

function tempPath(tempdirId, relative) {
  return { _tag: "TempPathV1", relative, tempdirId };
}

function basePlan() {
  return {
    _tag: "TaskEffectPlanV1",
    artifacts: [
      {
        _tag: "ArtifactV1",
        artifactId: "input",
        artifactKind: "file",
        digestWhen: "before",
        expectedDigest: null,
        path: repoPath("input.txt"),
      },
    ],
    authority: {
      _tag: "EffectAuthorityV1",
      attemptRef: "local-test:attempt",
      authorizationRef: "local-test:authorization",
      intentRef: "local-test:intent",
    },
    cases: [],
    effects: [],
    planKind: "test.fixture/v1",
    schemaVersion: "task-effect-plan/v1",
  };
}

function processPlan() {
  const plan = basePlan();
  plan.artifacts.push(
    {
      _tag: "ArtifactV1",
      artifactId: "stdout",
      artifactKind: "file",
      digestWhen: "after",
      expectedDigest: null,
      path: tempPath("run", "stdout"),
    },
    {
      _tag: "ArtifactV1",
      artifactId: "stderr",
      artifactKind: "file",
      digestWhen: "after",
      expectedDigest: null,
      path: tempPath("run", "stderr"),
    },
  );
  plan.effects.push(
    {
      _tag: "TempdirAllocateV1",
      dependsOn: [],
      effectId: "temp.run",
      prefix: "task-effect-test-",
      tempdirId: "run",
    },
    {
      _tag: "ProcessRunV1",
      acceptedStatuses: [0],
      argv: [{ _tag: "LiteralArgV1", value: "/bin/true" }],
      cwd: repoPath("."),
      deadlineSeconds: 1,
      dependsOn: ["temp.run"],
      effectId: "process.run",
      environment: { _tag: "ProcessEnvironmentV1", entries: [], policy: "replace" },
      killGraceSeconds: 1,
      maxStderrBytes: 1024,
      maxStdoutBytes: 1024,
      stderrArtifactId: "stderr",
      stdinMode: "null",
      stdoutArtifactId: "stdout",
      terminationSignal: "SIGTERM",
    },
  );
  return plan;
}

function expectContract(thunk, pattern) {
  assert.throws(thunk, (error) => error instanceof PlanContractError && pattern.test(error.message));
}

check("closed plan rejects unknown fields", () => {
  const plan = basePlan();
  plan.ambient = true;
  expectContract(() => validatePlan(plan), /fields must be exactly/);
});

check("unknown effect variants fail closed", () => {
  const plan = basePlan();
  plan.effects.push({ _tag: "ShellStringV1", effectId: "escape" });
  expectContract(() => validatePlan(plan), /unsupported operation kind/);
});

check("duplicate artifact ids are rejected", () => {
  const plan = basePlan();
  plan.artifacts.push({ ...plan.artifacts[0] });
  expectContract(() => validatePlan(plan), /artifact ids must be unique/);
});

check("undeclared check references are rejected", () => {
  const plan = basePlan();
  plan.cases.push({
    _tag: "SemanticCaseV1",
    caseId: "case",
    checks: [{ _tag: "ArtifactContainsCheckV1", artifactId: "absent", needle: "x" }],
    claim: "closed references",
  });
  expectContract(() => validatePlan(plan), /undeclared artifact absent/);
});

check("missing authorization fails closed", () => {
  const plan = basePlan();
  plan.authority.authorizationRef = "";
  expectContract(() => validatePlan(plan), /authorizationRef must not be empty/);
});

check("malformed process bounds are rejected", () => {
  const plan = processPlan();
  plan.effects[1].deadlineSeconds = 0;
  expectContract(() => validatePlan(plan), /deadlineSeconds must be a safe integer/);
});

check("lexical path escape is rejected", () => {
  const plan = basePlan();
  plan.artifacts[0].path.relative = "../outside";
  expectContract(() => validatePlan(plan), /escaping/);
});

check("receipt validation rejects unknown fields", () => {
  const receipt = {
    artifacts: [],
    attemptRef: "a",
    authorizationRef: "b",
    cases: [],
    effects: [],
    finalVerdict: "pass",
    intentRef: "c",
    planDigest: "0".repeat(64),
    planKind: "test",
    schemaVersion: "task-effect-receipt/v1",
    unknown: true,
  };
  expectContract(() => validateReceipt(receipt), /fields must be exactly/);
});

const repository = await mkdtemp(join(tmpdir(), "task-effect-repository-"));
const outside = await mkdtemp(join(tmpdir(), "task-effect-outside-"));
try {
  await writeFile(join(repository, "input.txt"), "input\n");
  await writeFile(join(outside, "secret.txt"), "secret\n");

  await checkAsync("digest mismatch is rejected before effects", async () => {
    const plan = basePlan();
    plan.artifacts[0].expectedDigest = "0".repeat(64);
    await assert.rejects(
      executeCanonicalPlan(canonicalJson(plan), repository, "/bin/false"),
      /digest mismatch/,
    );
  });

  await checkAsync("symlink escape is rejected", async () => {
    await symlink(join(outside, "secret.txt"), join(repository, "link.txt"));
    const plan = basePlan();
    plan.artifacts[0].path.relative = "link.txt";
    await assert.rejects(
      executeCanonicalPlan(canonicalJson(plan), repository, "/bin/false"),
      /traverses symlink/,
    );
  });

  await checkAsync("non-canonical plan bytes are rejected", async () => {
    await assert.rejects(
      executeCanonicalPlan(`${canonicalJson(basePlan())}\n`, repository, "/bin/false"),
      /not canonical JSON/,
    );
  });

  const beagleRoot = process.argv[2];
  if (beagleRoot === undefined) throw new Error("expected Beagle repository root argument");
  const supervisor = await resolveRunBounded(beagleRoot);
  const bun = process.execPath;
  const receipts = await mkdtemp(join(tmpdir(), "task-effect-supervision-"));
  try {
    await checkAsync("child exit 124 remains an exit receipt", async () => {
      const result = await runSupervised({
        supervisor,
        argv: [bun, "-e", "process.exit(124)"],
        cwd: repository,
        env: process.env,
        deadlineSeconds: 5,
        killGraceSeconds: 1,
        terminationSignal: "SIGTERM",
        maxStdoutBytes: 1024,
        maxStderrBytes: 8192,
        completionReceiptPath: join(receipts, "exit-124.receipt"),
      });
      assert.equal(result.status, 124);
      assert.equal(result.completionKind, "exit");
    });

    await checkAsync("supervisor timeout remains a timeout receipt", async () => {
      const result = await runSupervised({
        supervisor,
        argv: [bun, "-e", "await Bun.sleep(5000)"],
        cwd: repository,
        env: process.env,
        deadlineSeconds: 1,
        killGraceSeconds: 1,
        terminationSignal: "SIGTERM",
        maxStdoutBytes: 1024,
        maxStderrBytes: 8192,
        completionReceiptPath: join(receipts, "timeout.receipt"),
      });
      assert.equal(result.status, 124);
      assert.equal(result.completionKind, "timeout");
    });

    await checkAsync("capture overflow terminates and reaps the supervised tree", async () => {
      const result = await runSupervised({
        supervisor,
        argv: [bun, "-e", 'console.log("x".repeat(4096)); await Bun.sleep(5000)'],
        cwd: repository,
        env: process.env,
        deadlineSeconds: 5,
        killGraceSeconds: 1,
        terminationSignal: "SIGTERM",
        maxStdoutBytes: 32,
        maxStderrBytes: 8192,
        completionReceiptPath: join(receipts, "overflow.receipt"),
      });
      assert.equal(result.stdout.exceeded, true);
      assert.equal(result.completionKind, "exit");
      assert.notEqual(result.status, 0);
    });
  } finally {
    await rm(receipts, { recursive: true, force: true });
  }
} finally {
  await rm(repository, { recursive: true, force: true });
  await rm(outside, { recursive: true, force: true });
}

if (process.exitCode === undefined) console.log(`task-effect tests: ${checks} checks passed`);
