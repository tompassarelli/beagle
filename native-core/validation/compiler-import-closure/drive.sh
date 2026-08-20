#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
module_roots=(
  --module-root "store/src=$repo/store/src"
  --module-root "native-core/src=$repo/native-core/src"
)

"$repo/bin/beagle" syntax \
  "$repo/native-core/src/beagle/bootstrap_contract.bgl" \
  "$repo/native-core/src/beagle/cli.bgl" \
  "$repo/native-core/src/beagle/compiler_driver.bgl" \
  "$repo/native-core/src/beagle/module_source_resolver.bgl" \
  "$here/fixture.bgl"
"$repo/bin/beagle" check --agent "${module_roots[@]}" \
  "$repo/native-core/src/beagle/cli.bgl" \
  "$here/fixture.bgl"
echo "native compiler exact-root import effect boundary focused check: PASS"
