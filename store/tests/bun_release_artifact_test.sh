#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
packager="$repo/scripts/package-bun-release.sh"
scratch="$(mktemp -d)"
cleanup() {
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "bun release artifact test: FAIL: $*" >&2
  exit 1
}

for command in bun cmp git sha256sum tar touch; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
[[ "$(bun --version)" == "1.3.13" ]] || fail "Bun 1.3.13 is required"

source_seed="$scratch/source-seed"
mkdir -p "$source_seed/clients/bun"
package_files=(
  package.json
  LICENSE
  LICENSE-MIT
  LICENSE-APACHE
  store-rpc.mjs
  store-rpc-core.mjs
  store-rpc-core.d.ts
  store-rpc.d.ts
  backup.mjs
  schema.mjs
  schema.d.ts
  README.md
)
for package_file in "${package_files[@]}"; do
  cp "$repo/clients/bun/$package_file" "$source_seed/clients/bun/$package_file"
done
git -C "$source_seed" init -q
git -C "$source_seed" add \
  clients/bun/package.json \
  clients/bun/LICENSE \
  clients/bun/LICENSE-MIT \
  clients/bun/LICENSE-APACHE \
  clients/bun/store-rpc.mjs \
  clients/bun/store-rpc-core.mjs \
  clients/bun/store-rpc-core.d.ts \
  clients/bun/store-rpc.d.ts \
  clients/bun/backup.mjs \
  clients/bun/schema.mjs \
  clients/bun/schema.d.ts \
  clients/bun/README.md
GIT_AUTHOR_NAME=Beagle Store GIT_AUTHOR_EMAIL=store@example.invalid \
GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=Beagle Store GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
  git -C "$source_seed" commit -q -m release
GIT_COMMITTER_NAME=Beagle Store GIT_COMMITTER_EMAIL=store@example.invalid \
GIT_COMMITTER_DATE='2026-01-02T04:05:06Z' \
  git -C "$source_seed" tag -a v1.2.3 -m release
git -C "$source_seed" tag v1.2.4
source_commit="$(git -C "$source_seed" rev-parse HEAD)"
tag_object="$(git -C "$source_seed" rev-parse refs/tags/v1.2.3)"

git clone -q --no-local "$source_seed" "$scratch/work-a"
git clone -q --no-local "$source_seed" "$scratch/different/depth/work-b"
for package_file in "${package_files[@]}"; do
  touch -t 203801020304.05 \
    "$scratch/different/depth/work-b/clients/bun/$package_file"
done

mapfile -t files_a < <(
  "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-a" --version v1.2.3
)
mapfile -t files_b < <(
  "$packager" --source-root "$scratch/different/depth/work-b" \
    --output "$scratch/different/out-b" --version v1.2.3
)
[[ "${#files_a[@]}" == 2 && "${#files_b[@]}" == 2 ]] ||
  fail "packager did not return one archive and one receipt"
cmp -s "${files_a[0]}" "${files_b[0]}" ||
  fail "package archives differ across source workdirs"
cmp -s "${files_a[1]}" "${files_b[1]}" ||
  fail "package receipts differ across source workdirs"

for forbidden_path in "$scratch/work-a" "$scratch/different/depth/work-b"; do
  ! grep -Fq "$forbidden_path" "${files_a[1]}" ||
    fail "receipt leaked a checkout-local path: $forbidden_path"
done
grep -Fxq "source-commit $source_commit" "${files_a[1]}" ||
  fail "receipt omitted the exact source commit"
grep -Fxq 'release-tag v1.2.3' "${files_a[1]}" ||
  fail "receipt omitted the repository release tag"
grep -Fxq "release-tag-object $tag_object" "${files_a[1]}" ||
  fail "receipt omitted the annotated tag object"
grep -Fxq 'package-name @tompassarelli/beagle-store-rpc' "${files_a[1]}" ||
  fail "receipt omitted the package name"
grep -Fxq 'package-version 0.5.0' "${files_a[1]}" ||
  fail "receipt omitted the independent package version"
archive_sha256="$(sha256sum "${files_a[0]}" | awk '{print $1}')"
grep -Fxq "archive-sha256 $archive_sha256" "${files_a[1]}" ||
  fail "receipt does not hash the shipped archive"
expected_receipt_keys=$'store-bun-release-receipt/v2\nsource-commit\nsource-date-epoch\nrelease-tag\nrelease-tag-object\npackage-name\npackage-version\npackage-json-sha256\narchive-name\narchive-sha256'
[[ "$(awk 'NR == 1 { print; next } { print $1 }' "${files_a[1]}")" == \
  "$expected_receipt_keys" ]] ||
  fail "receipt schema is not closed and ordered"

