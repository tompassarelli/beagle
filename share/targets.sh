# GENERATED — do not edit. Regenerate with `bin/beagle doc-fill`.
# Source of truth: beagle-lib/private/targets.rkt (view: shell).
# Drift is a build failure (beagle-test/tests/docfill.rkt).

BEAGLE_TARGET_IDS=(clj js nix odin zig scriptc)
BEAGLE_TARGET_IDS_RE='clj|js|nix|odin|zig|scriptc'
BEAGLE_TARGET_IDS_LIST='clj, js, nix, odin, zig, and scriptc'
BEAGLE_TARGET_NAMES='Clojure, JavaScript, Nix, Odin, Zig, and TypeScript'
BEAGLE_TARGET_COUNT=6
declare -A BEAGLE_TARGET_LANG=([clj]=beagle [js]=beagle/js [nix]=beagle/nix [odin]=beagle/odin [zig]=beagle/zig [scriptc]=beagle/scriptc)
declare -A BEAGLE_TARGET_SRC_EXT=([clj]=bclj [js]=bjs [nix]=bnix [odin]=bodin [zig]=bzig [scriptc]=bsc)
declare -A BEAGLE_TARGET_OUT_EXT=([clj]=clj [js]=js [nix]=nix [odin]=odin [zig]=zig [scriptc]=ts)
declare -A BEAGLE_TARGET_STATUS=([clj]=live [js]=live [nix]=live [odin]=live [zig]=live [scriptc]=live)

beagle_known_target() {
    local t="$1"
    local k
    for k in "${BEAGLE_TARGET_IDS[@]}"; do
        [[ "$k" == "$t" ]] && return 0
    done
    return 1
}
