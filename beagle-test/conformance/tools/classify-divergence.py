#!/usr/bin/env python3
"""Classify host-leakage divergence dimensions against the decided rules."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


QUESTIONS = (
    "effects",
    "identity-equality",
    "strictness-laziness",
    "evaluation-order",
    "allocation-representation",
    "failure-behavior",
)
ALL_QUESTIONS = frozenset(QUESTIONS)

RULE_DOCUMENT = (
    "beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md"
)


def mapping(
    mapping_id: str,
    rule_id: str,
    section: str,
    clauses: list[str],
    family: str,
    names: list[str],
    questions: set[str] | frozenset[str],
    rationale: str,
) -> dict[str, Any]:
    return {
        "mappingId": mapping_id,
        "ruleId": rule_id,
        "reference": f"{RULE_DOCUMENT}#{section}",
        "clauses": clauses,
        "family": family,
        "names": names,
        "questions": sorted(questions),
        "rationale": rationale,
    }


# This is deliberately an allowlist. A builtin/question pair is decided only
# when one of these entries identifies rule text that fixes that exact concern.
# Similar spelling, shared implementation, and a rule's demand for a future
# contract are not classification evidence.
MAPPING_RULES = [
    mapping(
        "number-checked-arithmetic",
        "HL-NUMBER-SEMANTICS",
        "1-hl-number-semantics",
        ["DECIDED rule 1", "DECIDED rule 2", "Contract closure"],
        "checked Int and mixed numeric arithmetic",
        ["+", "-", "*", "/", "inc", "dec", "quot", "rem", "mod"],
        ALL_QUESTIONS,
        "The rule names these operations, their evaluation and failure order, "
        "and closes strictness, purity, representation, and identity for numeric primitives.",
    ),
    mapping(
        "number-float-order",
        "HL-NUMBER-SEMANTICS",
        "1-hl-number-semantics",
        ["DECIDED rule 3", "Contract closure"],
        "ordered Float predicates",
        ["<", "<=", ">", ">="],
        ALL_QUESTIONS,
        "The rule fixes ordered-predicate NaN results and the numeric-primitive closure "
        "fixes the remaining five questions.",
    ),
    mapping(
        "number-explicit-conversions",
        "HL-NUMBER-SEMANTICS",
        "1-hl-number-semantics",
        ["DECIDED rule 3", "DECIDED rule 4", "Contract closure"],
        "explicit numeric conversions and bit codecs",
        ["long", "double", "float-from-bits", "float-to-bits"],
        ALL_QUESTIONS,
        "Float/Int conversion and canonical Float-bit behavior are fixed explicitly; "
        "the numeric-primitive closure supplies strictness, order, purity, and identity.",
    ),
    mapping(
        "number-parser",
        "HL-NUMBER-SEMANTICS",
        "1-hl-number-semantics",
        ["DECIDED rule 7", "Contract closure"],
        "strict numeric parser",
        ["parse-double"],
        ALL_QUESTIONS,
        "The accepted grammar, complete consumption, range result, and absence result are "
        "fixed, with the numeric-primitive closure governing the other questions.",
    ),
    mapping(
        "equality-operations",
        "HL-EQUALITY-HASHING",
        "2-hl-equality-hashing",
        ["DECIDED rules 1-6"],
        "semantic equality, identity, and hashing operations",
        ["=", "hash", "identical?"],
        ALL_QUESTIONS,
        "The rule defines domains, results, rejections, evaluation order, purity, "
        "observable identity, representation independence, and allocation behavior.",
    ),
    mapping(
        "equality-collection-admission",
        "HL-EQUALITY-HASHING",
        "2-hl-equality-hashing",
        ["DECIDED rule 3"],
        "Map/Set admission operations",
        ["assoc", "conj", "hash-map", "hash-set", "set"],
        {"failure-behavior"},
        "NaN and other unhashable values have the named BEAGLE-UNHASHABLE-VALUE "
        "admission failure for Map/Set uses of these operations.",
    ),
    mapping(
        "symbol-constructor",
        "HL-SYMBOL-BEHAVIOR",
        "3-hl-symbol-behavior",
        ["DECIDED rules 1-3", "DECIDED rule 5"],
        "regular Symbol construction",
        ["symbol"],
        ALL_QUESTIONS,
        "The constructor's decomposition, value identity, representation, canonical form, "
        "Unicode failure, purity, and lack of observable allocation identity are explicit.",
    ),
    mapping(
        "symbol-generated",
        "HL-SYMBOL-BEHAVIOR",
        "3-hl-symbol-behavior",
        ["DECIDED rules 4-5"],
        "generated Symbol construction",
        ["gensym"],
        {
            "allocation-representation",
            "effects",
            "evaluation-order",
            "identity-equality",
            "strictness-laziness",
        },
        "Generated symbols have explicit origin/ordinal identity, left-to-right FreshName "
        "effects, tagged representation, and eager inputs; no gensym failure is decided.",
    ),
    mapping(
        "symbol-observers",
        "HL-SYMBOL-BEHAVIOR",
        "3-hl-symbol-behavior",
        ["DECIDED rules 1-2"],
        "Symbol part access and comparison",
        ["name", "namespace", "compare"],
        {"identity-equality"},
        "The rule fixes the returned textual parts and Symbol comparison, but does not "
        "claim unrelated operational questions for these broadly typed builtins.",
    ),
    mapping(
        "truthiness-forms",
        "HL-TRUTHINESS",
        "4-hl-truthiness",
        ["DECIDED rules 1-4"],
        "truth testing and short-circuit forms",
        ["if", "when", "cond", "boolean", "not", "and", "or"],
        ALL_QUESTIONS,
        "The truth table, operand identity, short-circuit order, purity, allocation-free "
        "implementation, strictness boundary, and foreign-value failure are explicit.",
    ),
    mapping(
        "collection-traversal",
        "HL-COLLECTION-ORDERING",
        "5-hl-collection-ordering",
        ["DECIDED rules 1-2", "DECIDED rule 5"],
        "named ordered collection traversal",
        ["seq", "keys", "vals", "map", "filter", "reduce", "reduce-kv"],
        {"allocation-representation", "evaluation-order", "strictness-laziness"},
        "The rule names these traversals, fixes their order independent of representation, "
        "and states that consumed elements are strict.",
    ),
    mapping(
        "collection-callback-effects",
        "HL-COLLECTION-ORDERING",
        "5-hl-collection-ordering",
        ["DECIDED rule 2"],
        "ordered collection callbacks",
        ["map", "filter", "reduce", "reduce-kv"],
        {"effects"},
        "Each callback completes before the next begins in the declared traversal order.",
    ),
    mapping(
        "collection-persistent-updates",
        "HL-COLLECTION-ORDERING",
        "5-hl-collection-ordering",
        ["DECIDED rules 1-2", "DECIDED rule 5"],
        "Map/Set insertion, replacement, and deletion operations",
        ["assoc", "dissoc", "conj", "disj"],
        {"allocation-representation", "evaluation-order", "strictness-laziness"},
        "The rule fixes insertion positions, replacement/deletion/reinsertion order, "
        "persistent-update representation independence, and strict consumption.",
    ),
    mapping(
        "collection-constructors",
        "HL-COLLECTION-ORDERING",
        "5-hl-collection-ordering",
        ["DECIDED rule 1", "DECIDED rule 5"],
        "ordered collection construction",
        ["list", "vector", "array-map", "hash-map", "hash-set", "set"],
        {"allocation-representation", "evaluation-order", "strictness-laziness"},
        "List/Vec authored order and Map/Set left-to-right insertion order are fixed, "
        "strict, and independent of the host collection representation.",
    ),
    mapping(
        "collection-stable-sort",
        "HL-COLLECTION-ORDERING",
        "5-hl-collection-ordering",
        ["DECIDED rules 4-5"],
        "stable sorting",
        ["sort"],
        {
            "allocation-representation",
            "effects",
            "evaluation-order",
            "failure-behavior",
            "strictness-laziness",
        },
        "Stable results, strict consumption, representation independence, and the named "
        "total-order/effectful-comparator rejections are explicit.",
    ),
    mapping(
        "ownership-promotion",
        "HL-NATIVE-CORE-GC-OWNERSHIP",
        "6-hl-native-core-gc-ownership",
        ["DECIDED rules 2-4", "DECIDED rule 6"],
        "explicit region promotion",
        ["bgl/promote"],
        ALL_QUESTIONS,
        "Promotion has explicit deep-copy representation and identity, eager left-to-right "
        "allocation effects, strictness, and named promotion/escape failures.",
    ),
    mapping(
        "macro-sequential-evaluation",
        "HL-HOST-MACRO-EXPANSION",
        "7-hl-host-macro-expansion",
        ["DECIDED rule 1", "DECIDED rule 5", "DECIDED rule 7"],
        "macro-evaluator sequencing forms",
        ["do", "let"],
        {
            "allocation-representation",
            "effects",
            "evaluation-order",
            "strictness-laziness",
        },
        "Within macro evaluation, bodies and sequential bindings are eager and left-to-right, "
        "the phase is pure, and allocation is confined to compile-time syntax and values.",
    ),
    mapping(
        "explicit-nondeterminism",
        "HL-UNSPECIFIED-BEHAVIOR-AS-SPEC",
        "8-hl-unspecified-behavior-as-spec",
        ["Status and authority", "DECIDED rule 3"],
        "entropy, UUID, shuffle, time, and concurrency operations",
        [
            "rand",
            "rand-int",
            "rand-nth",
            "random-sample",
            "random-uuid",
            "shuffle",
            "monotonic-nanoseconds",
            "await",
        ],
        {"effects", "evaluation-order", "strictness-laziness"},
        "These named nondeterministic families require explicit capabilities/providers and "
        "use the document-wide eager, left-to-right rule. The rule only requires future "
        "failure/result/ownership contracts, so those questions remain UNDECIDED here.",
    ),
]


def governing_rules(name: str, question: str) -> list[dict[str, Any]]:
    governed = []
    for item in MAPPING_RULES:
        if name in item["names"] and question in item["questions"]:
            governed.append(
                {
                    "mappingId": item["mappingId"],
                    "ruleId": item["ruleId"],
                    "reference": item["reference"],
                    "clauses": item["clauses"],
                }
            )
    return governed


def classify_row(row: dict[str, Any]) -> dict[str, Any]:
    rules = governing_rules(row["name"], row["question"])
    if not rules:
        bucket = "UNDECIDED"
    elif row["status"] == "covered":
        bucket = "DECIDED-AND-ENUMERATED"
    else:
        bucket = "DECIDED-NOT-ENUMERATED"

    result = {
        "dimension": row["dimension"],
        "builtin": row["name"],
        "question": row["question"],
        "profiles": row["profiles"],
        "bucket": bucket,
    }
    if rules:
        result["governingRules"] = rules
    if bucket == "DECIDED-AND-ENUMERATED":
        result["caseIds"] = row["caseIds"]
    return result


def build_artifact(coverage: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    declared_cases = {
        case["caseId"] for case in manifest["cases"] if case["status"] == "DECIDED"
    }
    rows = [classify_row(row) for row in coverage["rows"]]

    dimensions = [row["dimension"] for row in rows]
    if len(dimensions) != len(set(dimensions)):
        raise ValueError("coverage contains duplicate dimensions")
    if len(rows) != coverage["summary"]["dimensions"]:
        raise ValueError("classification row count does not match coverage summary")

    enumerated = [
        row for row in rows if row["bucket"] == "DECIDED-AND-ENUMERATED"
    ]
    for row in enumerated:
        unknown = set(row["caseIds"]) - declared_cases
        if unknown:
            raise ValueError(
                f"{row['dimension']} cites undeclared decided cases: {sorted(unknown)}"
            )

    counts = {
        bucket: sum(row["bucket"] == bucket for row in rows)
        for bucket in (
            "DECIDED-AND-ENUMERATED",
            "DECIDED-NOT-ENUMERATED",
            "UNDECIDED",
        )
    }
    if sum(counts.values()) != len(rows):
        raise ValueError("classification buckets do not partition all dimensions")

    return {
        "schema": "BeagleDivergenceClassificationV1",
        "version": 1,
        "sources": {
            "coverage": "beagle-test/conformance/divergence-coverage.json",
            "manifest": "beagle-test/conformance/manifest.json",
            "decidedRules": RULE_DOCUMENT,
        },
        "classificationPolicy": {
            "principle": (
                "Allowlist only: a rule governs a dimension only when its text fixes that "
                "builtin (or the explicitly named family containing it) and that question. "
                "Loose keyword similarity and requirements for a future contract do not count."
            ),
            "enumerationCriterion": (
                "A governed dimension is DECIDED-AND-ENUMERATED only when the banked coverage "
                "artifact marks it covered across every inventory profile; otherwise it is "
                "DECIDED-NOT-ENUMERATED."
            ),
            "uncertaintyRule": (
                "If the decided text does not fix the builtin/question pair, classify it "
                "UNDECIDED."
            ),
            "mappingRules": MAPPING_RULES,
        },
        "summary": {"dimensions": len(rows), "buckets": counts},
        "rows": rows,
    }


def parse_args() -> argparse.Namespace:
    conformance = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--coverage",
        type=Path,
        default=conformance / "divergence-coverage.json",
    )
    parser.add_argument(
        "--manifest", type=Path, default=conformance / "manifest.json"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=conformance / "divergence-classification.json",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with args.coverage.open(encoding="utf-8") as handle:
        coverage = json.load(handle)
    with args.manifest.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    artifact = build_artifact(coverage, manifest)
    args.output.write_text(
        json.dumps(artifact, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    counts = artifact["summary"]["buckets"]
    print(
        f"{artifact['summary']['dimensions']} dimensions: "
        f"DECIDED-AND-ENUMERATED={counts['DECIDED-AND-ENUMERATED']}, "
        f"DECIDED-NOT-ENUMERATED={counts['DECIDED-NOT-ENUMERATED']}, "
        f"UNDECIDED={counts['UNDECIDED']}"
    )


if __name__ == "__main__":
    main()
