#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source self-host/native/stage0-select.sh

SCRATCH="$(mktemp -d /tmp/beagle-stage0-select.XXXXXX)"
trap 'rm -rf "${SCRATCH:?}"' EXIT
FAKE_NATIVE="$SCRATCH/beagle-selfhost"
FAKE_SEED="$SCRATCH/seed"
cp -r self-host/seed "$FAKE_SEED"
printf '#!/usr/bin/env bash\nexit 99\n' > "$FAKE_NATIVE"
chmod +x "$FAKE_NATIVE"

PASS=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n' "$label" >&2
    exit 1
  fi
}

unset BEAGLE_NATIVE_BIN
beagle_select_stage0 "$FAKE_SEED" "$SCRATCH/missing" 2> "$SCRATCH/missing.err"
check "missing default selects bb" test "$STAGE0" = bb

beagle_select_stage0 "$FAKE_SEED" "$FAKE_NATIVE" 2> "$SCRATCH/no-sidecar.err"
check "unverified default selects bb" test "$STAGE0" = bb
check "unverified default is pointed" grep -Fq "missing ${FAKE_NATIVE}.seed-nar-hash" "$SCRATCH/no-sidecar.err"

nix hash path "$FAKE_SEED" > "${FAKE_NATIVE}.seed-nar-hash"
beagle_select_stage0 "$FAKE_SEED" "$FAKE_NATIVE"
check "matching provenance selects native" test "$STAGE0" = native
check "matching provenance selects exact path" test "$NATIVE_BIN" = "$FAKE_NATIVE"

printf 'seed changed\n' > "$FAKE_SEED/provenance-regression"
beagle_select_stage0 "$FAKE_SEED" "$FAKE_NATIVE" 2> "$SCRATCH/stale.err"
check "changed seed rejects stale native" test "$STAGE0" = bb
check "changed seed is pointed" grep -Fq "stale default native" "$SCRATCH/stale.err"

BEAGLE_NATIVE_BIN="$FAKE_NATIVE"
beagle_select_stage0 "$FAKE_SEED" "$SCRATCH/ignored"
check "explicit native override remains deliberate" test "$STAGE0" = native

BEAGLE_NATIVE_BIN=""
beagle_select_stage0 "$FAKE_SEED" "$FAKE_NATIVE"
check "empty override forces bb" test "$STAGE0" = bb

printf 'stage0 provenance: %d passed, 0 failed\n' "$PASS"
