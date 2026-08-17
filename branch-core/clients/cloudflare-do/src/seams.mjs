// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The wasm-embed seam this adapter serves, mirrored from native/wasm-embed.seams.
// scripts/check-seams.mjs compares these lines to that ledger and fails on any
// difference, so a new host hook cannot reach an embedder without landing here.

/** The ledger body of native/wasm-embed.seams: comments and blanks removed. */
export const WASM_EMBED_SEAMS = [
  "fram-wasm-embed-seams/v1",
  "export _initialize func",
  "export fram_abi_version func",
  "export fram_buffer_release func",
  "export fram_close func",
  "export fram_open func",
  "export fram_query func",
  "export fram_snapshot func",
  "export fram_transact func",
  "export fram_wasm_alloc func",
  "export fram_wasm_free func",
  "export memory memory",
  "import fram_host_v1 allocate (i32 i32) -> (i32)",
  "import fram_host_v1 clock_milliseconds (i32 i32) -> (i32)",
  "import fram_host_v1 deallocate (i32 i32) -> ()",
  "import fram_host_v1 storage_append (i32 i32 i32) -> (i32)",
  "import fram_host_v1 storage_close (i32) -> (i32)",
  "import fram_host_v1 storage_read (i32 i64 i32 i32) -> (i32)",
  "import fram_host_v1 storage_size (i32 i32) -> (i32)",
  "import fram_host_v1 storage_sync (i32) -> (i32)",
  "import fram_host_v1 storage_truncate (i32 i64) -> (i32)",
  "import wasi_snapshot_preview1 clock_time_get (i32 i64 i32) -> (i32)",
  "import wasi_snapshot_preview1 environ_get (i32 i32) -> (i32)",
  "import wasi_snapshot_preview1 environ_sizes_get (i32 i32) -> (i32)",
  "import wasi_snapshot_preview1 fd_close (i32) -> (i32)",
  "import wasi_snapshot_preview1 fd_seek (i32 i64 i32 i32) -> (i32)",
  "import wasi_snapshot_preview1 fd_write (i32 i32 i32 i32) -> (i32)",
  "import wasi_snapshot_preview1 proc_exit (i32) -> ()",
];

const KINDS = { func: "function", memory: "memory", table: "table",
  global: "global" };

/** The ledger's import lines as `module name` pairs, in ledger order. */
export function seamImports(lines = WASM_EMBED_SEAMS) {
  return lines
    .filter((line) => line.startsWith("import "))
    .map((line) => {
      const [, module, name] = line.split(" ");
      return { module, name, kind: "function" };
    });
}

/** The ledger's export lines as `name kind` pairs, in ledger order. */
export function seamExports(lines = WASM_EMBED_SEAMS) {
  return lines
    .filter((line) => line.startsWith("export "))
    .map((line) => {
      const [, name, kind] = line.split(" ");
      return { name, kind: KINDS[kind] ?? kind };
    });
}

/** Strip the ledger file's comments and blank lines. */
export function parseSeamsFile(text) {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"));
}

function describe(entries, key) {
  return entries.map(key).sort().join(" ");
}

/**
 * Startup check: the module's imports and exports are exactly the ledger's and
 * the import object answers every import and nothing else. Reflection exposes
 * names and kinds only; signatures stay pinned by scripts/check-seams.mjs.
 */
export function assertSeams(module, imports) {
  const wanted = seamImports();
  const found = WebAssembly.Module.imports(module).map(
    ({ module: from, name, kind }) => ({ module: from, name, kind }),
  );
  const key = (entry) => `${entry.module}.${entry.name}:${entry.kind}`;
  if (describe(wanted, key) !== describe(found, key)) {
    throw new Error(
      "the module's imports are not the wasm-embed seam: expected " +
        `${describe(wanted, key)}; found ${describe(found, key)}`,
    );
  }

  const wantedExports = seamExports();
  const foundExports = WebAssembly.Module.exports(module).map(
    ({ name, kind }) => ({ name, kind }),
  );
  const exportKey = (entry) => `${entry.name}:${entry.kind}`;
  if (describe(wantedExports, exportKey) !== describe(foundExports, exportKey)) {
    throw new Error(
      "the module's exports are not the wasm-embed seam: expected " +
        `${describe(wantedExports, exportKey)}; found ` +
        `${describe(foundExports, exportKey)}`,
    );
  }

  const supplied = [];
  for (const [from, table] of Object.entries(imports)) {
    for (const name of Object.keys(table)) supplied.push(`${from}.${name}`);
  }
  const demanded = wanted.map((entry) => `${entry.module}.${entry.name}`);
  if (supplied.sort().join(" ") !== demanded.sort().join(" ")) {
    throw new Error(
      `this adapter answers ${supplied.join(" ")}; the seam is ` +
        demanded.join(" "),
    );
  }
}
