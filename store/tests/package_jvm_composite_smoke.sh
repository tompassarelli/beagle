#!/usr/bin/env bash
# Hermetic contract test for the Beagle dispatcher plus packaged JVM Store.
set -euo pipefail

package_root="${1:?usage: package_jvm_composite_smoke.sh /nix/store/...-beagle-store-jvm-composite}"
cmp_bin="${BEAGLE_JVM_COMPOSITE_TEST_CMP:?BEAGLE_JVM_COMPOSITE_TEST_CMP is required}"
env_bin="${BEAGLE_JVM_COMPOSITE_TEST_ENV:?BEAGLE_JVM_COMPOSITE_TEST_ENV is required}"
grep_bin="${BEAGLE_JVM_COMPOSITE_TEST_GREP:?BEAGLE_JVM_COMPOSITE_TEST_GREP is required}"
java="${BEAGLE_JVM_COMPOSITE_TEST_JAVA:?BEAGLE_JVM_COMPOSITE_TEST_JAVA is required}"
raw_dispatcher="${BEAGLE_JVM_COMPOSITE_TEST_RAW_DISPATCHER:?BEAGLE_JVM_COMPOSITE_TEST_RAW_DISPATCHER is required}"
store_root="${BEAGLE_JVM_COMPOSITE_TEST_STORE_ROOT:?BEAGLE_JVM_COMPOSITE_TEST_STORE_ROOT is required}"

case "$package_root" in
  /nix/store/*) ;;
  *) echo "JVM composite smoke: refusing non-store package root: $package_root" >&2; exit 2 ;;
esac

composite_store="$package_root/libexec/store"
dispatcher="$package_root/libexec/bin/beagle"
[[ -d "$composite_store" && ! -L "$composite_store" ]] || {
  echo "JVM composite smoke: Store member is not a physical directory" >&2
  exit 1
}
[[ -x "$dispatcher" ]] || { echo "JVM composite smoke: missing dispatcher" >&2; exit 1; }
[[ -x "$composite_store/bin/beagle-store-server" ]] || {
  echo "JVM composite smoke: missing Store server" >&2
  exit 1
}
[[ -r "$composite_store/server.classpath" ]] || {
  echo "JVM composite smoke: missing Store server classpath" >&2
  exit 1
}
[[ -x "$java" ]] || { echo "JVM composite smoke: exact Java is not executable" >&2; exit 1; }
[[ -x "$raw_dispatcher" ]] || {
  echo "JVM composite smoke: raw Beagle dispatcher is not executable" >&2
  exit 1
}
"$cmp_bin" -s "$store_root/runtime.manifest" "$composite_store/runtime.manifest" || {
  echo "JVM composite smoke: canonical Store manifest bytes changed" >&2
  exit 1
}

work="$(mktemp -d)"
cleanup() {
  rm -rf "${work:?}"
}
trap cleanup EXIT INT TERM

evil="$work/evil"
marker="$work/hostile-executable-ran"
mkdir -p "$evil/bin" "$evil/store/bin" "$work/home" "$work/state"
for executable in beagle-store-server bb java; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >>%q\nexit 99\n' \
    "$executable" "$marker" >"$evil/bin/$executable"
  chmod +x "$evil/bin/$executable"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" hostile-store >>%q\nexit 99\n' \
  "$marker" >"$evil/store/bin/beagle-store-server"
chmod +x "$evil/store/bin/beagle-store-server"

help_output="$work/help.out"
(
  cd "$composite_store"
  "$env_bin" -i \
    HOME="$work/home" \
    XDG_STATE_HOME="$work/state" \
    PATH="$evil/bin" \
    BEAGLE_STORE_HOME="$evil/store" \
    BEAGLE_STORE_BIN="$evil/store/bin" \
    BEAGLE_STORE_OUT="$evil/store/out" \
    BEAGLE_STORE_RESOLVE="$evil/store/resolve.clj" \
    BEAGLE_STORE_SERVER_CLASSPATH_FILE="$evil/store/server.classpath" \
    BEAGLE_STORE_PACKAGED=0 \
    BEAGLE_STORE_SERVER_RUNTIME=native \
    BEAGLE_STORE_JAVA="$evil/bin/java" \
    BEAGLE_NATIVE_BIN="$evil/bin/beagle-selfhost" \
    ../bin/beagle store help >"$help_output"
)
"$grep_bin" -Fq 'Usage: beagle store <command>' "$help_output" || {
  echo "JVM composite smoke: relative dispatcher did not reach Store help" >&2
  exit 1
}
[[ ! -e "$marker" ]] || {
  echo "JVM composite smoke: hostile ambient executable ran" >&2
  exit 1
}

# Force an early server argument failure after dispatch. The hostile ambient
# selector requests Native and names a fake Java; reaching JVM argument parsing
# proves the wrapper replaced both with its immutable member bindings.
server_output="$work/server.out"
if "$env_bin" -i \
    HOME="$work/home" \
    XDG_STATE_HOME="$work/state" \
    PATH="$evil/bin" \
    BEAGLE_STORE_HOME="$evil/store" \
    BEAGLE_STORE_BIN="$evil/store/bin" \
    BEAGLE_STORE_OUT="$evil/store/out" \
    BEAGLE_STORE_RESOLVE="$evil/store/resolve.clj" \
    BEAGLE_STORE_SERVER_CLASSPATH_FILE="$evil/store/server.classpath" \
    BEAGLE_STORE_PACKAGED=0 \
    BEAGLE_STORE_SERVER_RUNTIME=native \
    BEAGLE_STORE_JAVA="$evil/bin/java" \
    BEAGLE_STORE_SPACE_ID=composite-smoke \
    "$dispatcher" store serve not-a-port "$work/history.storelog" \
    >"$server_output" 2>&1; then
  echo "JVM composite smoke: invalid port unexpectedly launched" >&2
  exit 1
fi
"$grep_bin" -Fq 'NumberFormatException' "$server_output" || {
  echo "JVM composite smoke: derived dispatcher did not reach packaged JVM Store" >&2
  sed -n '1,80p' "$server_output" >&2
  exit 1
}
if "$grep_bin" -Fq 'BEAGLE_STORE_NATIVE_ARTIFACT_DIR' "$server_output"; then
  echo "JVM composite smoke: hostile Native selector won" >&2
  exit 1
fi
[[ ! -e "$marker" ]] || {
  echo "JVM composite smoke: hostile ambient executable ran" >&2
  exit 1
}

printf '%s\n' 'JVM composite smoke: PASS'
