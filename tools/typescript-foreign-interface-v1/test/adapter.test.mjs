import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  bindCompiledAdapter,
  createCompilerBridge,
  createContext,
  foreignInterfaceBuilder,
} from "../src/typescript-api.mjs";

const adapterRoot = resolve(import.meta.dir, "..");
const repositoryRoot = resolve(adapterRoot, "../..");
const source = resolve(adapterRoot, "src/adapter.bjs");
const fixtureRoot = resolve(adapterRoot, "fixture");
const containingFile = resolve(fixtureRoot, "consumer.ts");
const temporary = mkdtempSync(join(tmpdir(), "beagle-ts-fi-v1-"));
const compiled = process.env.BEAGLE_COMPILED_ADAPTER ?? resolve(temporary, "adapter.mjs");
const moduleSpecifier = "@fixture/foreign-interface-v1";
const conditions = ["beagle"];
const runtimeRoot = resolve(repositoryRoot, "beagle-lib/lib/beagle");

afterAll(() => {
  rmSync(temporary, { recursive: true, force: true });
});

function compile() {
  if (process.env.BEAGLE_COMPILED_ADAPTER) return;
  const result = Bun.spawnSync([resolve(repositoryRoot, "bin/beagle"), "build", source, compiled], {
    cwd: repositoryRoot,
    stderr: "pipe",
    stdout: "pipe",
  });
  expect(result.exitCode, result.stderr.toString()).toBe(0);
}

async function prepare({ projectRoot = adapterRoot, importer = containingFile } = {}) {
  const compiledAdapter = bindCompiledAdapter(compiled);
  const bridge = createCompilerBridge({ adapterRoot, compiledAdapter });
  const context = createContext({ projectRoot, containingFile: importer, moduleSpecifier, conditions });
  const adapter = await compiledAdapter.load(runtimeRoot);
  const build = foreignInterfaceBuilder(adapter);
  return { bridge, build, context };
}

async function produce(options = {}) {
  const { bridge, build, context } = await prepare(options);
  return build(bridge, context, moduleSpecifier, conditions);
}

function fixtureProject({ typedEntry = false, projectLock = true } = {}) {
  const projectRoot = mkdtempSync(join(temporary, "project-"));
  const packageRoot = resolve(projectRoot, "node_modules/@fixture/foreign-interface-v1");
  mkdirSync(resolve(packageRoot, "types"), { recursive: true });
  copyFileSync(resolve(fixtureRoot, "package.json"), resolve(projectRoot, "package.json"));
  const fixturePackageRoot = resolve(fixtureRoot, "node_modules/@fixture/foreign-interface-v1");
  const packageManifest = JSON.parse(readFileSync(resolve(fixturePackageRoot, "package.json"), "utf8"));
  if (typedEntry) packageManifest.exports["."].beagle = "./types/beagle.ts";
  writeFileSync(resolve(packageRoot, "package.json"), `${JSON.stringify(packageManifest, null, 2)}\n`);
  for (const name of ["beagle.d.ts", "index.d.ts", "public.d.ts"]) {
    copyFileSync(resolve(fixturePackageRoot, "types", name), resolve(packageRoot, "types", name));
  }
  const entry = resolve(packageRoot, "types", typedEntry ? "beagle.ts" : "beagle.d.ts");
  if (typedEntry) copyFileSync(resolve(fixturePackageRoot, "types/beagle.d.ts"), entry);
  const importer = resolve(projectRoot, "consumer.ts");
  copyFileSync(containingFile, importer);
  const lockfile = resolve(projectRoot, "bun.lock");
  if (projectLock) writeFileSync(lockfile, '{"lockfileVersion":1}\n');
  return { entry, importer, lockfile, packageRoot, projectRoot };
}

const fileSha256 = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

const byName = (graph, name) => graph.exports.find((item) => item.name === name);
const nodeTable = (graph) => new Map(graph.nodes.map((node) => [node.id, node]));
const exportedNode = (graph, name) => nodeTable(graph).get(byName(graph, name).node);
const obligationCode = (graph, name) => {
  const node = exportedNode(graph, name);
  return graph.obligations.find((obligation) => obligation.id === node.obligationId)?.code;
};
const graphRefs = (value) => {
  const refs = new Set();
  const visit = (item) => {
    if (Array.isArray(item)) return item.forEach(visit);
    if (!item || typeof item !== "object") return;
    for (const [key, child] of Object.entries(item)) {
      if (["node", "type", "return", "constraint", "default", "target", "element", "key", "value", "base"].includes(key)
          && typeof child === "string" && /^n\d+$/.test(child)) refs.add(child);
      if (["members", "typeArguments"].includes(key) && Array.isArray(child)) child.forEach((id) => refs.add(id));
      visit(child);
    }
  };
  visit({ exports: value.exports, nodes: value.nodes });
  return refs;
};

beforeAll(() => {
  compile();
});

