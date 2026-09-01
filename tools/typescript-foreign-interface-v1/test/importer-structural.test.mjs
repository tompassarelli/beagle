import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  bindCompiledAdapter,
  bindProducerInputs,
  createSourceCompilerBridge,
  createSourceContext,
  sourceImporterBuilder,
} from "../src/typescript-api.mjs";

const adapterRoot = resolve(import.meta.dir, "..");
const repositoryRoot = resolve(adapterRoot, "../..");
const runtimeRoot = resolve(repositoryRoot, "beagle-lib/lib/beagle");
const fixture = resolve(adapterRoot, "fixture/structural-intersection.ts");
const classLoopFixture = resolve(adapterRoot, "fixture/class-loop-operators.ts");
const temporary = mkdtempSync(join(tmpdir(), "beagle-ts-structural-import-"));
const compiled = resolve(temporary, "importer.mjs");

afterAll(() => {
  rmSync(temporary, { recursive: true, force: true });
});

beforeAll(() => {
  const result = Bun.spawnSync([
    resolve(repositoryRoot, "bin/beagle-build"),
    resolve(adapterRoot, "src/importer.bjs"),
    compiled,
  ], {
    cwd: repositoryRoot,
    env: { ...process.env, BEAGLE_EMIT_SRCLOC: "0" },
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(result.exitCode, result.stderr.toString()).toBe(0);
}, 30_000);

async function importFixture(
  sourceFile = fixture,
  namespace = "beagle.typescript.structural-intersection",
) {
  const compiledAdapter = bindCompiledAdapter(compiled);
  const producerInputs = bindProducerInputs({
    adapterRoot,
    runnerName: "src/import-source.mjs",
  });
  const bridge = createSourceCompilerBridge({
    adapterRoot,
    compiledAdapter,
    producerInputs,
  });
  const context = createSourceContext({ projectRoot: adapterRoot, sourceFile });
  const importer = sourceImporterBuilder(await compiledAdapter.load(runtimeRoot));
  return importer(
    bridge,
    context,
    namespace,
    new Map(),
  );
}

test("intersections and anonymous object types become deterministic checked records", async () => {
  const first = await importFixture();
  const second = await importFixture();

  expect(second).toEqual(first);
  expect(first.diagnostics).toEqual([]);
  expect(first.source).toContain(
    "(defrecord TypeScriptAnonymousObjectV1 [entry TypeScriptStructuralObjectV1 label (U Nil String)])",
  );
  expect(first.source).toContain(
    "(defrecord TypeScriptStructuralObjectV1 [observedAt String pressure String])",
  );
  expect(first.source).toContain(
    "(defrecord OptionalEvidence [observedAt (U Nil String) pressure (U Nil String)])",
  );
  expect(first.source).toContain("(defrecord TypeScriptUnknownV1 [])");
  expect(first.source).toContain("(defrecord TypeScriptObjectV1 [])");
  expect(first.source).toContain(
    "(->TypeScriptAnonymousObjectV1 entry nil)",
  );
  expect(first.source).toContain(
    "[optional OptionalEvidence uncertainty TypeScriptUnknownV1 opaque TypeScriptObjectV1]",
  );
  expect(first.source).not.toContain("__typescript_import_unsupported__");
  expect(first.source).not.toContain(" Any");

  const imported = resolve(temporary, "structural-intersection.bjs");
  writeFileSync(imported, first.source);
  const checked = Bun.spawnSync([
    resolve(repositoryRoot, "bin/beagle"),
    "check",
    imported,
  ], {
    cwd: repositoryRoot,
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(checked.exitCode, checked.stderr.toString()).toBe(0);
});

test("classes, local constructors, bounded loops, and exact JS operators lower together", async () => {
  const result = await importFixture(
    classLoopFixture,
    "beagle.typescript.class-loop-operators",
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source).toContain(
    "(defrecord MutableBucket [selected (Atom (U Nil String)) visits (Atom Number) label String])",
  );
  expect(result.source).toContain("(defn new-MutableBucket");
  expect(result.source).toContain("(defn mutablebucket-choose! [self MutableBucket candidate String]");
  expect(result.source).toContain("(defn mutablebucket-count! [self MutableBucket values (Vec String)]");
  expect(result.source).toContain("(js/in? values key)");
  expect(result.source).toContain("(instance? Error value)");
  expect(result.source).toContain("(new-MutableBucket label)");
  expect(result.source).toContain("(do (.resolve Promise candidate) nil)");
  expect(result.source).toContain("#{}");
  expect(result.source).not.toContain("__typescript_import_unsupported__");

  const imported = resolve(temporary, "class-loop-operators.bjs");
  writeFileSync(imported, result.source);
  const checked = Bun.spawnSync([
    resolve(repositoryRoot, "bin/beagle"),
    "check",
    imported,
  ], {
    cwd: repositoryRoot,
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(checked.exitCode, checked.stderr.toString()).toBe(0);
});
