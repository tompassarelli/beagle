import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
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
const fixture = resolve(adapterRoot, "fixture/wasm-bindgen-init.ts");
const diagnosticIsolationDirty = resolve(adapterRoot, "fixture/diagnostic-isolation-dirty.ts");
const diagnosticIsolationTarget = resolve(adapterRoot, "fixture/diagnostic-isolation-target.ts");
const metaPropertySupported = resolve(adapterRoot, "fixture/meta-property-supported.ts");
const metaPropertyUnsupported = resolve(adapterRoot, "fixture/meta-property-unsupported.ts");
const temporary = mkdtempSync(join(tmpdir(), "beagle-ts-import-v1-"));
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
});

async function importFixture(sourceFile, namespace, moduleMappings = new Map()) {
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
    moduleMappings,
  );
}

test("wasm-bindgen anonymous init objects become checked records", async () => {
  const result = await importFixture(
    fixture,
    "beagle.typescript.wasm-bindgen-init",
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source.match(/\(defrecord TypeScriptAnonymousObjectV\d+ \[module SyncInitInput\]\)/g)).toEqual([
    "(defrecord TypeScriptAnonymousObjectV1 [module SyncInitInput])",
  ]);
  expect(result.source).toContain(
    "(js/export (defn initSync [module (U ArrayBuffer (ArrayBufferView ArrayBuffer) Module TypeScriptAnonymousObjectV1)] Number 0.0))",
  );
  expect(result.source).toContain(
    "(js/export (defn initArrayBuffer [module ArrayBuffer] Number (initSync module)))",
  );
  expect(result.source).toContain(
    "(js/export (defn initInput [module SyncInitInput] Number (initSync module)))",
  );
  expect(result.source).not.toContain("__typescript_import_unsupported__");
});

test("target translation ignores diagnostics owned by a transitive dependency", async () => {
  expect(() => createSourceContext({
    projectRoot: adapterRoot,
    sourceFile: diagnosticIsolationDirty,
  })).toThrow("TS2322");

  const result = await importFixture(
    diagnosticIsolationTarget,
    "beagle.typescript.diagnostic-isolation-target",
    new Map([[
      "./diagnostic-isolation-dirty.ts",
      "beagle.typescript.diagnostic-isolation-dirty",
    ]]),
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source).toContain(
    "(:require [beagle.typescript.diagnostic-isolation-dirty :refer [dependencyValue]])",
  );
  expect(result.source).toContain(
    "(js/export (defn isolatedValue [] String dependencyValue))",
  );
});

test("import.meta becomes the canonical Beagle import-meta form", async () => {
  const result = await importFixture(
    metaPropertySupported,
    "beagle.typescript.meta-property-supported",
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source.match(/\(js\/import-meta\)/g)).toEqual([
    "(js/import-meta)",
    "(js/import-meta)",
  ]);
  expect(result.source).not.toContain("__typescript_import_unsupported__");
});

test("unsupported TypeScript meta-properties retain an exact diagnostic", async () => {
  const result = await importFixture(
    metaPropertyUnsupported,
    "beagle.typescript.meta-property-unsupported",
  );

  expect(result.diagnostics).toEqual([{
    _tag: "SourceDiagnosticV1",
    code: "TSI_META_PROPERTY",
    message: "unsupported TypeScript meta-property new.target",
    file: "fixture/meta-property-unsupported.ts",
    line: 2,
    column: 3,
  }]);
  expect(result.source).toContain("__typescript_import_unsupported__");
});
