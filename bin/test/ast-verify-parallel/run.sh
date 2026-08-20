#!/usr/bin/env bash

set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-ast-verify-parallel.XXXXXX")"
cleanup() {
    local status=$?
    if [[ "$status" -eq 0 ]]; then
        rm -rf "${scratch:?}"
    else
        echo "ast-verify-parallel: preserved failure evidence at $scratch" >&2
    fi
    return "$status"
}
trap cleanup EXIT

fake_bin="$scratch/fake-bin"
sources_root="$scratch/sources"
mkdir -p "$fake_bin" "$sources_root"

for index in 0 1 2; do
    printf '#lang beagle\nfixture-%s\n' "$index" >"$sources_root/s$index.bgl"
done

cat >"$fake_bin/racket" <<'FAKE_RACKET'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --version ]]; then
    echo 'Welcome to Racket fixture'
    exit 0
fi

case "${1:-}" in
    */module-source-root-cli.rkt)
        shift
        while (($# > 0)); do
            case "$1" in
                --module-root) shift 2 ;;
                --source)
                    printf '%s\0%s\0' "$2" "$3"
                    shift 3
                    ;;
                *) exit 64 ;;
            esac
        done
        ;;
    -e)
        shift 2
        [[ "${1:-}" == -- ]] || exit 65
        shift
        shift 2
        root_count="$1"
        shift
        for ((root_index = 0; root_index < root_count; root_index++)); do shift; done
        printf '{"schemaVersion":2,"modules":['
        module_index=0
        separator=''
        while (($# > 0)); do
            physical="$1"
            logical="$2"
            shift 2
            printf '%s{"source":"%s","interfaceSha256":"sha256:%064d","program":{"fixture":%s}}' \
                "$separator" "$logical" 0 "$module_index"
            separator=,
            module_index=$((module_index + 1))
            [[ -f "$physical" ]] || exit 66
        done
        printf ']}\n'
        ;;
    */verify-checked-ast.rkt)
        ast="$2"
        source="$3"
        base="${source##*/}"
        index="${base#s}"
        index="${index%.bgl}"
        state="${FAKE_STATE:?}"
        expected="${FAKE_EXPECTED:?}"
        exec 9>"$state/worker-$index.lock"
        flock -x 9
        printf '%s\n' "$index" >"$state/start-$index"
        trap 'printf "%s\n" "$index" >"$state/term-$index"; exit 143' HUP INT TERM
        shopt -s nullglob
        reached=0
        for _ in {1..300}; do
            starts=("$state"/start-*)
            if ((${#starts[@]} >= expected)); then
                reached=1
                break
            fi
            sleep 0.01
        done
        [[ "$reached" == 1 ]] || exit 88
        printf '%s\n' "$index" >"$state/overlap-$index"
        case "${FAKE_ORDER:-forward}:$index" in
            forward:0|reverse:2) sleep 0.15 ;;
            forward:1|reverse:1) sleep 0.08 ;;
            forward:2|reverse:0) sleep 0.01 ;;
        esac
        fail=0
        hang=0
        case "$index" in
            0) fail="${FAKE_FAIL_0:-0}"; hang="${FAKE_HANG_0:-0}" ;;
            1) fail="${FAKE_FAIL_1:-0}"; hang="${FAKE_HANG_1:-0}" ;;
            2) fail="${FAKE_FAIL_2:-0}"; hang="${FAKE_HANG_2:-0}" ;;
        esac
        if [[ "$hang" == 1 ]]; then
            while :; do sleep 1; done
        fi
        [[ "$fail" == 0 ]] || exit "$fail"
        [[ -f "$ast" ]] || exit 67
        printf 'fixture/s%s.bgl\0fixture.s%s\0sha256:%064d\0sha256:%064d\0' \
            "$index" "$index" 0 0
        ;;
    *)
        echo "unexpected fake Racket invocation: $*" >&2
        exit 68
        ;;
esac
FAKE_RACKET

cat >"$fake_bin/bb" <<'FAKE_BB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
    echo 'babashka fixture'
    exit 0
