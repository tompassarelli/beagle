#!/usr/bin/env bash
# SELF-COMPILER-STAGE1: reproducible artifact plus a standalone Core canary.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="SELF-COMPILER-STAGE1"
deadline="${BEAGLE_SELF_COMPILER_STAGE1_DEADLINE_SECONDS:-240}"
kill_grace="${BEAGLE_SELF_COMPILER_STAGE1_KILL_GRACE_SECONDS:-5}"
projection="${BEAGLE_STAGE1_PROJECTION:-}"
[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || { echo "$gate: invalid deadline: $deadline" >&2; exit 2; }
[[ "$kill_grace" =~ ^[1-9][0-9]*$ ]] || { echo "$gate: invalid kill grace: $kill_grace" >&2; exit 2; }
[[ -n "$projection" && -d "$projection" ]] || {
    echo "$gate: BEAGLE_STAGE1_PROJECTION must name the complete projection" >&2
    exit 2
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-self-compiler-stage1.XXXXXX")"
cleanup() {
    local rc=$?
    rm -rf "${scratch:?}"
    return "$rc"
}
trap cleanup EXIT

nix_flags=(--offline --no-write-lock-file --option sandbox true)
build_once() {
    BEAGLE_STAGE1_PROJECTION="$projection" \
        nix build "${nix_flags[@]}" --impure --no-link --print-out-paths \
        "$root#beagle-compiler-native"
}

printf '%s: artifact rebuild 1 START projection=%s deadline=%ss\n' \
    "$gate" "$(basename "$projection")" "$deadline"
artifact_a="$(build_once)"
printf '%s: artifact rebuild 1 END %s\n' "$gate" "$artifact_a"
printf '%s: artifact rebuild 2 START\n' "$gate"
artifact_b="$(build_once)"
printf '%s: artifact rebuild 2 END %s\n' "$gate" "$artifact_b"
[[ "$artifact_a" == "$artifact_b" ]] || {
    echo "$gate: Nix output path changed between identical builds" >&2
    exit 1
}

nar_hash() {
    nix path-info --json "$1" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
if len(rows) != 1 or not rows[0].get("narHash"):
    raise SystemExit("missing unique NAR hash")
print(rows[0]["narHash"])
'
}
nar_a="$(nar_hash "$artifact_a")"
nar_b="$(nar_hash "$artifact_b")"
[[ "$nar_a" == "$nar_b" ]] || {
    echo "$gate: NAR hash changed between identical builds: $nar_a != $nar_b" >&2
    exit 1
}
[[ -x "$artifact_a/bin/beagle-compiler-native" ]] || {
    echo "$gate: artifact omitted result/bin/beagle-compiler-native" >&2
    exit 1
}
[[ -r "$artifact_a/bin/beagle-compiler-native.provenance" ]] || {
    echo "$gate: artifact omitted full-closure provenance sidecar" >&2
    exit 1
}
printf '%s: artifact NAR identity PASS %s\n' "$gate" "$nar_a"

fixture_args=(
    --materializer c17
    --out "$scratch/core-out"
    --entry native.zero-variant-fixture/-main
    "$root/native-core/validation/zero-variant/action.bgl"
    "$root/native-core/validation/zero-variant/fixture.bgl"
)
artifact="$artifact_a/bin/beagle-compiler-native"
printf '%s: native Core canary START deadline=%ss\n' "$gate" "$deadline"
set +e
"$artifact" "${fixture_args[@]}" >"$scratch/core.stdout" 2>"$scratch/core.stderr" &
pid=$!
set -e
started="$(date +%s)"
child_failure=""
process_descendants() {
    ps -eo pid=,ppid=,args= | awk -v root_pid="$pid" '
        {
            process = $1
            parent[process] = $2
            command = $0
            sub(/^[^ ]+[[:space:]]+[^ ]+[[:space:]]+/, "", command)
            command_line[process] = command
        }
        END {
            for (process in parent) {
                current = process
                while (current != root_pid && (current in parent)) {
                    current = parent[current]
                }
                if (current == root_pid) {
                    print process " " command_line[process]
                }
            }
        }
    '
}
while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    if (( now - started >= deadline )); then
        child_failure="native Core canary exceeded ${deadline}s"
        kill "$pid" 2>/dev/null || true
        break
    fi
    descendants="$(process_descendants)"
    if printf '%s\n' "$descendants" | grep -Eiq '(^|/)(racket|raco|bb|babashka)( |$)|racket-|babashka'; then
        child_failure="Racket or Babashka descendant detected:\n$descendants"
        kill "$pid" 2>/dev/null || true
        break
    fi
    sleep 0.05
done
set +e
wait "$pid"
status=$?
set -e
if [[ -n "$child_failure" ]]; then
    printf '%b\n' "$gate: $child_failure" >&2
    exit 1
fi
[[ "$status" == 0 ]] || {
    echo "$gate: native Core canary failed with status $status" >&2
    sed -n '1,160p' "$scratch/core.stderr" >&2 || true
    exit 1
}
printf '%s: native Core canary END status=0, zero Racket/Babashka descendants\n' "$gate"

# This is a landing gate as well as a stage-1 gate. Keep every live emission
# target explicit; the Nix target must not disappear behind a Clojure-only loop.
source "$root/bin/_beagle-racket"
suites=(
    beagle-test/tests/emit.rkt
    beagle-test/tests/emit-clj-behavioral.rkt
    beagle-test/tests/emit-js.rkt
    beagle-test/tests/emit-js-behavioral.rkt
    beagle-test/tests/emit-nix.rkt
    beagle-test/tests/nix-emit-errors.rkt
    beagle-test/tests/emit-matrix.rkt
)
for suite in "${suites[@]}"; do
    printf '%s: suite %s START\n' "$gate" "$suite"
    timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
        "$RACO" test "$root/$suite"
    printf '%s: suite %s END\n' "$gate" "$suite"
done

printf '%s: passed artifact NAR identity, standalone Core canary, and all emission suites\n' "$gate"
