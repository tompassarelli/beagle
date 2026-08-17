// SPDX-License-Identifier: MIT OR Apache-2.0

export interface WasmSeamImport {
  module: string;
  name: string;
  kind: 'function';
}

export interface WasmSeamExport {
  name: string;
  kind: string;
}

export const WASM_EMBED_SEAMS: readonly string[];

export function seamImports(lines?: readonly string[]): WasmSeamImport[];
export function seamExports(lines?: readonly string[]): WasmSeamExport[];
export function parseSeamsFile(text: string): string[];
export function assertSeams(
  module: WebAssembly.Module,
  imports: WebAssembly.Imports,
): void;
