// SPDX-License-Identifier: MIT OR Apache-2.0
import {
  keywordTerm,
  storeClient,
} from '../clients/bun/store-rpc.mjs';

export async function putDocument(store, { id, title }) {
  const version = await store.version();
  const actions = [
    { op: 'assert', t1: id, t2: keywordTerm('document/title'), t3: title },
    {
      op: 'assert',
      t1: id,
      t2: keywordTerm('document/kind'),
      t3: keywordTerm('document'),
    },
  ];
  const preflight = store.preflightBatch(actions, {
    expectedVersion: version.servedVersion,
  });
  return store.batch(actions, {
    expectedVersion: version.servedVersion,
    preflight,
  });
}

export async function readDocument(store, id) {
  return store.scan({ t1: id }, { page: { limit: 32 } });
}

if (import.meta.main) {
  const space = process.env.BEAGLE_STORE_SPACE_ID;
  if (!space) throw new Error('BEAGLE_STORE_SPACE_ID is required');

  const store = storeClient({
    host: process.env.BEAGLE_STORE_SERVER_CONNECT || '127.0.0.1',
    port: Number(process.env.BEAGLE_STORE_SERVER_PORT || 7977),
    space,
  });
  const id = process.argv[2] || 'document-1';
  const title = process.argv[3] || 'Stored through the sidecar';
  const write = await putDocument(store, { id, title });
  const read = await readDocument(store, id);
  console.log(JSON.stringify({
    servedVersion: write.servedVersion.toString(),
    triples: read.result,
  }));
}
