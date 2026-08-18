#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-selfhost-daily.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
fake="$scratch/beagle"
mkdir -p "$fake/bin" "$fake/self-host/native" "$fake/self-host/seed" \
    "$fake/share" "$scratch/work" "$scratch/inbox"
cp "$ROOT/bin/beagle-dev" "$fake/bin/beagle-dev"
cp "$ROOT/share/targets.sh" "$fake/share/targets.sh"
cp "$ROOT/self-host/native/stage0-select.sh" \
    "$fake/self-host/native/stage0-select.sh"

cat > "$fake/bin/beagle" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LEGACY_LOG:?}"
EOF
cat > "$fake/bin/beagle-build" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_RACKET_LOG:?}"
out="${!#}"
printf '%s\n' "${FAKE_RACKET_TEXT:?}" > "$out"
EOF
cat > "$scratch/beagle-selfhost" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_NATIVE_LOG:?}"
printf '%s\n' "${FAKE_NATIVE_TEXT:?}"
EOF
chmod +x "$fake/bin/beagle" "$fake/bin/beagle-build" \
    "$fake/bin/beagle-dev" "$scratch/beagle-selfhost"

known="$scratch/work/known.bclj"
cat > "$known" <<'EOF'
#lang beagle/clj
(ns daily.known)
(def answer Int 42)
EOF

export FAKE_LEGACY_LOG="$scratch/legacy.log"
export FAKE_NATIVE_LOG="$scratch/native.log"
export FAKE_RACKET_LOG="$scratch/racket.log"
export BEAGLE_NATIVE_BIN="$scratch/beagle-selfhost"
export BEAGLE_SELFHOST_DIVERGENCE_DIR="$scratch/inbox"

passes=0
check() {
    local label="$1"
    shift
    if "$@"; then
        printf '  PASS: %s\n' "$label"
        passes=$((passes + 1))
    else
        printf '  FAIL: %s\n' "$label" >&2
        exit 1
    fi
}

BEAGLE_SELFHOST_DEV=0 "$fake/bin/beagle-dev" build "$known"
check "flag off delegates to the Racket dispatcher" \
    grep -Fq "build $known" "$FAKE_LEGACY_LOG"
check "flag off never invokes native stage0" test ! -e "$FAKE_NATIVE_LOG"

out="$scratch/work/native.clj"
FAKE_NATIVE_TEXT="daily output" \
BEAGLE_SELFHOST_DEV=1 BEAGLE_SELFHOST_SHADOW_PERCENT=0 \
    "$fake/bin/beagle-dev" build "$known" "$out"
check "flag on dispatches a hosted build to native stage0" \
    grep -Fq "emit --target clj" "$FAKE_NATIVE_LOG"
check "native stage0 output is the development artifact" \
    grep -Fxq "daily output" "$out"
check "zero-percent shadow does not invoke Racket" test ! -e "$FAKE_RACKET_LOG"

FAKE_NATIVE_TEXT="same output" FAKE_RACKET_TEXT="same output" \
BEAGLE_SELFHOST_DEV=1 BEAGLE_SELFHOST_SHADOW_PERCENT=100 \
    "$fake/bin/beagle-dev" build "$known" "$out"
check "sampled matching compile invokes the Racket oracle" \
    test -s "$FAKE_RACKET_LOG"
check "matching canonical outputs create no divergence" \
    test -z "$(find "$scratch/inbox" -mindepth 1 -maxdepth 1 -type d -print -quit)"

FAKE_NATIVE_TEXT="native divergence" FAKE_RACKET_TEXT="racket divergence" \
BEAGLE_SELFHOST_DEV=1 BEAGLE_SELFHOST_SHADOW_PERCENT=100 \
    "$fake/bin/beagle-dev" build "$known" "$out"
entry="$(find "$scratch/inbox" -mindepth 1 -maxdepth 1 -type d -print -quit)"
check "known-input divergence appends one inbox candidate" test -n "$entry"
check "candidate retains the known input" cmp -s "$known" "$entry/input.source"
check "candidate retains native canonical output" \
    grep -Fxq "native divergence" "$entry/selfhost.output"
check "candidate retains Racket canonical output" \
    grep -Fxq "racket divergence" "$entry/racket.output"
check "candidate records the input hash and both output digests" \
    test "$(grep -c -- '-sha256 ' "$entry/manifest.txt")" -eq 3
check "shadow observation never replaces the native development artifact" \
    grep -Fxq "native divergence" "$out"

printf 'selfhost daily wrapper: %d passed, 0 failed\n' "$passes"
