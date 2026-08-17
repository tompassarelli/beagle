import {
  FRAMRPC_MAX_BATCH_ACTIONS,
  StoreRpcError,
  term,
} from './store-rpc-core.mjs';

export const SCHEMA_MAX_BATCH_ACTIONS = FRAMRPC_MAX_BATCH_ACTIONS;
export const SCHEMA_MAX_CONFLICT_RETRIES = 32;
export const SCHEMA_MAX_REQUIRE_UNIQUE = 247;
export const SCHEMA_MAX_GUARD_CONCURRENCY = 8;
export const SCHEMA_MAX_READ_PAGES = 2;

export const SCHEMA_ERROR_CODES = Object.freeze({
  INVALID_INPUT: 'schema/invalid-input',
  INVALID_RESPONSE: 'schema/invalid-response',
  IDENTITY_EXISTS: 'schema/identity-exists',
  IDENTITY_MISSING: 'schema/identity-missing',
  DUPLICATE_IDENTITY: 'schema/duplicate-identity',
  DUPLICATE_CREATE_SUBJECT: 'schema/duplicate-create-subject',
  DUPLICATE_UPDATE_TARGET: 'schema/duplicate-update-target',
  REQUIRED_IDENTITY_MISSING: 'schema/required-identity-missing',
  CURRENT_VALUE_REJECTED: 'schema/current-value-rejected',
  ACTION_LIMIT: 'schema/action-limit',
  CONFLICT_EXHAUSTED: 'schema/conflict-exhausted',
});

const QUERY_PAGE_LIMIT = 128;

class SnapshotSkew extends Error {
  constructor(requested, served) {
    super('current scan served a different version than the OCC attempt');
    this.requested = requested;
    this.served = served;
  }
}

export class SchemaConstraintError extends Error {
  constructor(code, message, { detail = null, cause } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'SchemaConstraintError';
    this.code = code;
    this.detail = detail;
  }
}

function schemaError(code, message, detail, cause) {
  throw new SchemaConstraintError(code, message, { detail, cause });
}

function own(value, key) {
  return Object.hasOwn(value, key);
}

function inputObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    schemaError(SCHEMA_ERROR_CODES.INVALID_INPUT, `${label} must be an object`, { label });
  }
  return value;
}

function exactKeys(value, allowed, label) {
  inputObject(value, label);
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        `${label}.${key} is unknown`,
        { label, key },
      );
    }
  }
}

function required(value, key, label) {
  if (!own(value, key)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.${key} is required`,
      { label, key },
    );
  }
  return value[key];
}

function boundedInteger(value, label, minimum, maximum) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label} must be an integer from ${minimum} through ${maximum}`,
      { label, minimum, maximum },
    );
  }
  return value;
}

function termKey(value) {
  return JSON.stringify(value);
}

function identityKey(identity) {
  return JSON.stringify([identity.predicate, identity.value]);
}

function sameTerm(left, right) {
  return termKey(left) === termKey(right);
}

function distinctTerms(values) {
  const seen = new Set();
  const distinct = [];
  for (const value of values) {
    const key = termKey(value);
    if (!seen.has(key)) {
      seen.add(key);
      distinct.push(value);
    }
  }
  return distinct;
}

function normalizeIdentity(value, label = 'identity') {
  inputObject(value, label);
  exactKeys(value, ['predicate', 'value'], label);
  return {
    predicate: term(required(value, 'predicate', label)),
    value: term(required(value, 'value', label)),
  };
}

function normalizeRequireUnique(value, label) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label} must be an array`,
      { label },
    );
  }
  if (value.length > SCHEMA_MAX_REQUIRE_UNIQUE) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label} accepts at most ${SCHEMA_MAX_REQUIRE_UNIQUE} entries`,
      {
        label,
        entries: value.length,
        maximum: SCHEMA_MAX_REQUIRE_UNIQUE,
      },
    );
  }
  return value.map((entry, index) => {
    const entryLabel = `${label}[${index}]`;
    exactKeys(entry, ['subject', 'predicate', 'value'], entryLabel);
    return {
      subject: term(required(entry, 'subject', entryLabel)),
      predicate: term(required(entry, 'predicate', entryLabel)),
      value: term(required(entry, 'value', entryLabel)),
    };
  });
}

