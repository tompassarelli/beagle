import { test } from 'bun:test';
import assert from 'node:assert/strict';
import {
  FRAMRPC_MAX_BATCH_ACTIONS,
  FramRpcError,
  FramTransportError,
  framClient,
} from '../clients/bun/framrpc.mjs';
import {
  SCHEMA_MAX_BATCH_ACTIONS,
  SCHEMA_MAX_GUARD_CONCURRENCY,
  SCHEMA_MAX_READ_PAGES,
  SCHEMA_MAX_REQUIRE_UNIQUE,
  SchemaConstraintError,
  schemaClient,
} from '../clients/bun/schema.mjs';

const PAGE_A = Object.freeze(['string', '@page-a']);
const PAGE_B = Object.freeze(['string', '@page-b']);
const PAGE_C = Object.freeze(['string', '@page-c']);
const REVISION_A = Object.freeze(['string', '@revision-a']);
const SLUG = Object.freeze(['keyword', 'page/slug']);
const TITLE = Object.freeze(['keyword', 'page/title']);
const TAG = Object.freeze(['keyword', 'page/tag']);
const CANONICAL_REVISION = Object.freeze(['keyword', 'page/canonical-revision']);
const REVISION_ID = Object.freeze(['keyword', 'revision/id']);
const REVISION_STATUS = Object.freeze(['keyword', 'revision/status']);
const REVISION_BODY = Object.freeze(['keyword', 'revision/body']);
const AUTHOR_EMAIL = Object.freeze(['keyword', 'author/email']);
const HOME = Object.freeze(['string', 'home']);
const REV_1 = Object.freeze(['string', 'rev-1']);
const ALICE_EMAIL = Object.freeze(['string', 'alice@example.test']);
const OLD_TITLE_A = Object.freeze(['string', 'Old title A']);
const OLD_TITLE_B = Object.freeze(['string', 'Old title B']);
const NEW_TITLE = Object.freeze(['string', 'Canonical title']);
const WIKI_TAG = Object.freeze(['string', 'wiki']);
const DRAFT = Object.freeze(['keyword', 'draft']);
const CANONICAL = Object.freeze(['keyword', 'canonical']);
const REVISION_TEXT = Object.freeze(['string', 'Revision text']);

function check(label, body) {
  test(label, body);
}

function rpcError(code, version, { retryable = false, message = code } = {}) {
  return new FramRpcError({
    space: 'schema-test',
    operation: 'rpc/batch',
    servedVersion: version,
    error: { code, retryable, message, detail: null },
  });
}

function conflict(version) {
  return rpcError('rpc/conflict', version, {
    retryable: true,
    message: 'expected-version does not match current version',
  });
}

function occurrenceCoordinateFixture(sequence, ordinal) {
  return ['triple',
    ['triple', ['string', 'schema-test'], ['keyword', 'kernel/tx-sequence'], ['integer', String(sequence)]],
    ['keyword', 'kernel/op-ordinal'],
    ['integer', String(ordinal)]];
}

function mutationResultsFixture(actions, sequence) {
  return actions.map((_, inputIndex) => ({
    inputIndex,
    stateChanged: true,
    occurrence: occurrenceCoordinateFixture(sequence, inputIndex),
  }));
}

function mockFram({
  versions = [0n],
  queryResults = [],
  scanResults = [],
  batchOutcomes = [],
} = {}) {
  const calls = {
    version: [], query: [], scan: [], reads: [], preflightBatch: [], batch: [],
  };
  let versionIndex = 0;
  let queryIndex = 0;
  let scanIndex = 0;
  let batchIndex = 0;
  let currentVersion;

  return {
    calls,
    client: {
      async version(options) {
        calls.version.push(options);
        const servedVersion = versions[Math.min(versionIndex, versions.length - 1)];
        versionIndex += 1;
        currentVersion = servedVersion;
        return { servedVersion };
      },
      async query(query, options) {
        const call = { kind: 'query', query, options };
        calls.query.push(call);
        calls.reads.push(call);
        const outcome = queryResults[queryIndex] ?? [];
        queryIndex += 1;
        if (outcome instanceof Error) throw outcome;
        if (Array.isArray(outcome)) {
          return { servedVersion: options.asOf, result: outcome };
        }
        return {
          servedVersion: outcome.servedVersion ?? options.asOf,
          result: outcome.result ?? [],
          page: outcome.page ?? null,
        };
      },
      async scan(pattern, options) {
        const call = { kind: 'scan', pattern, options, versionAtCall: currentVersion };
        calls.scan.push(call);
        calls.reads.push(call);
        const outcome = scanResults[scanIndex] ?? [];
        scanIndex += 1;
        if (outcome instanceof Error) throw outcome;
        if (Array.isArray(outcome)) {
          return { servedVersion: currentVersion, result: outcome };
        }
        return {
          servedVersion: outcome.servedVersion ?? currentVersion,
          result: outcome.result ?? [],
          page: outcome.page ?? null,
        };
      },
      preflightBatch(actions, options) {
        const preflight = Object.freeze({
          actionCount: actions.length,
          requestBytes: 100 + actions.length,
          bodyBytes: 74 + actions.length,
          termCount: actions.length * 10,
          maxTermDepth: 8,
        });
        calls.preflightBatch.push({ actions, options, preflight });
        return preflight;
      },
      async batch(actions, options) {
        calls.batch.push({ actions, options });
        const outcome = batchOutcomes[batchIndex];
        batchIndex += 1;
        if (outcome instanceof Error) throw outcome;
        const servedVersion = BigInt(options.expectedVersion) + 1n;
        return outcome ?? {
          servedVersion,
          result: mutationResultsFixture(actions, servedVersion),
        };
      },
    },
  };
}

function semanticActions(actions) {
  return actions.map(action => {
    const proposition = action.proposition;
    if (proposition !== undefined) {
      assert.equal(proposition[0], 'triple');
      return { op: action.op, terms: proposition.slice(1) };
    }
    return { op: action.op, terms: [action.t1, action.t2, action.t3] };
  });
}

function tripleFixture(subject, predicate, value) {
  return Object.freeze(['triple', subject, predicate, value]);
}

