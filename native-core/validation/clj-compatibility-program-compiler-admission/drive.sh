#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clj-compatibility-program-compiler-admission.XXXXXX")"
success=0
trap 'if [[ "$success" == 1 ]]; then rm -rf "${scratch:?}"; else echo "clj-compatibility-program-compiler-admission: failure artifacts preserved at $scratch" >&2; fi' EXIT

module_roots=(
  --module-root "store/src=$repo/store/src"
  --module-root "native-core/src=$repo/native-core/src"
)

echo "clj-compatibility-program-compiler-admission: syntax"
timeout --foreground 20s "$repo/bin/beagle" syntax \
  "$repo/native-core/src/beagle/compiler_driver.bgl" \
  "$here/fixture.bgl"

echo "clj-compatibility-program-compiler-admission: typed boundary"
timeout --foreground 30s "$repo/bin/beagle" check --agent \
  "${module_roots[@]}" "$here/fixture.bgl"

echo "clj-compatibility-program-compiler-admission: native direct seam"
if ! timeout --foreground 110s "$repo/bin/beagle-native-exe" \
    "${module_roots[@]}" \
    --out "$scratch/clj-compatibility-program-compiler-admission" \
    --artifacts "$scratch/artifacts" \
    --entry native.clj-compatibility-program-compiler-admission-fixture/main! \
    -- "$here/fixture.bgl" >"$scratch/native-exe.log" 2>&1; then
  tail -n 80 "$scratch/native-exe.log" >&2
  exit 1
fi

if timeout --foreground 5s "$scratch/clj-compatibility-program-compiler-admission"; then
  :
else
  status=$?
  echo "clj-compatibility-program-compiler-admission: fixture exit=$status" >&2
  exit "$status"
fi

success=1
echo "clj-compatibility-program-compiler-admission: namespace roots, canonical Triples, and pre-lookup admission PASS"
