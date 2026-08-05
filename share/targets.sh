# GENERATED — do not edit. Regenerate with `bin/beagle doc-fill`.
# Source of truth: beagle-lib/private/targets.rkt (view: shell).
# Drift is a build failure (beagle-test/tests/docfill.rkt).

BEAGLE_TARGET_IDS=(core clj js nix)
BEAGLE_HOSTED_TARGET_IDS=(clj js nix)
BEAGLE_TARGET_IDS_RE='core|clj|js|nix'
BEAGLE_TARGET_IDS_LIST='core, clj, js, and nix'
BEAGLE_TARGET_NAMES='Beagle Core, Clojure, JavaScript, and Nix'
BEAGLE_TARGET_COUNT=4
declare -A BEAGLE_TARGET_LANG=([core]=beagle [clj]=beagle/clj [js]=beagle/js [nix]=beagle/nix)
declare -A BEAGLE_TARGET_SRC_EXT=([core]=bgl [clj]=bclj [js]=bjs [nix]=bnix)
declare -A BEAGLE_TARGET_OUT_EXT=([core]=native-world [clj]=clj [js]=js [nix]=nix)
declare -A BEAGLE_TARGET_STATUS=([core]=live [clj]=live [js]=live [nix]=live)
declare -A BEAGLE_TARGET_PIPELINE=([core]=native-world [clj]=hosted-emitter [js]=hosted-emitter [nix]=hosted-emitter)
BEAGLE_MATERIALIZER_IDS=(c17 qbe)
BEAGLE_MATERIALIZER_IDS_LIST='c17 and qbe'
declare -A BEAGLE_MATERIALIZER_OUT_EXT=([c17]=c [qbe]=ssa)

beagle_known_target() {
    local t="$1"
    local k
    for k in "${BEAGLE_TARGET_IDS[@]}"; do
        [[ "$k" == "$t" ]] && return 0
    done
    return 1
}

beagle_known_hosted_target() {
    local t="$1"
    local k
    for k in "${BEAGLE_HOSTED_TARGET_IDS[@]}"; do
        [[ "$k" == "$t" ]] && return 0
    done
    return 1
}

beagle_known_materializer() {
    local m="$1"
    local k
    for k in "${BEAGLE_MATERIALIZER_IDS[@]}"; do
        [[ "$k" == "$m" ]] && return 0
    done
    return 1
}
