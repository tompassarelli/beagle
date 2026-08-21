#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/bin/_beagle-canonical-format-check"

grep -Fq \
    'beagle_canonical_format_check "$BEAGLE_ROOT" "$BEAGLE_ROOT/bin/beagle-fmt"' \
    "$ROOT/bin/beagle-test" || {
        echo "canonical-format: bin/beagle-test does not invoke the changed-source guard" >&2
        exit 1
    }

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/beagle-canonical-format.XXXXXX")"
cleanup() {
    rm -rf -- "${fixture_root:?}"
}
trap cleanup EXIT

git -C "$fixture_root" init -q -b main
git -C "$fixture_root" config user.email beagle-format-test@example.invalid
git -C "$fixture_root" config user.name beagle-format-test
mkdir -p "$fixture_root/src"
cat >"$fixture_root/src/sample.bjs" <<'EOF'
(declare-extern [globalThis process TextDecoder Error String Number Set Intl setInterval clearInterval] Any)
(defn bridge-sample [] String (.push kept segment))
EOF
git -C "$fixture_root" add src/sample.bjs
git -C "$fixture_root" commit -qm base
git -C "$fixture_root" checkout -qb candidate

cat >"$fixture_root/src/sample.bjs" <<'EOF'
(declare-extern [globalThis process TextDecoder Error String Number Set Intl setInterval clearInterval] Any)
(defn bridge-sample []  String (.push kept  segment ))
EOF

set +e
beagle_canonical_format_check "$fixture_root" "$ROOT/bin/beagle-fmt"
drift_status=$?
set -e
if [[ "$drift_status" -ne 3 ]]; then
    echo "canonical-format: expected changed-source drift status 3, got $drift_status" >&2
    exit 1
fi

"$ROOT/bin/beagle-fmt" --write "$fixture_root/src/sample.bjs"
beagle_canonical_format_check "$fixture_root" "$ROOT/bin/beagle-fmt"

diff -u <(cat <<'EOF'
(declare-extern
  [globalThis process
   TextDecoder Error
   String Number
   Set Intl
   setInterval clearInterval] Any)
(defn bridge-sample [] String (.push kept segment))
EOF
) "$fixture_root/src/sample.bjs"

echo "canonical-format: PASS — gate rejects drift and accepts one-write fixed point"
