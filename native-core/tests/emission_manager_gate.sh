#!/usr/bin/env bash

# The emission manager owns every supervised worker through success, worker
# failure, and deadline expiry. This isolates lifecycle correctness from the
# comparatively expensive native materializer fixtures.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manager="$root/native-core/bin/emit-workers"
BEAGLE_DIR="$root"
source "$root/bin/_beagle-rust-supervisor"
supervisor="$(beagle_resolve_rust_supervisor 'emission manager test')" || {
  echo "emission manager test: native bounded supervisor is unavailable" >&2
  exit 2
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-emission-manager.XXXXXX")"
cleanup() {
  rm -rf -- "${scratch:?}"
}
trap cleanup EXIT

fake_worker="$scratch/fake-worker"
cat >"$fake_worker" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
worker_dir="$7"
worker_index="${10}"
case "${BEAGLE_FAKE_WORKER_MODE:-success}" in
  success) ;;
  fail-two)
    if [[ "$worker_index" == 2 ]]; then
      printf 'injected worker failure\n' >"$worker_dir/error.txt"
      printf 'ERROR\n' >"$worker_dir/result"
      exit 2
    fi
    ;;
  hang) sleep 30 ;;
  *) exit 3 ;;
esac
printf 'OK\n' >"$worker_dir/result"
WORKER
chmod +x "$fake_worker"

run_case() {
  local label="$1" mode="$2" deadline="$3"
  local case_root="$scratch/$label"
  mkdir "$case_root"
  BEAGLE_FAKE_WORKER_MODE="$mode" \
    "$manager" "$supervisor" "$deadline" 1 \
    "$fake_worker" "$scratch/compiled" c17 "$scratch/program.wire" \
    "$case_root" 8 4 lp64 ignored
  grep -Fqx 'emission-manager-v0 reaped workers=4' \
    "$case_root/manager.receipt"
}

run_case success success 10
for worker_index in 0 1 2 3; do
  worker="$scratch/success/c17-$worker_index"
  grep -Fqx 0 "$worker/manager.status"
  grep -Fqx 'subtree-reaped-v0 exit status=0' "$worker/supervisor.receipt"
  grep -Fqx OK "$worker/result"
done

run_case failure fail-two 10
for worker_index in 0 1 3; do
  grep -Fqx 0 "$scratch/failure/c17-$worker_index/manager.status"
done
grep -Fqx 2 "$scratch/failure/c17-2/manager.status"
grep -Fqx 'subtree-reaped-v0 exit status=2' \
  "$scratch/failure/c17-2/supervisor.receipt"
grep -Fqx 'injected worker failure' "$scratch/failure/c17-2/error.txt"

run_case timeout hang 1
for worker_index in 0 1 2 3; do
  worker="$scratch/timeout/c17-$worker_index"
  grep -Fqx 124 "$worker/manager.status"
  grep -Fqx 'subtree-reaped-v0 timeout status=124' "$worker/supervisor.receipt"
done

echo "emission manager: success, worker failure, timeout, and complete reaping PASS"