function sameTermFixture(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function requiredAuthor(subject = PAGE_B) {
  return { subject, predicate: AUTHOR_EMAIL, value: ALICE_EMAIL };
}

function updateInput({
  predicate = TITLE,
  values = [NEW_TITLE],
  cardinality = 'single',
  allowedCurrent,
  requireUnique,
} = {}) {
  const field = { predicate, values, cardinality };
  if (allowedCurrent !== undefined) field.allowedCurrent = allowedCurrent;
  const input = {
    identity: { predicate: SLUG, value: HOME },
    field,
  };
  if (requireUnique !== undefined) input.requireUnique = requireUnique;
  return input;
}

function publicationInput({
  statusAllowed = [DRAFT],
  pointerAllowed = [],
  requireUnique,
} = {}) {
  const input = {
    updates: [
      {
        identity: { predicate: REVISION_ID, value: REV_1 },
        fields: [
          {
            predicate: REVISION_STATUS,
            values: [CANONICAL],
            cardinality: 'single',
            allowedCurrent: statusAllowed,
          },
          {
            predicate: REVISION_BODY,
            values: [REVISION_TEXT],
            cardinality: 'single',
          },
        ],
      },
      {
        identity: { predicate: SLUG, value: HOME },
        fields: [{
          predicate: CANONICAL_REVISION,
          values: [REVISION_A],
          cardinality: 'single',
          allowedCurrent: pointerAllowed,
        }],
      },
    ],
  };
  if (requireUnique !== undefined) input.requireUnique = requireUnique;
  return input;
}

function assertPinnedReads(calls, expectedVersions) {
  assert(calls.reads.length >= expectedVersions.length);
  const pins = calls.reads.map(call => (
    call.kind === 'query' ? call.options.asOf : call.versionAtCall
  ));
  const distinctAttempts = pins.filter((version, index) => index === 0 || version !== pins[index - 1]);
  assert.deepEqual(distinctAttempts, expectedVersions);
  for (const call of calls.reads) {
    if (call.kind === 'query') assert.equal(call.options.timeoutMs, 5000);
  }
}

function assertNoIo(calls) {
  assert.equal(calls.version.length, 0);
  assert.equal(calls.reads.length, 0);
  assert.equal(calls.preflightBatch.length, 0);
  assert.equal(calls.batch.length, 0);
}

check('schema aliases the canonical FRAMRPC batch depth ceiling', async () => {
  assert.equal(SCHEMA_MAX_BATCH_ACTIONS, FRAMRPC_MAX_BATCH_ACTIONS);
  assert.equal(FRAMRPC_MAX_BATCH_ACTIONS, 247);
  const disconnected = framClient({ space: 'batch-limit-test', port: 1 });
  assert.throws(
    () => disconnected.batch(Array.from(
      { length: FRAMRPC_MAX_BATCH_ACTIONS + 1 },
      () => ({ op: 'assert', t1: 'subject', t2: 'predicate', t3: 'value' }),
    )),
    error => error.code === 'client/action-limit',
  );
});

check('batch preflight reports exact deterministic request metrics and is rechecked before I/O', async () => {
  const disconnected = framClient({ space: 'preflight-test', port: 1 });
  const actions = [
    { op: 'assert', t1: PAGE_A, t2: TITLE, t3: NEW_TITLE },
    { op: 'retract', t1: PAGE_B, t2: TAG, t3: WIKI_TAG },
  ];
  const preflight = disconnected.preflightBatch(actions, { expectedVersion: 7n });
  assert(Object.isFrozen(preflight));
  assert.deepEqual(
    disconnected.preflightBatch(actions, { expectedVersion: 7n }),
    preflight,
  );
  assert.equal(preflight.actionCount, actions.length);
  assert.equal(preflight.requestBytes, preflight.bodyBytes + 26);
  assert(preflight.termCount > actions.length);
  assert(preflight.maxTermDepth > 0);
  assert.equal(
    preflight.bodyBytes,
    disconnected.preflightBatch(actions).bodyBytes + 8,
  );

  await assert.rejects(
    disconnected.batch(actions, {
      expectedVersion: 7n,
      preflight: { ...preflight, termCount: preflight.termCount + 1 },
    }),
    error => error.code === 'client/preflight-mismatch',
  );
  assert.throws(
    () => disconnected.preflightBatch([{
      op: 'assert',
      t1: PAGE_A,
      t2: TITLE,
      t3: 'x'.repeat(1024 * 1024),
    }]),
    error => error.code === 'client/frame-too-large',
  );
});

check('createUnique pins its identity read and guards creation with the same expected version', async () => {
  const fram = mockFram({ versions: [7n], queryResults: [[]] });
  const schema = schemaClient(fram.client);

  await schema.createUnique({
    subject: PAGE_A,
    identity: { predicate: SLUG, value: HOME },
    fields: [
      { predicate: TITLE, value: NEW_TITLE, cardinality: 'single' },
      { predicate: TAG, value: WIKI_TAG, cardinality: 'multi' },
    ],
  });

  assertPinnedReads(fram.calls, [7n]);
  assert.equal(fram.calls.preflightBatch.length, 1);
  assert.equal(fram.calls.preflightBatch[0].options.expectedVersion, 7n);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 7n);
  assert.equal(
    fram.calls.batch[0].options.preflight,
    fram.calls.preflightBatch[0].preflight,
  );
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'assert', terms: [PAGE_A, SLUG, HOME] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
    { op: 'assert', terms: [PAGE_A, TAG, WIKI_TAG] },
  ]);
});

check('replaceSingle retracts every value from one pinned snapshot and asserts exactly once', async () => {
  const fram = mockFram({
    versions: [11n],
    scanResults: [[
      ['triple', PAGE_A, TITLE, OLD_TITLE_A],
      ['triple', PAGE_A, TITLE, OLD_TITLE_B],
    ]],
  });
  const schema = schemaClient(fram.client);

  await schema.replaceSingle(PAGE_A, TITLE, NEW_TITLE);

  assertPinnedReads(fram.calls, [11n]);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 11n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_B] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('replaceSingle preserves duplicate live occurrences across pinned pages', async () => {
  const cursor = Object.freeze([
    'triple',
    Object.freeze(['keyword', 'schema/page']),
    Object.freeze(['integer', '0']),
    Object.freeze(['integer', '11']),
  ]);
  const fram = mockFram({
    versions: [12n],
    scanResults: [
      {
        result: [['triple', PAGE_A, TITLE, OLD_TITLE_A]],
        page: { done: false, nextCursor: cursor },
      },
      {
        result: [['triple', PAGE_A, TITLE, OLD_TITLE_A]],
        page: { done: true, nextCursor: null },
      },
    ],
  });
  const schema = schemaClient(fram.client);

  await schema.replaceSingle(PAGE_A, TITLE, NEW_TITLE);

  assertPinnedReads(fram.calls, [12n]);
  assert.equal(fram.calls.scan.length, 2);
  assert.deepEqual(fram.calls.scan[0].pattern, { t1: PAGE_A, t2: TITLE });
  assert.deepEqual(fram.calls.scan[0].options, {
    page: { limit: 128 },
  });
  assert.deepEqual(fram.calls.scan[1].options, {
    page: { limit: 128, cursor },
  });
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 12n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('an initial scan/version skew retries without sending a stale batch', async () => {
  const fram = mockFram({
    versions: [70n, 71n],
    scanResults: [
      {
        servedVersion: 71n,
        result: [['triple', PAGE_A, TITLE, OLD_TITLE_A]],
        page: { done: true, nextCursor: null },
      },
      {
        servedVersion: 71n,
        result: [['triple', PAGE_A, TITLE, OLD_TITLE_B]],
        page: { done: true, nextCursor: null },
      },
    ],
  });
  const schema = schemaClient(fram.client, { maxConflictRetries: 1 });

  await schema.replaceSingle(PAGE_A, TITLE, NEW_TITLE);

  assertPinnedReads(fram.calls, [70n, 71n]);
  assert.equal(fram.calls.version.length, 2);
  assert.equal(fram.calls.scan.length, 2);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 71n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_B] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('an OCC race re-reads a fresh pinned snapshot before retrying', async () => {
  const fram = mockFram({
    versions: [20n, 21n],
    queryResults: [[], []],
    batchOutcomes: [conflict(21n), undefined],
  });
  const schema = schemaClient(fram.client, { maxConflictRetries: 1 });

  await schema.createUnique({
    subject: PAGE_A,
    identity: { predicate: SLUG, value: HOME },
    fields: [{ predicate: TITLE, value: NEW_TITLE }],
  });

  assertPinnedReads(fram.calls, [20n, 21n]);
  assert.deepEqual(
    fram.calls.batch.map(call => call.options.expectedVersion),
    [20n, 21n],
  );
});

check('createUnique rejects an identity already owned by another subject without mutation', async () => {
  const fram = mockFram({ versions: [30n], queryResults: [[[PAGE_B]]] });
  const schema = schemaClient(fram.client);

  await assert.rejects(
    schema.createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [{ predicate: TITLE, value: NEW_TITLE }],
    }),
    error => error instanceof SchemaConstraintError,
  );

  assertPinnedReads(fram.calls, [30n]);
  assert.equal(fram.calls.batch.length, 0);
});

check('upsertUnique reuses the sole identity match as the write subject', async () => {
  const fram = mockFram({ versions: [40n], queryResults: [[[PAGE_B]]] });
  const schema = schemaClient(fram.client);

  await schema.upsertUnique({
    subject: PAGE_A,
    identity: { predicate: SLUG, value: HOME },
    fields: [{ predicate: TAG, value: WIKI_TAG, cardinality: 'multi' }],
  });

  assertPinnedReads(fram.calls, [40n]);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 40n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'assert', terms: [PAGE_B, TAG, WIKI_TAG] },
  ]);
});

