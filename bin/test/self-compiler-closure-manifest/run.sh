#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO="$repo"
python3 - <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

path = Path(os.environ["REPO"]) / "tools/verify-self-compiler-closure.py"
spec = importlib.util.spec_from_file_location("closure", path)
closure = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = closure
spec.loader.exec_module(closure)

base = closure.parse((Path(os.environ["REPO"]) / "self-host/full-compiler-closure.manifest").read_text())

def expect(label, records, fragment):
    failures = closure.verify(base, tuple(records))
    assert failures and all(closure.GATE in failure for failure in failures), (label, failures)
    assert fragment in "\n".join(failures), (label, failures)

expect("missing", base[1:], "missing input")
expect("extra", base + (closure.Record("input", "extra/file", "driver sha256:" + "0" * 64),), "extra input")
expect("reorder", (base[1], base[0], *base[2:]), "input order changed")
changed = list(base)
changed[0] = closure.Record(changed[0].kind, changed[0].name, "self-host sha256:" + "0" * 64)
expect("content-change", changed, "record 1 changed")
assert closure.verify(base, base) == ()
print("SELF-COMPILER-CLOSURE-MANIFEST: present/missing/extra/reorder/content-change passed")
PY

python3 "$repo/tools/verify-self-compiler-closure.py" "$repo"