fi
[[ "${1:-}" == */source-facts.clj ]] || {
    echo "unexpected fake bb invocation: $*" >&2
    exit 69
}
capture="${FAKE_CAPTURE:?}"
temporary="$capture.tmp"
: >"$temporary"
shift
while (($# > 0)); do
    case "$1" in
        --input)
            value="$2"
            printf 'input %s\n' "${value#*=}" >>"$temporary"
            shift 2
            ;;
        --interface-sha256)
            printf 'interface %s\n' "$2" >>"$temporary"
            shift 2
            ;;
        *) shift ;;
    esac
done
mv "$temporary" "$capture"
exit 73
FAKE_BB
chmod +x "$fake_bin/racket" "$fake_bin/bb"

run_case() {
    local name="$1" order="$2" expected_status="$3"
    shift 3
    local state="$scratch/$name" status=0 pid
    mkdir -p "$state/tmp" "$state/out" "$state/cache"
    set +e
    env \
        PATH="$fake_bin:$PATH" \
        TMPDIR="$state/tmp" \
        XDG_CACHE_HOME="$state/cache" \
        _BEAGLE_RACKET="$fake_bin/racket" \
        _BEAGLE_SCOPE_ROOT="$repo" \
        BEAGLE_NO_ZO_GATE=1 \
        BEAGLE_CHECKED_AST_REUSE=0 \
        BEAGLE_CORE_SUPERVISED=1 \
        BEAGLE_CORE_AST_TIMEOUT_SECONDS=5 \
        BEAGLE_CORE_FACTS_TIMEOUT_SECONDS=5 \
        BEAGLE_CORE_LOCK_TIMEOUT_SECONDS=5 \
        BEAGLE_CORE_VALIDATION_TIMEOUT_SECONDS=5 \
        FAKE_STATE="$state" \
        FAKE_EXPECTED=3 \
        FAKE_CAPTURE="$state/projector-order" \
        FAKE_ORDER="$order" \
        "$@" \
        timeout --foreground 25s "$repo/bin/beagle-build-core" \
            --materializer c17 \
            --emit-workers 3 \
            --out "$state/out" \
            --module-root "fixture=$sources_root" \
            "$sources_root/s0.bgl" "$sources_root/s1.bgl" "$sources_root/s2.bgl" \
            >"$state/stdout" 2>"$state/stderr"
    status=$?
    set -e
    [[ "$status" == "$expected_status" ]] || {
        sed -n '1,240p' "$state/stderr" >&2
        echo "ast-verify-parallel: $name expected status $expected_status, got $status" >&2
        return 1
    }
    for index in 0 1 2; do
        [[ -f "$state/overlap-$index" ]] || {
            echo "ast-verify-parallel: $name verifier $index never reached the cohort barrier" >&2
            return 1
        }
        if ! flock -n "$state/worker-$index.lock" true; then
            echo "ast-verify-parallel: $name verifier $index retained its process lock" >&2
            return 1
        fi
    done
}

run_case completion-a forward 73
run_case completion-b reverse 73
cmp "$scratch/completion-a/projector-order" \
    "$scratch/completion-b/projector-order"
cat >"$scratch/expected-order" <<'EXPECTED'
input fixture/s0.bgl
interface fixture/s0.bgl=sha256:0000000000000000000000000000000000000000000000000000000000000000
input fixture/s1.bgl
interface fixture/s1.bgl=sha256:0000000000000000000000000000000000000000000000000000000000000000
input fixture/s2.bgl
interface fixture/s2.bgl=sha256:0000000000000000000000000000000000000000000000000000000000000000
EXPECTED
cmp "$scratch/expected-order" "$scratch/completion-a/projector-order"

run_case failure forward 7 \
    FAKE_FAIL_0=7 FAKE_FAIL_1=9 FAKE_HANG_2=1
grep -Fq 'phase ast-verify-0 ERROR (7)' "$scratch/failure/stderr"
grep -Fq 'phase ast-verify-1 ERROR (9)' "$scratch/failure/stderr"
grep -Fq 'phase ast-verify-2 CANCELLED (143)' "$scratch/failure/stderr"
grep -Fq 'ast-verify-0 status=7' "$scratch/failure/stderr"
[[ -f "$scratch/failure/term-2" ]]

echo 'ast-verify-parallel: PASS overlap=3 ordered=stable failure=source-0 siblings=reaped'
