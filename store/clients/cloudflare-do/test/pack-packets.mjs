// SPDX-License-Identifier: MIT OR Apache-2.0
// Pack tests/wasm_embed/packets into the two bundle modules a Worker can carry:
// one Data blob of every packet and one Text catalogue of offsets + manifests.
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../..");
const packets = process.argv[2] ?? `${repo}/tests/wasm_embed/packets`;
const out = process.argv[3] ?? `${here}/bundle`;

mkdirSync(out, { recursive: true });

const names = readdirSync(packets)
  .filter((name) => name.endsWith(".bin"))
  .sort();

const table = {};
const parts = [];
let offset = 0;
for (const name of names) {
  const bytes = readFileSync(`${packets}/${name}`);
  table[name] = { offset, length: bytes.length };
  parts.push(bytes);
  offset += bytes.length;
}

const manifests = readdirSync(packets)
  .filter((name) => name.startsWith("manifest") && name.endsWith(".txt"))
  .sort()
  .map((manifest) => ({
    manifest,
    rows: readFileSync(`${packets}/${manifest}`, "utf8")
      .split("\n")
      .map((line) => line.split(/\s+/))
      .filter((fields) => fields.length >= 3)
      .map(([entry, name, declared]) => ({
        entry,
        name,
        declared: Number(declared),
      })),
  }));

writeFileSync(`${out}/packets.bin`, Buffer.concat(parts));
writeFileSync(`${out}/packets.json`, JSON.stringify({ table, manifests }));
process.stdout.write(
  `packed ${names.length} packets (${offset} bytes), ` +
    `${manifests.length} manifests -> ${out}\n`,
);
