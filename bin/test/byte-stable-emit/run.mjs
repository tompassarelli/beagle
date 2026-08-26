import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "fs/promises";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { pathToFileURL } from "url";

import {
  canonicalJson,
  executeCanonicalPlan,
  runSupervised,
} from "../../../tools/task-effects/executor.mjs";
import { resolveRunBounded } from "../../../tools/task-effects/run-bounded.mjs";

function fail(message) {
  throw new Error(`byte-stable-emit: ${message}`);
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (value === undefined || value === "") fail(`${name} must be explicit`);
  return value;
}

const here = dirname(new URL(import.meta.url).pathname);
const repositoryRoot = await realpath(resolve(here, "../../.."));
const racketPath = process.argv[2] || process.env.RACKET;
if (racketPath === undefined || racketPath === "") {
  fail("expected the pinned Racket path as the only argument");
}
if (process.argv.length > 3) fail("expected at most one pinned Racket argument");

const supervisor = await resolveRunBounded(repositoryRoot);
const lab = await mkdtemp(join(tmpdir(), "beagle-byte-stable-plan-"));
try {
  const plannerOutput = join(lab, "plan.mjs");
  const plannerReceipt = join(lab, "planner-build.receipt");
  const build = await runSupervised({
    supervisor,
    argv: [join(repositoryRoot, "bin", "beagle-build"), join(here, "plan.bjs"), plannerOutput],
    cwd: repositoryRoot,
    env: process.env,
    deadlineSeconds: 120,
    killGraceSeconds: 1,
    terminationSignal: "SIGTERM",
    maxStdoutBytes: 16777216,
    maxStderrBytes: 16777216,
    completionReceiptPath: plannerReceipt,
  });
  if (build.completionKind !== "exit" || build.status !== 0 || build.stdout.exceeded || build.stderr.exceeded) {
    fail(
      `typed planner build did not complete cleanly: completion=${build.completionKind} status=${build.status}\n${build.stderr.bytes.toString("utf8")}`,
    );
  }

  const packageRoot = join(lab, "node_modules", "beagle");
  await mkdir(packageRoot, { recursive: true });
  await writeFile(join(packageRoot, "package.json"), '{"type":"module"}\n', { flag: "wx" });
  await symlink(
    join(repositoryRoot, "beagle-lib", "lib", "beagle", "core.js"),
    join(packageRoot, "core.js"),
  );
  const planner = await import(pathToFileURL(plannerOutput).href);
  const makePlan = planner["make-byte-stable-emit-plan-v1"];
  if (typeof makePlan !== "function") fail("typed planner export is absent");
  const plan = makePlan(
    await realpath(racketPath),
    requiredEnvironment("PLTCOLLECTS"),
    "local-test:byte-stable-emit/v1",
    "local-test:byte-stable-emit/attempt/v1",
  );
  const planBytes = canonicalJson(plan);
  await Bun.write(join(lab, "plan.json"), planBytes);
  const receipt = await executeCanonicalPlan(planBytes, repositoryRoot, supervisor);

  for (const semanticCase of receipt.cases) {
    console.log(`${semanticCase.verdict === "pass" ? "PASS" : "FAIL"} ${semanticCase.caseId}: ${semanticCase.claim}`);
  }
  console.log(canonicalJson(receipt).trimEnd());
  process.exitCode = receipt.finalVerdict === "pass" ? 0 : 1;
} finally {
  await rm(lab, { recursive: true, force: true });
}
