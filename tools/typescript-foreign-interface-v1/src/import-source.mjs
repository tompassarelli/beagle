import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [
  compiledPath,
  adapterRoot,
  typescriptRuntimeRoot,
  runtimeRoot,
  projectRoot,
  sourceFile,
  namespace,
  outputMode = "source",
  ...mappingArguments
] = process.argv.slice(2);

if (!compiledPath || !adapterRoot || !typescriptRuntimeRoot || !runtimeRoot || !projectRoot || !sourceFile || !namespace) {
  throw new Error("usage: bun src/import-source.mjs COMPILED-IMPORTER ADAPTER-ROOT TYPESCRIPT-RUNTIME-ROOT BEAGLE-RUNTIME-ROOT PROJECT-ROOT SOURCE-FILE NAMESPACE [source|json] [SPECIFIER=NAMESPACE ...]");
}
if (outputMode !== "source" && outputMode !== "json") {
  throw new Error(`unknown TypeScript source importer output mode: ${outputMode}`);
}

const moduleMappings = new Map();
for (const argument of mappingArguments) {
  const separator = argument.indexOf("=");
  if (separator <= 0 || separator === argument.length - 1) {
    throw new Error(`invalid module mapping ${argument}; expected SPECIFIER=NAMESPACE`);
  }
  const specifier = argument.slice(0, separator);
  if (moduleMappings.has(specifier)) throw new Error(`duplicate module mapping ${specifier}`);
  moduleMappings.set(specifier, argument.slice(separator + 1));
}

const runnerPath = realpathSync(fileURLToPath(import.meta.url));
const runnerBytes = readFileSync(runnerPath);
const bridgePath = realpathSync(resolve(dirname(runnerPath), "typescript-api.mjs"));
const bridgeBytes = readFileSync(bridgePath);
const bridgePreamble = Buffer.from(
  `const __BEAGLE_TYPESCRIPT_API_SOURCE_URL__ = ${JSON.stringify(pathToFileURL(bridgePath).href)};\nconst __BEAGLE_TYPESCRIPT_RUNTIME_ROOT__ = ${JSON.stringify(typescriptRuntimeRoot)};\n`,
);
const bridgeModule = Buffer.concat([bridgePreamble, bridgeBytes]);
const bridgeUrl = URL.createObjectURL(new Blob([bridgeModule], { type: "text/javascript" }));
const {
  bindCompiledAdapter,
  bindProducerInputs,
  createSourceCompilerBridge,
  createSourceContext,
  sourceImporterBuilder,
} = await import(bridgeUrl);

const producerInputs = bindProducerInputs({
  adapterRoot,
  runnerBytes,
  bridgeBytes,
  runnerName: "src/import-source.mjs",
});
const compiledAdapter = bindCompiledAdapter(compiledPath);
const bridge = createSourceCompilerBridge({
  adapterRoot,
  compiledAdapter,
  producerInputs,
  typescriptRuntimeRoot,
});
const context = createSourceContext({ projectRoot, sourceFile });
const importerModule = await compiledAdapter.load(runtimeRoot);
const importSource = sourceImporterBuilder(importerModule);
const result = importSource(bridge, context, namespace, moduleMappings);
const provenance = bridge.sourceProvenance(context);
producerInputs.assertUnchanged();

if (outputMode === "json") {
  process.stdout.write(`${JSON.stringify({ ...result, provenance })}\n`);
} else if (result.diagnostics.length > 0) {
  for (const diagnostic of result.diagnostics) {
    process.stderr.write(`${diagnostic.file}:${diagnostic.line}:${diagnostic.column}: ${diagnostic.code}: ${diagnostic.message}\n`);
  }
  process.exitCode = 1;
} else {
  process.stdout.write(result.source);
}
