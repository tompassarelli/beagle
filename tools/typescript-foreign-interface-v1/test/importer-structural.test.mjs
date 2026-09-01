import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
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
const objectLiteralFixture = resolve(adapterRoot, "fixture/object-literal-spreads.ts");
const asyncGeneratorFixture = resolve(adapterRoot, "fixture/async-generator-method.ts");
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
  expect(first.source).toContain(
    "(defalias TypeScriptUnknownV1 (U JsObject JsArray String Number Bool Nil))",
  );
  expect(first.source).toContain("(defalias TypeScriptObjectV1 JsObject)");
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
test("object aliases, spreads, computed keys, and record returns preserve their fields", async () => {
  const result = await importFixture(
    objectLiteralFixture,
    "beagle.typescript.object-literal-spreads",
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source).toContain(
    "(defalias TypeScriptUnknownV1 (U JsObject JsArray String Number Bool Nil))",
  );
  expect(result.source).toContain("(defalias TypeScriptObjectV1 JsObject)");
  expect(result.source).toContain("(defalias JsonObject (Map String TypeScriptUnknownV1))");
  expect(result.source).toContain("(assoc {} projectRoot");
  expect(result.source).toContain("inherited {\"projects\"");
  expect(result.source).toContain(
    "(defrecord TypeScriptAnonymousObjectV1 [environment_id String name TypeScriptUnknownV1])",
  );
  expect(result.source).toContain(
    "(defrecord HookRow [eventName String enabled Bool])",
  );
  expect(result.source).toContain("(->HookRow \"Start\" true)");
  expect(result.source).not.toContain("->__object");
  expect(result.source).not.toContain("->JsonObject");
  expect(result.source).not.toMatch(/\(defrecord [^\s]+ \[\]\)/);
  expect(result.source).not.toContain("__typescript_import_unsupported__");

  const imported = resolve(temporary, "object-literal-spreads.bjs");
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

test("async generator methods preserve yield, for-await, return, and finally", async () => {
  const result = await importFixture(
    asyncGeneratorFixture,
    "beagle.typescript.async-generator-method",
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source).toContain("(js/async-generator");
  expect(result.source).toContain("(AsyncIterable String)");
  expect(result.source).toContain("(js/for-await [value String values]");
  expect(result.source).toContain("(js/yield value)");
  expect(result.source).toContain("(js/generator-return)");
  expect(result.source).toContain("(finally");
  expect(result.source).not.toContain("__typescript_import_unsupported__");

  const imported = resolve(temporary, "async-generator-method.bjs");
  writeFileSync(imported, result.source);
  const checked = Bun.spawnSync([
    resolve(repositoryRoot, "bin/beagle-check"),
    imported,
  ], {
    cwd: repositoryRoot,
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(checked.exitCode, checked.stderr.toString()).toBe(0);

  const semanticSource = resolve(temporary, "async-generator-semantics.bjs");
  const semanticOutput = resolve(temporary, "async-generator-semantics.mjs");
  writeFileSync(semanticSource, `#lang beagle/js
(ns beagle.typescript.async-generator-semantics)
(js/export
  (js/async-generator
    (defn stream
      [values (AsyncIterable String) closed (Vec Bool)]
      (AsyncIterable String)
      (try
        (js/for-await [value String values]
          (js/yield value))
        (js/generator-return)
        (finally (.push closed true))))))
`);
  const built = Bun.spawnSync([
    resolve(repositoryRoot, "bin/beagle-build"),
    semanticSource,
    semanticOutput,
  ], {
    cwd: repositoryRoot,
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(built.exitCode, built.stderr.toString()).toBe(0);

  const module = await import(`${pathToFileURL(semanticOutput).href}?v=${Date.now()}`);
  async function* input() {
    yield "first";
    yield "second";
  }
  const closed = [];
  const generator = module.stream(input(), closed);
  expect(await generator.next()).toEqual({ value: "first", done: false });
  await generator.return();
  expect(closed).toEqual([true]);
});
