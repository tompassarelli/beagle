#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
real_bb="$(command -v bb)"

work="$(mktemp -d "${TMPDIR:-/tmp}/core-progress-publication.XXXXXX")"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

mkdir -p "$work/fake-bin" "$work/out"

cat >"$work/progress.bgl" <<'BGL'
#lang beagle
(ns core.progress-publication-gate)

(defn value [] Int
  1)
BGL

cat >"$work/expected-progress" <<'REPORT'
stage-progress source-projection END
stage-progress source-freeze END
stage-progress source-to-typed RUNNING
result RUNNING
REPORT

cat >"$work/fake-bin/bb" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "$BEAGLE_TEST_PROJECTOR" ]]; then
    exec "$BEAGLE_TEST_REAL_BB" "$@"
fi

printf '%s\n' \
    'stage-progress source-projection END' \
    'stage-progress source-freeze END' \
    'stage-progress source-to-typed RUNNING' \
    'result RUNNING' >"${BEAGLE_CORE_REPORT:?}"
exit 73
FAKE
chmod +x "$work/fake-bin/bb"

set +e
timeout --foreground 240s env \
    PATH="$work/fake-bin:$PATH" \
    BEAGLE_TEST_REAL_BB="$real_bb" \
    BEAGLE_TEST_PROJECTOR="$repo/native-core/bin/source-facts.clj" \
    BEAGLE_CORE_BUILD_CACHE="$work/cache" \
    "$repo/bin/beagle-build-core" \
    --materializer c17 \
    --out "$work/out" \
    "$work/progress.bgl" \
    >"$work/stdout.log" 2>"$work/stderr.log"
rc=$?
set -e

if [[ $rc -ne 73 ]]; then
    echo "core_progress_publication_gate.sh: expected exit 73, got $rc" >&2
    sed -n '1,240p' "$work/stderr.log" >&2
    exit 1
fi

python3 - "$work/stderr.log" "$work/expected-progress" <<'PY'
import pathlib
import sys

stderr = pathlib.Path(sys.argv[1]).read_text()
progress = pathlib.Path(sys.argv[2]).read_text()
phase_error = "beagle build: phase core-lowering ERROR (73)\n"

if stderr.count(phase_error) != 1:
    raise SystemExit("core-lowering exit 73 diagnostic was not published exactly once")
if stderr.count(progress) != 1:
    raise SystemExit("staged progress was not published unchanged exactly once")
if stderr.index(progress) < stderr.index(phase_error) + len(phase_error):
    raise SystemExit("staged progress was published before core-lowering ERROR")
PY

for final_path in \
    "$work/out/report.txt" \
    "$work/out/module.native-program" \
    "$work/out/build.manifest" \
    "$work/out/build.manifest.sha256"; do
    if [[ -e "$final_path" ]]; then
        echo "core_progress_publication_gate.sh: failure committed $final_path" >&2
        exit 1
    fi
done

echo "core progress publication: exit 73, ordered single report, no commit PASS"
