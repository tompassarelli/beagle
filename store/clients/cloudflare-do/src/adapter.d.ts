// SPDX-License-Identifier: MIT OR Apache-2.0

export const STORERPC_MAX_PACKET_BYTES: 1048602;
export const OPTIONS_SIZE: 32;
export const ERROR_SIZE: 516;
export const BUFFER_SIZE: 16;
export const LOG_CONTEXT: 0;
export const IMAGE_CONTEXT: 1;

export type MaybePromise<T> = T | Promise<T>;
export type StoreStorageRange = 'log' | 'image';
export type StoreTransportEntry = 'query' | 'transact' | 'snapshot';
export type StoreInstanceEntry = 'q' | 't' | 's';

export type StoreRpcOperation =
  | 'rpc/version'
  | 'rpc/status'
  | 'rpc/validate'
  | 'rpc/assert'
  | 'rpc/retract'
  | 'rpc/batch'
  | 'rpc/scan'
  | 'rpc/query'
  | 'rpc/occurrences'
  | 'rpc/lease-acquire'
  | 'rpc/lease-renew'
  | 'rpc/lease-release'
  | 'rpc/lease-check'
  | 'rpc/checkpoint';

export type StoreRpcDispatchEntry = StoreTransportEntry | 'operator';

export interface StoreRpcRequestInspection {
  readonly space: string;
  readonly operation: StoreRpcOperation;
  readonly requestId: bigint;
  readonly packetBytes: number;
  readonly bodyBytes: number;
}

export interface StoreExchangeOptions {
  entry: StoreTransportEntry;
  space: string;
}

/** The subset of a STORERPC transport request consumed by this adapter. */
export interface StoreTransportRequestLike {
  readonly packet: Uint8Array;
  readonly entry: StoreTransportEntry;
  readonly space: string;
}

export interface StoreExchangeStub {
  exchange(
    packet: Uint8Array,
    options: StoreExchangeOptions,
  ): MaybePromise<Uint8Array>;
}

export type StoreDurableObjectTransport = (
  request: StoreTransportRequestLike,
) => MaybePromise<Uint8Array>;

export class StoreRequestError extends Error {
  constructor(message: string, code?: string, options?: ErrorOptions);
  readonly code: string;
}

export function inspectStoreRpcRequest(
  packet: Uint8Array,
): Readonly<StoreRpcRequestInspection>;

export function storeRpcEntry(operation: StoreRpcOperation): StoreRpcDispatchEntry;

export function storeDurableObjectTransport(
  stub: StoreExchangeStub,
): StoreDurableObjectTransport;

export interface DurableObjectListOptionsLike {
  prefix?: string;
  startAfter?: string;
  limit?: number;
}

/** Minimal transaction surface used by the adapter. */
export interface DurableObjectTransactionLike {
  get<T = unknown>(key: string): Promise<T | undefined>;
  get<T = unknown>(keys: string[]): Promise<Map<string, T>>;
  list<T = unknown>(
    options?: DurableObjectListOptionsLike,
  ): Promise<Map<string, T>>;
  put<T>(key: string, value: T): Promise<unknown>;
  put<T>(entries: Record<string, T>): Promise<unknown>;
  delete(key: string): Promise<unknown>;
  delete(keys: string[]): Promise<unknown>;
}

/** Minimal Durable Object storage surface used by the adapter. */
export interface DurableObjectStorageLike
  extends DurableObjectTransactionLike {
  transaction<T>(
    body: (transaction: DurableObjectTransactionLike) => Promise<T>,
  ): Promise<T>;
}

export interface DurableObjectIdLike {
  readonly name?: string;
}

export interface DurableObjectStateLike {
  readonly id?: DurableObjectIdLike;
  readonly storage: DurableObjectStorageLike;
}

export interface ChunkedRangeOptions {
  prefix?: string;
  chunkBytes?: number;
  batchKeys?: number;
}

export interface ChunkedRangePlan {
  writes: Array<[string, Uint8Array]>;
  stale: string[];
  chunks: number;
  length: number;
  publishMeta: boolean;
}

export class ChunkedRange {
  constructor(
    storage: DurableObjectStorageLike,
    options?: ChunkedRangeOptions,
  );

  storage: DurableObjectStorageLike;
  prefix: string;
  chunkBytes: number;
  batchKeys: number;
  metaKey: string;
  chunkCount: number | null;
  puts: number;
  gets: number;
  deletes: number;
  bytesWritten: number;
  bytesRead: number;

  load(): Promise<Uint8Array>;
  plan(bytes: Uint8Array, length: number, lowWater: number): ChunkedRangePlan;
  clearPlan(): Promise<ChunkedRangePlan>;
  applyTo(
    transaction: DurableObjectTransactionLike,
    plan: ChunkedRangePlan,
  ): Promise<void>;
  settle(plan: ChunkedRangePlan): void;
}

