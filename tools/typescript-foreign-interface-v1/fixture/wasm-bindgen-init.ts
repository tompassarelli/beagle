export type SyncInitInput = ArrayBuffer | WebAssembly.Module;

export function initSync(
  module: { module: SyncInitInput } | SyncInitInput,
): number {
  return 0;
}

export function initArrayBuffer(module: ArrayBuffer): number {
  return initSync(module);
}
