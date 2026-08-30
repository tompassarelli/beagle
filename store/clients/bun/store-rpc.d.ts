export type IntegerInput = bigint | number | string;

export type StringTerm = ['string', string];
export type IntegerTerm = ['integer', string];
export type Float64Term = ['float64', string];
export type BooleanTerm = ['boolean', boolean];
export type KeywordTerm = ['keyword', string];
export type InstantTerm = ['instant', string, string];
export type TripleTerm = ['triple', Term, Term, Term];
export type Term = StringTerm | IntegerTerm | Float64Term | BooleanTerm
  | KeywordTerm | InstantTerm | TripleTerm;
export type TermInput = Term | string | bigint | number | boolean | Date;

export type TransactionCoordinateTerm = [
  'triple',
  StringTerm,
  ['keyword', 'kernel/tx-sequence'],
  IntegerTerm,
];
export type OccurrenceCoordinateTerm = [
  'triple',
  TransactionCoordinateTerm,
  ['keyword', 'kernel/op-ordinal'],
  IntegerTerm,
];
export type OccurrenceAction = 'assert' | 'retract';

export interface Occurrence {
  coordinate: OccurrenceCoordinateTerm;
  action: OccurrenceAction;
  proposition: TripleTerm;
}

export interface QueryVariable {
  var: string;
}

export type QueryTermInput = TermInput | QueryVariable;

export interface QueryHead {
  rel: string;
  args: QueryTermInput[];
}

export interface QueryRelationClause {
  rel: string;
  args: QueryTermInput[];
  neg?: boolean;
}

export interface QueryPredicateClause {
  pred: string;
  args: [QueryTermInput, QueryTermInput];
}

export interface QueryFunctionClause {
  fn: string;
  args: QueryTermInput[];
  bind: string;
}

export type QueryClause = QueryRelationClause | QueryPredicateClause | QueryFunctionClause;

export interface QueryRule {
  head: QueryHead;
  body: QueryClause[];
}

export interface QueryAggregate {
  op: string;
  arg?: IntegerInput;
}

export interface QueryHaving {
  op: string;
  agg: IntegerInput;
  val: TermInput;
}

export interface QueryAggregateFind {
  rel: string;
  group?: IntegerInput[];
  agg: QueryAggregate[];
  having?: QueryHaving[];
}

export interface StructuredQueryRules {
  find: string | QueryAggregateFind;
  rules: QueryRule[];
  strata?: never;
  orderBy?: QueryOrderClause[];
  limit?: IntegerInput;
}

export interface StructuredQueryStrata {
  find: string | QueryAggregateFind;
  strata: QueryRule[][];
  rules?: never;
  orderBy?: QueryOrderClause[];
  limit?: IntegerInput;
}

export interface QueryOrderClause {
  column: IntegerInput;
  direction: 'asc' | 'desc';
}

export type StructuredQuery = StructuredQueryRules | StructuredQueryStrata;

export interface TriplePattern {
  t1?: TermInput;
  t2?: TermInput;
  t3?: TermInput;
}

export interface PageRequest {
  limit: IntegerInput;
  cursor?: Term;
}

export interface PageResponse {
  ordinal: number;
  nextCursor: Term | null;
  done: boolean;
}

export interface RequestOptions {
  expectedVersion?: IntegerInput;
  signal?: AbortSignal;
}

export interface PagedRequestOptions extends RequestOptions {
  page?: PageRequest;
}

export interface SinceSelector {
  lowerExclusive: IntegerInput;
  upper?: IntegerInput | 'current';
}

export interface QueryOptions extends PagedRequestOptions {
  timeoutMs?: IntegerInput;
  asOf?: IntegerInput;
  since?: IntegerInput | SinceSelector;
}

export interface WriteOptions extends RequestOptions {
  existing?: boolean;
  fence?: TripleTerm;
}

export interface BatchAction {
  op: 'assert' | 'retract';
  proposition?: TripleTerm;
  t1?: TermInput;
  t2?: TermInput;
  t3?: TermInput;
  existing?: boolean;
}

export interface BatchPreflight {
  readonly actionCount: number;
  readonly requestBytes: number;
  readonly bodyBytes: number;
  readonly termCount: number;
  readonly maxTermDepth: number;
}

export interface BatchPreflightOptions extends RequestOptions {
  fence?: TripleTerm;
}

export interface BatchOptions extends BatchPreflightOptions {
  preflight?: BatchPreflight;
}

export interface StoreResponse<Result> {
  space: string;
  operation: string;
  servedVersion: bigint;
  page: PageResponse | null;
  result: Result;
  payload: Term | null;
}

export interface MutationActionResult {
  inputIndex: number;
  stateChanged: boolean;
  occurrence: OccurrenceCoordinateTerm;
}

export interface StatusResult {
  state: string;
  liveCount: bigint;
  engine: string;
  cache: {
    hits: bigint;
    misses: bigint;
    bytes: bigint;
    evictions: bigint;
  };
}

export interface ValidationResult {
  valid: boolean;
  violations: Array<{ code: string; detail: Term }>;
}

export interface StoreInstant {
  epochSeconds: bigint;
  nanos: number;
}

export interface LeaseGrant {
  fence: TripleTerm;
  expires: StoreInstant;
}