export interface DurableStoreStoreOptions {
  chunkBytes?: number;
  batchKeys?: number;
  logPrefix?: string;
  imagePrefix?: string;
}

export interface StoreStoreCommitPart {
  which: StoreStorageRange;
  bytes: Uint8Array;
  length: number;
  lowWater: number;
}

export interface StoreStorePlannedPart {
  which: StoreStorageRange;
  plan: ChunkedRangePlan;
}

export interface StoreStoreLike {
  load(which: StoreStorageRange): MaybePromise<Uint8Array>;
  commit(parts: StoreStoreCommitPart[]): MaybePromise<void>;
}

export interface ChunkedRangeStats {
  puts: number;
  gets: number;
  deletes: number;
  bytesWritten: number;
  bytesRead: number;
  chunks: number | null;
}

export interface DurableStoreStoreStats {
  commits: number;
  log: ChunkedRangeStats;
  image: ChunkedRangeStats;
}

export interface StoreLogIdentity {
  readonly byteLength: number;
  readonly sha256: string;
}

export interface StoreLogRestoreMarker extends StoreLogIdentity {
  readonly format: 'store-cloudflare-restore/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
}

export class DurableStoreStore implements StoreStoreLike {
  constructor(
    storage: DurableObjectStorageLike,
    options?: DurableStoreStoreOptions,
  );

  storage: DurableObjectStorageLike;
  readonly ranges: Record<StoreStorageRange, ChunkedRange>;
  commits: number;
  queue: Promise<void>;

  load(which?: StoreStorageRange): Promise<Uint8Array>;
  clearPlan(which: StoreStorageRange): Promise<ChunkedRangePlan>;
  commit(parts: StoreStoreCommitPart[]): Promise<void>;
  replace(
    parts: Array<StoreStoreCommitPart | StoreStorePlannedPart>,
    marker: StoreLogRestoreMarker,
  ): Promise<void>;
  useStorage(storage: DurableObjectStorageLike): void;
  stats(): DurableStoreStoreStats;
}

export class MemoryStorage implements DurableObjectStorageLike {
  constructor(map?: Map<string, unknown>);

  map: Map<string, unknown>;
  latencyMs: number;

  get<T = unknown>(key: string): Promise<T | undefined>;
  get<T = unknown>(keys: string[]): Promise<Map<string, T>>;
  list<T = unknown>(
    options?: DurableObjectListOptionsLike,
  ): Promise<Map<string, T>>;
  put<T>(key: string, value: T): Promise<void>;
  put<T>(entries: Record<string, T>): Promise<void>;
  delete(key: string): Promise<void>;
  delete(keys: string[]): Promise<void>;
  transaction<T>(
    body: (transaction: MemoryStorage) => MaybePromise<T>,
  ): Promise<T>;
}

export type StoreBackupErrorCode =
  | 'administrative-fence'
  | 'conflict'
  | 'crypto-unavailable'
  | 'engine'
  | 'invalid-backup'
  | 'invalid-storelog'
  | 'restore-fenced'
  | 'space-mismatch'
  | 'storage'
  | 'target-not-empty'
  | 'verification';

export class StoreBackupError extends Error {
  constructor(code: string, message: string, options?: ErrorOptions);
  readonly code: string;
  readonly expectedCurrent?: Readonly<StoreLogIdentity> | null;
}

export class StoreStorageError extends Error {
  constructor(cause: Error);
}

export class StoreExchangeError extends Error {
  constructor(status: number, message: string);
  readonly status: number;
}

export interface StoreInstanceArenaOptions {
  initialPages?: number;
  growPages?: number;
}

export interface StoreInstanceOptions {
  store?: StoreStoreLike;
  nowMs?: () => number;
  arena?: StoreInstanceArenaOptions;
  memoryBudgetBytes?: number | bigint;
}

export interface StoreCallStatus {
  status: number;
  message: string;
}

export interface StoreCallResult extends StoreCallStatus {
  response: Uint8Array;
  released: boolean;
}

export interface StoreCheckpointResult extends StoreCallResult {
  imageBytes: number;
}

export interface PortableStoreLog {
  readonly bytes: Uint8Array;
  readonly servedVersion: string;
}

export interface StoreInstanceStats {
  instantiateMs: number;
  linearMemoryBytes: number;
  arenaReservedBytes: number;
  arenaPeakLiveBytes: number;
  arenaLiveBytes: number;
  arenaAllocations: number;
  arenaDeallocations: number;
  arenaReuses: number;
  arenaGrows: number;
  commits: number;
  logBytes: number;
  imageBytes: number;
  poisoned: string | null;
  hostCalls: Record<string, number>;
  wasiCalls: Record<string, number>;
  wasiRefused: Record<string, number>;
}

