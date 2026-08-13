#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export BEAGLE_NO_ZO_GATE=1
source "$ROOT/bin/_beagle-racket"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-racket-scope.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

linked="$scratch/linked"
sibling="$scratch/sibling"

copy_checkout() {
    local destination="$1"
    mkdir -p "$destination"
    cp -R "$ROOT/beagle-lib" "$ROOT/beagle-test" "$ROOT/beagle" \
        "$ROOT/bin" "$ROOT/contrib" "$ROOT/docs" "$ROOT/native-core" \
        "$ROOT/self-host" "$ROOT/share" "$destination/"
    find "${destination:?}" -type d -name compiled -prune -exec rm -rf -- {} +
}

copy_checkout "$linked"
copy_checkout "$sibling"

(
    export PLTUSERHOME="$scratch/racket-home"
    unset PLTCOLLECTS _BEAGLE_SCOPE_ROOT _BEAGLE_ZO_GATE_PID

    "$RACO" pkg install --auto --link \
        "$linked/beagle-lib" "$linked/beagle-test" "$linked/beagle" >/dev/null

    test -f "$linked/beagle-test/tests/compiled/checked-bundle_rkt.zo"

    export _BEAGLE_RACKET="$RACKET"
    export BEAGLE_NO_ZO_GATE=1
    source "$linked/bin/_beagle-racket"

    [[ ! -v PLTCOLLECTS ]]
    [[ "$_BEAGLE_SCOPE_ROOT" == "$linked" ]]
    [[ "$(realpath "$("$RACKET" -e \
        '(display (path->string (collection-file-path "parse.rkt" "beagle" "private")))')")" \
        == "$linked/beagle-lib/private/parse.rkt" ]]
    [[ "$(realpath "$("$RACKET" -e \
        '(display (path->string (collection-path "beagle" "tests")))')")" \
        == "$linked/beagle-test/tests" ]]

    "$RACO" test "$linked/beagle-test/tests/checked-bundle.rkt" >/dev/null

    unset PLTCOLLECTS _BEAGLE_SCOPE_ROOT _BEAGLE_ZO_GATE_PID BEAGLE_ROOT
    source "$sibling/bin/_beagle-racket"

    expected_collects="$sibling/.beagle/scope/lib:$sibling/.beagle/scope/test:"
    [[ "$PLTCOLLECTS" == "$expected_collects" ]]
    [[ "$_BEAGLE_SCOPE_ROOT" == "$sibling" ]]
    [[ "$(realpath "$("$RACKET" -e \
        '(display (path->string (collection-file-path "parse.rkt" "beagle" "private")))')")" \
        == "$sibling/beagle-lib/private/parse.rkt" ]]
    [[ "$(realpath "$("$RACKET" -e \
        '(display (path->string (collection-path "beagle" "tests")))')")" \
        == "$sibling/beagle-test/tests" ]]

    first_collects="$PLTCOLLECTS"
    source "$sibling/bin/_beagle-racket"
    [[ "$PLTCOLLECTS" == "$first_collects" ]]
)

printf 'racket-scope: exact package identity preserved; sibling checkout isolated\n'
