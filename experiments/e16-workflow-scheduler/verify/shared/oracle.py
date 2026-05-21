#!/usr/bin/env python3
"""Shared behavioral oracle for the E16 workflow scheduler.

Feeds JSON test cases to any scheduler binary via stdin, validates output.
Language-agnostic: works with Beagle and Python implementations.

Usage:
    python oracle.py --cmd "python -m python"
    python oracle.py --cmd "./scheduler"
    python oracle.py --cmd "bb -m beagle.main"

Exit codes:
    0 — all cases passed
    1 — at least one case failed
    2 — usage / setup error
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


CASES_FILE = Path(__file__).parent / "cases.json"


@dataclass
class Failure:
    case_name: str
    field: str
    expected: Any
    actual: Any

    def __str__(self) -> str:
        return f"  {self.field}: expected {_fmt(self.expected)}, got {_fmt(self.actual)}"


@dataclass
class CaseResult:
    name: str
    category: str
    passed: bool
    failures: list[Failure] = field(default_factory=list)
    error: str | None = None
    duration_ms: int = 0


def _fmt(v: Any) -> str:
    if isinstance(v, str):
        return repr(v)
    return json.dumps(v, separators=(",", ":"))


def run_scheduler(cmd: str, input_json: dict, timeout: int = 30) -> dict | str:
    """Run scheduler binary with JSON stdin. Returns parsed output or error string."""
    try:
        proc = subprocess.run(
            cmd,
            shell=True,
            input=json.dumps(input_json),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return f"timeout after {timeout}s"
    except FileNotFoundError:
        return f"command not found: {cmd}"

    if proc.returncode != 0 and not proc.stdout.strip():
        stderr = proc.stderr.strip()[:200]
        return f"exit {proc.returncode}: {stderr}"

    stdout = proc.stdout.strip()
    if not stdout:
        return "empty stdout"

    try:
        return json.loads(stdout)
    except json.JSONDecodeError as e:
        return f"invalid JSON: {e} — got: {stdout[:200]}"


def _get(obj: dict, path: str) -> Any:
    """Get nested value by dot path: 'assignments.0.task_id'."""
    parts = path.split(".")
    current = obj
    for part in parts:
        if isinstance(current, list):
            try:
                current = current[int(part)]
            except (IndexError, ValueError):
                return _MISSING
        elif isinstance(current, dict):
            if part not in current:
                return _MISSING
            current = current[part]
        else:
            return _MISSING
    return current


_MISSING = object()


def check_status(output: dict, expect: dict) -> list[Failure]:
    """Check status field."""
    failures = []
    if "status" in expect:
        actual_status = output.get("status")
        if actual_status != expect["status"]:
            failures.append(Failure("", "status", expect["status"], actual_status))
    return failures


def check_assignments(
    case_name: str, output: dict, expect: dict
) -> list[Failure]:
    """Check assignment count and individual assignment fields.

    If assignment_count is set, enforce exact count.
    If assignments is set without assignment_count, check only the listed
    assignments (partial match — other assignments may exist).
    If both are set, enforce count AND check listed assignments.
    """
    failures = []
    actual_assignments = output.get("assignments", [])

    if "assignment_count" in expect:
        if len(actual_assignments) != expect["assignment_count"]:
            failures.append(Failure(
                case_name, "assignment_count",
                expect["assignment_count"], len(actual_assignments),
            ))
            return failures

    if "assignments" not in expect:
        return failures

    expected = expect["assignments"]

    partial = expect.get("assignments_partial", False)
    if not partial and "assignment_count" not in expect and len(expected) != len(actual_assignments):
        failures.append(Failure(
            case_name, "assignment_count",
            len(expected), len(actual_assignments),
        ))
        return failures

    actual_by_task = {a["task_id"]: a for a in actual_assignments}
    for i, exp_a in enumerate(expected):
        if "task_id" not in exp_a:
            continue
        tid = exp_a["task_id"]
        actual_a = actual_by_task.get(tid)
        if actual_a is None:
            failures.append(Failure(
                case_name, f"assignments[task_id={tid}]",
                "present", "missing",
            ))
            continue
        for k, v in exp_a.items():
            if actual_a.get(k) != v:
                failures.append(Failure(
                    case_name, f"assignments[task_id={tid}].{k}",
                    v, actual_a.get(k),
                ))
    return failures


def check_failures_field(
    case_name: str, output: dict, expect: dict
) -> list[Failure]:
    """Check failure count, failure types, and specific failure fields."""
    failures = []
    actual_failures = output.get("failures", [])

    if "failure_count" in expect:
        if len(actual_failures) != expect["failure_count"]:
            failures.append(Failure(
                case_name, "failure_count",
                expect["failure_count"], len(actual_failures),
            ))

    if "has_failure_type" in expect:
        actual_types = set()
        for f in actual_failures:
            reason = f.get("reason", {})
            if isinstance(reason, dict):
                actual_types.add(reason.get("type", ""))
            elif isinstance(reason, str):
                actual_types.add(reason)
        for ft in expect["has_failure_type"]:
            if ft not in actual_types:
                failures.append(Failure(
                    case_name, f"has_failure_type",
                    ft, sorted(actual_types),
                ))

    if "failure_task_ids" in expect:
        actual_ids = sorted({f.get("task_id", "") for f in actual_failures})
        expected_ids = sorted(expect["failure_task_ids"])
        if actual_ids != expected_ids:
            failures.append(Failure(
                case_name, "failure_task_ids",
                expected_ids, actual_ids,
            ))

    return failures


def check_ordering(
    case_name: str, output: dict, expect: dict
) -> list[Failure]:
    """Check assignment ordering constraints."""
    failures = []
    assignments = output.get("assignments", [])

    if expect.get("assignments_sorted_by_start_then_id"):
        for i in range(len(assignments) - 1):
            a, b = assignments[i], assignments[i + 1]
            key_a = (a.get("start_time", 0), a.get("task_id", ""))
            key_b = (b.get("start_time", 0), b.get("task_id", ""))
            if key_a > key_b:
                failures.append(Failure(
                    case_name, f"sort_order[{i},{i+1}]",
                    f"({key_a[0]},{key_a[1]}) <= ({key_b[0]},{key_b[1]})",
                    "out of order",
                ))
                break

    if "before" in expect:
        a_map = {a["task_id"]: a for a in assignments}
        for constraint in expect["before"]:
            early_id, late_id = constraint["early"], constraint["late"]
            early = a_map.get(early_id)
            late = a_map.get(late_id)
            if early and late:
                if early["end_time"] > late["start_time"]:
                    failures.append(Failure(
                        case_name,
                        f"before({early_id},{late_id})",
                        f"{early_id}.end_time <= {late_id}.start_time",
                        f"{early['end_time']} > {late['start_time']}",
                    ))

    return failures


def check_violations(
    case_name: str, output: dict, expect: dict
) -> list[Failure]:
    """Check validator violations."""
    failures = []

    if "violation_count" in expect:
        actual = output.get("violations", [])
        if len(actual) != expect["violation_count"]:
            failures.append(Failure(
                case_name, "violation_count",
                expect["violation_count"], len(actual),
            ))

    return failures


def check_case(case: dict, output: dict) -> list[Failure]:
    """Run all checks for a single test case."""
    name = case["name"]
    expect = case["expect"]

    all_failures: list[Failure] = []
    all_failures.extend(check_status(output, expect))

    if all_failures:
        return all_failures

    all_failures.extend(check_assignments(name, output, expect))
    all_failures.extend(check_failures_field(name, output, expect))
    all_failures.extend(check_ordering(name, output, expect))
    all_failures.extend(check_violations(name, output, expect))

    return all_failures


def load_cases(path: Path | None = None, category: str | None = None) -> list[dict]:
    p = path or CASES_FILE
    with open(p) as f:
        cases = json.load(f)
    if category:
        cases = [c for c in cases if c.get("category") == category]
    return cases


def run_oracle(
    cmd: str,
    cases: list[dict],
    timeout: int = 30,
    verbose: bool = False,
) -> list[CaseResult]:
    results = []
    for case in cases:
        t0 = time.monotonic()
        raw = run_scheduler(cmd, case["input"], timeout=timeout)
        elapsed = int((time.monotonic() - t0) * 1000)

        if isinstance(raw, str):
            results.append(CaseResult(
                name=case["name"],
                category=case.get("category", ""),
                passed=False,
                error=raw,
                duration_ms=elapsed,
            ))
            continue

        failures = check_case(case, raw)
        results.append(CaseResult(
            name=case["name"],
            category=case.get("category", ""),
            passed=len(failures) == 0,
            failures=failures,
            duration_ms=elapsed,
        ))

    return results


def format_results(results: list[CaseResult], verbose: bool = False) -> str:
    lines = []
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)

    for r in results:
        if r.passed:
            if verbose:
                lines.append(f"  pass  {r.name} ({r.duration_ms}ms)")
        else:
            lines.append(f"  FAIL  {r.name}")
            if r.error:
                lines.append(f"    error: {r.error}")
            for f in r.failures:
                lines.append(str(f))

    lines.append("")
    lines.append(f"{passed}/{passed + failed} passed")
    if failed:
        by_cat: dict[str, int] = {}
        for r in results:
            if not r.passed:
                cat = r.category or "uncategorized"
                by_cat[cat] = by_cat.get(cat, 0) + 1
        for cat, count in sorted(by_cat.items()):
            lines.append(f"  {cat}: {count} failing")

    return "\n".join(lines)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Shared behavioral oracle for E16 scheduler",
    )
    parser.add_argument(
        "--cmd", required=True,
        help="Command to run the scheduler (reads JSON stdin, writes JSON stdout)",
    )
    parser.add_argument(
        "--cases", type=Path, default=None,
        help=f"Path to test cases JSON (default: {CASES_FILE})",
    )
    parser.add_argument(
        "--category", default=None,
        help="Run only cases in this category",
    )
    parser.add_argument(
        "--timeout", type=int, default=30,
        help="Per-case timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Show passing tests too",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output results as JSON",
    )
    args = parser.parse_args()

    cases = load_cases(args.cases, args.category)
    if not cases:
        print("no test cases found", file=sys.stderr)
        return 2

    results = run_oracle(args.cmd, cases, timeout=args.timeout, verbose=args.verbose)

    if args.json:
        out = {
            "total": len(results),
            "passed": sum(1 for r in results if r.passed),
            "failed": sum(1 for r in results if not r.passed),
            "results": [
                {
                    "name": r.name,
                    "category": r.category,
                    "passed": r.passed,
                    "duration_ms": r.duration_ms,
                    **({"error": r.error} if r.error else {}),
                    **({"failures": [
                        {"field": f.field, "expected": f.expected, "actual": f.actual}
                        for f in r.failures
                    ]} if r.failures else {}),
                }
                for r in results
            ],
        }
        json.dump(out, sys.stdout, indent=2)
        print()
    else:
        print(format_results(results, verbose=args.verbose))

    return 0 if all(r.passed for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