export interface LeaseCheck {
  valid: boolean;
  expires: StoreInstant | null;
}

export interface StoreClient {
  version(options?: RequestOptions): Promise<StoreResponse<null>>;
  status(options?: RequestOptions): Promise<StoreResponse<StatusResult>>;
  validate(options?: RequestOptions): Promise<StoreResponse<ValidationResult>>;
  occurrences(options?: PagedRequestOptions): Promise<StoreResponse<Occurrence[]>>;
  scan(pattern?: TriplePattern, options?: PagedRequestOptions): Promise<StoreResponse<TripleTerm[]>>;
  query(query: StructuredQuery | Term, options?: QueryOptions): Promise<StoreResponse<Term[][]>>;
  assert(t1: TermInput, t2: TermInput, t3: TermInput,
    options?: WriteOptions): Promise<StoreResponse<MutationActionResult[]>>;
  retract(t1: TermInput, t2: TermInput, t3: TermInput,
    options?: WriteOptions): Promise<StoreResponse<MutationActionResult[]>>;
  preflightBatch(actions: readonly BatchAction[], options?: BatchPreflightOptions): BatchPreflight;
  batch(actions: readonly BatchAction[], options?: BatchOptions): Promise<StoreResponse<MutationActionResult[]>>;
  leaseAcquire(resource: TermInput, holder: TermInput, ttlMs: IntegerInput,
    options?: RequestOptions): Promise<StoreResponse<LeaseGrant>>;
  leaseRenew(fence: TripleTerm, ttlMs: IntegerInput,
    options?: RequestOptions): Promise<StoreResponse<LeaseGrant>>;
  leaseRelease(fence: TripleTerm,
    options?: RequestOptions): Promise<StoreResponse<{ released: boolean }>>;
  leaseCheck(fence: TripleTerm, options?: RequestOptions): Promise<StoreResponse<LeaseCheck>>;
}

export interface StoreClientOptions {
  host?: string;
  port?: number;
  space: string;
  /** Outer transport/response deadline in milliseconds; defaults to 60,000. */
  requestTimeoutMs?: number;
  transport?: StoreTransport;
}

export type StoreTransportEntry = 'query' | 'transact' | 'snapshot';

export interface StoreTransportRequest {
  readonly packet: Uint8Array;
  readonly entry: StoreTransportEntry;
  readonly operation: string;
  readonly space: string;
  readonly requestId: bigint;
  readonly timeoutMs: number;
  readonly signal: AbortSignal;
}

export type StoreTransport = (
  request: StoreTransportRequest,
) => Promise<Uint8Array> | Uint8Array;

export interface StoreTransportClientOptions {
  transport: StoreTransport;
  space: string;
  /** Outer transport/response deadline in milliseconds; defaults to 60,000. */
  requestTimeoutMs?: number;
}

export interface StoreNativeCheckpointResult {
  readonly space: string;
  readonly operation: 'rpc/checkpoint';
  readonly servedVersion: bigint;
  readonly watermarkBytes: bigint;
  readonly createdAtUnixMs: bigint;
  readonly snapshotCrc32: bigint;
  readonly snapshotBytes: bigint;
}

export const STORERPC_VERSION: Readonly<{ major: 2; minor: 0 }>;
export const STORERPC_MAX_BATCH_ACTIONS: 247;
export const STORERPC_MAX_PACKET_BYTES: 1048602;

export class StoreProtocolError extends Error {
  code: string;
}

export class StoreTransportError extends Error {}

export class StoreRpcError extends Error {
  code: string;
  retryable: boolean;
  detail: Term | null;
  space: string;
  operation: string;
  servedVersion: bigint;
}

export function stringTerm(value: string): StringTerm;
export function integerTerm(value: IntegerInput): IntegerTerm;
export function float64Term(value: number): Float64Term;
export function booleanTerm(value: boolean): BooleanTerm;
export function keywordTerm(value: string): KeywordTerm;
export function instantTerm(seconds: IntegerInput, nanos: IntegerInput): InstantTerm;
export function tripleTerm(t1: TermInput, t2: TermInput, t3: TermInput): TripleTerm;
export function validateTerm(value: Term): Term;
export function term(value: TermInput): Term;
export function float64Value(value: Float64Term): number;
export function integerValue(value: IntegerTerm): bigint;
export function listValues(value: Term): Term[];
export function recordFields(value: Term, tag: string, count: number): Term[];
export function lowerQueryPlan(value: StructuredQuery): TripleTerm;
export function tripleQuery(pattern?: TriplePattern): TripleTerm;
/** Operator-only fixed capability; deliberately absent from StoreClient. */
export function storeNativeCheckpoint(options: StoreClientOptions): Promise<StoreNativeCheckpointResult>;
/** Runtime-neutral operator capability over an injected exact-packet transport. */
export function storeTransportCheckpoint(options: StoreTransportClientOptions): Promise<StoreNativeCheckpointResult>;
export function storeTcpTransport(options?: Pick<StoreClientOptions, 'host' | 'port'>): StoreTransport;
export function storeRpcDeclaredPacketBytes(packet: Uint8Array): number | null;
export function storeClient(options: StoreClientOptions): StoreClient;
