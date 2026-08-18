#!/usr/bin/env python3
"""Turn selfhost-daily shadow divergences into adjudication drafts."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def first(record, *names):
    for name in names:
        if name in record:
            return record[name]
    return None


def load_records(path):
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return []
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = [json.loads(line) for line in text.splitlines() if line.strip()]
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list) and all(isinstance(item, dict) for item in value):
        return value
    raise ValueError("inbox must contain one object, an array, or JSON Lines")


def require(record, name, value):
    if value is None or value == "":
        raise ValueError("record is missing " + name)
    return value


def safe_id(input_hash):
    token = re.sub(r"[^a-zA-Z0-9]+", "-", input_hash).strip("-").lower()
    if not token:
        token = hashlib.sha256(input_hash.encode("utf-8")).hexdigest()
    return token[:48]


def make_draft(record):
    input_hash = require(record, "inputHash", first(record, "inputHash", "input_hash"))
    inputs = first(record, "input", "request")
    outputs = first(record, "outputs", "shadowDiff")
    if outputs is None:
        outputs = {
            "native": first(record, "native", "stage0", "nativeOutput"),
            "oracle": first(record, "oracle", "racket", "oracleOutput", "racketOutput"),
        }
    outputs = require(record, "outputs", outputs)
    if not isinstance(outputs, dict):
        raise ValueError("record outputs must be an object")
    native = first(outputs, "native", "stage0", "nativeOutput")
    oracle = first(outputs, "oracle", "racket", "oracleOutput", "racketOutput")
    if native is None or oracle is None:
        raise ValueError("record outputs must contain native and racket/oracle")

    return {
        "schema": "BeagleConformanceCaseV1",
        "corpusVersion": 1,
        "caseId": "draft-shadow-divergence-" + safe_id(str(input_hash)),
        "status": "IMPLEMENTATION-OBSERVED",
        "inputHash": input_hash,
        "profile": first(record, "profile", "profileId") or "unspecified",
        "input": inputs if inputs is not None else {"inputHash": input_hash},
        "rule": {
            "id": "PENDING-ADJUDICATION",
            "text": "No semantic rule has been decided for this implementation divergence.",
            "reference": None,
        },
        "expected": {
            "kind": "pending-adjudication",
            "reason": "Neither implementation output is authoritative by itself.",
        },
        "coverage": {
            "surface": [],
            "alarmBell": None,
            "hostLeakage": [],
            "parityChannels": ["status", "diagnostic", "artifact"],
        },
        "decision": {
            "owner": None,
            "reviewer": None,
            "reference": None,
            "date": None,
        },
        "observations": {
            "source": "selfhost-daily-shadow-diff",
            "inputHash": input_hash,
            "native": native,
            "oracle": oracle,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inbox", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    try:
        records = load_records(args.inbox)
        args.out_dir.mkdir(parents=True, exist_ok=True)
        for record in records:
            draft = make_draft(record)
            destination = args.out_dir / (draft["caseId"] + ".json")
            if destination.exists() and not args.force:
                raise ValueError("draft already exists: " + str(destination))
            destination.write_text(
                json.dumps(draft, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            print("DRAFT " + str(destination))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("harvest-divergence: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
