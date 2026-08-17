import { afterAll, expect, test } from 'bun:test';
import { mkdtemp, mkdir, rm } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { canonicalManifestBytes, verifyBackup } from '../clients/bun/backup.mjs';

const scratch = await mkdtemp(join(tmpdir(), 'beagle-store-backup-unit-'));
afterAll(() => rm(scratch, { recursive: true, force: true }));

function sha256(bytes) {
  return new Bun.CryptoHasher('sha256').update(bytes).digest('hex');
}

function historyBytes(spaceId) {
  const space = Buffer.from(spaceId, 'utf8');
  const bytes = Buffer.alloc(16 + space.length);
  bytes.write('FRAMLOG\0', 0, 'ascii');
  bytes.writeUInt16LE(1, 8);
  bytes.writeUInt16LE(0, 10);
  bytes.writeUInt32LE(space.length, 12);
  space.copy(bytes, 16);
  return bytes;
}

async function fixture(name) {
  const directory = join(scratch, name);
  await mkdir(directory);
  const spaceId = 'backup-unit-space';
  const history = historyBytes(spaceId);
  const artifact = Buffer.from(`beagle-store-native-build/v1 ${'a'.repeat(64)}\n`, 'ascii');
  const manifest = {
    artifactReceipt: {
      bytes: String(artifact.length),
      closureSha256: 'a'.repeat(64),
      file: 'artifact.READY',
      format: 'beagle-store-native-build/v1',
      sha256: sha256(artifact),
    },
    checkpoint: {
      createdAtUnixMs: '1786496400000',
      snapshotBytes: '512',
      snapshotCrc32: '1234',
      watermarkBytes: String(history.length),
    },
    format: 'beagle-store-backup/v1',
    history: {
      bytes: String(history.length),
      file: 'history.framlog',
      sha256: sha256(history),
    },
    servedVersion: '0',
    spaceId,
  };
  const manifestBytes = canonicalManifestBytes(manifest);
  await Promise.all([
    Bun.write(join(directory, 'history.framlog'), history),
    Bun.write(join(directory, 'artifact.READY'), artifact),
    Bun.write(join(directory, 'manifest.json'), manifestBytes),
    Bun.write(
      join(directory, 'manifest.sha256'),
      `${sha256(manifestBytes)}  manifest.json\n`,
    ),
  ]);
  return { directory, history, manifest, manifestBytes, spaceId };
}

test('verifyBackup accepts only the canonical exact four-file backup', async () => {
  const value = await fixture('valid');
  const receipt = await verifyBackup({ backup: value.directory, spaceId: value.spaceId });
  expect(receipt).toEqual({
    format: 'beagle-store-backup/verify-receipt/v1',
    backup: value.directory,
    manifestSha256: sha256(value.manifestBytes),
    spaceId: value.spaceId,
    servedVersion: '0',
    historyBytes: String(value.history.length),
    historySha256: sha256(value.history),
  });
  await expect(verifyBackup({ backup: value.directory, spaceId: 'wrong' }))
    .rejects.toMatchObject({ code: 'space-mismatch' });
  await Bun.write(join(value.directory, 'unexpected'), 'no');
  await expect(verifyBackup({ backup: value.directory }))
    .rejects.toMatchObject({ code: 'verification' });
});

test('verifyBackup rejects changed authoritative history', async () => {
  const value = await fixture('changed-history');
  const changed = Buffer.from(value.history);
  changed[changed.length - 1] ^= 1;
  await Bun.write(join(value.directory, 'history.framlog'), changed);
  await expect(verifyBackup({ backup: value.directory }))
    .rejects.toMatchObject({ code: 'verification' });
});

test('verifyBackup rejects noncanonical manifest bytes', async () => {
  const value = await fixture('noncanonical');
  const pretty = Buffer.from(`${JSON.stringify(value.manifest, null, 2)}\n`, 'utf8');
  await Bun.write(join(value.directory, 'manifest.json'), pretty);
  await Bun.write(
    join(value.directory, 'manifest.sha256'),
    `${sha256(pretty)}  manifest.json\n`,
  );
  await expect(verifyBackup({ backup: value.directory }))
    .rejects.toMatchObject({ code: 'invalid-manifest' });
});

test('canonical manifest bytes are stable for non-ASCII SpaceIds', () => {
  const first = canonicalManifestBytes({ spaceId: '百科', format: 'beagle-store-backup/v1' });
  const second = canonicalManifestBytes({ format: 'beagle-store-backup/v1', spaceId: '百科' });
  expect(first.equals(second)).toBe(true);
  expect(first.toString('utf8')).toBe(
    '{"format":"beagle-store-backup/v1","spaceId":"\\u767e\\u79d1"}\n',
  );
});
