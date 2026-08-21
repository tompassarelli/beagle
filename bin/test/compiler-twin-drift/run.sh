#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
checker="$repo/tools/check-compiler-twin-drift.py"
fixtures="$here/fixtures"

run_case() { # name expected-status expected-output-fragment
    local name="$1" expected="$2" fragment="$3" status=0 output
    set +e
    output="$(python3 "$checker" --repo "$repo" \
        --contracts "$fixtures/contracts.tsv" \
        --exceptions "$fixtures/${name}.exceptions.tsv" \
        --changes-file "$fixtures/${name}.changes.tsv" --strict 2>&1)"
    status=$?
    set -e
    [[ "$status" == "$expected" ]] || {
        printf 'compiler-twin-drift fixture %s: expected status %s, got %s\n%s\n' \
            "$name" "$expected" "$status" "$output" >&2
        exit 1
    }
    [[ "$output" == *"$fragment"* ]] || {
        printf 'compiler-twin-drift fixture %s: missing %q\n%s\n' \
            "$name" "$fragment" "$output" >&2
        exit 1
    }
}

run_case both-side 0 'PASS declared compiler twin paths changed together or not at all'
run_case hosted-only 1 'pair=parse changed-selfhost=hosted/parse.bclj companion=oracle/parse.rkt'
run_case native-only 1 'pair=parse changed-oracle=oracle/parse.rkt companion=hosted/parse.bclj'
run_case unpaired 0 'PASS declared compiler twin paths changed together or not at all'
run_case explicit-exception 0 'EXCEPTION pair=parse side=selfhost paths=hosted/parse.bclj'
run_case rename 1 'pair=parse changed-selfhost=hosted/parse.bclj companion=oracle/parse.rkt'
run_case delete 1 'pair=parse changed-oracle=oracle/parse.rkt companion=hosted/parse.bclj'

printf 'COMPILER-TWIN-DRIFT: both-side, one-side, unpaired, exception, rename, and delete fixtures passed\n'