describe("ForeignInterfaceV1 graph semantics", () => {
  test("is deterministic, canonical, and preserves the representative surface", async () => {
    const first = await produce();
    const second = await produce();
    expect(JSON.stringify(first)).toBe(JSON.stringify(second));
    expect(first).toMatchObject({ kind: "ForeignInterfaceV1", frontend: "typescript", moduleSpecifier });
    expect(first.provenance.typescript.version).toBe("5.9.3");
    expect(first.provenance.conditions).toEqual(["beagle"]);
    expect(first.stats).toEqual({
      nodeCount: first.nodes.length,
      exportCount: first.exports.length,
      obligationCount: first.obligations.length,
      anyCount: 0,
      generatedSourceCount: 0,
    });
    expect(first.exports.map(({ name }) => name)).toEqual(first.exports.map(({ name }) => name).toSorted());
    expect(first.exports.some(({ name }) => name === "wrongCondition")).toBeFalse();
    expect(first.nodes.map(({ id }) => id)).toEqual(first.nodes.map(({ id }) => id).toSorted());
    const refs = graphRefs(first);
    expect(first.nodes.map(({ id }) => id).filter((id) => !refs.has(id))).toEqual([]);

    const nodes = nodeTable(first);
    const parse = exportedNode(first, "parse");
    expect(parse.kind).toBe("function");
    expect(parse.overloads.map(({ parameters }) => parameters.length)).toEqual([1, 1]);
    expect(parse.overloads.map(({ parameters }) => nodes.get(parameters[0].type).name)).toEqual(["string", "number"]);

    const generic = exportedNode(first, "select").overloads[0].typeParameters[0];
    expect(nodes.get(generic.constraint).name).toBe("Entity");
    expect(nodes.get(generic.default).name).toBe("User");
    expect(nodes.get(exportedNode(first, "UserId").base).name).toBe("string");
    expect(exportedNode(first, "Mode").members.map((id) => nodes.get(id).value).sort()).toEqual(["careful", "fast"]);

    const users = exportedNode(first, "users");
    const page = nodes.get(users.target);
    const itemArray = nodes.get(page.properties.find(({ name }) => name === "items").type);
    expect(page.typeParameters).toHaveLength(1);
    expect(page.typeParameters[0]).toMatchObject({ name: "T", node: itemArray.element });
    expect(nodes.get(users.typeArguments[0]).name).toBe("User");

    const transformer = exportedNode(first, "Transformer");
    expect(transformer.kind).toBe("function");
    expect(transformer.typeParameters).toHaveLength(1);
    const genericSignature = transformer.overloads[0];
    expect(genericSignature.parameters[0].type).toBe(transformer.typeParameters[0].node);
    expect(genericSignature.return).toBe(transformer.typeParameters[0].node);

    const stringTransformer = exportedNode(first, "stringTransformer");
    expect(stringTransformer.kind).toBe("function");
    expect(stringTransformer.typeParameters).toHaveLength(0);
    const transformerSignature = stringTransformer.overloads[0];
    expect(nodes.get(transformerSignature.parameters[0].type).name).toBe("string");
    expect(nodes.get(transformerSignature.return).name).toBe("string");

    expect(exportedNode(first, "ArrayBuffer")).toMatchObject({
      kind: "object",
      name: "ArrayBuffer",
    });
  });

  test("preserves mapped, inherited, and index readonly semantics", async () => {
    const graph = await produce();
    const closed = exportedNode(graph, "ClosedFlags");
    expect(closed.properties.map(({ name }) => name)).toEqual(["careful", "fast"]);
    expect(closed.properties.every(({ readonly }) => readonly)).toBeTrue();

    const inherited = exportedNode(graph, "InheritedSurface");
    expect(inherited.properties).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "inherited", readonly: true }),
      expect.objectContaining({ name: "mutableInherited", readonly: false }),
      expect.objectContaining({ name: "own", readonly: false }),
    ]));
    expect(exportedNode(graph, "ReadonlyDictionary").indexes).toEqual([
      expect.objectContaining({ readonly: true }),
    ]);
  });

  test("emits boolean literal values and omits absent tuple labels", async () => {
    const graph = await produce();
    const nodes = nodeTable(graph);
    const pair = exportedNode(graph, "Pair");
    expect(pair.elements.every((element) => !("name" in element))).toBeTrue();
    expect(exportedNode(graph, "LabeledPair").elements.map(({ name }) => name)).toEqual(["left", "right"]);
    expect(exportedNode(graph, "TruthTuple").elements.map(({ type }) => nodes.get(type).value)).toEqual([true, false]);
  });

  test("fails closed for unsupported TypeScript kinds", async () => {
    const graph = await produce();
    expect(obligationCode(graph, "OpenConditional")).toBe("TS_OPEN_CONDITIONAL");
    expect(obligationCode(graph, "OpenIndexed")).toBe("TS_INDEXED_ACCESS");
    expect(obligationCode(graph, "TemplateText")).toBe("TS_TEMPLATE_LITERAL");
    expect(obligationCode(graph, "UpperText")).toBe("TS_STRING_MAPPING");
    expect(obligationCode(graph, "Direction")).toBe("TS_ENUM");
    expect(obligationCode(graph, "uniqueToken")).toBe("TS_UNIQUE_SYMBOL");
  });
});

