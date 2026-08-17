import { test } from 'bun:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const root = resolve(import.meta.dir, '..');
const packageRoot = resolve(root, 'clients/bun');
const decoder = new TextDecoder();

function run(command, args, cwd) {
  const result = Bun.spawnSync([command, ...args], {
    cwd,
    env: Bun.env,
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const stdout = decoder.decode(result.stdout);
  const stderr = decoder.decode(result.stderr);
  assert.equal(
    result.exitCode,
    0,
    `${command} ${args.join(' ')} failed\n${stdout}${stderr}`,
  );
  return stdout;
}

test('packed Bun consumer accepts the public declaration surface', async () => {
  const scratch = await mkdtemp(resolve(tmpdir(), 'framrpc-bun-types-'));
  try {
    run(Bun.argv[0], [
      'pm',
      'pack',
      '--destination',
      scratch,
      '--ignore-scripts',
      '--quiet',
    ], packageRoot);
    const archives = (await readdir(scratch)).filter(path => path.endsWith('.tgz'));
    assert.equal(archives.length, 1, 'bun pm pack must produce exactly one archive');
    const archive = resolve(scratch, archives[0]);

    await Bun.write(resolve(scratch, 'package.json'), JSON.stringify({
      name: 'framrpc-types-consumer',
      private: true,
      type: 'module',
    }));
    await Bun.write(resolve(scratch, 'tsconfig.json'), JSON.stringify({
      compilerOptions: {
        target: 'ES2022',
        module: 'ESNext',
        moduleResolution: 'Bundler',
        strict: true,
        noEmit: true,
        skipLibCheck: false,
        exactOptionalPropertyTypes: true,
        types: ['bun'],
      },
      include: ['consumer.mts'],
    }));
    await Bun.write(resolve(scratch, 'consumer.mts'), `
import {
  FRAMRPC_MAX_BATCH_ACTIONS,
  FRAMRPC_VERSION,
  framNativeCheckpoint,
  keywordTerm,
} from '@tompassarelli/framrpc';
import type {
  BatchPreflight,
  FramClient,
  MutationActionResult,
  Occurrence,
  OccurrenceCoordinateTerm,
  Term,
} from '@tompassarelli/framrpc';
import { framClient as framTransportClient } from '@tompassarelli/framrpc/core';
import type { FramTransport } from '@tompassarelli/framrpc/core';
import {
  SCHEMA_MAX_BATCH_ACTIONS,
  SCHEMA_MAX_READ_PAGES,
  SchemaConstraintError,
  schemaClient,
} from '@tompassarelli/framrpc/schema';
import type {
  SchemaConstraintCode,
  UniqueTransaction,
  UpdateUniqueManyMutation,
  UpdateUniqueMutation,
} from '@tompassarelli/framrpc/schema';

declare const fram: FramClient;
declare const receipt: MutationActionResult;
declare const occurrence: Occurrence;
const transport: FramTransport = async request => request.frame;
const embedded: FramClient = framTransportClient({
  space: 'worker-space',
  transport,
});
const schema = schemaClient(fram);
const state: Term = keywordTerm('draft');
const update: UpdateUniqueMutation = {
  identity: { predicate: keywordTerm('page/slug'), value: 'home' },
  field: {
    predicate: keywordTerm('page/state'),
    values: [keywordTerm('canonical')],
    cardinality: 'single',
    allowedCurrent: [state],
  },
};
const many: UpdateUniqueManyMutation = {
  updates: [{
    identity: update.identity,
    fields: [{
      predicate: keywordTerm('page/tag'),
      values: ['wiki'],
      cardinality: 'multi',
    }],
  }],
};
const transaction: UniqueTransaction = {
  creates: [{
    subject: 'revision-1',
    identity: { predicate: keywordTerm('revision/id'), value: 'revision-1' },
    fields: [],
  }],
  updates: [{
    identity: update.identity,
    fields: [{
      predicate: keywordTerm('page/temporary-title'),
      values: [],
      cardinality: 'single',
    }],
  }],
};
const preflight: BatchPreflight = fram.preflightBatch([{
  op: 'assert',
  t1: 'page-1',
  t2: keywordTerm('page/state'),
  t3: state,
}], { expectedVersion: 1n });
const code: SchemaConstraintCode = 'schema/current-value-rejected';
const protocolMajor: 2 = FRAMRPC_VERSION.major;
const protocolMinor: 0 = FRAMRPC_VERSION.minor;
const protocolActions: 247 = FRAMRPC_MAX_BATCH_ACTIONS;
const schemaActions: typeof FRAMRPC_MAX_BATCH_ACTIONS = SCHEMA_MAX_BATCH_ACTIONS;
const pages: 2 = SCHEMA_MAX_READ_PAGES;
const checkpoint = framNativeCheckpoint({ space: 'operator-space' });
const coordinate: OccurrenceCoordinateTerm = receipt.occurrence;
const stateChanged: boolean = receipt.stateChanged;
const action: 'assert' | 'retract' = occurrence.action;
const proposition: Term = occurrence.proposition;
void schema.updateUnique(update);
void schema.updateUniqueMany(many);
void schema.transactUnique(transaction);
void fram.batch([{
  op: 'assert',
  t1: 'page-1',
  t2: keywordTerm('page/state'),
  t3: state,
}], { expectedVersion: 1n, preflight });
void SchemaConstraintError;
void code;
void protocolMajor;
void protocolMinor;
void protocolActions;
void schemaActions;
void pages;
void checkpoint;
void coordinate;
void stateChanged;
void action;
void proposition;
void embedded;
`);

    run(Bun.argv[0], [
      'add',
      '--ignore-scripts',
      '--exact',
      archive,
      'typescript@6.0.3',
      '@types/bun@1.3.13',
    ], scratch);
    run('bunx', [
      '--bun',
      '--no-install',
      'tsc',
      '--project',
      resolve(scratch, 'tsconfig.json'),
    ], scratch);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}, 120000);
