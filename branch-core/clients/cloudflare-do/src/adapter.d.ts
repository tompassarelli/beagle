// SPDX-License-Identifier: MIT OR Apache-2.0

export const FRAMRPC_MAX_FRAME_BYTES: 1048602;
export const OPTIONS_SIZE: 32;
export const ERROR_SIZE: 516;
export const BUFFER_SIZE: 16;
export const LOG_CONTEXT: 0;
export const IMAGE_CONTEXT: 1;

export type MaybePromise<T> = T | Promise<T>;
export type FramStorageRange = 'log' | 'image';
export type FramTransportEntry = 'query' | 'transact' | 'snapshot';
export type FramInstanceEntry = 'q' | 't' | 's';

export type FramRpcOperation =
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

export type FramRpcDispatchEntry = FramTransportEntry | 'operator';

export interface FramRpcRequestInspection {
  readonly space: string;
  readonly operation: FramRpcOperation;
  readonly requestId: bigint;
  readonly frameBytes: number;
  readonly bodyBytes: number;
}

export interface FramExchangeOptions {
  entry: FramTransportEntry;
  space: string;
}

/** The subset of a FRAMRPC transport request consumed by this adapter. */
export interface FramTransportRequestLike {
  readonly frame: Uint8Array;
  readonly entry: FramTransportEntry;
  readonly space: string;
}

export interface FramExchangeStub {
  exchange(
    frame: Uint8Array,
    options: FramExchangeOptions,
  ): MaybePromise<Uint8Array>;
}

export type FramDurableObjectTransport = (
  request: FramTransportRequestLike,
) => MaybePromise<Uint8Array>;

export class FramRequestError extends Error {
  constructor(message: string, code?: string, options?: ErrorOptions);
  readonly code: string;
}

export function inspectFramRpcRequest(
  frame: Uint8Array,
): Readonly<FramRpcRequestInspection>;

export function framRpcEntry(operation: FramRpcOperation): FramRpcDispatchEntry;

export function framDurableObjectTransport(
  stub: FramExchangeStub,
): FramDurableObjectTransport;

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

export interface DurableFramStoreOptions {
  chunkBytes?: number;
  batchKeys?: number;
  logPrefix?: string;
  imagePrefix?: string;
}

export interface FramStoreCommitPart {
  which: FramStorageRange;
  bytes: Uint8Array;
  length: number;
  lowWater: number;
}

export interface FramStorePlannedPart {
  which: FramStorageRange;
  plan: ChunkedRangePlan;
}

export interface FramStoreLike {
  load(which: FramStorageRange): MaybePromise<Uint8Array>;
  commit(parts: FramStoreCommitPart[]): MaybePromise<void>;
}

export interface ChunkedRangeStats {
  puts: number;
  gets: number;
  deletes: number;
  bytesWritten: number;
  bytesRead: number;
  chunks: number | null;
}

export interface DurableFramStoreStats {
  commits: number;
  log: ChunkedRangeStats;
  image: ChunkedRangeStats;
}

export interface FramlogIdentity {
  readonly byteLength: number;
  readonly sha256: string;
}

export interface FramlogRestoreMarker extends FramlogIdentity {
  readonly format: 'fram-cloudflare-restore/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
}

export class DurableFramStore implements FramStoreLike {
  constructor(
    storage: DurableObjectStorageLike,
    options?: DurableFramStoreOptions,
  );

  storage: DurableObjectStorageLike;
  readonly ranges: Record<FramStorageRange, ChunkedRange>;
  commits: number;
  queue: Promise<void>;

  load(which?: FramStorageRange): Promise<Uint8Array>;
  clearPlan(which: FramStorageRange): Promise<ChunkedRangePlan>;
  commit(parts: FramStoreCommitPart[]): Promise<void>;
  replace(
    parts: Array<FramStoreCommitPart | FramStorePlannedPart>,
    marker: FramlogRestoreMarker,
  ): Promise<void>;
  useStorage(storage: DurableObjectStorageLike): void;
  stats(): DurableFramStoreStats;
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

export type FramBackupErrorCode =
  | 'administrative-fence'
  | 'conflict'
  | 'crypto-unavailable'
  | 'engine'
  | 'invalid-backup'
  | 'invalid-framlog'
  | 'restore-fenced'
  | 'space-mismatch'
  | 'storage'
  | 'target-not-empty'
  | 'verification';

export class FramBackupError extends Error {
  constructor(code: string, message: string, options?: ErrorOptions);
  readonly code: string;
  readonly expectedCurrent?: Readonly<FramlogIdentity> | null;
}

export class FramStorageError extends Error {
  constructor(cause: Error);
}

export class FramExchangeError extends Error {
  constructor(status: number, message: string);
  readonly status: number;
}

export interface FramInstanceArenaOptions {
  initialPages?: number;
  growPages?: number;
}

export interface FramInstanceOptions {
  store?: FramStoreLike;
  nowMs?: () => number;
  arena?: FramInstanceArenaOptions;
  memoryBudgetBytes?: number | bigint;
}

export interface FramCallStatus {
  status: number;
  message: string;
}

export interface FramCallResult extends FramCallStatus {
  response: Uint8Array;
  released: boolean;
}

export interface FramCheckpointResult extends FramCallResult {
  imageBytes: number;
}

export interface PortableFramlog {
  readonly bytes: Uint8Array;
  readonly servedVersion: string;
}

export interface FramInstanceStats {
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

export class FramInstance {
  static instantiate(
    module: WebAssembly.Module,
    options?: FramInstanceOptions,
  ): Promise<FramInstance>;

