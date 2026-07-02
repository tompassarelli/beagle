#!/usr/bin/env bash
# Build a native beagle-selfhost binary from the blessed seed (../seed) — the
# self-hosted compiler's own emitted Clojure. selfhost.main is the entry
# (beagle emits its (:gen-class)).
# Run under GraalVM CE (same mechanism as fram/native/build.sh):
#   nix shell nixpkgs#graalvmPackages.graalvm-ce -c ./build.sh
# Deps are clojure core + cheshire (JSON for the ast/emit-from-ast commands).
# Zero reflection config: no tracing agent, no reflection JSON.
set -euo pipefail
cd "$(dirname "$0")"

echo "== [1/2] AOT compile selfhost.main (seed must be AOT-clean) =="
rm -rf classes && mkdir -p classes
clojure -M -e "(compile 'selfhost.main)"

CP="$(clojure -Spath):classes"

echo "== [2/2] native-image =="

# --initialize-at-build-time=com.fasterxml.jackson: cheshire's factory namespace
# instantiates a JsonFactory at namespace load; InitClojureClasses runs that load
# at build time, so Jackson's classes must be build-time-initialized too (the
# same arrangement babashka ships). Class-init only — still zero reflection config.
time native-image -cp "$CP" \
  --no-fallback \
  --features=clj_easy.graal_build_time.InitClojureClasses \
  --initialize-at-build-time=com.fasterxml.jackson \
  -o beagle-selfhost \
  selfhost.main

echo "== done -> $(pwd)/beagle-selfhost =="; ls -lh beagle-selfhost