export class StoreInstance {
  static instantiate(
    module: WebAssembly.Module,
    options?: StoreInstanceOptions,
  ): Promise<StoreInstance>;

  constructor(options?: StoreInstanceOptions);

  store: StoreStoreLike | undefined;
  readonly nowMs: () => number;
  readonly arenaOptions: StoreInstanceArenaOptions;
  readonly memoryBudgetBytes: bigint;
  readonly hostCalls: Record<string, number>;
  readonly wasiCalls: Record<string, number>;
  readonly wasiRefused: Record<string, number>;
  commits: number;
  opened: boolean;
  closed: boolean;
  poisoned: Error | null;
  spaceId: string | null;

  alloc(size: number): number;
  free(pointer: number): void;
  write(pointer: number, payload: Uint8Array): void;
  read(pointer: number, length: number): Uint8Array;
  readCString(pointer: number, limit: number): string;
  putCString(text: string): number;
  open(spaceId: string, logLabel?: string): Promise<StoreCallStatus>;
  call(entry: StoreInstanceEntry, packet: Uint8Array): Promise<StoreCallResult>;
  query(packet: Uint8Array): Promise<StoreCallResult>;
  transact(packet: Uint8Array): Promise<StoreCallResult>;
  snapshot(packet: Uint8Array): Promise<StoreCallResult>;
  checkpoint(packet: Uint8Array): Promise<StoreCheckpointResult>;
  close(): Promise<StoreCallStatus>;
  portableStoreLog(): Promise<Readonly<PortableStoreLog>>;
  fence(error: Error): Promise<Error>;
  logBytes(): Uint8Array;
  imageBytes(): Uint8Array;
  stats(): StoreInstanceStats;
}

export interface StoreLogBackup extends StoreLogIdentity {
  readonly format: 'store-cloudflare-backup/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
  readonly bytes: Uint8Array;
}

export type StoreLogRestoreOptions =
  | { readonly replace?: false }
  | {
      readonly replace: true;
      readonly expectedCurrent: Readonly<StoreLogIdentity>;
    };

export interface StoreLogRestoreResult extends StoreLogIdentity {
  readonly format: 'store-cloudflare-backup/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
  readonly replaced: boolean;
}

export interface StoreDurableObjectOptions {
  spaceId: string;
  logLabel?: string;
  store?: DurableStoreStoreOptions;
  instance?: Omit<StoreInstanceOptions, 'store'>;
}

export class StoreDurableObjectBase<Env = unknown> {
  constructor(
    state: DurableObjectStateLike,
    env: Env,
    module: WebAssembly.Module,
    options: StoreDurableObjectOptions,
  );

  readonly state: DurableObjectStateLike;
  readonly env: Env;
  readonly module: WebAssembly.Module;
  readonly spaceId: string;
  readonly logLabel: string;
  instance: StoreInstance | null;
  store: DurableStoreStore | null;
  openResult?: StoreCallStatus;

  store(): Promise<StoreInstance>;
  query(packet: Uint8Array): Promise<StoreCallResult>;
  transact(packet: Uint8Array): Promise<StoreCallResult>;
  snapshot(packet: Uint8Array): Promise<StoreCallResult>;
  checkpoint(packet: Uint8Array): Promise<StoreCheckpointResult>;
  exchange(
    packet: Uint8Array,
    options: StoreExchangeOptions,
  ): Promise<Uint8Array>;
  exportStoreLog(): Promise<Readonly<StoreLogBackup>>;
  restoreStoreLog(
    backup: StoreLogBackup,
    options?: StoreLogRestoreOptions,
  ): Promise<Readonly<StoreLogRestoreResult>>;
  recycle(): Promise<StoreCallStatus | null>;
}

export interface DurableObjectNamespaceLike<Stub> {
  getByName(name: string): Stub;
}

export interface StoreDataPlaneEntrypoint extends StoreExchangeStub {}

export interface StoreAdminStub {
  exportStoreLog(): MaybePromise<Readonly<StoreLogBackup>>;
  restoreStoreLog(
    backup: StoreLogBackup,
    options?: StoreLogRestoreOptions,
  ): MaybePromise<Readonly<StoreLogRestoreResult>>;
}

export interface StoreAdminEntrypoint extends StoreAdminStub {}

export function storeDataPlaneEntrypoint(
  namespace: DurableObjectNamespaceLike<StoreExchangeStub>,
  spaceId: string,
): Readonly<StoreDataPlaneEntrypoint>;

export function storeAdminEntrypoint(
  namespace: DurableObjectNamespaceLike<StoreAdminStub>,
  spaceId: string,
): Readonly<StoreAdminEntrypoint>;

export function nowHiRes(): number;
export function hex(bytes: Uint8Array): string;