function normalizeField(value, index, fieldLabel = 'fields') {
  const label = `${fieldLabel}[${index}]`;
  exactKeys(value, ['predicate', 'value', 'cardinality'], label);
  const cardinality = own(value, 'cardinality') ? value.cardinality : 'single';
  if (cardinality !== 'single' && cardinality !== 'multi') {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.cardinality must be 'single' or 'multi'`,
      { label, cardinality },
    );
  }
  return {
    predicate: term(required(value, 'predicate', label)),
    value: term(required(value, 'value', label)),
    cardinality,
  };
}

function normalizeCreateRecord(value, label, allowRequireUnique) {
  exactKeys(
    value,
    allowRequireUnique
      ? ['subject', 'identity', 'fields', 'requireUnique']
      : ['subject', 'identity', 'fields'],
    label,
  );
  const subject = term(required(value, 'subject', label));
  const identity = normalizeIdentity(
    required(value, 'identity', label),
    `${label}.identity`,
  );
  const fieldsInput = own(value, 'fields') ? value.fields : [];
  if (!Array.isArray(fieldsInput)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.fields must be an array`,
      { label: `${label}.fields` },
    );
  }
  enforceActionCount(fieldsInput.length + 1, `${label}.fields plus identity`);

  const fields = [];
  const predicates = new Map();
  for (let index = 0; index < fieldsInput.length; index += 1) {
    const field = normalizeField(fieldsInput[index], index, `${label}.fields`);
    if (sameTerm(field.predicate, identity.predicate)) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        'identity predicate must not be repeated in fields',
        { predicate: identity.predicate },
      );
    }

    const predicateKey = termKey(field.predicate);
    const prior = predicates.get(predicateKey);
    if (prior && prior.cardinality !== field.cardinality) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        'one field predicate cannot mix single and multi cardinality',
        { predicate: field.predicate },
      );
    }
    if (prior && field.cardinality === 'single'
        && !sameTerm(prior.values[0], field.value)) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        'one single-cardinality predicate cannot request multiple values',
        { predicate: field.predicate, values: [prior.values[0], field.value] },
      );
    }
    if (prior && prior.keys.has(termKey(field.value))) continue;

    if (prior) {
      prior.keys.add(termKey(field.value));
      prior.values.push(field.value);
    } else {
      predicates.set(predicateKey, {
        cardinality: field.cardinality,
        keys: new Set([termKey(field.value)]),
        values: [field.value],
      });
    }
    fields.push(field);
  }
  return { subject, identity, fields };
}

function normalizeUniqueInput(value) {
  return {
    ...normalizeCreateRecord(value, 'unique input', true),
    requireUnique: normalizeRequireUnique(value.requireUnique, 'requireUnique'),
  };
}

function normalizeUpdateField(value, label, identity) {
  const fieldInput = inputObject(value, label);
  exactKeys(
    fieldInput,
    ['predicate', 'values', 'cardinality', 'allowedCurrent'],
    label,
  );
  const cardinality = required(fieldInput, 'cardinality', label);
  if (cardinality !== 'single' && cardinality !== 'multi') {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.cardinality must be 'single' or 'multi'`,
      { label, cardinality },
    );
  }
  const valuesInput = required(fieldInput, 'values', label);
  if (!Array.isArray(valuesInput)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.values must be an array`,
      { label: `${label}.values` },
    );
  }
  enforceActionCount(valuesInput.length, `${label}.values`);
  if (cardinality === 'single' && valuesInput.length > 1) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      'a single-cardinality update accepts zero or one desired value',
      { label, cardinality, values: valuesInput.length },
    );
  }
  const fieldPredicate = term(required(fieldInput, 'predicate', label));
  if (sameTerm(fieldPredicate, identity.predicate)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      'update field predicate must differ from its lookup identity predicate',
      { label, predicate: fieldPredicate },
    );
  }
  const hasAllowedCurrent = own(fieldInput, 'allowedCurrent');
  const allowedInput = hasAllowedCurrent
    ? fieldInput.allowedCurrent : undefined;
  if (allowedInput !== undefined && !Array.isArray(allowedInput)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.allowedCurrent must be an array when present`,
      { label: `${label}.allowedCurrent` },
    );
  }
  if (allowedInput !== undefined
      && allowedInput.length > SCHEMA_MAX_BATCH_ACTIONS) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.allowedCurrent accepts at most ${SCHEMA_MAX_BATCH_ACTIONS} entries`,
      {
        label: `${label}.allowedCurrent`,
        entries: allowedInput.length,
        maximum: SCHEMA_MAX_BATCH_ACTIONS,
      },
    );
  }
  return {
    predicate: fieldPredicate,
    values: distinctTerms(valuesInput.map(valueInput => term(valueInput))),
    cardinality,
    allowedCurrent: allowedInput === undefined
      ? null
      : distinctTerms(allowedInput.map(valueInput => term(valueInput))),
  };
}

function normalizeUpdateInput(value) {
  exactKeys(value, ['identity', 'field', 'requireUnique'], 'update input');
  const identity = normalizeIdentity(required(value, 'identity', 'update input'));
  const requireUnique = normalizeRequireUnique(value.requireUnique, 'requireUnique');
  const field = normalizeUpdateField(
    required(value, 'field', 'update input'),
    'field',
    identity,
  );
  return { identity, requireUnique, field };
}

