#!/usr/bin/env python3
"""Verify the authority and content addresses of a Beagle corpus manifest."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


class ManifestViolation(ValueError):
    """A stable, named conformance-manifest rejection."""

    def __init__(self, reason, detail):
        super().__init__(detail)
        self.reason = reason


def reject(reason, detail):
    raise ManifestViolation(reason, detail)


def read_json(path):
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except json.JSONDecodeError as error:
        reject("INVALID_JSON", "{}: {}".format(path, error))


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def validate_coverage_labels(entry, case_id):
    labels = entry.get("coverage")
    if not isinstance(labels, list) or not labels:
        reject("MISSING_COVERAGE_LABELS", case_id + " has no coverage labels")
    for label in labels:
        if not nonempty_string(label):
            reject("MISSING_COVERAGE_LABELS", case_id + " has an empty coverage label")
        if re.search(r"(?:^|[-_ ])(?:TODO|TBD|UNKNOWN|UNRESOLVED|PENDING)(?:$|[-_ ])",
                     label, re.IGNORECASE):
            reject("UNRESOLVED_COVERAGE_LABEL", case_id + " has unresolved label " + label)


def implementation_observed_only(expected):
    provenance_keys = {
        "authority",
        "basis",
        "derivedfrom",
        "origin",
        "provenance",
        "source",
    }

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                normalized_key = re.sub(r"[^a-z]", "", str(key).lower())
                if normalized_key in provenance_keys and isinstance(child, str):
                    normalized_value = re.sub(r"[^a-z]", " ", child.lower())
                    words = set(normalized_value.split())
                    if "observed" in words or (
                        "implementation" in words
                        and words.intersection({"agreement", "observed", "output"})
                    ):
                        return True
                if walk(child):
                    return True
        elif isinstance(value, list):
            return any(walk(child) for child in value)
        return False

    return walk(expected)


def validate_case(case, entry):
    case_id = entry["caseId"]
    if case.get("caseId") != case_id:
        reject("CASE_ID_MISMATCH", case_id + " does not match its payload caseId")
    if entry.get("status") != "DECIDED" or case.get("status") != "DECIDED":
        reject("CASE_NOT_DECIDED", case_id + " is not DECIDED")

    rule = case.get("rule")
    if not isinstance(rule, dict) or not nonempty_string(rule.get("id")) or not nonempty_string(
        rule.get("text")
    ):
        reject("MISSING_DECIDED_RULE", case_id + " has no decided rule")
    if not nonempty_string(rule.get("reference")):
        reject("MISSING_RULE_REFERENCE", case_id + " has no decided-rule reference")

    expected = case.get("expected")
    if not isinstance(expected, dict) or not nonempty_string(expected.get("kind")) or not any(
        value not in (None, "", [], {}) for key, value in expected.items() if key != "kind"
    ):
        reject("MISSING_EXPECTED_ASSERTION", case_id + " has no expected assertion")
    if implementation_observed_only(expected):
        reject(
            "IMPLEMENTATION_OBSERVED_ONLY",
            case_id + " derives its expected assertion only from observed implementation output",
        )

    decision = case.get("decision")
    if not isinstance(decision, dict) or not nonempty_string(decision.get("owner")):
        reject("MISSING_DECISION_OWNER", case_id + " has no decision owner")
    if not nonempty_string(decision.get("reviewer")):
        reject("MISSING_DECISION_REVIEWER", case_id + " has no decision reviewer")


def validate_required_coverage(manifest, entries_by_id):
    required = manifest.get("requiredCoverage")
    if not isinstance(required, dict):
        required = {}
    families = (
        ("alarmBell", "ALARM-BELL", "MISSING_REQUIRED_ALARM_BELL_COVERAGE"),
        ("hostLeakage", "HOST-LEAKAGE", "MISSING_REQUIRED_HOST_LEAKAGE_COVERAGE"),
    )
    for field, label, reason in families:
        required_ids = required.get(field)
        if not isinstance(required_ids, list) or not required_ids:
            reject(reason, "requiredCoverage.{} is empty".format(field))
        required_set = set(required_ids)
        tagged_set = {
            case_id
            for case_id, entry in entries_by_id.items()
            if label in entry.get("coverage", [])
        }
        if required_set != tagged_set or any(
            case_id not in entries_by_id for case_id in required_set
        ):
            reject(
                reason,
                "requiredCoverage.{} does not match {} cases".format(field, label),
            )


def verify_manifest(manifest_path):
    manifest_path = Path(manifest_path)
    manifest = read_json(manifest_path)
    if manifest.get("schema") != "BeagleConformanceCorpusV1":
        reject("UNSUPPORTED_MANIFEST_SCHEMA", "manifest schema is not BeagleConformanceCorpusV1")
    if manifest.get("digestAlgorithm") != "sha256":
        reject("UNSUPPORTED_DIGEST_ALGORITHM", "manifest digestAlgorithm is not sha256")
    entries = manifest.get("cases")
    if not isinstance(entries, list):
        reject("MALFORMED_CASE_LIST", "manifest cases is not a list")

    entries_by_id = {}
    for entry in entries:
        if not isinstance(entry, dict) or not nonempty_string(entry.get("caseId")):
            reject("MALFORMED_CASE_ENTRY", "manifest has an entry without a caseId")
        case_id = entry["caseId"]
        if case_id in entries_by_id:
            reject("DUPLICATE_CASE_ID", "manifest repeats caseId " + case_id)
        entries_by_id[case_id] = entry

    for case_id, entry in entries_by_id.items():
        validate_coverage_labels(entry, case_id)
        declared_path = entry.get("path")
        if not nonempty_string(declared_path):
            reject("DECLARED_PATH_MISSING", case_id + " has no declared path")
        payload_path = manifest_path.parent / declared_path
        if not payload_path.is_file():
            reject("DECLARED_PATH_MISSING", case_id + " path does not exist: " + declared_path)
        declared_digest = entry.get("sha256")
        if not nonempty_string(declared_digest):
            reject("MISSING_PAYLOAD_SHA256", case_id + " has no sha256")
        actual_digest = digest(payload_path)
        if declared_digest != actual_digest:
            reject(
                "PAYLOAD_SHA256_MISMATCH",
                "{} sha256 is {}, manifest declares {}".format(
                    case_id, actual_digest, declared_digest
                ),
            )
        validate_case(read_json(payload_path), entry)

    validate_required_coverage(manifest, entries_by_id)
    return len(entries)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        count = verify_manifest(args.manifest)
    except (ManifestViolation, OSError) as error:
        reason = getattr(error, "reason", "MANIFEST_IO_ERROR")
        print("verify-manifest: {}: {}".format(reason, error), file=sys.stderr)
        return 1
    print("verify-manifest: PASS {} cases".format(count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
