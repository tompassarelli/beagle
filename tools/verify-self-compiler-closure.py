#!/usr/bin/env python3
"""Pure ordered verifier for the Stage 1 full compiler closure."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys
from dataclasses import dataclass

GATE = "SELF-COMPILER-CLOSURE-MANIFEST"
VERSION = "# beagle-self-compiler-closure/v1"
CORE_SUPPORT_SUFFIXES = ("_validation_corpus.bclj", "validation_corpus.bclj",
                         "fold_slice_corpus.bclj", "lowering_worklist_validation_corpus.bclj")


@dataclass(frozen=True)
class Record:
    kind: str
    name: str
    value: str


def parse(text: str) -> tuple[Record, ...]:
    lines = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if fields[0] == "input" and len(fields) == 4:
            lines.append(Record(fields[0], fields[2], f"{fields[1]} {fields[3]}"))
        elif fields[0] == "toolchain" and len(fields) >= 3:
            lines.append(Record(fields[0], fields[1], " ".join(fields[2:])))
        else:
            raise ValueError(f"{GATE}: malformed record at line {number}")
    return tuple(lines)


def verify(expected: tuple[Record, ...], actual: tuple[Record, ...]) -> tuple[str, ...]:
    """Compare ordered records without filesystem or process effects."""
    if expected == actual:
        return ()
    failures = []
    if len(expected) != len(actual):
        failures.append(f"{GATE}: record-count mismatch expected={len(expected)} actual={len(actual)}")
    for index, (want, got) in enumerate(zip(expected, actual)):
        if want != got:
            failures.append(f"{GATE}: record {index + 1} changed expected={want.name} actual={got.name}")
            break
    if len(expected) != len(actual):
        expected_names = [record.name for record in expected]
        actual_names = [record.name for record in actual]
        missing = [name for name in expected_names if name not in actual_names]
        extra = [name for name in actual_names if name not in expected_names]
        if missing:
            failures.append(f"{GATE}: missing input {missing[0]}")
        if extra:
            failures.append(f"{GATE}: extra input {extra[0]}")
    elif [record.name for record in expected] != [record.name for record in actual]:
        failures.append(f"{GATE}: input order changed")
    return tuple(failures)


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return f"sha256:{digest.hexdigest()}"


def snapshot(root: pathlib.Path, expected: tuple[Record, ...]) -> tuple[Record, ...]:
    records = []
    for record in expected:
        if record.kind != "input":
            records.append(record)
            continue
        path = root / record.name
        if path.is_file():
            records.append(Record(record.kind, record.name, f"{record.value.split()[0]} {_sha256(path)}"))
    expected_selfhost = {record.name for record in expected if record.value.startswith("self-host ")}
    for path in sorted((root / "self-host/src/selfhost").glob("*")):
        if path.suffix in (".bclj", ".clj") and path.is_file() and str(path.relative_to(root)) not in expected_selfhost:
            records.append(Record("input", str(path.relative_to(root)), f"self-host {_sha256(path)}"))
    expected_native = {record.name for record in expected if record.value.startswith("native-core ")}
    for path in sorted((root / "native-core/src/native").glob("*.bclj")):
        relative = str(path.relative_to(root))
        if (path.is_file() and relative not in expected_native and
                not path.name.endswith(CORE_SUPPORT_SUFFIXES)):
            records.append(Record("input", relative, f"native-core {_sha256(path)}"))
    return tuple(records)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} ROOT", file=sys.stderr)
        return 2
    root = pathlib.Path(argv[1]).resolve()
    manifest = root / "self-host/full-compiler-closure.manifest"
    try:
        expected = parse(manifest.read_text())
        failures = verify(expected, snapshot(root, expected))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"{GATE}: {error}", file=sys.stderr)
        return 1
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"{GATE}: verified {len(expected)} ordered records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
