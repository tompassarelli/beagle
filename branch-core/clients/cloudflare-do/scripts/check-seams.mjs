// SPDX-License-Identifier: MIT OR Apache-2.0
// The build-time half of the seam check: src/seams.mjs must be native/
// wasm-embed.seams line for line, and the published wasm must have been linked
// against the same ledger.
import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { WASM_EMBED_SEAMS, parseSeamsFile } from "../src/seams.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const repo = resolve(root, "../..");

const problems = [];

function compare(label, expected, found) {
  for (let i = 0; i < Math.max(expected.length, found.length); i++) {
    if (expected[i] !== found[i]) {
      problems.push(
        `${label} line ${i + 1}: ledger has "${expected[i] ?? ""}", ` +
          `this adapter has "${found[i] ?? ""}"`,
      );
      return;
    }
  }
}

const ledgerPath = `${repo}/native/wasm-embed.seams`;
compare(
  "native/wasm-embed.seams",
  parseSeamsFile(readFileSync(ledgerPath, "utf8")),
  WASM_EMBED_SEAMS,
);

const linkedPath = `${root}/lib/wasm-embed.seams`;
if (existsSync(linkedPath)) {
  compare(
    "lib/wasm-embed.seams",
    parseSeamsFile(readFileSync(linkedPath, "utf8")),
    WASM_EMBED_SEAMS,
  );
} else {
  process.stdout.write(
    "check-seams: no lib/wasm-embed.seams yet; run scripts/build-wasm.sh\n",
  );
}

const provenancePath = `${root}/lib/provenance.json`;
if (existsSync(provenancePath)) {
  const provenance = JSON.parse(readFileSync(provenancePath, "utf8"));
  const wasm = readFileSync(`${root}/lib/libfram.wasm`);
  const sha = createHash("sha256").update(wasm).digest("hex");
  if (sha !== provenance.wasmSha256) {
    problems.push(
      `lib/libfram.wasm is sha256 ${sha}; provenance.json pins ` +
        `${provenance.wasmSha256} from artifact ${provenance.artifactAddress}`,
    );
  } else {
    process.stdout.write(
      `check-seams: lib/libfram.wasm matches artifact ` +
        `${provenance.artifactAddress}\n`,
    );
  }
}

if (problems.length) {
  process.stderr.write(`check-seams: FAIL\n${problems.join("\n")}\n`);
  process.exit(1);
}
process.stdout.write(
  `check-seams: PASS ${WASM_EMBED_SEAMS.length} seam lines\n`,
);
