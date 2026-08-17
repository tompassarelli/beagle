import { test } from 'bun:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import {
  FRAMRPC_MAX_BATCH_ACTIONS,
  FRAMRPC_VERSION,
  FramRpcError,
  float64Term,
  float64Value,
  framClient,
  framNativeCheckpoint,
  instantTerm,
  integerTerm,
  keywordTerm,
  lowerQueryPlan,
  stringTerm,
  tripleQuery,
  tripleTerm,
} from '../clients/bun/framrpc.mjs';
import {
  SCHEMA_MAX_BATCH_ACTIONS,
  schemaClient,
} from '../clients/bun/schema.mjs';

const root = resolve(import.meta.dir, '..');
const checks = [];
const I64_MIN = -(1n << 63n);
const expectedEngine = Bun.env.FRAM_EXPECTED_ENGINE ?? 'rpc/jvm';

async function check(label, body) {
  await body();
  checks.push(label);
  console.log(`  [PASS] ${label}`);
}

function assertOccurrenceCoordinate(value, sequence, ordinal) {
  assert.equal(value[0], 'triple');
  assert.equal(value[1][0], 'triple');
  assert.deepEqual(value[1][2], keywordTerm('kernel/tx-sequence'));
  assert.deepEqual(value[1][3], integerTerm(sequence));
  assert.deepEqual(value[2], keywordTerm('kernel/op-ordinal'));
  assert.deepEqual(value[3], integerTerm(ordinal));
}

async function freePort() {
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch() {
      return new Response(null, { status: 204 });
    },
  });
  const port = server.port;
  await server.stop(true);
  return port;
}

async function startServer(port, log, space) {
  let output = '';
  let ready = false;
  let timer;
  let resolveReady;
  let rejectReady;
  const startup = new Promise((resolveStartup, rejectStartup) => {
    resolveReady = resolveStartup;
    rejectReady = rejectStartup;
  });
  const child = Bun.spawn([
    resolve(root, 'bin/fram-server'),
    'serve',
    String(port),
    log,
    space,
  ], {
    cwd: root,
    env: {
      ...Bun.env,
      FRAM_SERVER_RUNTIME: Bun.env.FRAM_SERVER_RUNTIME ?? 'jvm-dev',
      FRAM_SPACE_ID: space,
      FRAM_GRAPH_OPS_LOG: 'off',
      FRAM_SERVER_QUIET: '1',
    },
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    onExit(_subprocess, exitCode, signalCode, error) {
      if (!ready) {
        clearTimeout(timer);
        rejectReady(new Error(
          `server exited during startup (${exitCode ?? signalCode})\n${output}`,
          { cause: error },
        ));
      }
    },
  });

  const consume = async stream => {
    const decoder = new TextDecoder();
    try {
      for await (const chunk of stream) {
        output += decoder.decode(chunk, { stream: true });
        if (!ready && output.includes('Fram server listening')) {
          ready = true;
          clearTimeout(timer);
          resolveReady();
        }
      }
      output += decoder.decode();
      if (!ready && output.includes('Fram server listening')) {
        ready = true;
        clearTimeout(timer);
        resolveReady();
      }
    } catch (error) {
      if (!ready) {
        clearTimeout(timer);
        rejectReady(error);
      }
    }
  };
  void consume(child.stdout);
  void consume(child.stderr);
  timer = setTimeout(
    () => rejectReady(new Error(`server startup timeout\n${output}`)),
    60000,
  );
  try {
    await startup;
  } catch (error) {
    clearTimeout(timer);
    if (child.exitCode === null) {
      child.kill('SIGKILL');
      await child.exited;
    }
    throw error;
  }
  return {
    child,
    output: () => output,
    async stop() {
      if (child.exitCode !== null) return;
      child.kill('SIGTERM');
      const stopped = await Promise.race([
        child.exited.then(() => true),
        Bun.sleep(10000).then(() => false),
      ]);
      if (!stopped && child.exitCode === null) {
        child.kill('SIGKILL');
        await child.exited;
      }
    },
  };
}

