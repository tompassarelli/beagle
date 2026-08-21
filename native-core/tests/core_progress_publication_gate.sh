#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/core-progress-publication.XXXXXX")"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

cat >"$work/progress" <<'REPORT'
stage-progress source-projection END
stage-progress source-freeze END
stage-progress source-to-typed RUNNING
result RUNNING
REPORT

awk '
    /^publish_interrupted_progress\(\) \{/ { copying = 1 }
    copying { print }
    /^interrupted\(\) \{/ { exit }
' "$repo/bin/beagle-build-core" >"$work/interrupted-progress.sh"
[[ -s "$work/interrupted-progress.sh" ]] || {
    echo "core_progress_publication_gate.sh: interruption boundary was not found" >&2
    exit 1
}

set +e
timeout -k 5s 1s env BEAGLE_CORE_REPORT="$work/progress" \
    bash -c '
        set -euo pipefail
        source "$1"
        trap interrupted HUP INT TERM
        sleep 120
    ' core-progress-interrupt "$work/interrupted-progress.sh" \
    >"$work/stdout.log" 2>"$work/stderr.log"
rc=$?
set -e

if [[ $rc -ne 124 ]]; then
    echo "core_progress_publication_gate.sh: expected timeout 124, got $rc" >&2
    sed -n '1,120p' "$work/stderr.log" >&2
    exit 1
fi

python3 - "$work/stderr.log" "$work/progress" <<'PY'
import pathlib
import sys

stderr = pathlib.Path(sys.argv[1]).read_text()
progress = pathlib.Path(sys.argv[2]).read_text()
boundary = "beagle build: interrupted Core progress\n"

if stderr.count(boundary) != 1:
    raise SystemExit("interruption did not publish one Core progress boundary")
if stderr.count(progress) != 1:
    raise SystemExit("interruption did not publish the staged progress unchanged once")
if stderr.index(progress) != stderr.index(boundary) + len(boundary):
    raise SystemExit("staged progress did not immediately follow its interruption boundary")
PY

[[ ! -s "$work/stdout.log" ]] || {
    echo "core_progress_publication_gate.sh: progress escaped on stdout" >&2
    exit 1
}

echo "core progress publication: timeout 124, staged source-to-typed RUNNING PASS"