describe("provenance authority", () => {
  test("distinguishes adapter and project roots and binds the executed bytes", async () => {
    const project = fixtureProject({ typedEntry: true });
    const graph = await produce({ projectRoot: project.projectRoot, importer: project.importer });
    const provenance = graph.provenance;
    const consulted = new Map(provenance.consultedFiles.map((file) => [file.path, file.sha256]));

    expect(provenance.adapter).toMatchObject({
      source: "src/adapter.bjs",
      compiled: `compiled/${bindCompiledAdapter(compiled).sha256}.mjs`,
      compiledSha256: bindCompiledAdapter(compiled).sha256,
    });
    expect(provenance.package.path).toBe("project/node_modules/@fixture/foreign-interface-v1/package.json");
    expect(provenance.lockfile.path).toBe("bun.lock");
    expect(consulted.get("adapter/src/run.mjs")).toBe(fileSha256(resolve(adapterRoot, "src/run.mjs")));
    expect(consulted.get("adapter/src/typescript-api.mjs")).toBe(fileSha256(resolve(adapterRoot, "src/typescript-api.mjs")));
    expect(consulted.get("adapter/node_modules/typescript/lib/lib.es5.d.ts")).toBe(
      fileSha256(resolve(adapterRoot, "node_modules/typescript/lib/lib.es5.d.ts")),
    );
    expect(consulted.get("runtime/core.js")).toBe(fileSha256(resolve(runtimeRoot, "core.js")));
    expect(consulted.get("project/bun.lock")).toBe(fileSha256(project.lockfile));
    expect(consulted.get("project/node_modules/@fixture/foreign-interface-v1/types/beagle.ts")).toBe(
      fileSha256(project.entry),
    );
    expect(consulted.get("project/node_modules/@fixture/foreign-interface-v1/types/public.d.ts")).toBe(
      fileSha256(resolve(project.packageRoot, "types/public.d.ts")),
    );
    expect(provenance.consultedFiles.map(({ path }) => path)).toEqual(
      provenance.consultedFiles.map(({ path }) => path).toSorted(),
    );
    expect(provenance.consultedFiles.every(({ path }) => (
      !path.startsWith("/")
      && !path.includes("\\")
      && path.split("/").every((segment) => segment !== "." && segment !== "..")
    ))).toBeTrue();
  });

  test("executes the immutable compiled snapshot after its source path is substituted", async () => {
    const cached = resolve(tmpdir(), `cached-adapter-${crypto.randomUUID()}.mjs`);
    writeFileSync(cached, "export const build_foreign_interface_v1_bang = () => 'bound bytes';\n");
    try {
      const bound = bindCompiledAdapter(cached);
      writeFileSync(cached, "throw new Error('substituted after binding');\n");
      const loaded = await bound.load(runtimeRoot);
      expect(foreignInterfaceBuilder(loaded)()).toBe("bound bytes");
    } finally {
      rmSync(cached, { force: true });
    }
  });

  test("rejects a Program source substitution before issuing provenance", async () => {
    const project = fixtureProject({ typedEntry: true });
    const prepared = await prepare({ projectRoot: project.projectRoot, importer: project.importer });
    writeFileSync(project.entry, "export declare const substituted: string;\n");
    expect(() => prepared.build(
      prepared.bridge,
      prepared.context,
      moduleSpecifier,
      conditions,
    )).toThrow("compiler input changed after snapshot");
  });

  test("rejects project lockfile substitution before issuing provenance", async () => {
    const project = fixtureProject();
    const prepared = await prepare({ projectRoot: project.projectRoot, importer: project.importer });
    writeFileSync(project.lockfile, '{"lockfileVersion":2}\n');
    expect(() => prepared.build(
      prepared.bridge,
      prepared.context,
      moduleSpecifier,
      conditions,
    )).toThrow("project lockfile bun.lock changed after snapshot");
  });

  test("production runner executes the snapshotted bridge and reports its identity", () => {
    const result = Bun.spawnSync([
      process.execPath,
      resolve(adapterRoot, "src/run.mjs"),
      compiled,
      adapterRoot,
      runtimeRoot,
      adapterRoot,
      containingFile,
      moduleSpecifier,
      ...conditions,
    ], {
      cwd: repositoryRoot,
      stderr: "pipe",
      stdout: "pipe",
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    const graph = JSON.parse(result.stdout.toString());
    const consulted = new Map(graph.provenance.consultedFiles.map((file) => [file.path, file.sha256]));
    expect(consulted.get("adapter/src/run.mjs")).toBe(fileSha256(resolve(adapterRoot, "src/run.mjs")));
    expect(consulted.get("adapter/src/typescript-api.mjs")).toBe(fileSha256(resolve(adapterRoot, "src/typescript-api.mjs")));
  });
});
