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

test("wasm-bindgen anonymous init objects become checked records", async () => {
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
  const context = createSourceContext({ projectRoot: adapterRoot, sourceFile: fixture });
  const importer = sourceImporterBuilder(await compiledAdapter.load(runtimeRoot));
  const result = importer(
    bridge,
    context,
    "beagle.typescript.wasm-bindgen-init",
    new Map(),
  );

  expect(result.diagnostics).toEqual([]);
  expect(result.source.match(/\(defrecord TypeScriptAnonymousObjectV\d+ \[module SyncInitInput\]\)/g)).toEqual([
    "(defrecord TypeScriptAnonymousObjectV1 [module SyncInitInput])",
  ]);
  expect(result.source).toContain(
    "(js/export (defn initSync [module (U ArrayBuffer Module TypeScriptAnonymousObjectV1)] Number 0.0))",
  );
  expect(result.source).toContain(
    "(js/export (defn initArrayBuffer [module ArrayBuffer] Number (initSync module)))",
  );
  expect(result.source).not.toContain("__typescript_import_unsupported__");
});
