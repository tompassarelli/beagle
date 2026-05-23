#!/usr/bin/env bash
# E23 harness: compile reference.bsql via beagle, seed sqlite, run query,
# diff against expected. Returns 0 iff the beagle pipeline produces SQL
# that yields the expected rows.

set -euo pipefail
cd "$(dirname "$0")"

BEAGLE_BIN="$(cd ../../bin && pwd)/beagle-build"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# 1. Compile reference.bsql → sql
"$BEAGLE_BIN" reference.bsql "$TMP/query.sql"

# 2. Seed sqlite + run query
sqlite3 "$TMP/db.sqlite" < seed.sql
sqlite3 "$TMP/db.sqlite" < "$TMP/query.sql" > "$TMP/actual.txt"

# 3. Diff
if diff -u expected.txt "$TMP/actual.txt"; then
  echo "OK: beagle/sql output matches expected"
else
  echo "FAIL: output diverged"
  exit 1
fi