check('upsertUnique rejects an identity resolved to multiple subjects', async () => {
  const fram = mockFram({ versions: [41n], queryResults: [[[PAGE_B], [PAGE_C]]] });
  const schema = schemaClient(fram.client);

  await assert.rejects(
    schema.upsertUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [{ predicate: TAG, value: WIKI_TAG, cardinality: 'multi' }],
    }),
    error => error instanceof SchemaConstraintError,
  );
  assert.equal(fram.calls.batch.length, 0);
});

check('updateUnique rejects a missing or duplicate source before scanning or writing', async () => {
  const cases = [
    { owners: [], code: 'schema/identity-missing' },
    { owners: [[PAGE_A], [PAGE_B]], code: 'schema/duplicate-identity' },
  ];

  for (const [index, testCase] of cases.entries()) {
    const version = 80n + BigInt(index);
    const fram = mockFram({ versions: [version], queryResults: [testCase.owners] });
    const schema = schemaClient(fram.client);

    await assert.rejects(
      schema.updateUnique(updateInput()),
      error => error instanceof SchemaConstraintError && error.code === testCase.code,
    );
    assertPinnedReads(fram.calls, [version]);
    assert.equal(fram.calls.scan.length, 0);
    assert.equal(fram.calls.batch.length, 0);
  }
});

check('multi allowedCurrent accepts reordered sets and duplicate occurrences', async () => {
  const fram = mockFram({
    versions: [81n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[
      tripleFixture(PAGE_A, TAG, OLD_TITLE_A),
      tripleFixture(PAGE_A, TAG, OLD_TITLE_B),
      tripleFixture(PAGE_A, TAG, OLD_TITLE_A),
    ]],
  });
  await schemaClient(fram.client).updateUnique(updateInput({
    predicate: TAG,
    cardinality: 'multi',
    values: [NEW_TITLE],
    allowedCurrent: [OLD_TITLE_B, OLD_TITLE_A, OLD_TITLE_B],
  }));

  assertPinnedReads(fram.calls, [81n]);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TAG, OLD_TITLE_A] },
    { op: 'retract', terms: [PAGE_A, TAG, OLD_TITLE_B] },
    { op: 'retract', terms: [PAGE_A, TAG, OLD_TITLE_A] },
    { op: 'assert', terms: [PAGE_A, TAG, NEW_TITLE] },
  ]);
});

check('multi allowedCurrent rejects stale missing and extra values without writing', async () => {
  const cases = [
    [tripleFixture(PAGE_A, TAG, OLD_TITLE_A)],
    [
      tripleFixture(PAGE_A, TAG, OLD_TITLE_A),
      tripleFixture(PAGE_A, TAG, OLD_TITLE_B),
      tripleFixture(PAGE_A, TAG, WIKI_TAG),
    ],
  ];
  for (const [index, current] of cases.entries()) {
    const version = 82n + BigInt(index);
    const fram = mockFram({
      versions: [version],
      queryResults: [[[PAGE_A]]],
      scanResults: [current],
    });
    await assert.rejects(
      schemaClient(fram.client).updateUnique(updateInput({
        predicate: TAG,
        cardinality: 'multi',
        values: [NEW_TITLE],
        allowedCurrent: [OLD_TITLE_A, OLD_TITLE_B],
      })),
      error => error instanceof SchemaConstraintError
        && error.code === 'schema/current-value-rejected',
    );
    assertPinnedReads(fram.calls, [version]);
    assert.equal(fram.calls.batch.length, 0);
  }
});

check('multi allowedCurrent empty set accepts only an empty current cell', async () => {
  const accepted = mockFram({
    versions: [84n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[]],
  });
  await schemaClient(accepted.client).updateUnique(updateInput({
    predicate: TAG,
    cardinality: 'multi',
    values: [NEW_TITLE],
    allowedCurrent: [],
  }));
  assert.equal(accepted.calls.batch.length, 1);

  const rejected = mockFram({
    versions: [85n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[tripleFixture(PAGE_A, TAG, OLD_TITLE_A)]],
  });
  await assert.rejects(
    schemaClient(rejected.client).updateUnique(updateInput({
      predicate: TAG,
      cardinality: 'multi',
      values: [NEW_TITLE],
      allowedCurrent: [],
    })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/current-value-rejected',
  );
  assert.equal(rejected.calls.batch.length, 0);
});

check('updateUnique rejects a field predicate equal to its identity predicate before I/O', async () => {
  const fram = mockFram();
  const schema = schemaClient(fram.client);
  await assert.rejects(
    schema.updateUnique(updateInput({ predicate: SLUG })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-input',
  );
  assertNoIo(fram.calls);
});

check('updateUnique requires each exact identity to resolve solely to its required subject', async () => {
  const cases = [
    { owners: [], code: 'schema/required-identity-missing' },
    { owners: [[PAGE_C]], code: 'schema/required-identity-missing' },
    { owners: [[PAGE_B], [PAGE_C]], code: 'schema/duplicate-identity' },
  ];

  for (const [index, testCase] of cases.entries()) {
    const version = 82n + BigInt(index);
    const fram = mockFram({
      versions: [version],
      queryResults: [[[PAGE_A]], testCase.owners],
    });
    const schema = schemaClient(fram.client);

    await assert.rejects(
      schema.updateUnique(updateInput({ requireUnique: [requiredAuthor()] })),
      error => error instanceof SchemaConstraintError && error.code === testCase.code,
    );
    assertPinnedReads(fram.calls, [version]);
    assert.equal(fram.calls.scan.length, 0);
    assert.equal(fram.calls.batch.length, 0);
  }
});

check('single update accepts duplicate allowed current occurrences and replaces every occurrence at one version', async () => {
  const fram = mockFram({
    versions: [85n],
    queryResults: [[[PAGE_A]], [[PAGE_B]]],
    scanResults: [[
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_A),
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_A),
    ]],
  });
  const schema = schemaClient(fram.client);

  await schema.updateUnique(updateInput({
    allowedCurrent: [OLD_TITLE_A],
    requireUnique: [requiredAuthor()],
  }));

  assertPinnedReads(fram.calls, [85n]);
  assert.equal(fram.calls.query.length, 2);
  assert.equal(fram.calls.scan.length, 1);
  assert.equal(fram.calls.scan[0].versionAtCall, 85n);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 85n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('allowedCurrent rejects absent, different, and multiple distinct current values without writing', async () => {
  const cases = [
    [],
    [tripleFixture(PAGE_A, TITLE, OLD_TITLE_B)],
    [
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_A),
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_B),
    ],
  ];

  for (const [index, current] of cases.entries()) {
    const version = 86n + BigInt(index);
    const fram = mockFram({
      versions: [version],
      queryResults: [[[PAGE_A]]],
      scanResults: [current],
    });
    const schema = schemaClient(fram.client);

    await assert.rejects(
      schema.updateUnique(updateInput({ allowedCurrent: [OLD_TITLE_A] })),
      error => error instanceof SchemaConstraintError
        && error.code === 'schema/current-value-rejected',
    );
    assertPinnedReads(fram.calls, [version]);
    assert.equal(fram.calls.batch.length, 0);
  }
});

