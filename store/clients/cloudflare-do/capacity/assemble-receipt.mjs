// SPDX-License-Identifier: MIT OR Apache-2.0
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { canonicalJson, loadReceiptInputs } from "./receipt.mjs";

const argumentsByName = Object.fromEntries(
  process.argv.slice(2).map((argument) => {
    const at = argument.indexOf("=");
    if (at <= 2 || !argument.startsWith("--")) {
      throw new Error(`expected --name=value, got ${argument}`);
    }
    return [argument.slice(2, at), argument.slice(at + 1)];
  }),
);
for (const name of [
  "plan",
  "bundle",
  "wrangler-log",
  "functional",
  "cgroup",
  "wasm-provenance",
  "output",
]) {
  if (!argumentsByName[name]) throw new Error(`missing --${name}=...`);
}

const receipt = loadReceiptInputs({
  plan: argumentsByName.plan,
  bundleDirectory: resolve(argumentsByName.bundle),
  wranglerLog: resolve(argumentsByName["wrangler-log"]),
  functionalResult: resolve(argumentsByName.functional),
  cgroupProperties: resolve(argumentsByName.cgroup),
  wasmProvenance: resolve(argumentsByName["wasm-provenance"]),
});
const output = resolve(argumentsByName.output);
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, canonicalJson(receipt));
process.stdout.write(
  `assemble-receipt: ${receipt.pass ? "PASS" : "FAIL"} -> ${output}\n`,
);
if (!receipt.pass) process.exitCode = 1;
