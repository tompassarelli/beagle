#!/usr/bin/env python3
"""Warn when a declared self-host/Racket compiler pair changes on one side.

This is a changed-path admission signal, not a semantic comparison.  The
self-host oracle ladder remains the authority for byte-exact parity.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Contract:
    name: str
    selfhost: str
    oracle: tuple[str, ...]


def die(message: str) -> None:
    print(f"compiler-twin-drift: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_contracts(path: Path) -> tuple[Contract, ...]:
    contracts: list[Contract] = []
    seen_names: set[str] = set()
    seen_selfhost: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        die(f"cannot read contracts {path}: {error}")
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            die(f"{path}:{number}: expected four tab-separated fields")
        name, selfhost, oracle_text, _basis = fields
        oracle = tuple(part for part in oracle_text.split(",") if part)
        if not name or not selfhost or not oracle:
            die(f"{path}:{number}: contract needs an id, self-host path, and oracle path")
        if name in seen_names or selfhost in seen_selfhost:
            die(f"{path}:{number}: duplicate contract id or self-host path")
        seen_names.add(name)
        seen_selfhost.add(selfhost)
        contracts.append(Contract(name, selfhost, oracle))
    if not contracts:
        die(f"{path}: no contracts declared")
    return tuple(contracts)


def load_exceptions(path: Path, contracts: tuple[Contract, ...]) -> set[tuple[str, str, str]]:
    known = {contract.name: contract for contract in contracts}
    exceptions: set[tuple[str, str, str]] = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        die(f"cannot read exceptions {path}: {error}")
    for number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            die(f"{path}:{number}: expected four tab-separated fields")
        name, side, changed_path, reason = fields
        contract = known.get(name)
        if contract is None or side not in {"selfhost", "oracle"} or not reason:
            die(f"{path}:{number}: unknown contract, invalid side, or empty reason")
        allowed = {contract.selfhost} if side == "selfhost" else set(contract.oracle)
        if changed_path not in allowed:
            die(f"{path}:{number}: exception path is not in contract {name}")
        exceptions.add((name, side, changed_path))
    return exceptions


def paths_from_status_bytes(data: bytes) -> set[str]:
    fields = data.split(b"\0")
    paths: set[str] = set()
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        if not status:
            continue
        code = status[:1]
        if code in {b"R", b"C"}:
            if index + 1 >= len(fields):
                die("malformed git name-status rename/copy record")
            names = fields[index : index + 2]
            index += 2
        else:
            if index >= len(fields):
                die("malformed git name-status record")
            names = fields[index : index + 1]
            index += 1
        for name in names:
            paths.add(name.decode("utf-8", "surrogateescape"))
    return paths


def paths_from_fixture(path: Path) -> set[str]:
    paths: set[str] = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        code = fields[0][:1]
        expected = 3 if code in {"R", "C"} else 2
        if len(fields) != expected or code not in {"A", "C", "D", "M", "R", "T", "U"}:
            die(f"{path}:{number}: expected git name-status fields")
        paths.update(fields[1:])
    return paths


def git_paths(repo: Path, base_ref: str | None) -> set[str]:
    candidates = (base_ref,) if base_ref else ("main", "origin/main")
    base = None
    for candidate in candidates:
        if not candidate:
            continue
        result = subprocess.run(
            ["git", "-C", str(repo), "merge-base", "HEAD", candidate],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0 and result.stdout.strip():
            base = result.stdout.strip()
            break
    if base is None:
        die("could not resolve a merge base with main (set --base to override)")

    paths: set[str] = set()
    for revision in (base, "HEAD"):
        result = subprocess.run(
            ["git", "-C", str(repo), "diff", "--name-status", "-z", "--find-renames", revision],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            die(result.stderr.decode("utf-8", "replace").strip() or "git diff failed")
        paths.update(paths_from_status_bytes(result.stdout))
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        die(result.stderr.decode("utf-8", "replace").strip() or "git ls-files failed")
    paths.update(name.decode("utf-8", "surrogateescape") for name in result.stdout.split(b"\0") if name)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", help="merge-base target (default: main, then origin/main)")
    parser.add_argument("--contracts", type=Path)
    parser.add_argument("--exceptions", type=Path)
    parser.add_argument("--changes-file", type=Path, help="hermetic tab-separated git name-status fixture")
    parser.add_argument("--strict", action="store_true", help="fail when a declared pair changes on one side")
    args = parser.parse_args()

    repo = args.repo.resolve()
    contracts_path = args.contracts or repo / "self-host/compiler-twin-contracts.tsv"
    exceptions_path = args.exceptions or repo / "self-host/compiler-twin-exceptions.tsv"
    contracts = load_contracts(contracts_path)
    exceptions = load_exceptions(exceptions_path, contracts)
    changed = paths_from_fixture(args.changes_file) if args.changes_file else git_paths(repo, args.base)

    warnings: list[str] = []
    for contract in contracts:
        selfhost_paths = {contract.selfhost} & changed
        oracle_paths = set(contract.oracle) & changed
        if bool(selfhost_paths) == bool(oracle_paths):
            continue
        side, changed_paths = ("selfhost", selfhost_paths) if selfhost_paths else ("oracle", oracle_paths)
        if all((contract.name, side, path) in exceptions for path in changed_paths):
            print(f"compiler-twin-drift: EXCEPTION pair={contract.name} side={side} paths={','.join(sorted(changed_paths))}")
            continue
        other = ",".join(contract.oracle) if side == "selfhost" else contract.selfhost
        warnings.append(
            f"pair={contract.name} changed-{side}={','.join(sorted(changed_paths))} companion={other}"
        )

    if not warnings:
        print("compiler-twin-drift: PASS declared compiler twin paths changed together or not at all")
        return 0
    for warning in warnings:
        print(f"compiler-twin-drift: WARN {warning}", file=sys.stderr)
    print(
        "compiler-twin-drift: changed-path signal only; self-host parity remains the semantic proof",
        file=sys.stderr,
    )
    return 1 if args.strict else 0


if __name__ == "__main__":
    raise SystemExit(main())
