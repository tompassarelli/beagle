#!/usr/bin/env bash
# Run one bounded compiler command inside a named, host-specific envelope.
#
# Usage:
#   tools/compiler-resource-envelope/run.sh --root ABSOLUTE-RUN-ROOT \
#     canonical|candidate-a|candidate-b DEADLINE KILL-GRACE -- COMMAND [ARG...]
#
# The three envelopes divide the 24 logical CPUs on the development host into
# 8-CPU sets. The kernel reports canonical's L3 domain separately; the two
# candidate domains have non-overlapping CPUs and private compiler cache roots,
# but share the host's second L3 domain. There is no global mutex: callers
# choose a fresh run root, and canonical timing is an operationally exclusive
# use of the named canonical CPUs.

set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
supervisor="$repo/native-core/bin/run-bounded"

usage() {
    cat >&2 <<'USAGE'
usage:
  tools/compiler-resource-envelope/run.sh --root ABSOLUTE-RUN-ROOT \
    canonical|candidate-a|candidate-b DEADLINE KILL-GRACE -- COMMAND [ARG...]

The command inherits a private XDG/Beagle cache root, TMPDIR/TMP/TEMP, output
root, CPU affinity, and a nested-worker budget. Candidates run at nice 19 and
idle I/O priority. Canonical timing uses its own named CPU set at inherited
priority; do not launch another compiler command in that envelope while timing.

The command's explicit --emit-workers value may be no greater than the named
envelope budget. A fresh --root is evidence for one run; no lock is taken.
USAGE
}

die() {
    echo "beagle compiler envelope: $*" >&2
    exit 2
}

positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

