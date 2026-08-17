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

export interface FramResponse<Result> {
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

export interface FramInstant {
  epochSeconds: bigint;
  nanos: number;
}

export interface LeaseGrant {
  fence: TripleTerm;
  expires: FramInstant;
}

export interface LeaseCheck {
  valid: boolean;
  expires: FramInstant | null;
}

export interface FramClient {
  version(options?: RequestOptions): Promise<FramResponse<null>>;
  status(options?: RequestOptions): Promise<FramResponse<StatusResult>>;
  validate(options?: RequestOptions): Promise<FramResponse<ValidationResult>>;
  occurrences(options?: PagedRequestOptions): Promise<FramResponse<Occurrence[]>>;
  scan(pattern?: TriplePattern, options?: PagedRequestOptions): Promise<FramResponse<TripleTerm[]>>;
  query(query: StructuredQuery | Term, options?: QueryOptions): Promise<FramResponse<Term[][]>>;
  assert(t1: TermInput, t2: TermInput, t3: TermInput,
    options?: WriteOptions): Promise<FramResponse<MutationActionResult[]>>;
  retract(t1: TermInput, t2: TermInput, t3: TermInput,
    options?: WriteOptions): Promise<FramResponse<MutationActionResult[]>>;
  preflightBatch(actions: readonly BatchAction[], options?: BatchPreflightOptions): BatchPreflight;
  batch(actions: readonly BatchAction[], options?: BatchOptions): Promise<FramResponse<MutationActionResult[]>>;
  leaseAcquire(resource: TermInput, holder: TermInput, ttlMs: IntegerInput,
    options?: RequestOptions): Promise<FramResponse<LeaseGrant>>;
  leaseRenew(fence: TripleTerm, ttlMs: IntegerInput,
    options?: RequestOptions): Promise<FramResponse<LeaseGrant>>;
  leaseRelease(fence: TripleTerm,
    options?: RequestOptions): Promise<FramResponse<{ released: boolean }>>;
  leaseCheck(fence: TripleTerm, options?: RequestOptions): Promise<FramResponse<LeaseCheck>>;
}

export interface FramClientOptions {
  host?: string;
  port?: number;
  space: string;
  requestTimeoutMs?: number;
  transport?: FramTransport;
}

export type FramTransportEntry = 'query' | 'transact' | 'snapshot';

export interface FramTransportRequest {
  readonly frame: Uint8Array;
  readonly entry: FramTransportEntry;
  readonly operation: string;
  readonly space: string;
  readonly requestId: bigint;
  readonly timeoutMs: number;
  readonly signal: AbortSignal;
}

export type FramTransport = (
  request: FramTransportRequest,
) => Promise<Uint8Array> | Uint8Array;

export interface FramTransportClientOptions {
  transport: FramTransport;
  space: string;
  requestTimeoutMs?: number;
}

export interface FramNativeCheckpointResult {
  readonly space: string;
  readonly operation: 'rpc/checkpoint';
  readonly servedVersion: bigint;
  readonly watermarkBytes: bigint;
  readonly createdAtUnixMs: bigint;
  readonly snapshotCrc32: bigint;
  readonly snapshotBytes: bigint;
}

export const FRAMRPC_VERSION: Readonly<{ major: 2; minor: 0 }>;
export const FRAMRPC_MAX_BATCH_ACTIONS: 247;
export const FRAMRPC_MAX_FRAME_BYTES: 1048602;

export class FramProtocolError extends Error {
  code: string;
}

export class FramTransportError extends Error {}

export class FramRpcError extends Error {
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
/** Operator-only fixed capability; deliberately absent from FramClient. */
export function framNativeCheckpoint(options: FramClientOptions): Promise<FramNativeCheckpointResult>;
/** Runtime-neutral operator capability over an injected exact-frame transport. */
export function framTransportCheckpoint(options: FramTransportClientOptions): Promise<FramNativeCheckpointResult>;
export function framTcpTransport(options?: Pick<FramClientOptions, 'host' | 'port'>): FramTransport;
export function framRpcDeclaredFrameBytes(frame: Uint8Array): number | null;
export function framClient(options: FramClientOptions): FramClient;