function normalizeUpdateManyInput(value) {
  const label = 'update many input';
  exactKeys(value, ['updates', 'requireUnique'], label);
  const updatesInput = required(value, 'updates', label);
  if (!Array.isArray(updatesInput) || updatesInput.length === 0) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.updates must be a nonempty array`,
      { label: `${label}.updates` },
    );
  }
  if (updatesInput.length > SCHEMA_MAX_BATCH_ACTIONS) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.updates accepts at most ${SCHEMA_MAX_BATCH_ACTIONS} entries`,
      {
        label: `${label}.updates`,
        entries: updatesInput.length,
        maximum: SCHEMA_MAX_BATCH_ACTIONS,
      },
    );
  }

  let fieldCount = 0;
  let desiredActionCount = 0;
  const updates = updatesInput.map((updateInput, updateIndex) => {
    const updateLabel = `updates[${updateIndex}]`;
    exactKeys(updateInput, ['identity', 'fields'], updateLabel);
    const identity = normalizeIdentity(
      required(updateInput, 'identity', updateLabel),
      `${updateLabel}.identity`,
    );
    const fieldsInput = required(updateInput, 'fields', updateLabel);
    if (!Array.isArray(fieldsInput) || fieldsInput.length === 0) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        `${updateLabel}.fields must be a nonempty array`,
        { label: `${updateLabel}.fields` },
      );
    }
    fieldCount += fieldsInput.length;
    if (fieldCount > SCHEMA_MAX_BATCH_ACTIONS) {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        `update many input accepts at most ${SCHEMA_MAX_BATCH_ACTIONS} target fields`,
        {
          label: 'update many input.updates[].fields',
          entries: fieldCount,
          maximum: SCHEMA_MAX_BATCH_ACTIONS,
        },
      );
    }

    const predicates = new Set();
    const fields = fieldsInput.map((fieldInput, fieldIndex) => {
      const field = normalizeUpdateField(
        fieldInput,
        `${updateLabel}.fields[${fieldIndex}]`,
        identity,
      );
      const predicateKey = termKey(field.predicate);
      if (predicates.has(predicateKey)) {
        schemaError(
          SCHEMA_ERROR_CODES.DUPLICATE_UPDATE_TARGET,
          'one update cannot target the same field predicate twice',
          { update: updateIndex, predicate: field.predicate },
        );
      }
      predicates.add(predicateKey);
      desiredActionCount += field.values.length;
      enforceActionCount(desiredActionCount, 'update many desired values');
      return field;
    });
    return { identity, fields };
  });

  return {
    updates,
    requireUnique: normalizeRequireUnique(value.requireUnique, 'requireUnique'),
  };
}