expected_entries=$'package/package.json\npackage/LICENSE\npackage/LICENSE-APACHE\npackage/LICENSE-MIT\npackage/README.md\npackage/backup.mjs\npackage/store-rpc-core.d.ts\npackage/store-rpc-core.mjs\npackage/store-rpc.d.ts\npackage/store-rpc.mjs\npackage/schema.d.ts\npackage/schema.mjs'
[[ "$(tar -tzf "${files_a[0]}")" == "$expected_entries" ]] ||
  fail "archive member set or order is not canonical"

extract="$scratch/extract"
mkdir -p "$extract"
tar -xzf "${files_a[0]}" -C "$extract"
for package_file in "${package_files[@]}"; do
  cmp -s "$source_seed/clients/bun/$package_file" \
    "$extract/package/$package_file" ||
    fail "archive changed or omitted $package_file"
done
package_json_sha256="$(sha256sum "$extract/package/package.json" | awk '{print $1}')"
grep -Fxq "package-json-sha256 $package_json_sha256" "${files_a[1]}" ||
  fail "receipt does not hash the packed manifest"

# Inspect every static module edge in the unpacked artifact. Relative edges
# must resolve inside it; bare edges must be Bun builtins or the two declared
# self-package entries.
# The following single-quoted string is Bun source, not shell.
# shellcheck disable=SC2016
bun -e '
  import { readdir } from "node:fs/promises";
  import { dirname, relative, resolve } from "node:path";
  const root = resolve(Bun.argv.at(-1));
  const allowedBare = new Set([
    "@tompassarelli/beagle-store-rpc",
    "@tompassarelli/beagle-store-rpc/core",
    "fs",
    "fs/promises",
    "path",
    "node:net",
  ]);
  const entries = await readdir(root);
  for (const entry of entries.filter(name => /\.(?:mjs|d\.ts)$/.test(name))) {
    const path = resolve(root, entry);
    const source = await Bun.file(path).text();
    const edges = source.matchAll(/\b(?:import|export)\s+(?:[^"\x27]*?\s+from\s*)?["\x27]([^"\x27]+)["\x27]/g);
    for (const edge of edges) {
      const specifier = edge[1];
      if (specifier.startsWith(".")) {
        const target = resolve(dirname(path), specifier);
        if (relative(root, target).startsWith("..") || !(await Bun.file(target).exists())) {
          throw new Error(`${entry}: unresolved package-relative import ${specifier}`);
        }
      } else if (!allowedBare.has(specifier)) {
        throw new Error(`${entry}: external import escapes the package: ${specifier}`);
      }
    }
  }
' "$extract/package"

# The schema entry is part of the Worker surface. Walk its packed, transitive
# module graph rather than trusting a source-tree filename check: neither the
# Bun TCP entry nor any bare runtime dependency may be reachable from schema or
# core. Then make Bun accept the complete namespaces as a browser bundle, which
# exercises the same no-Node-builtins boundary a Worker deployment needs.
# The following single-quoted string is Bun source, not shell.
# shellcheck disable=SC2016
bun -e '
  import { dirname, relative, resolve } from "node:path";
  const root = resolve(Bun.argv.at(-1));
  const pending = ["schema.mjs", "store-rpc-core.mjs"];
  const visited = new Set();
  while (pending.length > 0) {
    const entry = pending.pop();
    if (visited.has(entry)) continue;
    visited.add(entry);
    const path = resolve(root, entry);
    const source = await Bun.file(path).text();
    const edges = source.matchAll(/\b(?:import|export)\s+(?:[^"\x27]*?\s+from\s*)?["\x27]([^"\x27]+)["\x27]/g);
    for (const edge of edges) {
      const specifier = edge[1];
      if (!specifier.startsWith(".")) {
        throw new Error(`${entry}: Worker graph reaches bare import ${specifier}`);
      }
      const target = resolve(dirname(path), specifier);
      const member = relative(root, target);
      if (member.startsWith("..") || member === "store-rpc.mjs") {
        throw new Error(`${entry}: Worker graph reaches forbidden module ${member}`);
      }
      if (!(await Bun.file(target).exists())) {
        throw new Error(`${entry}: Worker graph has unresolved module ${specifier}`);
      }
      pending.push(member);
    }
  }
  if (!visited.has("schema.mjs") || !visited.has("store-rpc-core.mjs")) {
    throw new Error("packed Worker graph omitted schema or the runtime-neutral core");
  }
' "$extract/package"

cat >"$extract/package/worker-probe.mjs" <<'PROBE'
import * as core from './store-rpc-core.mjs';
import * as schema from './schema.mjs';
globalThis.__storeWorkerProbe = [Object.keys(core), Object.keys(schema)];
PROBE
bun build "$extract/package/worker-probe.mjs" --target=browser \
  --outfile="$scratch/store-rpc-worker-probe.js" >/dev/null
[[ -s "$scratch/store-rpc-worker-probe.js" ]] ||
  fail "schema and core did not produce a browser-target bundle"
! grep -Fq 'node:net' "$scratch/store-rpc-worker-probe.js" ||
  fail "schema and core browser bundle retained node:net"
! grep -Fq 'store-rpc.mjs' "$scratch/store-rpc-worker-probe.js" ||
  fail "schema and core browser bundle retained the TCP entry"

# Install the local tarball with an empty cache, offline mode, and an unusable
# registry. Successful root and schema imports therefore come from the artifact
# alone, not the checkout or a fetched package.
consumer="$scratch/consumer"
mkdir -p "$consumer/empty-cache"
printf '%s\n' '{"name":"store-rpc-release-consumer","private":true,"type":"module"}' \
  >"$consumer/package.json"
(
  cd "$consumer"
  bun add --offline --cache-dir "$consumer/empty-cache" \
    --registry http://127.0.0.1:9 --ignore-scripts --exact "${files_a[0]}" \
    >/dev/null
)
cat >"$consumer/probe.mjs" <<'PROBE'
import assert from 'node:assert/strict';
import { storeClient, storeNativeCheckpoint, keywordTerm } from '@tompassarelli/beagle-store-rpc';
import { storeClient as storeTransportClient } from '@tompassarelli/beagle-store-rpc/core';
import { schemaClient } from '@tompassarelli/beagle-store-rpc/schema';

const client = storeClient({ space: 'offline-package-probe', port: 1 });
assert.deepEqual(Object.keys(client).sort(), [
  'assert',
  'batch',
  'leaseAcquire',
  'leaseCheck',
  'leaseRelease',
  'leaseRenew',
  'occurrences',
  'preflightBatch',
  'query',
  'retract',
  'scan',
  'status',
  'validate',
  'version',
]);
assert.equal('checkpoint' in client, false);
assert.equal('storeNativeCheckpoint' in client, false);
assert.equal(typeof storeNativeCheckpoint, 'function');
assert.equal(typeof schemaClient, 'function');
assert.equal(typeof storeTransportClient, 'function');
assert.deepEqual(keywordTerm('draft'), ['keyword', 'draft']);

for (const privateSubpath of ['backup', 'store-rpc.mjs', 'store-rpc-core.mjs', 'schema.mjs']) {
  try {
    await import(`@tompassarelli/beagle-store-rpc/${privateSubpath}`);
    assert.fail(`private package subpath unexpectedly imported: ${privateSubpath}`);
  } catch (error) {
    assert.match(String(error), /not defined by "exports"|Cannot find module/);
  }
}
PROBE
(
  cd "$consumer"
  bun probe.mjs
)

# A tracked mutation and a tag/HEAD mismatch both fail before package bytes are
# produced.
git clone -q --no-local "$source_seed" "$scratch/dirty-source"
printf '\nchanged\n' >>"$scratch/dirty-source/clients/bun/README.md"
if "$packager" --source-root "$scratch/dirty-source" \
    --output "$scratch/out-dirty" --version v1.2.3 \
    >"$scratch/dirty.stdout" 2>"$scratch/dirty.stderr"; then
  fail "packager accepted a tracked-dirty source"
fi
grep -Fq 'source worktree has tracked changes' "$scratch/dirty.stderr" ||
  fail "tracked-dirty source did not fail exactly"

git clone -q --no-local "$source_seed" "$scratch/untagged-source"
git -C "$scratch/untagged-source" config user.name Beagle Store
git -C "$scratch/untagged-source" config user.email store@example.invalid
git -C "$scratch/untagged-source" commit --allow-empty -q -m after-release
if "$packager" --source-root "$scratch/untagged-source" \
    --output "$scratch/out-untagged" --version v1.2.3 \
    >"$scratch/untagged.stdout" 2>"$scratch/untagged.stderr"; then
  fail "packager accepted a tag that did not point at HEAD"
fi
grep -Fq 'does not point at source commit' "$scratch/untagged.stderr" ||
  fail "tag/HEAD mismatch did not fail exactly"

if "$packager" --source-root "$scratch/work-a" \
    --output "$scratch/out-lightweight" --version v1.2.4 \
    >"$scratch/lightweight.stdout" 2>"$scratch/lightweight.stderr"; then
  fail "packager accepted a lightweight release tag"
fi
grep -Fq 'must name an annotated tag object' "$scratch/lightweight.stderr" ||
  fail "lightweight release tag failed for the wrong reason"

printf 'bun release artifact test: PASS commit=%s archive=%s\n' \
  "$source_commit" "$archive_sha256"