root=""
while (($# > 0)); do
    case "$1" in
        --root)
            (($# >= 2)) || die "--root needs an absolute directory"
            root="$2"
            shift 2
            ;;
        --root=*)
            root="${1#*=}"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

[[ -n "$root" && "$root" == /* ]] || die "--root must be absolute"
(($# >= 5)) || {
    usage
    exit 2
}

envelope="$1"
deadline="$2"
kill_grace="$3"
shift 3
[[ "${1:-}" == "--" ]] || die "expected -- before COMMAND"
shift
(($# > 0)) || die "COMMAND is required"
command=("$@")

positive_integer "$deadline" || die "deadline must be a positive integer"
positive_integer "$kill_grace" || die "kill grace must be a positive integer"
[[ -x "$supervisor" ]] || die "bounded supervisor is unavailable: $supervisor"
command -v taskset >/dev/null 2>&1 || die "taskset is required"
command -v nice >/dev/null 2>&1 || die "nice is required"

# These are deliberately host topology declarations, not a scheduler. CPU
# affinity is inherited by every supervisor/worker descendant, so nproc in a
# child observes the same bound as the environment variables below.
case "$envelope" in
    canonical)
        cpu_set="0-3,12-15"
        worker_budget=8
        priority="normal"
        io_priority="inherited"
        ;;
    candidate-a)
        cpu_set="4-7,16-19"
        worker_budget=8
        priority="nice-19"
        io_priority="idle"
        ;;
    candidate-b)
        cpu_set="8-11,20-23"
        worker_budget=8
        priority="nice-19"
        io_priority="idle"
        ;;
    *)
        die "unknown envelope '$envelope' (expected canonical, candidate-a, or candidate-b)"
        ;;
esac

# Do not let an explicitly requested inner emission pool undo the affinity
# limit. Lower values remain useful for a tiny reproducer.
for ((index = 0; index < ${#command[@]}; index++)); do
    case "${command[$index]}" in
        --emit-workers)
            ((index + 1 < ${#command[@]})) || die "--emit-workers needs a value"
            requested_workers="${command[$((index + 1))]}"
            positive_integer "$requested_workers" ||
                die "--emit-workers must be a positive integer"
            ((requested_workers <= worker_budget)) ||
                die "--emit-workers=$requested_workers exceeds $envelope budget $worker_budget"
            ;;
        --emit-workers=*)
            requested_workers="${command[$index]#*=}"
            positive_integer "$requested_workers" ||
                die "--emit-workers must be a positive integer"
            ((requested_workers <= worker_budget)) ||
                die "--emit-workers=$requested_workers exceeds $envelope budget $worker_budget"
            ;;
    esac
done

mkdir -p -- "$root"
root="$(realpath -e -- "$root")"
[[ -d "$root" && ! -L "$root" ]] || die "run root must be a real directory"

envelope_root="$root/$envelope"
[[ ! -e "$envelope_root" ]] ||
    die "refusing to reuse envelope evidence: $envelope_root"
mkdir -- "$envelope_root"
cache_root="$envelope_root/cache"
tmp_root="$envelope_root/tmp"
output_root="$envelope_root/out"
mkdir -p -- "$cache_root" "$cache_root/racket-compiled" "$tmp_root" "$output_root"

available_kib="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
minimum_available_kib="${BEAGLE_ENVELOPE_MIN_MEM_AVAILABLE_KIB:-8388608}"
positive_integer "$minimum_available_kib" ||
    die "BEAGLE_ENVELOPE_MIN_MEM_AVAILABLE_KIB must be a positive integer"
[[ -n "$available_kib" ]] || die "MemAvailable is unavailable"
((available_kib >= minimum_available_kib)) ||
    die "memory admission denied: available=${available_kib}KiB need=${minimum_available_kib}KiB"

# Verify the requested host affinity before starting a process tree. This makes
# an unavailable CPU set a setup failure rather than an unisolated run.
observed_budget="$(taskset -c "$cpu_set" nproc)"
[[ "$observed_budget" == "$worker_budget" ]] ||
    die "CPU set $cpu_set yields $observed_budget workers, expected $worker_budget"

first_cpu="${cpu_set%%[-,]*}"
l3_path="/sys/devices/system/cpu/cpu${first_cpu}/cache/index3/shared_cpu_list"
l3_shared="unavailable"
[[ -r "$l3_path" ]] && l3_shared="$(tr -d '\n' <"$l3_path")"

provenance="$envelope_root/provenance.env"
{
    printf 'format=beagle-compiler-resource-envelope/v1\n'
    printf 'envelope=%s\n' "$envelope"
    printf 'cpu_set=%s\n' "$cpu_set"
    printf 'worker_budget=%s\n' "$worker_budget"
    printf 'l3_shared_cpu_list=%s\n' "$l3_shared"
    printf 'priority=%s\n' "$priority"
    printf 'io_priority=%s\n' "$io_priority"
    printf 'mem_available_kib=%s\n' "$available_kib"
    printf 'mem_admission_kib=%s\n' "$minimum_available_kib"
    printf 'cache_root=%s\n' "$cache_root"
    printf 'tmp_root=%s\n' "$tmp_root"
    printf 'output_root=%s\n' "$output_root"
    printf 'supervisor=%s\n' "$supervisor"
    printf 'command_executable=%s\n' "${command[0]}"
} >"$provenance"

environment=(
    "XDG_CACHE_HOME=$cache_root/xdg"
    "TMPDIR=$tmp_root"
    "TMP=$tmp_root"
    "TEMP=$tmp_root"
    "BEAGLE_ENVELOPE_NAME=$envelope"
    "BEAGLE_ENVELOPE_CPUSET=$cpu_set"
    "BEAGLE_ENVELOPE_WORKERS=$worker_budget"
    "BEAGLE_ENVELOPE_ROOT=$envelope_root"
    "BEAGLE_ENVELOPE_CACHE=$cache_root"
    "BEAGLE_ENVELOPE_OUTPUT=$output_root"
    "BEAGLE_ENVELOPE_PROVENANCE=$provenance"
    "BEAGLE_ENVELOPE_REPO=$repo"
    "BEAGLE_CORE_MODULE_JOBS=$worker_budget"
    "BEAGLE_TEST_JOBS=$worker_budget"
    "BEAGLE_EVAL_JOBS=$worker_budget"
    "BEAGLE_CORE_COMPILER_CACHE=$cache_root/core-compiler-projections"
    "BEAGLE_CORE_BUILD_CACHE=$cache_root/build-core"
    "BEAGLE_NATIVE_EXE_CACHE=$cache_root/native-executables"
    "BEAGLE_GATE_CACHE=$cache_root/gate-results"
    "BEAGLE_CHECKED_AST_STORE=$cache_root/checked-ast.storelog"
    # The trailing empty path asks Racket to append its configured roots after
    # this private root. It keeps the pinned runtime bytecode readable while
    # redirecting this invocation's source bytecode cache out of the checkout.
    "PLTCOMPILEDROOTS=$cache_root/racket-compiled:"
    "BEAGLE_BOUNDED_COMPLETION_RECEIPT=$envelope_root/subtree-reaped.receipt"
)

# Candidate correctness probes run source directly and must not acquire the
# checkout-local zo freshness lock or write its stamp. That existing gate is a
# preparation concern for canonical runs; it is neither a source of semantic
# authority nor a candidate-lane scheduler. Canonical runs retain the normal
# gate and therefore remain the sole route for comparable latency evidence.
if [[ "$envelope" == candidate-* ]]; then
    environment+=("BEAGLE_NO_ZO_GATE=1")
fi

runner=(env "${environment[@]}" taskset -c "$cpu_set" "$supervisor" \
    "$deadline" "$kill_grace" -- "${command[@]}")
if [[ "$envelope" == candidate-* ]]; then
    command -v ionice >/dev/null 2>&1 || die "ionice is required for candidate lanes"
    runner=(ionice -c 3 -- nice -n 19 "${runner[@]}")
else
    runner=(nice -n 0 "${runner[@]}")
fi

printf 'beagle compiler envelope: START envelope=%s cpus=%s workers=%s output=%s\n' \
    "$envelope" "$cpu_set" "$worker_budget" "$output_root" >&2
started="$(date +%s%N)"
set +e
"${runner[@]}"
status=$?
set -e
ended="$(date +%s%N)"
{
    printf 'exit_status=%s\n' "$status"
    printf 'started_ns=%s\n' "$started"
    printf 'ended_ns=%s\n' "$ended"
} >>"$provenance"
printf 'beagle compiler envelope: END envelope=%s status=%s\n' \
    "$envelope" "$status" >&2
exit "$status"
