import importlib.util
import json
import unittest
from pathlib import Path


CONFORMANCE = Path(__file__).resolve().parents[2]
CLASSIFIER_PATH = CONFORMANCE / "tools" / "classify-divergence.py"
SPEC = importlib.util.spec_from_file_location("classify_divergence", CLASSIFIER_PATH)
CLASSIFIER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CLASSIFIER)


class ClassifyDivergenceTest(unittest.TestCase):
    def test_known_bucket_examples(self):
        examples = [
            (
                {
                    "dimension": "symbol::failure-behavior",
                    "name": "symbol",
                    "question": "failure-behavior",
                    "profiles": ["Core", "Hosted JavaScript"],
                    "status": "covered",
                    "caseIds": ["hl-symbol-behavior-core"],
                },
                "DECIDED-AND-ENUMERATED",
            ),
            (
                {
                    "dimension": "-::evaluation-order",
                    "name": "-",
                    "question": "evaluation-order",
                    "profiles": ["Core", "Hosted JavaScript"],
                    "status": "uncovered",
                    "caseIds": [],
                },
                "DECIDED-NOT-ENUMERATED",
            ),
            (
                {
                    "dimension": "zipmap::failure-behavior",
                    "name": "zipmap",
                    "question": "failure-behavior",
                    "profiles": ["Core", "Hosted JavaScript"],
                    "status": "uncovered",
                    "caseIds": [],
                },
                "UNDECIDED",
            ),
        ]
        for row, expected in examples:
            with self.subTest(dimension=row["dimension"]):
                self.assertEqual(CLASSIFIER.classify_row(row)["bucket"], expected)

    def test_full_inventory_is_partitioned_once(self):
        with (CONFORMANCE / "divergence-coverage.json").open(encoding="utf-8") as handle:
            coverage = json.load(handle)
        with (CONFORMANCE / "manifest.json").open(encoding="utf-8") as handle:
            manifest = json.load(handle)
        artifact = CLASSIFIER.build_artifact(coverage, manifest)
        counts = artifact["summary"]["buckets"]
        dimensions = [row["dimension"] for row in artifact["rows"]]

        self.assertEqual(len(dimensions), 2062)
        self.assertEqual(len(dimensions), len(set(dimensions)))
        self.assertEqual(sum(counts.values()), 2062)
        self.assertEqual(set(counts), {
            "DECIDED-AND-ENUMERATED",
            "DECIDED-NOT-ENUMERATED",
            "UNDECIDED",
        })


if __name__ == "__main__":
    unittest.main()
