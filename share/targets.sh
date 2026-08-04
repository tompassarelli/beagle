# GENERATED — do not edit. Regenerate with `bin/beagle doc-fill`.
# Source of truth: beagle-lib/private/targets.rkt (view: shell).
# Drift is a build failure (beagle-test/tests/docfill.rkt).

BEAGLE_TARGET_IDS=(clj js nix)
BEAGLE_TARGET_IDS_RE='clj|js|nix'
BEAGLE_TARGET_IDS_LIST='clj, js, and nix'
BEAGLE_TARGET_NAMES='Clojure, JavaScript, and Nix'
BEAGLE_TARGET_COUNT=3
declare -A BEAGLE_TARGET_LANG=([clj]=beagle [js]=beagle/js [nix]=beagle/nix)
declare -A BEAGLE_TARGET_SRC_EXT=([clj]=bclj [js]=bjs [nix]=bnix)
declare -A BEAGLE_TARGET_OUT_EXT=([clj]=clj [js]=js [nix]=nix)
declare -A BEAGLE_TARGET_STATUS=([clj]=live [js]=live [nix]=live)

beagle_known_target() {
    local t="$1"
    local k
    for k in "${BEAGLE_TARGET_IDS[@]}"; do
        [[ "$k" == "$t" ]] && return 0
    done
    return 1
}
