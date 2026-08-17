import { storeClient, keywordTerm, tripleTerm } from '../clients/bun/store-rpc.mjs';

const [portText, space, mode, expectedText] = Bun.argv.slice(2);
if (!portText || !space || !mode) {
  throw new Error('usage: store_backup_restore_driver.mjs PORT SPACE MODE [EXPECTED_VERSION]');
}
const port = Number(portText);
const store = storeClient({ host: '127.0.0.1', port, space, requestTimeoutMs: 3000 });
const title = keywordTerm('title');

function equal(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}

function deepEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

function expectedVersion() {
  if (!/^(?:0|[1-9][0-9]*)$/.test(expectedText ?? '')) {
    throw new Error(`${mode} requires a canonical expected version`);
  }
  return BigInt(expectedText);
}

switch (mode) {
  case 'version': {
    const response = await store.version();
    process.stdout.write(`${response.servedVersion}\n`);
    break;
  }
  case 'seed': {
    const response = await store.batch([
      { op: 'assert', t1: 'backup-seed', t2: title, t3: 'included-a' },
      { op: 'assert', t1: 'backup-seed', t2: title, t3: 'included-b' },
    ], { expectedVersion: 0n });
    equal(response.servedVersion, 1n, 'seed version');
    process.stdout.write('1\n');
    break;
  }
  case 'tail': {
    const response = await store.assert('backup-tail', title, 'excluded', {
      expectedVersion: expectedVersion(),
    });
    process.stdout.write(`${response.servedVersion}\n`);
    break;
  }
  case 'restored': {
    const expected = expectedVersion();
    equal((await store.version()).servedVersion, expected, 'restored version');
    deepEqual(
      (await store.scan({ t1: 'backup-seed', t2: title })).result,
      [
        tripleTerm('backup-seed', title, 'included-a'),
        tripleTerm('backup-seed', title, 'included-b'),
      ],
      'restored seed facts',
    );
    deepEqual((await store.scan({ t1: 'backup-tail' })).result, [], 'excluded source tail');
    process.stdout.write(`${expected}\n`);
    break;
  }
  case 'postwrite': {
    const expected = expectedVersion();
    const response = await store.assert('backup-post-restore', title, 'durable', {
      expectedVersion: expected,
    });
    equal(response.servedVersion, expected + 1n, 'post-restore write version');
    process.stdout.write(`${response.servedVersion}\n`);
    break;
  }
  case 'postrestart': {
    const expected = expectedVersion();
    equal((await store.version()).servedVersion, expected, 'post-restart version');
    deepEqual(
      (await store.scan({ t1: 'backup-post-restore', t2: title })).result,
      [tripleTerm('backup-post-restore', title, 'durable')],
      'post-restart write',
    );
    process.stdout.write(`${expected}\n`);
    break;
  }
  default:
    throw new Error(`unknown mode ${mode}`);
}
