#!/usr/bin/env bash
set -euo pipefail

BEAGLE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$BEAGLE_DIR/bin/_beagle-racket"

scratch="$(mktemp -d)"
watch_pid=""
cleanup() {
    if [[ -n "$watch_pid" ]] && kill -0 "$watch_pid" 2>/dev/null; then
        kill "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
    fi
    rm -rf "${scratch:?}"
}
trap cleanup EXIT

source_file="$scratch/example.bgl"
log_file="$scratch/build.log"
fake_build="$scratch/build"
printf '#lang beagle\n(ns watch.example)\n(def value Int 1)\n' >"$source_file"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s %s\n" "${BEAGLE_DEV_FACT_REUSE:-}" "$(sha256sum "$SOURCE_FILE" | cut -d" " -f1)" >>"$BUILD_LOG"' \
    >"$fake_build"
chmod +x "$fake_build"

SOURCE_FILE="$source_file" BUILD_LOG="$log_file" \
    "$RACKET" "$BEAGLE_DIR/beagle-lib/private/watch-cli.rkt" \
    --source "$source_file" example.bgl -- "$fake_build" &
watch_pid=$!

for _ in $(seq 1 100); do
    [[ -f "$log_file" ]] && [[ $(wc -l <"$log_file") -ge 1 ]] && break
    sleep 0.05
done
[[ $(wc -l <"$log_file") -eq 1 ]]
[[ $(cut -d' ' -f1 "$log_file") == 1 ]]

idle_before=$(awk '{print $14 + $15}' "/proc/$watch_pid/stat")
sleep 0.5
idle_after=$(awk '{print $14 + $15}' "/proc/$watch_pid/stat")
(( idle_after - idle_before <= 1 ))

printf '#lang beagle\n(ns watch.example)\n(def value Int 2)\n' >"$source_file"
for _ in $(seq 1 100); do
    [[ $(wc -l <"$log_file") -ge 2 ]] && break
    sleep 0.05
done
[[ $(wc -l <"$log_file") -eq 2 ]]
first_digest=$(sed -n '1s/^[^ ]* //p' "$log_file")
second_digest=$(sed -n '2s/^[^ ]* //p' "$log_file")
[[ "$first_digest" != "$second_digest" ]]

kill "$watch_pid"
for _ in $(seq 1 40); do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.05
done
! kill -0 "$watch_pid" 2>/dev/null
wait "$watch_pid" 2>/dev/null || true
watch_pid=""

echo "foreground watch: initial=1 edit=1 idle_jiffies=$((idle_after - idle_before)) term=PASS"