  constructor(options?: FramInstanceOptions);

  store: FramStoreLike | undefined;
  readonly nowMs: () => number;
  readonly arenaOptions: FramInstanceArenaOptions;
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
  open(spaceId: string, logLabel?: string): Promise<FramCallStatus>;
  call(entry: FramInstanceEntry, frame: Uint8Array): Promise<FramCallResult>;
  query(frame: Uint8Array): Promise<FramCallResult>;
  transact(frame: Uint8Array): Promise<FramCallResult>;
  snapshot(frame: Uint8Array): Promise<FramCallResult>;
  checkpoint(frame: Uint8Array): Promise<FramCheckpointResult>;
  close(): Promise<FramCallStatus>;
  portableFramlog(): Promise<Readonly<PortableFramlog>>;
  fence(error: Error): Promise<Error>;
  logBytes(): Uint8Array;
  imageBytes(): Uint8Array;
  stats(): FramInstanceStats;
}

export interface FramlogBackup extends FramlogIdentity {
  readonly format: 'fram-cloudflare-backup/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
  readonly bytes: Uint8Array;
}

export type FramlogRestoreOptions =
  | { readonly replace?: false }
  | {
      readonly replace: true;
      readonly expectedCurrent: Readonly<FramlogIdentity>;
    };

export interface FramlogRestoreResult extends FramlogIdentity {
  readonly format: 'fram-cloudflare-backup/v1';
  readonly spaceId: string;
  readonly servedVersion: string;
  readonly replaced: boolean;
}

export interface FramDurableObjectOptions {
  spaceId: string;
  logLabel?: string;
  store?: DurableFramStoreOptions;
  instance?: Omit<FramInstanceOptions, 'store'>;
}

export class FramDurableObjectBase<Env = unknown> {
  constructor(
    state: DurableObjectStateLike,
    env: Env,
    module: WebAssembly.Module,
    options: FramDurableObjectOptions,
  );

  readonly state: DurableObjectStateLike;
  readonly env: Env;
  readonly module: WebAssembly.Module;
  readonly spaceId: string;
  readonly logLabel: string;
  instance: FramInstance | null;
  store: DurableFramStore | null;
  openResult?: FramCallStatus;

  fram(): Promise<FramInstance>;
  query(frame: Uint8Array): Promise<FramCallResult>;
  transact(frame: Uint8Array): Promise<FramCallResult>;
  snapshot(frame: Uint8Array): Promise<FramCallResult>;
  checkpoint(frame: Uint8Array): Promise<FramCheckpointResult>;
  exchange(
    frame: Uint8Array,
    options: FramExchangeOptions,
  ): Promise<Uint8Array>;
  exportFramlog(): Promise<Readonly<FramlogBackup>>;
  restoreFramlog(
    backup: FramlogBackup,
    options?: FramlogRestoreOptions,
  ): Promise<Readonly<FramlogRestoreResult>>;
  recycle(): Promise<FramCallStatus | null>;
}

export interface DurableObjectNamespaceLike<Stub> {
  getByName(name: string): Stub;
}

export interface FramDataPlaneEntrypoint extends FramExchangeStub {}

export interface FramAdminStub {
  exportFramlog(): MaybePromise<Readonly<FramlogBackup>>;
  restoreFramlog(
    backup: FramlogBackup,
    options?: FramlogRestoreOptions,
  ): MaybePromise<Readonly<FramlogRestoreResult>>;
}

export interface FramAdminEntrypoint extends FramAdminStub {}

export function framDataPlaneEntrypoint(
  namespace: DurableObjectNamespaceLike<FramExchangeStub>,
  spaceId: string,
): Readonly<FramDataPlaneEntrypoint>;

export function framAdminEntrypoint(
  namespace: DurableObjectNamespaceLike<FramAdminStub>,
  spaceId: string,
): Readonly<FramAdminEntrypoint>;

export function nowHiRes(): number;
export function hex(bytes: Uint8Array): string;
