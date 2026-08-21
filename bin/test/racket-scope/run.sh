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
    mkdir -p "$destination/store"
    cp -R "$ROOT/store/." "$destination/store/"
    find "${destination:?}" -type d -name compiled -prune -exec rm -rf -- {} +
}

copy_checkout "$linked"
copy_checkout "$sibling"

(
    export PLTUSERHOME="$scratch/racket-home"
    export XDG_CACHE_HOME="$scratch/cache"
    unset PLTCOLLECTS _BEAGLE_SCOPE_ROOT _BEAGLE_ZO_GATE_PID

    "$RACO" pkg install --auto --link \
        "$linked/beagle-lib" "$linked/beagle-test" "$linked/beagle" >/dev/null

    test -f "$linked/beagle-test/tests/compiled/checked-bundle_rkt.zo"

    first_gate_errors="$scratch/first-gate.err"
    second_gate_errors="$scratch/second-gate.err"
    for errors in "$first_gate_errors" "$second_gate_errors"; do
        env -u BEAGLE_NO_ZO_GATE -u PLTCOLLECTS -u _BEAGLE_SCOPE_ROOT \
            -u _BEAGLE_ZO_GATE_PID \
            PLTUSERHOME="$PLTUSERHOME" _BEAGLE_RACKET="$RACKET" \
            bash -c 'source "$1"' bash "$linked/bin/_beagle-racket" \
            2>"$errors"
    done
    grep -Fq "beagle: bytecode current." "$first_gate_errors"
    [[ ! -s "$second_gate_errors" ]]

    rm -f "$linked/.beagle/zo-fresh"
    quiet_gate_errors="$scratch/quiet-gate.err"
    env -u BEAGLE_NO_ZO_GATE -u PLTCOLLECTS -u _BEAGLE_SCOPE_ROOT \
        -u _BEAGLE_ZO_GATE_PID \
        PLTUSERHOME="$PLTUSERHOME" _BEAGLE_RACKET="$RACKET" \
        BEAGLE_ZO_GATE_QUIET=1 \
        bash -c 'source "$1"' bash "$linked/bin/_beagle-racket" \
        2>"$quiet_gate_errors"
    [[ ! -s "$quiet_gate_errors" ]]
    test -f "$linked/.beagle/zo-fresh"

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
    "$RACO" test "$sibling/beagle-test/tests/checked-bundle.rkt" >/dev/null
    rm -rf "$sibling/.beagle"

    # A copied checkout can be immutable (as a Nix store checkout is).  Its
    # scope verdict and links must still land in the writable identity cache.
    chmod -R a-w "$sibling"
    unset PLTCOLLECTS _BEAGLE_SCOPE_ROOT _BEAGLE_ZO_GATE_PID BEAGLE_ROOT
    source "$sibling/bin/_beagle-racket"

    scope_entry="$(find "$XDG_CACHE_HOME/beagle/racket-scope" \
        -path '*/scope/lib/beagle' -type l -print -quit | sed 's:/scope/lib/beagle$::')"
    test -n "$scope_entry"
    expected_collects="$scope_entry/scope/lib:$scope_entry/scope/test:"
    [[ "$PLTCOLLECTS" == "$expected_collects" ]]
    [[ ! -e "$sibling/.beagle" ]]
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

    chmod -R u+w "$sibling"
)

printf 'racket-scope: exact package identity preserved; sibling checkout isolated\n'
