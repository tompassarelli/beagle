#!/usr/bin/env bash
# Shared stage0 selection for parity harnesses. A default local native binary is
# build output, not source truth: use it only when its sidecar proves it was
# built from the checkout's exact blessed seed. An explicit override remains a
# deliberate caller assertion; an empty override forces the bb seed.

beagle_select_stage0() {
  local seed_root="${1:?seed root required}"
  local default_native="${2:?default native path required}"
  local candidate explicit=0 sidecar current_hash recorded_hash reason

  STAGE0=bb
  NATIVE_BIN=""
  STAGE0_REASON="default native absent"

  if [ "${BEAGLE_NATIVE_BIN+x}" = x ]; then
    explicit=1
    candidate="$BEAGLE_NATIVE_BIN"
    if [ -z "$candidate" ]; then
      STAGE0_REASON="bb fallback explicitly requested"
      return 0
    fi
  else
    candidate="$default_native"
  fi

  if [ ! -x "$candidate" ]; then
    reason="native is missing or not executable: $candidate"
    if [ "$explicit" -eq 1 ]; then
      printf 'stage0: %s\n' "$reason" >&2
      return 2
    fi
    STAGE0_REASON="$reason"
    return 0
  fi

  # Explicit paths are caller-owned artifacts (including immutable Nix store
  # outputs). The default checkout-local binary is ambient mutable state and
  # therefore requires content-addressed provenance before it can execute.
  if [ "$explicit" -eq 1 ]; then
    STAGE0=native
    NATIVE_BIN="$candidate"
    STAGE0_REASON="explicit native override"
    return 0
  fi

  sidecar="${candidate}.seed-nar-hash"
  if [ ! -r "$sidecar" ]; then
    STAGE0_REASON="unverified default native (missing $sidecar)"
    printf 'stage0: %s; using current bb seed\n' "$STAGE0_REASON" >&2
    return 0
  fi
  if ! command -v nix >/dev/null 2>&1; then
    STAGE0_REASON="cannot verify default native provenance (nix unavailable)"
    printf 'stage0: %s; using current bb seed\n' "$STAGE0_REASON" >&2
    return 0
  fi
  if ! current_hash="$(nix hash path "$seed_root" 2>/dev/null)"; then
    STAGE0_REASON="cannot hash current seed at $seed_root"
    printf 'stage0: %s; using current bb seed\n' "$STAGE0_REASON" >&2
    return 0
  fi
  recorded_hash="$(tr -d '\r\n' < "$sidecar")"
  if [ "$recorded_hash" != "$current_hash" ]; then
    STAGE0_REASON="stale default native (built from ${recorded_hash:-missing-hash}, current seed $current_hash)"
    printf 'stage0: %s; using current bb seed\n' "$STAGE0_REASON" >&2
    return 0
  fi

  STAGE0=native
  NATIVE_BIN="$candidate"
  STAGE0_REASON="seed provenance $current_hash"
}

beagle_stage0_banner() {
  local seed_root="${1:?seed root required}"
  if [ "$STAGE0" = native ]; then
    printf '=== stage0: native (%s) [%s] ===\n' "$NATIVE_BIN" "$STAGE0_REASON"
  else
    printf '=== stage0: bb seed (%s) [%s] ===\n' "$seed_root" "$STAGE0_REASON"
  fi
}
