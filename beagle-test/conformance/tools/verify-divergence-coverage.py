#!/usr/bin/env python3
"""Verify the divergence inventory-to-corpus coverage join."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class VerificationError(Exception):
    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def reject(reason: str, detail: str) -> None:
    raise VerificationError(reason, detail)


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        reject("INVALID_JSON", f"cannot read {label} {path}: {exc}")
    if not isinstance(value, dict):
        reject("INVALID_DOCUMENT", f"{label} must be a JSON object")
    return value


def normalized_marker(value: object) -> str:
    return str(value).strip().lower().replace("_", "-")


def implementation_observed_only(
    manifest_case: dict[str, Any], payload: dict[str, Any]
) -> bool:
    markers: list[object] = [manifest_case.get("status"), payload.get("status")]
    for owner, keys in (
        (payload, ("evidenceAuthority", "evidenceStatus", "evidenceKind")),
        (payload.get("evidence"), ("authority", "status", "kind", "basis")),
        (payload.get("decision"), ("authority", "status", "kind", "basis")),
        (payload.get("expected"), ("authority", "status", "kind", "basis")),
        (payload.get("observations"), ("authority", "status", "kind", "basis")),
    ):
        if isinstance(owner, dict):
            markers.extend(owner.get(key) for key in keys)
    if payload.get("implementationObservedOnly") is True:
        return True
    return any(
        normalized_marker(marker) == "implementation-observed-only"
        for marker in markers
        if marker is not None
    )


def enumerated_dimension(payload: dict[str, Any]) -> str | None:
    expected = payload.get("expected")
    if not isinstance(expected, dict) or expected.get("name") != (
        "literal-builtin-enumeration"
    ):
        return None
    coverage = payload.get("coverage")
    if not isinstance(coverage, dict):
        reject("INVALID_DOCUMENT", "enumeration case has no coverage object")
    surface = coverage.get("surface")
    if (
        not isinstance(surface, list)
        or len(surface) != 3
        or not all(isinstance(value, str) and value for value in surface)
        or surface[2] != "literal-builtin-enumeration"
    ):
        reject(
            "INVALID_DOCUMENT",
            "enumeration case coverage.surface must be [name, question, "
            "'literal-builtin-enumeration']",
        )
    return f"{surface[0]}::{surface[1]}"


def verify(coverage_path: Path, manifest_path: Path) -> tuple[int, int]:
    coverage = load_object(coverage_path, "coverage document")
    manifest = load_object(manifest_path, "manifest")

    rows = coverage.get("rows")
    if not isinstance(rows, list):
        reject("INVALID_DOCUMENT", "coverage rows must be an array")
    manifest_cases = manifest.get("cases")
    if not isinstance(manifest_cases, list):
        reject("INVALID_DOCUMENT", "manifest cases must be an array")

    case_index: dict[str, dict[str, Any]] = {}
    payload_index: dict[str, dict[str, Any]] = {}
    for entry in manifest_cases:
        if not isinstance(entry, dict) or not isinstance(entry.get("caseId"), str):
            reject("INVALID_DOCUMENT", "every manifest case must have a string caseId")
        case_id = entry["caseId"]
        case_index[case_id] = entry
        case_path = entry.get("path")
        if not isinstance(case_path, str) or not case_path:
            reject("INVALID_DOCUMENT", f"manifest case {case_id!r} has no path")
        payload_index[case_id] = load_object(
            manifest_path.parent / case_path, f"case {case_id!r}"
        )

    seen: set[str] = set()
    row_case_ids: dict[str, set[str]] = {}
    covered = 0
    uncovered = 0
    for row_number, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            reject("INVALID_DOCUMENT", f"row {row_number} must be an object")
        dimension = row.get("dimension")
        status = row.get("status")
        if not isinstance(dimension, str) or not dimension or status not in {
            "covered",
            "uncovered",
        }:
            reject(
                "UNRESOLVED_QUESTION_DIMENSION",
                f"row {row_number} must name a dimension and resolve it to covered or uncovered",
            )
        if dimension in seen:
            reject("DUPLICATE_DIMENSION", f"dimension {dimension!r} occurs more than once")
        seen.add(dimension)

        case_ids = row.get("caseIds")
        if not isinstance(case_ids, list) or not all(
            isinstance(case_id, str) and case_id for case_id in case_ids
        ):
            reject("INVALID_DOCUMENT", f"dimension {dimension!r} has invalid caseIds")
        if status == "covered" and not case_ids:
            reject(
                "COVERED_WITHOUT_CASE_EVIDENCE",
                f"dimension {dimension!r} claims coverage with no case evidence",
            )
        if status == "uncovered" and case_ids:
            reject(
                "UNCOVERED_WITH_CASE_EVIDENCE",
                f"dimension {dimension!r} has case evidence but claims to be uncovered",
            )
        row_case_ids[dimension] = set(case_ids)

        for case_id in case_ids:
            entry = case_index.get(case_id)
            if entry is None:
                reject(
                    "CASE_NOT_IN_MANIFEST",
                    f"dimension {dimension!r} references absent case {case_id!r}",
                )
            payload = payload_index[case_id]
            if implementation_observed_only(entry, payload):
                reject(
                    "IMPLEMENTATION_OBSERVED_ONLY_EVIDENCE",
                    f"dimension {dimension!r} uses implementation-observed-only case {case_id!r}",
                )
            if entry.get("status") != "DECIDED" or payload.get("status") != "DECIDED":
                reject(
                    "CASE_NOT_DECIDED",
                    f"dimension {dimension!r} references non-DECIDED case {case_id!r}",
                )

        if case_ids:
            covered += 1
        else:
            uncovered += 1

    for case_id, payload in payload_index.items():
        dimension = enumerated_dimension(payload)
        if dimension is None:
            continue
        entry = case_index[case_id]
        if entry.get("status") != "DECIDED" or payload.get("status") != "DECIDED":
            continue
        if dimension not in row_case_ids:
            reject(
                "ENUMERATION_DIMENSION_NOT_IN_INVENTORY",
                f"enumeration case {case_id!r} names absent dimension {dimension!r}",
            )
        if case_id not in row_case_ids[dimension]:
            reject(
                "ENUMERATION_CASE_NOT_JOINED",
                f"enumeration case {case_id!r} is absent from dimension {dimension!r}",
            )

    return covered, uncovered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_root = Path(__file__).resolve().parent.parent
    parser.add_argument(
        "--coverage", type=Path, default=default_root / "divergence-coverage.json"
    )
    parser.add_argument("--manifest", type=Path, default=default_root / "manifest.json")
    args = parser.parse_args()
    try:
        covered, uncovered = verify(args.coverage, args.manifest)
    except VerificationError as exc:
        print(f"{exc.reason}: {exc.detail}", file=sys.stderr)
        return 1
    print(f"ok: {covered + uncovered} dimensions; {covered} covered, {uncovered} uncovered")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