check('multi update supports empty replacement and deduplicates exact desired Terms', async () => {
  const removing = mockFram({
    versions: [90n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_A),
      tripleFixture(PAGE_A, TITLE, OLD_TITLE_B),
    ]],
  });
  await schemaClient(removing.client).updateUnique(updateInput({
    cardinality: 'multi',
    values: [],
  }));
  assertPinnedReads(removing.calls, [90n]);
  assert.deepEqual(semanticActions(removing.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_B] },
  ]);

  const replacing = mockFram({
    versions: [91n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[tripleFixture(PAGE_A, TITLE, OLD_TITLE_A)]],
  });
  await schemaClient(replacing.client).updateUnique(updateInput({
    cardinality: 'multi',
    values: [NEW_TITLE, NEW_TITLE, WIKI_TAG, WIKI_TAG],
  }));
  assertPinnedReads(replacing.calls, [91n]);
  assert.deepEqual(semanticActions(replacing.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
    { op: 'assert', terms: [PAGE_A, TITLE, WIKI_TAG] },
  ]);
});

check('an update OCC conflict reruns source, required identities, and current guards', async () => {
  const fram = mockFram({
    versions: [100n, 101n],
    queryResults: [
      [[PAGE_A]], [[PAGE_B]],
      [[PAGE_A]], [[PAGE_B]],
    ],
    scanResults: [
      [tripleFixture(PAGE_A, TITLE, OLD_TITLE_A)],
      [tripleFixture(PAGE_A, TITLE, OLD_TITLE_B)],
    ],
    batchOutcomes: [conflict(101n), undefined],
  });
  const schema = schemaClient(fram.client, { maxConflictRetries: 1 });

  await schema.updateUnique(updateInput({
    allowedCurrent: [OLD_TITLE_A, OLD_TITLE_B],
    requireUnique: [requiredAuthor()],
  }));

  assertPinnedReads(fram.calls, [100n, 101n]);
  assert.equal(fram.calls.query.length, 4);
  assert.equal(fram.calls.scan.length, 2);
  assert.deepEqual(fram.calls.batch.map(call => call.options.expectedVersion), [100n, 101n]);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
  assert.deepEqual(semanticActions(fram.calls.batch[1].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_B] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('an update scan skew reruns every guard and never submits the stale attempt', async () => {
  const fram = mockFram({
    versions: [110n, 111n],
    queryResults: [
      [[PAGE_A]], [[PAGE_B]],
      [[PAGE_A]], [[PAGE_B]],
    ],
    scanResults: [
      {
        servedVersion: 111n,
        result: [tripleFixture(PAGE_A, TITLE, OLD_TITLE_A)],
        page: { done: true, nextCursor: null },
      },
      [tripleFixture(PAGE_A, TITLE, OLD_TITLE_B)],
    ],
  });
  const schema = schemaClient(fram.client, { maxConflictRetries: 1 });

  await schema.updateUnique(updateInput({
    allowedCurrent: [OLD_TITLE_A, OLD_TITLE_B],
    requireUnique: [requiredAuthor()],
  }));

  assertPinnedReads(fram.calls, [110n, 111n]);
  assert.equal(fram.calls.query.length, 4);
  assert.equal(fram.calls.scan.length, 2);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 111n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_B] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('updateUniqueMany replaces multiple fields and subjects in one pinned batch', async () => {
  const fram = mockFram({
    versions: [140n],
    queryResults: [[[REVISION_A]], [[PAGE_A]], [[PAGE_B]]],
    scanResults: [
      [tripleFixture(REVISION_A, REVISION_STATUS, DRAFT)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      [],
    ],
  });
  const result = await schemaClient(fram.client).updateUniqueMany(publicationInput({
    requireUnique: [requiredAuthor()],
  }));

  assertPinnedReads(fram.calls, [140n]);
  assert.deepEqual(result.subjects, [REVISION_A, PAGE_A]);
  assert.equal(result.changed, true);
  assert.equal(result.servedVersion, 141n);
  assert.equal(fram.calls.query.length, 3);
  assert.equal(fram.calls.scan.length, 3);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 140n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [REVISION_A, REVISION_STATUS, DRAFT] },
    { op: 'assert', terms: [REVISION_A, REVISION_STATUS, CANONICAL] },
    { op: 'assert', terms: [PAGE_A, CANONICAL_REVISION, REVISION_A] },
  ]);
});

check('an exact single replacement is a no-op but duplicate occurrences still collapse', async () => {
  const exact = mockFram({
    versions: [141n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[tripleFixture(PAGE_A, TITLE, NEW_TITLE)]],
  });
  const unchanged = await schemaClient(exact.client).updateUnique(updateInput({
    allowedCurrent: [NEW_TITLE],
  }));
  assert.deepEqual(unchanged, {
    subject: PAGE_A,
    created: false,
    changed: false,
    servedVersion: 141n,
    result: [],
  });
  assert.equal(exact.calls.batch.length, 0);

  const duplicates = mockFram({
    versions: [142n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[
      tripleFixture(PAGE_A, TITLE, NEW_TITLE),
      tripleFixture(PAGE_A, TITLE, NEW_TITLE),
    ]],
  });
  await schemaClient(duplicates.client).updateUnique(updateInput({
    allowedCurrent: [NEW_TITLE],
  }));
  assert.deepEqual(semanticActions(duplicates.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TITLE, NEW_TITLE] },
    { op: 'retract', terms: [PAGE_A, TITLE, NEW_TITLE] },
    { op: 'assert', terms: [PAGE_A, TITLE, NEW_TITLE] },
  ]);
});

