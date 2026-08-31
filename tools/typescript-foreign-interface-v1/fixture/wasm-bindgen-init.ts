export type SyncInitInput =
  | ArrayBuffer
  | ArrayBufferView<ArrayBuffer>
  | WebAssembly.Module;

export function initSync(
  module: { module: SyncInitInput } | SyncInitInput,
): number {
  return 0;
}

export function initArrayBuffer(module: ArrayBuffer): number {
  return initSync(module);
}

export function initInput(module: SyncInitInput): number {
  return initSync(module);
}
