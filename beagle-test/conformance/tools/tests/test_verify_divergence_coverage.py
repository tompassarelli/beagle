#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


VERIFIER = Path(__file__).resolve().parents[1] / "verify-divergence-coverage.py"


def baseline() -> tuple[dict, dict, dict]:
    coverage = {
        "schema": "BeagleDivergenceCoverageV1",
        "version": 1,
        "rows": [
            {
                "dimension": "symbol::failure-behavior",
                "name": "symbol",
                "question": "failure-behavior",
                "profiles": ["Core"],
                "caseIds": ["decided-case"],
                "status": "covered",
            }
        ],
    }
    manifest = {
        "schema": "BeagleConformanceCorpusV1",
        "cases": [
            {
                "caseId": "decided-case",
                "path": "corpus/decided/decided-case.json",
                "status": "DECIDED",
            }
        ],
    }
    payload = {
        "schema": "BeagleConformanceCaseV1",
        "caseId": "decided-case",
        "status": "DECIDED",
        "decision": {"authority": "language-contract-authority"},
        "expected": {"kind": "named-diagnostic"},
    }
    return coverage, manifest, payload


def run_fixture(coverage: dict, manifest: dict, payload: dict) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory(prefix="beagle-divergence-coverage-") as raw:
        root = Path(raw)
        case_dir = root / "corpus" / "decided"
        case_dir.mkdir(parents=True)
        coverage_path = root / "divergence-coverage.json"
        manifest_path = root / "manifest.json"
        coverage_path.write_text(json.dumps(coverage), encoding="utf-8")
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        (case_dir / "decided-case.json").write_text(json.dumps(payload), encoding="utf-8")
        return subprocess.run(
            [
                "python3",
                str(VERIFIER),
                "--coverage",
                str(coverage_path),
                "--manifest",
                str(manifest_path),
            ],
            text=True,
            capture_output=True,
            check=False,
        )


class VerifyDivergenceCoverageTest(unittest.TestCase):
    def test_valid_fixture(self) -> None:
        result = run_fixture(*baseline())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejection_reasons(self) -> None:
        def unresolved(coverage: dict, manifest: dict, payload: dict) -> None:
            coverage["rows"][0]["status"] = "unresolved"

        def duplicate(coverage: dict, manifest: dict, payload: dict) -> None:
            coverage["rows"].append(copy.deepcopy(coverage["rows"][0]))

        def absent_case(coverage: dict, manifest: dict, payload: dict) -> None:
            coverage["rows"][0]["caseIds"] = ["absent-case"]

        def not_decided(coverage: dict, manifest: dict, payload: dict) -> None:
            manifest["cases"][0]["status"] = "DRAFT"

        def implementation_only(coverage: dict, manifest: dict, payload: dict) -> None:
            payload["evidenceAuthority"] = "IMPLEMENTATION_OBSERVED_ONLY"

        def no_evidence(coverage: dict, manifest: dict, payload: dict) -> None:
            coverage["rows"][0]["caseIds"] = []

        cases = [
            ("UNRESOLVED_QUESTION_DIMENSION", unresolved),
            ("DUPLICATE_DIMENSION", duplicate),
            ("CASE_NOT_IN_MANIFEST", absent_case),
            ("CASE_NOT_DECIDED", not_decided),
            ("IMPLEMENTATION_OBSERVED_ONLY_EVIDENCE", implementation_only),
            ("COVERED_WITHOUT_CASE_EVIDENCE", no_evidence),
        ]
        for reason, mutate in cases:
            with self.subTest(reason=reason):
                coverage, manifest, payload = baseline()
                mutate(coverage, manifest, payload)
                result = run_fixture(coverage, manifest, payload)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f"{reason}:", result.stderr)


if __name__ == "__main__":
    unittest.main()