check('empty allowedCurrent is an absence CAS and one failed cell prevents the whole command', async () => {
  const fram = mockFram({
    versions: [143n],
    queryResults: [[[REVISION_A]], [[PAGE_A]]],
    scanResults: [
      [tripleFixture(REVISION_A, REVISION_STATUS, DRAFT)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      [tripleFixture(PAGE_A, CANONICAL_REVISION, PAGE_B)],
    ],
  });

  await assert.rejects(
    schemaClient(fram.client).updateUniqueMany(publicationInput()),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/current-value-rejected'
      && error.detail.allowed.length === 0,
  );
  assert.equal(fram.calls.scan.length, 3);
  assert.equal(fram.calls.batch.length, 0);
});

check('updateUniqueMany rejects duplicate resolved cells and cross-alias identity writes', async () => {
  const duplicate = mockFram({
    versions: [144n],
    queryResults: [[[PAGE_A]], [[PAGE_A]]],
  });
  await assert.rejects(
    schemaClient(duplicate.client).updateUniqueMany({
      updates: [
        {
          identity: { predicate: SLUG, value: HOME },
          fields: [{ predicate: TITLE, values: [NEW_TITLE], cardinality: 'single' }],
        },
        {
          identity: { predicate: AUTHOR_EMAIL, value: ALICE_EMAIL },
          fields: [{ predicate: TITLE, values: [OLD_TITLE_A], cardinality: 'single' }],
        },
      ],
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/duplicate-update-target',
  );
  assert.equal(duplicate.calls.scan.length, 0);
  assert.equal(duplicate.calls.batch.length, 0);

  const identityWrite = mockFram({
    versions: [145n],
    queryResults: [[[PAGE_A]], [[PAGE_A]]],
  });
  await assert.rejects(
    schemaClient(identityWrite.client).updateUniqueMany({
      updates: [
        {
          identity: { predicate: SLUG, value: HOME },
          fields: [{
            predicate: AUTHOR_EMAIL,
            values: [ALICE_EMAIL],
            cardinality: 'single',
          }],
        },
        {
          identity: { predicate: AUTHOR_EMAIL, value: ALICE_EMAIL },
          fields: [{ predicate: TAG, values: [WIKI_TAG], cardinality: 'multi' }],
        },
      ],
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-input',
  );
  assert.equal(identityWrite.calls.scan.length, 0);
  assert.equal(identityWrite.calls.batch.length, 0);
});

check('a later multi-update scan skew replans every source and field', async () => {
  const fram = mockFram({
    versions: [150n, 151n],
    queryResults: [
      [[REVISION_A]], [[PAGE_A]],
      [[REVISION_A]], [[PAGE_A]],
    ],
    scanResults: [
      [tripleFixture(REVISION_A, REVISION_STATUS, DRAFT)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      { servedVersion: 151n, result: [], page: { done: true, nextCursor: null } },
      [tripleFixture(REVISION_A, REVISION_STATUS, DRAFT)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      [],
    ],
  });
  await schemaClient(fram.client, { maxConflictRetries: 1 })
    .updateUniqueMany(publicationInput());

  assert.deepEqual(fram.calls.query.map(call => call.options.asOf), [150n, 150n, 151n, 151n]);
  assert.equal(fram.calls.scan.length, 6);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 151n);
});

check('a multi-update conflict rereads and rebuilds the whole command', async () => {
  const fram = mockFram({
    versions: [152n, 153n],
    queryResults: [
      [[REVISION_A]], [[PAGE_A]],
      [[REVISION_A]], [[PAGE_A]],
    ],
    scanResults: [
      [tripleFixture(REVISION_A, REVISION_STATUS, DRAFT)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      [],
      [tripleFixture(REVISION_A, REVISION_STATUS, CANONICAL)],
      [tripleFixture(REVISION_A, REVISION_BODY, REVISION_TEXT)],
      [],
    ],
    batchOutcomes: [conflict(153n), undefined],
  });
  await schemaClient(fram.client, { maxConflictRetries: 1 })
    .updateUniqueMany(publicationInput({ statusAllowed: [DRAFT, CANONICAL] }));

  assert.deepEqual(fram.calls.batch.map(call => call.options.expectedVersion), [152n, 153n]);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions).slice(0, 2), [
    { op: 'retract', terms: [REVISION_A, REVISION_STATUS, DRAFT] },
    { op: 'assert', terms: [REVISION_A, REVISION_STATUS, CANONICAL] },
  ]);
  assert.deepEqual(semanticActions(fram.calls.batch[1].actions), [
    { op: 'assert', terms: [PAGE_A, CANONICAL_REVISION, REVISION_A] },
  ]);
});

check('updateUniqueMany enforces the aggregate 247-action boundary without splitting', async () => {
  const current = (subject, predicate, count) => Array.from(
    { length: count },
    (_, index) => tripleFixture(subject, predicate, ['integer', String(index)]),
  );
  const input = {
    updates: [
      {
        identity: { predicate: SLUG, value: HOME },
        fields: [{ predicate: TITLE, values: [], cardinality: 'multi' }],
      },
      {
        identity: { predicate: REVISION_ID, value: REV_1 },
        fields: [{ predicate: REVISION_STATUS, values: [], cardinality: 'multi' }],
      },
    ],
  };

  const exact = mockFram({
    versions: [154n],
    queryResults: [[[PAGE_A]], [[REVISION_A]]],
    scanResults: [current(PAGE_A, TITLE, 123), current(REVISION_A, REVISION_STATUS, 124)],
  });
  await schemaClient(exact.client).updateUniqueMany(input);
  assert.equal(exact.calls.batch.length, 1);
  assert.equal(exact.calls.batch[0].actions.length, SCHEMA_MAX_BATCH_ACTIONS);

  const overflow = mockFram({
    versions: [155n],
    queryResults: [[[PAGE_A]], [[REVISION_A]]],
    scanResults: [current(PAGE_A, TITLE, 124), current(REVISION_A, REVISION_STATUS, 124)],
  });
  await assert.rejects(
    schemaClient(overflow.client).updateUniqueMany(input),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/action-limit'
      && error.detail.actions === SCHEMA_MAX_BATCH_ACTIONS + 1,
  );
  assert.equal(overflow.calls.batch.length, 0);
});

check('updateUniqueMany validates structure before I/O and skips an empty action plan', async () => {
  for (const input of [
    { updates: [] },
    { updates: [{ identity: { predicate: SLUG, value: HOME }, fields: [] }] },
    {
      updates: [{
        identity: { predicate: SLUG, value: HOME },
        fields: [
          { predicate: TITLE, values: [NEW_TITLE], cardinality: 'single' },
          { predicate: TITLE, values: [OLD_TITLE_A], cardinality: 'single' },
        ],
      }],
    },
  ]) {
    const invalid = mockFram();
    await assert.rejects(
      schemaClient(invalid.client).updateUniqueMany(input),
      error => error instanceof SchemaConstraintError,
    );
    assertNoIo(invalid.calls);
  }

  const empty = mockFram({
    versions: [156n],
    queryResults: [[[PAGE_A]], [[REVISION_A]]],
    scanResults: [[], []],
  });
  const result = await schemaClient(empty.client).updateUniqueMany({
    updates: [
      {
        identity: { predicate: SLUG, value: HOME },
        fields: [{ predicate: TAG, values: [], cardinality: 'multi' }],
      },
      {
        identity: { predicate: REVISION_ID, value: REV_1 },
        fields: [{ predicate: REVISION_STATUS, values: [], cardinality: 'multi' }],
      },
    ],
  });
  assert.deepEqual(result, {
    subjects: [PAGE_A, REVISION_A],
    changed: false,
    servedVersion: 156n,
    result: [],
  });
  assert.equal(empty.calls.batch.length, 0);
});

check('createUnique checks required identities at the same version as creation', async () => {
  const fram = mockFram({
    versions: [120n],
    queryResults: [[], [[PAGE_B]]],
  });
  const schema = schemaClient(fram.client);

  await schema.createUnique({
    subject: PAGE_A,
    identity: { predicate: SLUG, value: HOME },
    fields: [{ predicate: TITLE, value: NEW_TITLE }],
    requireUnique: [requiredAuthor()],
  });

  assertPinnedReads(fram.calls, [120n]);
  assert.equal(fram.calls.query.length, 2);
  assert.equal(fram.calls.scan.length, 0);
  assert.equal(fram.calls.batch.length, 1);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 120n);
});

check('createUnique rejects more than 247 batch actions before mutation', async () => {
  const fields = Array.from({ length: 247 }, (_, index) => ({
    predicate: Object.freeze(['keyword', `field/${index}`]),
    value: Object.freeze(['integer', String(index)]),
    cardinality: 'multi',
  }));
  const fram = mockFram({ versions: [50n], queryResults: [[]] });
  const schema = schemaClient(fram.client);

  await assert.rejects(
    schema.createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields,
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/action-limit',
  );
  assertNoIo(fram.calls);
});

check('upsertUnique rejects an oversized desired field list before I/O', async () => {
  const fields = Array.from({ length: SCHEMA_MAX_BATCH_ACTIONS }, (_, index) => ({
    predicate: Object.freeze(['keyword', `upsert-field/${index}`]),
    value: Object.freeze(['integer', String(index)]),
    cardinality: 'multi',
  }));
  const fram = mockFram();

  await assert.rejects(
    schemaClient(fram.client).upsertUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields,
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/action-limit'
      && error.detail.actions === SCHEMA_MAX_BATCH_ACTIONS + 1,
  );
  assertNoIo(fram.calls);
});

check('updateUnique rejects an oversized desired value list before I/O', async () => {
  const values = Array.from(
    { length: SCHEMA_MAX_BATCH_ACTIONS + 1 },
    (_, index) => Object.freeze(['integer', String(index)]),
  );
  const fram = mockFram();

  await assert.rejects(
    schemaClient(fram.client).updateUnique(updateInput({
      cardinality: 'multi',
      values,
    })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/action-limit'
      && error.detail.actions === SCHEMA_MAX_BATCH_ACTIONS + 1,
  );
  assertNoIo(fram.calls);
});

check('updateUnique rejects an oversized allowedCurrent guard before I/O', async () => {
  const allowedCurrent = Array.from(
    { length: SCHEMA_MAX_BATCH_ACTIONS + 1 },
    (_, index) => Object.freeze(['integer', String(index)]),
  );
  const fram = mockFram();

  await assert.rejects(
    schemaClient(fram.client).updateUnique(updateInput({ allowedCurrent })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-input'
      && error.detail.entries === SCHEMA_MAX_BATCH_ACTIONS + 1,
  );
  assertNoIo(fram.calls);
});

check('schema mutations reject an oversized requireUnique list before I/O', async () => {
  const requireUnique = Array.from(
    { length: SCHEMA_MAX_REQUIRE_UNIQUE + 1 },
    () => requiredAuthor(),
  );
  const fram = mockFram();

  await assert.rejects(
    schemaClient(fram.client).createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [],
      requireUnique,
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-input'
      && error.detail.entries === SCHEMA_MAX_REQUIRE_UNIQUE + 1,
  );
  assertNoIo(fram.calls);
});

check('requireUnique resolution keeps query concurrency bounded', async () => {
  const version = 130n;
  const requireUnique = Array.from(
    { length: SCHEMA_MAX_GUARD_CONCURRENCY * 2 + 1 },
    () => requiredAuthor(),
  );
  let activeGuards = 0;
  let maximumActiveGuards = 0;
  let guardCalls = 0;
  let releaseGuards;
  let signalFirstWave;
  const guardGate = new Promise(resolve => { releaseGuards = resolve; });
  const firstWave = new Promise(resolve => { signalFirstWave = resolve; });
  const calls = { version: 0, query: 0, scan: 0, batch: 0 };
  const fram = {
    async version() {
      calls.version += 1;
      return { servedVersion: version };
    },
    async query(query, options) {
      calls.query += 1;
      const predicate = query.rules[0].body[0].args[1];
      if (sameTermFixture(predicate, SLUG)) {
        return { servedVersion: options.asOf, result: [] };
      }
      activeGuards += 1;
      guardCalls += 1;
      maximumActiveGuards = Math.max(maximumActiveGuards, activeGuards);
      if (activeGuards === SCHEMA_MAX_GUARD_CONCURRENCY) signalFirstWave();
      await guardGate;
      activeGuards -= 1;
      return { servedVersion: options.asOf, result: [[PAGE_B]] };
    },
    async scan() {
      calls.scan += 1;
      throw new Error('unexpected scan');
    },
    preflightBatch(actions) {
      return {
        actionCount: actions.length,
        requestBytes: 100 + actions.length,
        bodyBytes: 74 + actions.length,
        termCount: actions.length * 10,
        maxTermDepth: 8,
      };
    },
    async batch(actions, options) {
      calls.batch += 1;
      return {
        servedVersion: options.expectedVersion + 1n,
        result: mutationResultsFixture(actions, options.expectedVersion + 1n),
      };
    },
  };

  const mutation = schemaClient(fram).createUnique({
    subject: PAGE_A,
    identity: { predicate: SLUG, value: HOME },
    fields: [],
    requireUnique,
  });
  await firstWave;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(maximumActiveGuards, SCHEMA_MAX_GUARD_CONCURRENCY);
  assert.equal(guardCalls, SCHEMA_MAX_GUARD_CONCURRENCY);
  releaseGuards();
  await mutation;

  assert.equal(maximumActiveGuards, SCHEMA_MAX_GUARD_CONCURRENCY);
  assert.equal(guardCalls, requireUnique.length);
  assert.deepEqual(calls, {
    version: 1,
    query: requireUnique.length + 1,
    scan: 0,
    batch: 1,
  });
});

check('upsertUnique keeps single-field scan concurrency bounded', async () => {
  const version = 131n;
  const fields = Array.from(
    { length: SCHEMA_MAX_GUARD_CONCURRENCY * 2 + 1 },
    (_, index) => ({
      predicate: Object.freeze(['keyword', `bounded-field/${index}`]),
      value: Object.freeze(['integer', String(index)]),
      cardinality: 'single',
    }),
  );
  let activeScans = 0;
  let maximumActiveScans = 0;
  let scanCalls = 0;
  let releaseScans;
  let signalFirstWave;
  const scanGate = new Promise(resolve => { releaseScans = resolve; });
  const firstWave = new Promise(resolve => { signalFirstWave = resolve; });
  const calls = { version: 0, query: 0, batch: 0 };
  const fram = {
    async version() {
      calls.version += 1;
      return { servedVersion: version };
    },
    async query(query, options) {
      calls.query += 1;
      return { servedVersion: options.asOf, result: [[PAGE_A]] };
    },
    async scan() {
      activeScans += 1;
      scanCalls += 1;
      maximumActiveScans = Math.max(maximumActiveScans, activeScans);
      if (activeScans === SCHEMA_MAX_GUARD_CONCURRENCY) signalFirstWave();
      await scanGate;
      activeScans -= 1;
      return { servedVersion: version, result: [] };
    },
    preflightBatch(actions) {
      return {
        actionCount: actions.length,
        requestBytes: 100 + actions.length,
        bodyBytes: 74 + actions.length,
        termCount: actions.length * 10,
        maxTermDepth: 8,
      };
    },
    async batch(actions, options) {
      calls.batch += 1;
      return {
        servedVersion: options.expectedVersion + 1n,
        result: mutationResultsFixture(actions, options.expectedVersion + 1n),
      };
    },
  };

  const mutation = schemaClient(fram).upsertUnique({
    subject: PAGE_B,
    identity: { predicate: SLUG, value: HOME },
    fields,
  });
  await firstWave;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(maximumActiveScans, SCHEMA_MAX_GUARD_CONCURRENCY);
  assert.equal(scanCalls, SCHEMA_MAX_GUARD_CONCURRENCY);
  releaseScans();
  await mutation;

  assert.equal(maximumActiveScans, SCHEMA_MAX_GUARD_CONCURRENCY);
  assert.equal(scanCalls, fields.length);
  assert.deepEqual(calls, { version: 1, query: 1, batch: 1 });
});

check('schema reads reject repeated cursors and pages beyond their ceiling', async () => {
  const cursorA = Object.freeze(['keyword', 'schema/cursor-a']);
  const cursorB = Object.freeze(['keyword', 'schema/cursor-b']);
  const repeated = mockFram({
    versions: [160n],
    queryResults: [
      { result: [], page: { done: false, nextCursor: cursorA } },
      { result: [], page: { done: false, nextCursor: cursorA } },
    ],
  });
  await assert.rejects(
    schemaClient(repeated.client).createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [],
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-response',
  );
  assert.equal(repeated.calls.query.length, SCHEMA_MAX_READ_PAGES);
  assert.equal(repeated.calls.batch.length, 0);

  const overPages = mockFram({
    versions: [161n],
    queryResults: [[[PAGE_A]]],
    scanResults: [
      { result: [], page: { done: false, nextCursor: cursorA } },
      { result: [], page: { done: false, nextCursor: cursorB } },
    ],
  });
  await assert.rejects(
    schemaClient(overPages.client).updateUnique(updateInput({
      predicate: TAG,
      values: [],
      cardinality: 'multi',
    })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/invalid-response',
  );
  assert.equal(overPages.calls.scan.length, SCHEMA_MAX_READ_PAGES);
  assert.equal(overPages.calls.batch.length, 0);
});

check('two scan pages can expose the 248th occurrence action-limit sentinel', async () => {
  const cursor = Object.freeze(['keyword', 'schema/cursor-overflow']);
  const occurrence = tripleFixture(PAGE_A, TAG, WIKI_TAG);
  const fram = mockFram({
    versions: [162n],
    queryResults: [[[PAGE_A]]],
    scanResults: [
      {
        result: Array.from({ length: 128 }, () => occurrence),
        page: { done: false, nextCursor: cursor },
      },
      {
        result: Array.from({ length: 120 }, () => occurrence),
        page: { done: true, nextCursor: null },
      },
    ],
  });
  await assert.rejects(
    schemaClient(fram.client).updateUnique(updateInput({
      predicate: TAG,
      values: [],
      cardinality: 'multi',
    })),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/action-limit'
      && error.detail.actions === SCHEMA_MAX_BATCH_ACTIONS + 1,
  );
  assert.equal(fram.calls.scan.length, SCHEMA_MAX_READ_PAGES);
  assert.equal(fram.calls.batch.length, 0);
});

check('transactUnique creates a mutually-referencing set with planned uniqueness guards', async () => {
  const alpha = Object.freeze(['string', 'alpha']);
  const beta = Object.freeze(['string', 'beta']);
  const gamma = Object.freeze(['string', 'gamma']);
  const fram = mockFram({
    versions: [170n],
    queryResults: [[], [], []],
  });
  const result = await schemaClient(fram.client).transactUnique({
    creates: [
      {
        subject: PAGE_A,
        identity: { predicate: SLUG, value: alpha },
        fields: [{ predicate: TAG, value: PAGE_B }],
      },
      {
        subject: PAGE_B,
        identity: { predicate: SLUG, value: beta },
        fields: [{ predicate: TAG, value: PAGE_C }],
      },
      {
        subject: PAGE_C,
        identity: { predicate: SLUG, value: gamma },
        fields: [{ predicate: TAG, value: PAGE_A }],
      },
    ],
    requireUnique: [
      { subject: PAGE_A, predicate: SLUG, value: alpha },
      { subject: PAGE_B, predicate: SLUG, value: beta },
      { subject: PAGE_C, predicate: SLUG, value: gamma },
    ],
  });

  assert.deepEqual(result.createdSubjects, [PAGE_A, PAGE_B, PAGE_C]);
  assert.deepEqual(result.updatedSubjects, []);
  assert.equal(result.changed, true);
  assert.equal(result.servedVersion, 171n);
  assert.equal(fram.calls.query.length, 3);
  assert.equal(fram.calls.scan.length, 0);
  assert.equal(fram.calls.preflightBatch.length, 1);
  assert.equal(result.preflight, fram.calls.preflightBatch[0].preflight);
  assert.equal(fram.calls.batch[0].options.preflight, result.preflight);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'assert', terms: [PAGE_A, SLUG, alpha] },
    { op: 'assert', terms: [PAGE_A, TAG, PAGE_B] },
    { op: 'assert', terms: [PAGE_B, SLUG, beta] },
    { op: 'assert', terms: [PAGE_B, TAG, PAGE_C] },
    { op: 'assert', terms: [PAGE_C, SLUG, gamma] },
    { op: 'assert', terms: [PAGE_C, TAG, PAGE_A] },
  ]);
});

check('transactUnique mixes create and update while zero desired single values clear the cell', async () => {
  const child = Object.freeze(['string', 'child']);
  const fram = mockFram({
    versions: [171n],
    queryResults: [[], [[PAGE_A]]],
    scanResults: [[tripleFixture(PAGE_A, TITLE, OLD_TITLE_A)]],
  });
  const result = await schemaClient(fram.client).transactUnique({
    creates: [{
      subject: PAGE_C,
      identity: { predicate: SLUG, value: child },
      fields: [{ predicate: TAG, value: PAGE_A }],
    }],
    updates: [{
      identity: { predicate: SLUG, value: HOME },
      fields: [{
        predicate: TITLE,
        values: [],
        cardinality: 'single',
        allowedCurrent: [OLD_TITLE_A],
      }],
    }],
    requireUnique: [{ subject: PAGE_C, predicate: SLUG, value: child }],
  });

  assert.deepEqual(result.createdSubjects, [PAGE_C]);
  assert.deepEqual(result.updatedSubjects, [PAGE_A]);
  assert.equal(result.preflight.actionCount, 3);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'assert', terms: [PAGE_C, SLUG, child] },
    { op: 'assert', terms: [PAGE_C, TAG, PAGE_A] },
    { op: 'retract', terms: [PAGE_A, TITLE, OLD_TITLE_A] },
  ]);
});

check('transactUnique composes an exact multi-set guard with required Ref identities', async () => {
  const fram = mockFram({
    versions: [172n],
    queryResults: [[[PAGE_A]], [[PAGE_B]], [[PAGE_C]]],
    scanResults: [[
      tripleFixture(PAGE_A, TAG, PAGE_C),
      tripleFixture(PAGE_A, TAG, PAGE_B),
    ]],
  });
  const result = await schemaClient(fram.client).transactUnique({
    updates: [{
      identity: { predicate: SLUG, value: HOME },
      fields: [{
        predicate: TAG,
        values: [PAGE_B],
        cardinality: 'multi',
        allowedCurrent: [PAGE_B, PAGE_C],
      }],
    }],
    requireUnique: [
      { subject: PAGE_B, predicate: AUTHOR_EMAIL, value: ALICE_EMAIL },
      { subject: PAGE_C, predicate: REVISION_ID, value: REV_1 },
    ],
  });

  assert.deepEqual(result.updatedSubjects, [PAGE_A]);
  assertPinnedReads(fram.calls, [172n]);
  assert.equal(fram.calls.batch[0].options.expectedVersion, 172n);
  assert.deepEqual(semanticActions(fram.calls.batch[0].actions), [
    { op: 'retract', terms: [PAGE_A, TAG, PAGE_C] },
    { op: 'retract', terms: [PAGE_A, TAG, PAGE_B] },
    { op: 'assert', terms: [PAGE_A, TAG, PAGE_B] },
  ]);
});

check('transactUnique multi-set or target identity failure has zero partial effects', async () => {
  const staleSet = mockFram({
    versions: [173n],
    queryResults: [[[PAGE_A]], [[PAGE_B]]],
    scanResults: [[tripleFixture(PAGE_A, TAG, PAGE_B)]],
  });
  await assert.rejects(
    schemaClient(staleSet.client).transactUnique({
      updates: [{
        identity: { predicate: SLUG, value: HOME },
        fields: [{
          predicate: TAG,
          values: [PAGE_B],
          cardinality: 'multi',
          allowedCurrent: [PAGE_B, PAGE_C],
        }],
      }],
      requireUnique: [requiredAuthor()],
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/current-value-rejected',
  );
  assert.equal(staleSet.calls.batch.length, 0);

  const missingTarget = mockFram({
    versions: [174n],
    queryResults: [[[PAGE_A]], []],
  });
  await assert.rejects(
    schemaClient(missingTarget.client).transactUnique({
      updates: [{
        identity: { predicate: SLUG, value: HOME },
        fields: [{
          predicate: TAG,
          values: [PAGE_B],
          cardinality: 'multi',
          allowedCurrent: [],
        }],
      }],
      requireUnique: [requiredAuthor()],
    }),
    error => error instanceof SchemaConstraintError
      && error.code === 'schema/required-identity-missing',
  );
  assert.equal(missingTarget.calls.scan.length, 0);
  assert.equal(missingTarget.calls.batch.length, 0);
});

check('an already-empty single clear is an update-only transaction no-op', async () => {
  const fram = mockFram({
    versions: [172n],
    queryResults: [[[PAGE_A]]],
    scanResults: [[]],
  });
  const result = await schemaClient(fram.client).transactUnique({
    updates: [{
      identity: { predicate: SLUG, value: HOME },
      fields: [{
        predicate: TITLE,
        values: [],
        cardinality: 'single',
        allowedCurrent: [],
      }],
    }],
  });
  assert.deepEqual(result, {
    createdSubjects: [],
    updatedSubjects: [PAGE_A],
    changed: false,
    servedVersion: 172n,
    result: [],
    preflight: null,
  });
  assert.equal(fram.calls.preflightBatch.length, 0);
  assert.equal(fram.calls.batch.length, 0);
});

check('transactUnique rejects duplicate planned identities and subjects before I/O', async () => {
  const duplicateIdentity = mockFram();
  await assert.rejects(
    schemaClient(duplicateIdentity.client).transactUnique({
      creates: [
        { subject: PAGE_A, identity: { predicate: SLUG, value: HOME }, fields: [] },
        { subject: PAGE_B, identity: { predicate: SLUG, value: HOME }, fields: [] },
      ],
    }),
    error => error.code === 'schema/duplicate-identity',
  );
  assertNoIo(duplicateIdentity.calls);

  const duplicateSubject = mockFram();
  await assert.rejects(
    schemaClient(duplicateSubject.client).transactUnique({
      creates: [
        { subject: PAGE_A, identity: { predicate: SLUG, value: HOME }, fields: [] },
        { subject: PAGE_A, identity: { predicate: REVISION_ID, value: REV_1 }, fields: [] },
      ],
    }),
    error => error.code === 'schema/duplicate-create-subject',
  );
  assertNoIo(duplicateSubject.calls);

  const fieldCollision = mockFram();
  await assert.rejects(
    schemaClient(fieldCollision.client).transactUnique({
      creates: [
        { subject: PAGE_A, identity: { predicate: SLUG, value: HOME }, fields: [] },
        {
          subject: PAGE_B,
          identity: { predicate: REVISION_ID, value: REV_1 },
          fields: [{ predicate: SLUG, value: HOME }],
        },
      ],
    }),
    error => error.code === 'schema/duplicate-identity',
  );
  assertNoIo(fieldCollision.calls);

  const updateCollision = mockFram();
  await assert.rejects(
    schemaClient(updateCollision.client).transactUnique({
      creates: [{
        subject: PAGE_A,
        identity: { predicate: SLUG, value: HOME },
        fields: [],
      }],
      updates: [{
        identity: { predicate: REVISION_ID, value: REV_1 },
        fields: [{ predicate: SLUG, values: [HOME], cardinality: 'multi' }],
      }],
    }),
    error => error.code === 'schema/duplicate-identity',
  );
  assertNoIo(updateCollision.calls);

  const resolvedCellCollision = mockFram({
    versions: [173n],
    queryResults: [[], [[PAGE_A]]],
  });
  await assert.rejects(
    schemaClient(resolvedCellCollision.client).transactUnique({
      creates: [{
        subject: PAGE_A,
        identity: { predicate: REVISION_ID, value: REV_1 },
        fields: [{ predicate: TITLE, value: NEW_TITLE }],
      }],
      updates: [{
        identity: { predicate: SLUG, value: HOME },
        fields: [{
          predicate: TITLE,
          values: [OLD_TITLE_A],
          cardinality: 'single',
        }],
      }],
    }),
    error => error.code === 'schema/duplicate-update-target',
  );
  assert.equal(resolvedCellCollision.calls.version.length, 1);
  assert.equal(resolvedCellCollision.calls.query.length, 2);
  assert.equal(resolvedCellCollision.calls.scan.length, 0);
  assert.equal(resolvedCellCollision.calls.preflightBatch.length, 0);
  assert.equal(resolvedCellCollision.calls.batch.length, 0);

  const mismatchedGuard = mockFram();
  await assert.rejects(
    schemaClient(mismatchedGuard.client).transactUnique({
      creates: [{
        subject: PAGE_A,
        identity: { predicate: SLUG, value: HOME },
        fields: [],
      }],
      requireUnique: [{ subject: PAGE_B, predicate: SLUG, value: HOME }],
    }),
    error => error.code === 'schema/required-identity-missing',
  );
  assertNoIo(mismatchedGuard.calls);
});

check('a planned idempotency reservation is re-resolved after conflict before any second write', async () => {
  const requestId = Object.freeze(['string', 'request-1']);
  const requestIdentity = Object.freeze(['keyword', 'request/id']);
  const fram = mockFram({
    versions: [180n, 181n],
    queryResults: [[], [], [[PAGE_C]], []],
    batchOutcomes: [conflict(180n)],
  });
  await assert.rejects(
    schemaClient(fram.client).transactUnique({
      creates: [
        {
          subject: PAGE_C,
          identity: { predicate: requestIdentity, value: requestId },
          fields: [],
        },
        {
          subject: PAGE_A,
          identity: { predicate: SLUG, value: HOME },
          fields: [],
        },
      ],
    }),
    error => error.code === 'schema/identity-exists'
      && sameTermFixture(error.detail.identity.predicate, requestIdentity),
  );
  assert.equal(fram.calls.version.length, 2);
  assert.equal(fram.calls.query.length, 4);
  assert.equal(fram.calls.preflightBatch.length, 1);
  assert.equal(fram.calls.batch.length, 1);
});

check('transport ambiguity is never retried and conflict exhaustion remains typed', async () => {
  const ambiguity = new FramTransportError('connection ended after write');
  const ambiguous = mockFram({
    versions: [190n],
    queryResults: [[]],
    batchOutcomes: [ambiguity],
  });
  await assert.rejects(
    schemaClient(ambiguous.client).createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [],
    }),
    error => error === ambiguity,
  );
  assert.equal(ambiguous.calls.version.length, 1);
  assert.equal(ambiguous.calls.batch.length, 1);

  const exhausted = mockFram({
    versions: [191n, 192n],
    queryResults: [[], []],
    batchOutcomes: [conflict(191n), conflict(192n)],
  });
  await assert.rejects(
    schemaClient(exhausted.client, { maxConflictRetries: 1 }).createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [],
    }),
    error => error.code === 'schema/conflict-exhausted'
      && error.detail.attempts === 2
      && error.detail.reason === 'rpc/conflict',
  );
  assert.equal(exhausted.calls.preflightBatch.length, 2);
  assert.equal(exhausted.calls.batch.length, 2);
});

check('non-conflict write errors propagate unchanged and are not retried', async () => {
  const failure = rpcError('rpc/unavailable', 60n, {
    retryable: true,
    message: 'server unavailable',
  });
  const fram = mockFram({
    versions: [60n],
    queryResults: [[]],
    batchOutcomes: [failure],
  });
  const schema = schemaClient(fram.client, { maxConflictRetries: 4 });

  await assert.rejects(
    schema.createUnique({
      subject: PAGE_A,
      identity: { predicate: SLUG, value: HOME },
      fields: [{ predicate: TITLE, value: NEW_TITLE }],
    }),
    error => error === failure,
  );
  assert.equal(fram.calls.version.length, 1);
  assert.equal(fram.calls.batch.length, 1);
});