function normalizeUniqueTransaction(value) {
  const label = 'unique transaction';
  exactKeys(value, ['creates', 'updates', 'requireUnique'], label);
  const createsInput = own(value, 'creates') ? value.creates : [];
  const updatesInput = own(value, 'updates') ? value.updates : [];
  if (!Array.isArray(createsInput)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.creates must be an array`,
      { label: `${label}.creates` },
    );
  }
  if (!Array.isArray(updatesInput)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.updates must be an array`,
      { label: `${label}.updates` },
    );
  }
  if (createsInput.length === 0 && updatesInput.length === 0) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label} requires at least one create or update`,
      { label },
    );
  }
  if (createsInput.length > SCHEMA_MAX_BATCH_ACTIONS) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_INPUT,
      `${label}.creates accepts at most ${SCHEMA_MAX_BATCH_ACTIONS} entries`,
      {
        label: `${label}.creates`,
        entries: createsInput.length,
        maximum: SCHEMA_MAX_BATCH_ACTIONS,
      },
    );
  }

  const creates = createsInput.map((create, index) => (
    normalizeCreateRecord(create, `creates[${index}]`, false)
  ));
  const createIdentities = new Map();
  const createSubjects = new Map();
  for (let index = 0; index < creates.length; index += 1) {
    const create = creates[index];
    const plannedIdentity = identityKey(create.identity);
    const priorIdentity = createIdentities.get(plannedIdentity);
    if (priorIdentity !== undefined) {
      schemaError(
        SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
        'two creates declare the same identity',
        { identity: create.identity, first: priorIdentity, second: index },
      );
    }
    createIdentities.set(plannedIdentity, index);

    const plannedSubject = termKey(create.subject);
    const priorSubject = createSubjects.get(plannedSubject);
    if (priorSubject !== undefined) {
      schemaError(
        SCHEMA_ERROR_CODES.DUPLICATE_CREATE_SUBJECT,
        'two creates declare the same subject',
        { subject: create.subject, first: priorSubject, second: index },
      );
    }
    createSubjects.set(plannedSubject, index);
  }

  const updates = updatesInput.length === 0
    ? []
    : normalizeUpdateManyInput({ updates: updatesInput }).updates;
  for (let createIndex = 0; createIndex < creates.length; createIndex += 1) {
    for (const field of creates[createIndex].fields) {
      const identityOwner = createIdentities.get(identityKey({
        predicate: field.predicate,
        value: field.value,
      }));
      if (identityOwner !== undefined) {
        schemaError(
          SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
          'a create field also asserts a planned identity',
          {
            identity: creates[identityOwner].identity,
            owner: identityOwner,
            fieldCreate: createIndex,
          },
        );
      }
    }
  }
  for (let updateIndex = 0; updateIndex < updates.length; updateIndex += 1) {
    for (const field of updates[updateIndex].fields) {
      for (const valueInput of field.values) {
        const identityOwner = createIdentities.get(identityKey({
          predicate: field.predicate,
          value: valueInput,
        }));
        if (identityOwner !== undefined) {
          schemaError(
            SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
            'an update value also asserts a planned identity',
            {
              identity: creates[identityOwner].identity,
              owner: identityOwner,
              update: updateIndex,
              predicate: field.predicate,
            },
          );
        }
      }
    }
  }
  const requireUnique = normalizeRequireUnique(value.requireUnique, 'requireUnique');
  for (const requirement of requireUnique) {
    const createIndex = createIdentities.get(identityKey(requirement));
    if (createIndex !== undefined
        && !sameTerm(creates[createIndex].subject, requirement.subject)) {
      schemaError(
        SCHEMA_ERROR_CODES.REQUIRED_IDENTITY_MISSING,
        'required planned identity does not resolve to its required subject',
        { requirement, subject: creates[createIndex].subject },
      );
    }
  }
  let desiredActions = creates.reduce(
    (count, create) => count + create.fields.length + 1,
    0,
  );
  for (const update of updates) {
    for (const field of update.fields) desiredActions += field.values.length;
  }
  enforceActionCount(desiredActions, `${label} desired values`);
  return { creates, updates, requireUnique };
}

function singleColumnQuery(relation, variable, tripleArgs) {
  return {
    find: relation,
    rules: [{
      head: { rel: relation, args: [{ var: variable }] },
      body: [{ rel: 'triple', args: tripleArgs }],
    }],
  };
}

function identityQuery(identity) {
  const variable = 'schemaSubject';
  return singleColumnQuery('schemaIdentitySubjects', variable, [
    { var: variable }, identity.predicate, identity.value,
  ]);
}

function responseVersion(response, label) {
  if (!response || typeof response.servedVersion !== 'bigint') {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      `${label} response has no bigint servedVersion`,
      { label },
    );
  }
  return response.servedVersion;
}

function responseRows(response) {
  if (!Array.isArray(response.result)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      'query response result must be an array',
      null,
    );
  }
  return response.result;
}

function rowTerm(row) {
  if (!Array.isArray(row) || row.length !== 1) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      'schema query rows must contain exactly one Term',
      { row },
    );
  }
  return term(row[0]);
}

function continuationCursor(response, label, pagesRead, seenCursors) {
  if (!response.page || response.page.done) return null;
  if (response.page.nextCursor === null || response.page.nextCursor === undefined) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      `unfinished ${label} page has no continuation cursor`,
      null,
    );
  }
  const cursor = term(response.page.nextCursor);
  const key = termKey(cursor);
  if (seenCursors.has(key)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      `${label} continuation cursor repeated`,
      { cursor },
    );
  }
  if (pagesRead >= SCHEMA_MAX_READ_PAGES) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      `${label} exceeded the schema read page ceiling`,
      { pages: pagesRead, maximum: SCHEMA_MAX_READ_PAGES },
    );
  }
  seenCursors.add(key);
  return cursor;
}

function enforceActionCount(actionCount, label = 'schema mutation') {
  if (actionCount > SCHEMA_MAX_BATCH_ACTIONS) {
    schemaError(
      SCHEMA_ERROR_CODES.ACTION_LIMIT,
      `${label} needs ${actionCount} actions; the FRAMRPC mutation-response depth ceiling is ${SCHEMA_MAX_BATCH_ACTIONS}`,
      { label, actions: actionCount, maximum: SCHEMA_MAX_BATCH_ACTIONS },
    );
  }
}

function enforceActionLimit(actions) {
  enforceActionCount(actions.length);
}

async function mapWithConcurrency(values, concurrency, mapper) {
  const results = new Array(values.length);
  let nextIndex = 0;
  let firstError;
  let failed = false;

  async function worker() {
    while (!failed && nextIndex < values.length) {
      const index = nextIndex;
      nextIndex += 1;
      try {
        results[index] = await mapper(values[index], index);
      } catch (error) {
        if (!failed) firstError = error;
        failed = true;
      }
    }
  }

  const workerCount = Math.min(concurrency, values.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  if (failed) throw firstError;
  return results;
}

function assertAction(subject, predicate, value) {
  return { op: 'assert', t1: subject, t2: predicate, t3: value };
}

function retractAction(subject, predicate, value) {
  return { op: 'retract', t1: subject, t2: predicate, t3: value };
}

function createActions(input, subject = input.subject) {
  return [
    assertAction(subject, input.identity.predicate, input.identity.value),
    ...input.fields.map(field => assertAction(subject, field.predicate, field.value)),
  ];
}

function summarize(subject, created, asOf, response = null) {
  if (response === null) {
    return Object.freeze({
      subject,
      created,
      changed: false,
      servedVersion: asOf,
      result: [],
    });
  }
  const servedVersion = responseVersion(response, 'batch');
  if (!Array.isArray(response.result)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      'batch response result must be an array',
      null,
    );
  }
  return Object.freeze({
    subject,
    created,
    changed: response.result.some(action => action.stateChanged === true),
    servedVersion,
    result: response.result,
  });
}

function summarizeMany(subjects, asOf, response = null) {
  const exactSubjects = Object.freeze([...subjects]);
  if (response === null) {
    return Object.freeze({
      subjects: exactSubjects,
      changed: false,
      servedVersion: asOf,
      result: [],
    });
  }
  const servedVersion = responseVersion(response, 'batch');
  if (!Array.isArray(response.result)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      'batch response result must be an array',
      null,
    );
  }
  return Object.freeze({
    subjects: exactSubjects,
    changed: response.result.some(action => action.stateChanged === true),
    servedVersion,
    result: response.result,
  });
}

function summarizeTransaction(
  createdSubjects,
  updatedSubjects,
  asOf,
  response = null,
  preflight = null,
) {
  const exactCreatedSubjects = Object.freeze([...createdSubjects]);
  const exactUpdatedSubjects = Object.freeze([...updatedSubjects]);
  if (response === null) {
    return Object.freeze({
      createdSubjects: exactCreatedSubjects,
      updatedSubjects: exactUpdatedSubjects,
      changed: false,
      servedVersion: asOf,
      result: [],
      preflight: null,
    });
  }
  const servedVersion = responseVersion(response, 'batch');
  if (!Array.isArray(response.result)) {
    schemaError(
      SCHEMA_ERROR_CODES.INVALID_RESPONSE,
      'batch response result must be an array',
      null,
    );
  }
  return Object.freeze({
    createdSubjects: exactCreatedSubjects,
    updatedSubjects: exactUpdatedSubjects,
    changed: response.result.some(action => action.stateChanged === true),
    servedVersion,
    result: response.result,
    preflight,
  });
}

function typedConflict(error) {
  return error instanceof StoreRpcError
    && error.code === 'rpc/conflict'
    && error.retryable === true;
}

export function schemaClient(store, {
  maxConflictRetries = 4,
  queryTimeoutMs = 5000,
} = {}) {
  inputObject(store, 'store client');
  for (const method of ['version', 'query', 'scan', 'preflightBatch', 'batch']) {
    if (typeof store[method] !== 'function') {
      schemaError(
        SCHEMA_ERROR_CODES.INVALID_INPUT,
        `store client.${method} must be a function`,
        { method },
      );
    }
  }
  boundedInteger(
    maxConflictRetries,
    'maxConflictRetries',
    0,
    SCHEMA_MAX_CONFLICT_RETRIES,
  );
  boundedInteger(queryTimeoutMs, 'queryTimeoutMs', 0, 0xffffffff);

  async function readColumn(query, asOf, maximumDistinct) {
    const values = [];
    const keys = new Set();
    const seenCursors = new Set();
    let pagesRead = 0;
    let cursor;
    while (values.length < maximumDistinct) {
      const page = { limit: QUERY_PAGE_LIMIT };
      if (cursor !== undefined) page.cursor = cursor;
      const response = await store.query(query, { asOf, timeoutMs: queryTimeoutMs, page });
      pagesRead += 1;
      if (responseVersion(response, 'query') !== asOf) {
        schemaError(
          SCHEMA_ERROR_CODES.INVALID_RESPONSE,
          'query response did not serve its requested asOf version',
          { requested: asOf, served: response.servedVersion },
        );
      }
      for (const row of responseRows(response)) {
        const value = rowTerm(row);
        const key = termKey(value);
        if (!keys.has(key)) {
          keys.add(key);
          values.push(value);
          if (values.length === maximumDistinct) break;
        }
      }
      if (values.length === maximumDistinct || !response.page || response.page.done) break;
      cursor = continuationCursor(response, 'query', pagesRead, seenCursors);
    }
    return values;
  }

  async function scanValues(subject, predicate, asOf) {
    const values = [];
    const seenCursors = new Set();
    let pagesRead = 0;
    let cursor;
    const overflowSentinel = SCHEMA_MAX_BATCH_ACTIONS + 1;
    while (values.length < overflowSentinel) {
      const page = { limit: QUERY_PAGE_LIMIT };
      if (cursor !== undefined) page.cursor = cursor;
      const response = await store.scan({ t1: subject, t2: predicate }, { page });
      pagesRead += 1;
      const servedVersion = responseVersion(response, 'scan');
      if (servedVersion !== asOf) {
        if (cursor === undefined) throw new SnapshotSkew(asOf, servedVersion);
        schemaError(
          SCHEMA_ERROR_CODES.INVALID_RESPONSE,
          'scan continuation changed its pinned servedVersion',
          { requested: asOf, served: servedVersion },
        );
      }
      if (!Array.isArray(response.result)) {
        schemaError(
          SCHEMA_ERROR_CODES.INVALID_RESPONSE,
          'scan response result must be an array',
          null,
        );
      }
      for (const row of response.result) {
        const proposition = term(row);
        if (proposition[0] !== 'triple'
            || !sameTerm(proposition[1], subject)
            || !sameTerm(proposition[2], predicate)) {
          schemaError(
            SCHEMA_ERROR_CODES.INVALID_RESPONSE,
            'scan response contains a proposition outside its requested pattern',
            { proposition, subject, predicate },
          );
        }
        values.push(proposition[3]);
        if (values.length === overflowSentinel) break;
      }
      if (values.length === overflowSentinel
          || !response.page || response.page.done) break;
      cursor = continuationCursor(response, 'scan', pagesRead, seenCursors);
    }
    return values;
  }

  function ownersAt(identity, asOf) {
    return readColumn(identityQuery(identity), asOf, 2);
  }

  function valuesAt(subject, predicate, asOf) {
    return scanValues(subject, predicate, asOf);
  }

  function rejectOwners(owners, identity, create) {
    if (owners.length > 1) {
      schemaError(
        SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
        'identity resolves to multiple distinct subjects',
        { identity, subjects: owners },
      );
    }
    if (create && owners.length === 1) {
      schemaError(
        SCHEMA_ERROR_CODES.IDENTITY_EXISTS,
        'identity already belongs to a subject',
        { identity, subject: owners[0] },
      );
    }
  }

  function requireSource(owners, identity) {
    if (owners.length > 1) {
      schemaError(
        SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
        'identity resolves to multiple distinct subjects',
        { identity, subjects: owners },
      );
    }
    if (owners.length === 0) {
      schemaError(
        SCHEMA_ERROR_CODES.IDENTITY_MISSING,
        'identity does not resolve to a subject',
        { identity },
      );
    }
    return owners[0];
  }

  async function requireUniqueAt(requirements, asOf) {
    const resolved = await mapWithConcurrency(
      requirements,
      SCHEMA_MAX_GUARD_CONCURRENCY,
      requirement => ownersAt(requirement, asOf),
    );
    for (let index = 0; index < requirements.length; index += 1) {
      const requirement = requirements[index];
      const owners = resolved[index];
      if (owners.length > 1) {
        schemaError(
          SCHEMA_ERROR_CODES.DUPLICATE_IDENTITY,
          'required identity resolves to multiple distinct subjects',
          { requirement, subjects: owners },
        );
      }
      if (owners.length !== 1 || !sameTerm(owners[0], requirement.subject)) {
        schemaError(
          SCHEMA_ERROR_CODES.REQUIRED_IDENTITY_MISSING,
          'required identity does not resolve solely to its required subject',
          { requirement, subjects: owners },
        );
      }
    }
  }

  async function retrying(body) {
    let retries = 0;
    while (true) {
      const versionResponse = await store.version();
      const asOf = responseVersion(versionResponse, 'version');
      try {
        return await body(asOf);
      } catch (error) {
        const skew = error instanceof SnapshotSkew;
        if (!skew && !typedConflict(error)) throw error;
        if (retries === maxConflictRetries) {
          schemaError(
            SCHEMA_ERROR_CODES.CONFLICT_EXHAUSTED,
            `schema mutation exhausted ${maxConflictRetries} OCC retries`,
            {
              attempts: retries + 1,
              retries: maxConflictRetries,
              reason: skew ? 'snapshot-skew' : 'rpc/conflict',
            },
            error,
          );
        }
        retries += 1;
      }
    }
  }

  async function commit(asOf, actions) {
    enforceActionLimit(actions);
    if (actions.length === 0) return { response: null, preflight: null };
    const preflight = store.preflightBatch(actions, { expectedVersion: asOf });
    const response = await store.batch(actions, {
      expectedVersion: asOf,
      preflight,
    });
    return { response, preflight };
  }

  async function write(subject, created, asOf, actions) {
    const { response } = await commit(asOf, actions);
    return summarize(subject, created, asOf, response);
  }

  async function writeMany(subjects, asOf, actions) {
    const { response } = await commit(asOf, actions);
    return summarizeMany(subjects, asOf, response);
  }

  async function writeTransaction(createdSubjects, updatedSubjects, asOf, actions) {
    const { response, preflight } = await commit(asOf, actions);
    return summarizeTransaction(
      createdSubjects,
      updatedSubjects,
      asOf,
      response,
      preflight,
    );
  }

  async function replaceSingle(subjectInput, predicateInput, valueInput) {
    const subject = term(subjectInput);
    const predicate = term(predicateInput);
    const value = term(valueInput);
    return retrying(async asOf => {
      const current = await valuesAt(subject, predicate, asOf);
      const actions = [
        ...current.map(oldValue => retractAction(subject, predicate, oldValue)),
        assertAction(subject, predicate, value),
      ];
      return write(subject, false, asOf, actions);
    });
  }

  async function createUnique(value) {
    const input = normalizeUniqueInput(value);
    const actions = createActions(input);
    enforceActionLimit(actions);
    return retrying(async asOf => {
      const owners = await ownersAt(input.identity, asOf);
      rejectOwners(owners, input.identity, true);
      await requireUniqueAt(input.requireUnique, asOf);
      return write(input.subject, true, asOf, actions);
    });
  }

  async function upsertUnique(value) {
    const input = normalizeUniqueInput(value);
    return retrying(async asOf => {
      const owners = await ownersAt(input.identity, asOf);
      rejectOwners(owners, input.identity, false);
      await requireUniqueAt(input.requireUnique, asOf);
      if (owners.length === 0) {
        return write(input.subject, true, asOf, createActions(input));
      }

      const subject = owners[0];
      const currentSingles = await mapWithConcurrency(
        input.fields,
        SCHEMA_MAX_GUARD_CONCURRENCY,
        field => field.cardinality === 'single'
          ? valuesAt(subject, field.predicate, asOf)
          : null,
      );
      const actions = [];
      for (let index = 0; index < input.fields.length; index += 1) {
        const field = input.fields[index];
        const current = currentSingles[index];
        if (current !== null) {
          actions.push(...current.map(oldValue => (
            retractAction(subject, field.predicate, oldValue)
          )));
        }
        actions.push(assertAction(subject, field.predicate, field.value));
      }
      return write(subject, false, asOf, actions);
    });
  }

  async function resolveUpdates(updates, asOf) {
    const ownerLists = await mapWithConcurrency(
      updates,
      SCHEMA_MAX_GUARD_CONCURRENCY,
      update => ownersAt(update.identity, asOf),
    );
    const resolved = updates.map((update, updateIndex) => ({
      ...update,
      subject: requireSource(ownerLists[updateIndex], update.identity),
      updateIndex,
    }));

    const lookupPredicates = new Map();
    for (const update of resolved) {
      const subjectKey = termKey(update.subject);
      const predicates = lookupPredicates.get(subjectKey) ?? [];
      if (!predicates.some(predicate => sameTerm(predicate, update.identity.predicate))) {
        predicates.push(update.identity.predicate);
      }
      lookupPredicates.set(subjectKey, predicates);
    }

    const cells = [];
    const cellKeys = new Map();
    for (const update of resolved) {
      const protectedPredicates = lookupPredicates.get(termKey(update.subject));
      for (let fieldIndex = 0; fieldIndex < update.fields.length; fieldIndex += 1) {
        const field = update.fields[fieldIndex];
        if (protectedPredicates.some(predicate => sameTerm(predicate, field.predicate))) {
          schemaError(
            SCHEMA_ERROR_CODES.INVALID_INPUT,
            'an update field cannot replace a lookup identity predicate on its subject',
            {
              subject: update.subject,
              predicate: field.predicate,
              update: update.updateIndex,
              field: fieldIndex,
            },
          );
        }
        const cellKey = JSON.stringify([update.subject, field.predicate]);
        const prior = cellKeys.get(cellKey);
        if (prior) {
          schemaError(
            SCHEMA_ERROR_CODES.DUPLICATE_UPDATE_TARGET,
            'two updates resolve to the same subject and field predicate',
            {
              subject: update.subject,
              predicate: field.predicate,
              first: prior,
              second: { update: update.updateIndex, field: fieldIndex },
            },
          );
        }
        cellKeys.set(cellKey, { update: update.updateIndex, field: fieldIndex });
        cells.push({
          subject: update.subject,
          field,
          updateIndex: update.updateIndex,
          fieldIndex,
        });
      }
    }
    return { resolved, cells };
  }

  function rejectCreateUpdateCellCollisions(creates, cells) {
    const createCells = new Map();
    for (let createIndex = 0; createIndex < creates.length; createIndex += 1) {
      const create = creates[createIndex];
      for (const predicate of [
        create.identity.predicate,
        ...create.fields.map(field => field.predicate),
      ]) {
        const key = JSON.stringify([create.subject, predicate]);
        if (!createCells.has(key)) {
          createCells.set(key, { create: createIndex, predicate });
        }
      }
    }
    for (const cell of cells) {
      const createCell = createCells.get(JSON.stringify([cell.subject, cell.field.predicate]));
      if (createCell !== undefined) {
        schemaError(
          SCHEMA_ERROR_CODES.DUPLICATE_UPDATE_TARGET,
          'a create and update target the same subject and field predicate',
          {
            subject: cell.subject,
            predicate: cell.field.predicate,
            create: createCell.create,
            update: cell.updateIndex,
            field: cell.fieldIndex,
          },
        );
      }
    }
  }

  function requirementsOutsideCreateSet(requirements, creates) {
    const planned = new Map(creates.map(create => [identityKey(create.identity), create]));
    const live = [];
    for (const requirement of requirements) {
      const create = planned.get(identityKey(requirement));
      if (create === undefined) {
        live.push(requirement);
      } else if (!sameTerm(create.subject, requirement.subject)) {
        schemaError(
          SCHEMA_ERROR_CODES.REQUIRED_IDENTITY_MISSING,
          'required planned identity does not resolve to its required subject',
          { requirement, subject: create.subject },
        );
      }
    }
    return live;
  }

  async function appendUpdateActions(actions, cells, asOf) {
    const currentValues = await mapWithConcurrency(
      cells,
      SCHEMA_MAX_GUARD_CONCURRENCY,
      cell => valuesAt(cell.subject, cell.field.predicate, asOf),
    );
    for (let cellIndex = 0; cellIndex < cells.length; cellIndex += 1) {
      const cell = cells[cellIndex];
      const current = currentValues[cellIndex];
      const field = cell.field;
      if (field.allowedCurrent !== null) {
        const distinctCurrent = distinctTerms(current);
        const accepted = field.cardinality === 'multi'
          ? distinctCurrent.length === field.allowedCurrent.length
            && distinctCurrent.every(currentValue => (
              field.allowedCurrent.some(allowed => sameTerm(allowed, currentValue))
            ))
          : field.allowedCurrent.length === 0
            ? distinctCurrent.length === 0
            : distinctCurrent.length === 1
              && field.allowedCurrent.some(allowed => (
                sameTerm(allowed, distinctCurrent[0])
              ));
        if (!accepted) {
          schemaError(
            SCHEMA_ERROR_CODES.CURRENT_VALUE_REJECTED,
            'current field value does not satisfy allowedCurrent',
            {
              subject: cell.subject,
              predicate: field.predicate,
              current: distinctCurrent,
              allowed: field.allowedCurrent,
              update: cell.updateIndex,
              field: cell.fieldIndex,
            },
          );
        }
      }
      const exactSingleNoop = field.cardinality === 'single'
        && current.length === field.values.length
        && (current.length === 0 || sameTerm(current[0], field.values[0]));
      if (exactSingleNoop) continue;
      actions.push(...current.map(oldValue => (
        retractAction(cell.subject, field.predicate, oldValue)
      )));
      actions.push(...field.values.map(desired => (
        assertAction(cell.subject, field.predicate, desired)
      )));
      enforceActionLimit(actions);
    }
    return actions;
  }

  async function executeUpdateUniqueMany(input) {
    return retrying(async asOf => {
      const { resolved, cells } = await resolveUpdates(input.updates, asOf);
      await requireUniqueAt(input.requireUnique, asOf);
      const actions = await appendUpdateActions([], cells, asOf);
      return writeMany(resolved.map(update => update.subject), asOf, actions);
    });
  }

  async function executeUniqueTransaction(input) {
    return retrying(async asOf => {
      const createOwnerLists = await mapWithConcurrency(
        input.creates,
        SCHEMA_MAX_GUARD_CONCURRENCY,
        create => ownersAt(create.identity, asOf),
      );
      for (let index = 0; index < input.creates.length; index += 1) {
        rejectOwners(createOwnerLists[index], input.creates[index].identity, true);
      }

      const { resolved, cells } = await resolveUpdates(input.updates, asOf);
      rejectCreateUpdateCellCollisions(input.creates, cells);
      await requireUniqueAt(
        requirementsOutsideCreateSet(input.requireUnique, input.creates),
        asOf,
      );
      const actions = input.creates.flatMap(create => createActions(create));
      enforceActionLimit(actions);
      await appendUpdateActions(actions, cells, asOf);
      return writeTransaction(
        input.creates.map(create => create.subject),
        resolved.map(update => update.subject),
        asOf,
        actions,
      );
    });
  }

  async function updateUniqueMany(value) {
    return executeUpdateUniqueMany(normalizeUpdateManyInput(value));
  }

  async function transactUnique(value) {
    return executeUniqueTransaction(normalizeUniqueTransaction(value));
  }

  async function updateUnique(value) {
    const input = normalizeUpdateInput(value);
    const result = await executeUpdateUniqueMany({
      updates: [{ identity: input.identity, fields: [input.field] }],
      requireUnique: input.requireUnique,
    });
    return Object.freeze({
      subject: result.subjects[0],
      created: false,
      changed: result.changed,
      servedVersion: result.servedVersion,
      result: result.result,
    });
  }

  return Object.freeze({
    replaceSingle,
    createUnique,
    upsertUnique,
    updateUnique,
    updateUniqueMany,
    transactUnique,
  });
}
