#!/usr/bin/env bash
# Shared selector and phase supervision for direct Native Core validation.

native_validation_select_binary() {
  local destination="$1"
  local configured resolved provenance expected actual

  if [[ "${BEAGLE_NATIVE_COMPILER_BIN+x}" != x ]]; then
    printf -v "$destination" '%s' ''
    return 1
  fi

  configured="$BEAGLE_NATIVE_COMPILER_BIN"
  if [[ -z "$configured" ]]; then
    echo "native validation: BEAGLE_NATIVE_COMPILER_BIN must name the immutable compiler" >&2
    return 2
  fi
  if [[ ! -x "$configured" ]]; then
    echo "native validation: compiler is unavailable or not executable: $configured" >&2
    return 2
  fi
  resolved="$(realpath -e "$configured")" || {
    echo "native validation: compiler cannot be resolved: $configured" >&2
    return 2
  }
  case "$resolved" in
    /nix/store/*/bin/beagle-compiler-native) ;;
    *)
      echo "native validation: compiler is not an immutable Nix artifact: $resolved" >&2
      return 2
      ;;
  esac

  provenance="$resolved.provenance"
  if [[ ! -r "$provenance" ]]; then
    echo "native validation: compiler provenance is unavailable: $provenance" >&2
    return 2
  fi
  expected="$(sed -nE 's/^artifact-sha256 sha256:([0-9a-f]{64})$/\1/p' "$provenance")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "native validation: compiler provenance has no unique artifact digest: $provenance" >&2
    return 2
  fi
  actual="$(sha256sum "$resolved" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "native validation: compiler digest differs from its provenance" >&2
    return 2
  fi

  printf -v "$destination" '%s' "$resolved"
}

native_validation_positive_seconds() {
  local value="$1" name="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "native validation: $name must be a positive integer" >&2
    return 2
  fi
}

native_validation_run_phase() {
  local label="$1" deadline="$2" receipt_dir="$3"
  shift 3
  local route_root supervisor receipt kill_grace status expected

  route_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  supervisor="$route_root/native-core/bin/run-bounded"
  kill_grace="${BEAGLE_NATIVE_VALIDATION_KILL_GRACE_SECONDS:-5}"
  native_validation_positive_seconds "$deadline" phase-deadline || return $?
  native_validation_positive_seconds "$kill_grace" kill-grace || return $?
  if [[ ! -x "$supervisor" ]]; then
    echo "native validation: platform supervisor is unavailable: $supervisor" >&2
    return 2
  fi
  mkdir -p "$receipt_dir"
  receipt="$receipt_dir/$label.receipt"
  rm -f -- "$receipt"

  echo "native validation: phase $label START deadline=${deadline}s receipt=$receipt" >&2
  if BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
      "$supervisor" "$deadline" "$kill_grace" -- "$@"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" == 124 ]]; then
    expected='subtree-reaped-v0 timeout status=124'
  else
    expected="subtree-reaped-v0 exit status=$status"
  fi
  if [[ ! -f "$receipt" || "$(<"$receipt")" != "$expected" ]]; then
    echo "native validation: phase $label receipt mismatch status=$status" >&2
    return 2
  fi
  if [[ "$status" == 0 ]]; then
    echo "native validation: phase $label END status=0" >&2
  elif [[ "$status" == 124 ]]; then
    echo "native validation: phase $label TIMEOUT status=124" >&2
  else
    echo "native validation: phase $label ERROR status=$status" >&2
  fi
  return "$status"
}
