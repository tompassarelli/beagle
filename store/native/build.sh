#!/usr/bin/env bash
# Build the Store RPC server as a GraalVM native image. Domain semantics
# remain the Beagle-emitted Clojure under ../out; the entry is a platform
# adapter around server/-main.
# Run under GraalVM CE:
#   nix shell nixpkgs#graalvmPackages.graalvm-ce -c ./build.sh
# Container releases run `aot` and `image` in separate builder stages.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$native_dir/.." && pwd)"
phase="${1:-all}"
case "$phase" in
  all|aot|image) ;;
  *)
    echo "usage: native/build.sh [all|aot|image]" >&2
    exit 2
    ;;
esac
cd "$repo_dir"
# The manifest paths are repository-relative because server preserves
# its file-based host boundary for the JVM development route.
native_deps="$(<"$native_dir/deps.edn")"
classpath_file="$native_dir/classpath.txt"

if [[ "$phase" != "image" ]]; then
  echo "== [1/2] AOT compile Beagle Store server =="
  rm -rf "${native_dir:?}/classes"
  mkdir -p "$native_dir/classes"
  clojure -Sdeps "$native_deps" -M -e \
    "(set! *warn-on-reflection* true) (binding [*compile-path* \"native/classes\"] (compile 'store.graal-server))"
  clojure -Sdeps "$native_deps" -Spath >"$classpath_file"
fi

if [[ "$phase" != "aot" ]]; then
  if [[ ! -s "$classpath_file" ]]; then
    echo "native/build.sh: run the aot phase before image" >&2
    exit 2
  fi
  CP="$(<"$classpath_file")"
  default_init_classes="$(
    find "$native_dir/classes" -maxdepth 1 -type f -name '*.class' \
      ! -name '*__init.class' -printf '%f\n' \
      | sed 's/\.class$//' \
      | sort \
      | paste -sd, -
  )"
  link_args=()
  if [[ "${BEAGLE_STORE_GRAAL_STATIC:-0}" == "1" ]]; then
    link_args=(--static --libc=musl)
  fi

  echo "== [2/2] native-image =="
  time native-image -cp "$CP" \
    --no-fallback \
    "${link_args[@]}" \
    --features=clj_easy.graal_build_time.InitClojureClasses \
    "-H:ConfigurationFileDirectories=$native_dir" \
    "--initialize-at-build-time=$default_init_classes" \
    -o "$native_dir/beagle-store-server-graal" \
    store.graal_server

  echo "== done -> $native_dir/beagle-store-server-graal =="
  ls -lh "$native_dir/beagle-store-server-graal"
fi
