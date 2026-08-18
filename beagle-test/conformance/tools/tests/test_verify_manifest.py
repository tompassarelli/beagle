import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


VERIFIER_PATH = Path(__file__).parents[1] / "verify-manifest.py"
SPEC = importlib.util.spec_from_file_location("verify_manifest", VERIFIER_PATH)
VERIFY_MANIFEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_MANIFEST)


class VerifyManifestTest(unittest.TestCase):
    def base_case(self):
        return {
            "schema": "BeagleConformanceCaseV1",
            "corpusVersion": 1,
            "caseId": "case-one",
            "status": "DECIDED",
            "rule": {
                "id": "RULE-ONE",
                "text": "The decided semantic rule.",
                "reference": "authority.md#rule-one",
            },
            "expected": {"kind": "named-assertion", "assertion": "decided result"},
            "coverage": {"hostLeakage": ["RULE-ONE"]},
            "decision": {"owner": "owner", "reviewer": "reviewer"},
        }

    def write_fixture(self, root, case, mutate_manifest=None, write_payload=True):
        payload_path = root / "corpus" / "decided" / "case-one.json"
        payload_path.parent.mkdir(parents=True)
        payload_bytes = (json.dumps(case, sort_keys=True) + "\n").encode()
        if write_payload:
            payload_path.write_bytes(payload_bytes)
        entry = {
            "caseId": "case-one",
            "path": "corpus/decided/case-one.json",
            "status": "DECIDED",
            "sha256": hashlib.sha256(payload_bytes).hexdigest(),
            "coverage": ["ALARM-BELL", "HOST-LEAKAGE"],
        }
        manifest = {
            "schema": "BeagleConformanceCorpusV1",
            "version": 1,
            "digestAlgorithm": "sha256",
            "cases": [entry],
            "requiredCoverage": {
                "alarmBell": ["case-one"],
                "hostLeakage": ["case-one"],
            },
        }
        if mutate_manifest:
            mutate_manifest(manifest)
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return manifest_path

    def test_rejects_each_inadmissible_case_with_distinct_reason(self):
        def remove_rule(case):
            case.pop("rule")

        def remove_rule_reference(case):
            case["rule"].pop("reference")

        def remove_expected(case):
            case.pop("expected")

        def remove_owner(case):
            case["decision"].pop("owner")

        def remove_reviewer(case):
            case["decision"].pop("reviewer")

        def observed_only(case):
            case["expected"]["basis"] = "implementation-observed-output"

        def manifest_status(manifest):
            manifest["cases"][0]["status"] = "PROPOSED"

        def missing_labels(manifest):
            manifest["cases"][0]["coverage"] = []

        def unresolved_labels(manifest):
            manifest["cases"][0]["coverage"] = ["ALARM-BELL", "TBD"]

        def duplicate_id(manifest):
            manifest["cases"].append(copy.deepcopy(manifest["cases"][0]))

        def bad_digest(manifest):
            manifest["cases"][0]["sha256"] = "0" * 64

        def missing_alarm_bell(manifest):
            manifest["requiredCoverage"]["alarmBell"] = []

        def missing_host_leakage(manifest):
            manifest["requiredCoverage"]["hostLeakage"] = []

        cases = [
            ("CASE_NOT_DECIDED", lambda case: case.update(status="PROPOSED"), None, True),
            ("MISSING_DECIDED_RULE", remove_rule, None, True),
            ("MISSING_RULE_REFERENCE", remove_rule_reference, None, True),
            ("MISSING_EXPECTED_ASSERTION", remove_expected, None, True),
            ("MISSING_DECISION_OWNER", remove_owner, None, True),
            ("MISSING_DECISION_REVIEWER", remove_reviewer, None, True),
            ("MISSING_COVERAGE_LABELS", None, missing_labels, True),
            ("UNRESOLVED_COVERAGE_LABEL", None, unresolved_labels, True),
            ("DUPLICATE_CASE_ID", None, duplicate_id, True),
            ("PAYLOAD_SHA256_MISMATCH", None, bad_digest, True),
            ("DECLARED_PATH_MISSING", None, None, False),
            ("IMPLEMENTATION_OBSERVED_ONLY", observed_only, None, True),
            ("MISSING_REQUIRED_ALARM_BELL_COVERAGE", None, missing_alarm_bell, True),
            ("MISSING_REQUIRED_HOST_LEAKAGE_COVERAGE", None, missing_host_leakage, True),
        ]
        self.assertEqual(len(cases), len({reason for reason, *_ in cases}))
        for reason, mutate_case, mutate_manifest, write_payload in cases:
            with self.subTest(reason=reason):
                with tempfile.TemporaryDirectory(prefix="beagle-manifest-test-") as temp:
                    case = self.base_case()
                    if mutate_case:
                        mutate_case(case)
                    manifest_path = self.write_fixture(
                        Path(temp), case, mutate_manifest, write_payload=write_payload
                    )
                    with self.assertRaises(VERIFY_MANIFEST.ManifestViolation) as raised:
                        VERIFY_MANIFEST.verify_manifest(manifest_path)
                    self.assertEqual(reason, raised.exception.reason)


if __name__ == "__main__":
    unittest.main()
