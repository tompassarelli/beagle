import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [compiledPath, adapterRoot, typescriptRuntimeRoot, runtimeRoot, projectRoot, containingFile, moduleSpecifier, ...conditions] = process.argv.slice(2);
if (!compiledPath || !adapterRoot || !typescriptRuntimeRoot || !runtimeRoot || !projectRoot || !containingFile || !moduleSpecifier) {
  throw new Error("usage: bun src/run.mjs COMPILED-ADAPTER ADAPTER-ROOT TYPESCRIPT-RUNTIME-ROOT BEAGLE-RUNTIME-ROOT PROJECT-ROOT CONTAINING-FILE MODULE-SPECIFIER [CONDITION ...]");
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
  createCompilerBridge,
  createContext,
  foreignInterfaceBuilder,
} = await import(bridgeUrl);

const producerInputs = bindProducerInputs({ adapterRoot, runnerBytes, bridgeBytes });
const compiledAdapter = bindCompiledAdapter(compiledPath);
const bridge = createCompilerBridge({
  adapterRoot,
  compiledAdapter,
  producerInputs,
  typescriptRuntimeRoot,
});
const context = createContext({ projectRoot, containingFile, moduleSpecifier, conditions });
const adapter = await compiledAdapter.load(runtimeRoot);
const build = foreignInterfaceBuilder(adapter);
const graph = build(bridge, context, moduleSpecifier, [...conditions].sort());
producerInputs.assertUnchanged();
process.stdout.write(`${JSON.stringify(graph)}\n`);