async function exerciseClient(fram) {
  await check('native checkpoint is fixed and separate from the data client object', async () => {
    assert.equal(typeof framNativeCheckpoint, 'function');
    assert.equal(fram.checkpoint, undefined);
  });

  await check('Term constructors preserve i64, float, recursive Triple, and Instant identity', async () => {
    assert.deepEqual(FRAMRPC_VERSION, { major: 2, minor: 0 });
    assert.equal(FRAMRPC_MAX_BATCH_ACTIONS, 247);
    assert.equal(SCHEMA_MAX_BATCH_ACTIONS, FRAMRPC_MAX_BATCH_ACTIONS);
    assert.deepEqual(integerTerm(I64_MIN), ['integer', '-9223372036854775808']);
    assert(Object.is(float64Value(float64Term(-0)), -0));
    assert.deepEqual(
      tripleTerm('nested', keywordTerm('edge'), instantTerm(-2, 3)),
      ['triple', ['string', 'nested'], ['keyword', 'edge'], ['instant', '-2', '3']],
    );
    assert.throws(() => keywordTerm(''), /nonempty/);
    assert.throws(() => tripleTerm('\ud800', 'p', 'r'), /surrogate/);
    assert.throws(() => tripleQuery({ unexpected: 'value' }), /unknown/);
  });

  await check('structured query lowering emits the closed query/plan record', async () => {
    const plan = lowerQueryPlan({
      find: 'titles',
      rules: [{
        head: { rel: 'titles', args: [{ var: 'entity' }, { var: 'title' }] },
        body: [{ rel: 'triple', args: [{ var: 'entity' }, keywordTerm('title'), { var: 'title' }] }],
      }],
    });
    assert.equal(plan[0], 'triple');
    assert.deepEqual(plan[1], keywordTerm('query/plan'));
  });

  let firstVersion;
  await check('version and status use direct binary FRAMRPC', async () => {
    const version = await fram.version();
    const status = await fram.status();
    assert.equal(version.servedVersion, 0n);
    assert.equal(status.result.engine, expectedEngine);
    assert.equal(status.result.liveCount, 0n);
  });

  await check('expected-version assert preserves recursive Terms exactly', async () => {
    const response = await fram.assert('@doc-a', keywordTerm('title'), 'Running with Wolves', {
      expectedVersion: 0n,
    });
    assert.equal(response.servedVersion, 1n);
    assert.equal(response.result.length, 1);
    assert.equal(response.result[0].stateChanged, true);
    assertOccurrenceCoordinate(response.result[0].occurrence, 1n, 0n);
    firstVersion = response.servedVersion;

    const nested = await fram.assert(
      tripleTerm('nested', keywordTerm('edge'), integerTerm(I64_MIN)),
      keywordTerm('observed-at'),
      instantTerm(-2, 3),
      { expectedVersion: firstVersion },
    );
    assert.equal(nested.servedVersion, 2n);
  });

  await check('batch is atomic and stale expected-version writes fail typed', async () => {
    const batch = await fram.batch([
      { op: 'assert', t1: '@doc-b', t2: keywordTerm('title'), t3: 'Runner Notes' },
      { op: 'assert', t1: '@doc-c', t2: keywordTerm('title'), t3: 'Other Notes' },
    ], { expectedVersion: 2n });
    assert.equal(batch.servedVersion, 3n);
    assert.deepEqual(batch.result.map(result => result.stateChanged), [true, true]);
    assertOccurrenceCoordinate(batch.result[0].occurrence, 3n, 0n);
    assertOccurrenceCoordinate(batch.result[1].occurrence, 3n, 1n);

    await assert.rejects(
      fram.assert('@stale', keywordTerm('title'), 'must not land', { expectedVersion: 0n }),
      error => error instanceof FramRpcError && error.code === 'rpc/conflict'
        && error.retryable === true && error.servedVersion === 3n,
    );
    assert.equal((await fram.version()).servedVersion, 3n);
  });

  await check('scan pagination pins the served snapshot and carries its exact cursor', async () => {
    const pattern = { t2: keywordTerm('title') };
    const first = await fram.scan(pattern, { page: { limit: 2 } });
    assert.equal(first.servedVersion, 3n);
    assert.equal(first.result.length, 2);
    assert.equal(first.page.done, false);
    assert(first.page.nextCursor);

    const second = await fram.scan(pattern, {
      page: { limit: 2, cursor: first.page.nextCursor },
    });
    assert.equal(second.servedVersion, first.servedVersion);
    assert.equal(second.result.length, 1);
    assert.equal(second.page.done, true);
  });

  const titleQuery = {
    find: 'titles',
    rules: [{
      head: { rel: 'titles', args: [{ var: 'entity' }, { var: 'title' }] },
      body: [{ rel: 'triple', args: [{ var: 'entity' }, keywordTerm('title'), { var: 'title' }] }],
    }],
  };

  await check('recursive ask supports current and historical structured queries', async () => {
    const current = await fram.query(titleQuery, { timeoutMs: 5000 });
    assert.equal(current.result.length, 3);
    assert.equal(current.servedVersion, 3n);

    const historical = await fram.query(titleQuery, { asOf: firstVersion, timeoutMs: 5000 });
    assert.equal(historical.servedVersion, firstVersion);
    assert.deepEqual(historical.result, [[stringTerm('@doc-a'), stringTerm('Running with Wolves')]]);

    const events = await fram.query({
      find: 'events',
      rules: [{
        head: { rel: 'events', args: [{ var: 'where' }, { var: 'action' }, { var: 'value' }] },
        body: [{ rel: 'occurrence', args: [{ var: 'where' }, { var: 'action' }, { var: 'value' }] }],
      }],
    }, { since: { lowerExclusive: 1n, upper: 3n } });
    assert.equal(events.servedVersion, 3n);
    assert.equal(events.result.length, 3);
  });

  await check('structured query order and top-K are evaluated by FRAM', async () => {
    const ranked = await fram.query({
      ...titleQuery,
      orderBy: [
        { column: 1, direction: 'desc' },
        { column: 0, direction: 'asc' },
      ],
      limit: 2,
    });
    assert.deepEqual(ranked.result, [
      [stringTerm('@doc-a'), stringTerm('Running with Wolves')],
      [stringTerm('@doc-b'), stringTerm('Runner Notes')],
    ]);
  });

  await check('text-match runs through the same direct query operation', async () => {
    const response = await fram.query({
      find: 'matches',
      rules: [{
        head: { rel: 'matches', args: [{ var: 'entity' }] },
        body: [{
          rel: 'text-match',
          args: [{ var: 'entity' }, keywordTerm('title'), 'running'],
        }],
      }],
    });
    assert.deepEqual(response.result, [[stringTerm('@doc-a')]]);
  });

  await check('occurrence replay and validate retain typed payloads', async () => {
    const occurrences = await fram.occurrences({ page: { limit: 16 } });
    const validation = await fram.validate();
    assert(occurrences.result.length >= 4);
    for (const occurrence of occurrences.result) {
      assert.deepEqual(Object.keys(occurrence).sort(), ['action', 'coordinate', 'proposition']);
      assert(['assert', 'retract'].includes(occurrence.action));
      assert.equal(occurrence.proposition[0], 'triple');
      assertOccurrenceCoordinate(
        occurrence.coordinate,
        BigInt(occurrence.coordinate[1][3][1]),
        BigInt(occurrence.coordinate[3][1]),
      );
    }
    assert.equal(validation.result.valid, true);
    assert(Array.isArray(validation.result.violations));
  });

  await check('lease acquire, check, renew, release, and stale check are exact', async () => {
    const acquired = await fram.leaseAcquire('builder', 'plangrep', 30000);
    assert(acquired.result.fence);
    const checked = await fram.leaseCheck(acquired.result.fence);
    assert.equal(checked.result.valid, true);

    const renewed = await fram.leaseRenew(acquired.result.fence, 30000);
    const released = await fram.leaseRelease(renewed.result.fence);
    assert.equal(released.result.released, true);
    const stale = await fram.leaseCheck(renewed.result.fence);
    assert.equal(stale.result.valid, false);
  });

  await check('retract completes the closed thirteen-operation client surface', async () => {
    const response = await fram.retract('@doc-c', keywordTerm('title'), 'Other Notes');
    assert.equal(response.result[0].stateChanged, true);
    assertOccurrenceCoordinate(response.result[0].occurrence, response.servedVersion, 0n);
    const scan = await fram.scan({ t1: '@doc-c' });
    assert.equal(scan.result.length, 0);

    const beforeNoMatch = (await fram.version()).servedVersion;
    const noMatch = await fram.retract('@missing', keywordTerm('title'), 'Missing');
    assert.equal(noMatch.servedVersion, beforeNoMatch + 1n);
    assert.equal(noMatch.result[0].stateChanged, false);
    assertOccurrenceCoordinate(noMatch.result[0].occurrence, noMatch.servedVersion, 0n);
  });

  await check('schema writes compose identity guards and occurrence-correct replacement on the live server', async () => {
    const schema = schemaClient(fram);
    const subject = tripleTerm(keywordTerm('entity'), keywordTerm('page'), stringTerm('home'));
    const slug = tripleTerm(keywordTerm('field'), keywordTerm('page'), keywordTerm('slug'));
    const title = tripleTerm(keywordTerm('field'), keywordTerm('page'), keywordTerm('title'));
    const canonicalRevision = tripleTerm(
      keywordTerm('field'),
      keywordTerm('page'),
      keywordTerm('canonical-revision'),
    );
    const linksTo = tripleTerm(
      keywordTerm('field'),
      keywordTerm('page'),
      keywordTerm('links-to'),
    );
    const revisionSubject = tripleTerm(
      keywordTerm('entity'),
      keywordTerm('revision'),
      stringTerm('rev-1'),
    );
    const revisionId = tripleTerm(
      keywordTerm('field'),
      keywordTerm('revision'),
      keywordTerm('id'),
    );
    const revisionStatus = tripleTerm(
      keywordTerm('field'),
      keywordTerm('revision'),
      keywordTerm('status'),
    );
    const authorSubject = tripleTerm(keywordTerm('entity'), keywordTerm('author'), stringTerm('tom'));
    const authorName = tripleTerm(keywordTerm('field'), keywordTerm('author'), keywordTerm('name'));
    const tom = stringTerm('tom');
    const home = stringTerm('home');
    const firstTitle = stringTerm('Home');
    const canonicalTitle = stringTerm('Canonical home');
    const rev1 = stringTerm('rev-1');
    const draft = keywordTerm('draft');
    const canonical = keywordTerm('canonical');

    await schema.createUnique({
      subject: authorSubject,
      identity: { predicate: authorName, value: tom },
      fields: [],
    });
    const created = await schema.createUnique({
      subject,
      identity: { predicate: slug, value: home },
      fields: [{ predicate: title, value: firstTitle, cardinality: 'single' }],
      requireUnique: [{ subject: authorSubject, predicate: authorName, value: tom }],
    });
    await fram.assert(subject, title, firstTitle, { expectedVersion: created.servedVersion });

    const updated = await schema.updateUnique({
      identity: { predicate: slug, value: home },
      field: {
        predicate: title,
        values: [canonicalTitle],
        cardinality: 'single',
        allowedCurrent: [firstTitle],
      },
    });
    assert.equal(updated.result.length, 3);

    const current = await fram.scan({ t1: subject, t2: title });
    assert.deepEqual(current.result, [tripleTerm(subject, title, canonicalTitle)]);

    await schema.createUnique({
      subject: revisionSubject,
      identity: { predicate: revisionId, value: rev1 },
      fields: [{ predicate: revisionStatus, value: draft, cardinality: 'single' }],
    });
    const beforePublish = await fram.version();
    const published = await schema.updateUniqueMany({
      updates: [
        {
          identity: { predicate: revisionId, value: rev1 },
          fields: [{
            predicate: revisionStatus,
            values: [canonical],
            cardinality: 'single',
            allowedCurrent: [draft],
          }],
        },
        {
          identity: { predicate: slug, value: home },
          fields: [{
            predicate: canonicalRevision,
            values: [revisionSubject],
            cardinality: 'single',
            allowedCurrent: [],
          }],
        },
      ],
      requireUnique: [{ subject: authorSubject, predicate: authorName, value: tom }],
    });
    assert.deepEqual(published.subjects, [revisionSubject, subject]);
    assert.equal(published.servedVersion, beforePublish.servedVersion + 1n);
    assert.equal(published.result.length, 3);
    assert.deepEqual(
      (await fram.scan({ t1: revisionSubject, t2: revisionStatus })).result,
      [tripleTerm(revisionSubject, revisionStatus, canonical)],
    );
    assert.deepEqual(
      (await fram.scan({ t1: subject, t2: canonicalRevision })).result,
      [tripleTerm(subject, canonicalRevision, revisionSubject)],
    );

    const linked = await schema.transactUnique({
      updates: [{
        identity: { predicate: slug, value: home },
        fields: [{
          predicate: linksTo,
          values: [revisionSubject, authorSubject],
          cardinality: 'multi',
          allowedCurrent: [],
        }],
      }],
      requireUnique: [
        { subject: revisionSubject, predicate: revisionId, value: rev1 },
        { subject: authorSubject, predicate: authorName, value: tom },
      ],
    });
    assert.equal(linked.changed, true);
    assert.deepEqual(
      new Set((await fram.scan({ t1: subject, t2: linksTo })).result.map(JSON.stringify)),
      new Set([
        tripleTerm(subject, linksTo, revisionSubject),
        tripleTerm(subject, linksTo, authorSubject),
      ].map(JSON.stringify)),
    );

    const beforeRejectedLinks = await fram.version();
    await assert.rejects(
      schema.transactUnique({
        updates: [{
          identity: { predicate: slug, value: home },
          fields: [
            {
              predicate: title,
              values: [stringTerm('must not land')],
              cardinality: 'single',
              allowedCurrent: [canonicalTitle],
            },
            {
              predicate: linksTo,
              values: [authorSubject],
              cardinality: 'multi',
              allowedCurrent: [authorSubject],
            },
          ],
        }],
      }),
      error => error.code === 'schema/current-value-rejected',
    );
    assert.equal((await fram.version()).servedVersion, beforeRejectedLinks.servedVersion);
    assert.deepEqual(
      (await fram.scan({ t1: subject, t2: title })).result,
      [tripleTerm(subject, title, canonicalTitle)],
    );

    const beforeRejectedPublish = await fram.version();
    await assert.rejects(
      schema.updateUniqueMany({
        updates: [
          {
            identity: { predicate: revisionId, value: rev1 },
            fields: [{
              predicate: revisionStatus,
              values: [keywordTerm('obsolete')],
              cardinality: 'single',
              allowedCurrent: [canonical],
            }],
          },
          {
            identity: { predicate: slug, value: home },
            fields: [{
              predicate: canonicalRevision,
              values: [revisionSubject],
              cardinality: 'single',
              allowedCurrent: [],
            }],
          },
        ],
      }),
      error => error.code === 'schema/current-value-rejected',
    );
    assert.equal((await fram.version()).servedVersion, beforeRejectedPublish.servedVersion);
    assert.deepEqual(
      (await fram.scan({ t1: revisionSubject, t2: revisionStatus })).result,
      [tripleTerm(revisionSubject, revisionStatus, canonical)],
    );
    await assert.rejects(
      schema.updateUnique({
        identity: { predicate: slug, value: home },
        field: {
          predicate: title,
          values: [stringTerm('stale overwrite')],
          cardinality: 'single',
          allowedCurrent: [firstTitle],
        },
      }),
      error => error.code === 'schema/current-value-rejected',
    );
    await assert.rejects(
      schema.createUnique({ subject, identity: { predicate: slug, value: home }, fields: [] }),
      error => error.code === 'schema/identity-exists',
    );
  });

  await check('schema mixed transactions create planned graphs and update existing owners atomically', async () => {
    const schema = schemaClient(fram);
    const page = tripleTerm(keywordTerm('entity'), keywordTerm('page'), stringTerm('home'));
    const slug = tripleTerm(keywordTerm('field'), keywordTerm('page'), keywordTerm('slug'));
    const home = stringTerm('home');
    const temporary = keywordTerm('page/temporary-title');
    const temporaryValue = stringTerm('remove me');
    const graphId = keywordTerm('graph/id');
    const graphNext = keywordTerm('graph/next');
    const requestId = keywordTerm('request/id');
    const requestRoot = keywordTerm('request/root');
    const reservation = stringTerm('@request-graph-1');
    const reservationValue = stringTerm('graph-request-1');
    const nodeA = stringTerm('@graph-a');
    const nodeB = stringTerm('@graph-b');
    const nodeC = stringTerm('@graph-c');
    const idA = stringTerm('a');
    const idB = stringTerm('b');
    const idC = stringTerm('c');

    await fram.assert(page, temporary, temporaryValue);
    const mixed = await schema.transactUnique({
      creates: [
        {
          subject: reservation,
          identity: { predicate: requestId, value: reservationValue },
          fields: [{ predicate: requestRoot, value: nodeA }],
        },
        {
          subject: nodeA,
          identity: { predicate: graphId, value: idA },
          fields: [{ predicate: graphNext, value: nodeB }],
        },
        {
          subject: nodeB,
          identity: { predicate: graphId, value: idB },
          fields: [{ predicate: graphNext, value: nodeC }],
        },
        {
          subject: nodeC,
          identity: { predicate: graphId, value: idC },
          fields: [{ predicate: graphNext, value: nodeA }],
        },
      ],
      updates: [{
        identity: { predicate: slug, value: home },
        fields: [{
          predicate: temporary,
          values: [],
          cardinality: 'single',
          allowedCurrent: [temporaryValue],
        }],
      }],
      requireUnique: [
        { subject: reservation, predicate: requestId, value: reservationValue },
        { subject: nodeA, predicate: graphId, value: idA },
        { subject: nodeB, predicate: graphId, value: idB },
        { subject: nodeC, predicate: graphId, value: idC },
      ],
    });
    assert.deepEqual(mixed.createdSubjects, [reservation, nodeA, nodeB, nodeC]);
    assert.deepEqual(mixed.updatedSubjects, [page]);
    assert.equal(mixed.preflight.actionCount, 9);
    assert.equal(mixed.result.length, 9);
    assert.deepEqual(
      (await fram.scan({ t1: nodeA, t2: graphNext })).result,
      [tripleTerm(nodeA, graphNext, nodeB)],
    );
    assert.deepEqual(
      (await fram.scan({ t1: nodeB, t2: graphNext })).result,
      [tripleTerm(nodeB, graphNext, nodeC)],
    );
    assert.deepEqual(
      (await fram.scan({ t1: nodeC, t2: graphNext })).result,
      [tripleTerm(nodeC, graphNext, nodeA)],
    );
    assert.deepEqual((await fram.scan({ t1: page, t2: temporary })).result, []);

    const staleSubject = stringTerm('@stale-create');
    const beforeStale = await fram.version();
    await assert.rejects(
      schema.transactUnique({
        creates: [{
          subject: staleSubject,
          identity: { predicate: graphId, value: stringTerm('stale') },
          fields: [],
        }],
        updates: [{
          identity: { predicate: slug, value: home },
          fields: [{
            predicate: temporary,
            values: [stringTerm('must not appear')],
            cardinality: 'single',
            allowedCurrent: [temporaryValue],
          }],
        }],
      }),
      error => error.code === 'schema/current-value-rejected',
    );
    assert.equal((await fram.version()).servedVersion, beforeStale.servedVersion);
    assert.deepEqual((await fram.scan({ t1: staleSubject })).result, []);

    const beforeExistingReservation = await fram.version();
    await assert.rejects(
      schema.transactUnique({
        creates: [{
          subject: reservation,
          identity: { predicate: requestId, value: reservationValue },
          fields: [],
        }],
      }),
      error => error.code === 'schema/identity-exists',
    );
    assert.equal(
      (await fram.version()).servedVersion,
      beforeExistingReservation.servedVersion,
    );
  });

  console.log(`\nBun FRAMRPC client: ${checks.length}/${checks.length} PASS`);
}

test('Bun FRAMRPC client matches the live server', async () => {
  const tmp = await mkdtemp(resolve(tmpdir(), 'fram-bun-client-'));
  let server;
  try {
    const port = await freePort();
    const space = `bun-client-${process.pid}`;
    server = await startServer(port, resolve(tmp, 'history.framlog'), space);
    const fram = framClient({ host: '127.0.0.1', port, space, requestTimeoutMs: 30000 });
    await exerciseClient(fram);
  } catch (error) {
    throw new Error(
      `Bun FRAMRPC client failed\n${server?.output() ?? ''}`,
      { cause: error },
    );
  } finally {
    await server?.stop();
    await rm(tmp, { recursive: true, force: true });
  }
}, 180000);
