#!/usr/bin/env python3
"""Run decided Beagle corpus cases against one compiler binary."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def fail(message):
    raise ValueError(message)


def read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate_case(case, expected_id=None):
    required = ["caseId", "corpusVersion", "status", "profile", "input", "rule", "expected"]
    for field in required:
        if field not in case:
            fail("case missing " + field)
    if expected_id is not None and case["caseId"] != expected_id:
        fail("manifest id does not match case id")
    if case["status"] != "DECIDED":
        fail("case is not DECIDED")
    if not case["rule"].get("id") or not case["rule"].get("reference"):
        fail("case rule lacks id or reference")
    if not case["rule"].get("text"):
        fail("case rule lacks decided text")
    expected = case["expected"]
    if expected.get("kind") not in (
        "diagnostic",
        "canonical-output",
        "named-diagnostic",
        "named-diagnostic-assertion",
    ):
        fail("case expected assertion is not canonical")
    source = case["input"].get("source")
    command = case["input"].get("command", {}).get("argv")
    if not isinstance(source, str) or not isinstance(command, list) or not command:
        fail("case input must contain source and command.argv")


def normalize(text):
    return text.replace("\r\n", "\n").replace("\r", "\n")


def canonicalize(text, temp_root):
    return normalize(text).replace(str(temp_root), "")


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def prepare_core_compiler(repo_root):
    builder = repo_root / "bin" / "beagle-core-compiler-projection"
    if not builder.is_file():
        fail("Core compiler projection builder is unavailable")
    print("PREPARE core-compiler-projection", flush=True)
    result = subprocess.run(
        [str(builder), "--cache"],
        cwd=str(repo_root),
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail("Core compiler projection preparation failed")
    destination = Path(result.stdout.strip())
    if not destination.is_dir():
        fail("Core compiler projection cache returned no artifact")
    print("PREPARED core-compiler-projection", flush=True)
    return destination


def needs_core_compiler(entries, manifest_path, requested_ids):
    for entry in entries:
        case_id = entry.get("caseId") if isinstance(entry, dict) else None
        if requested_ids and case_id not in requested_ids:
            continue
        try:
            case = read_json(manifest_path.parent / entry["path"])
            validate_case(case, case_id)
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue
        argv = case["input"]["command"]["argv"]
        if case["input"].get("target") == "core" and argv[0] == "execute":
            return True
    return False


def run_case(case, compiler, repo_root, core_compiler=None):
    with tempfile.TemporaryDirectory(prefix="beagle-corpus-") as temp:
        temp_root = Path(temp)
        closure = case["input"].get("closure", {})
        input_path = temp_root / (case["input"].get("fileName") or "input.bgl")
        input_path.parent.mkdir(parents=True, exist_ok=True)
        for file_entry in closure.get("files", []):
            file_name = file_entry.get("fileName") or file_entry.get("path")
            if not file_name:
                fail("closure file missing fileName")
            file_path = temp_root / file_name
            file_path.parent.mkdir(parents=True, exist_ok=True)
            file_path.write_text(file_entry["source"], encoding="utf-8")
        output_path = temp_root / "output"
        input_path.write_text(case["input"]["source"], encoding="utf-8")
        def substitute(token):
            return (token.replace("{input}", str(input_path))
                        .replace("{root}", str(temp_root))
                        .replace("{output}", str(output_path)))

        argv = [substitute(token) for token in case["input"]["command"]["argv"]]
        build_env = None
        if argv and argv[0] == "execute":
            if len(argv) != 4 or argv[1] != "--entry":
                fail("execute command must be: execute --entry NS/NAME {input}")
            target = case["input"].get("target")
            entry = argv[2]
            if target == "core":
                if core_compiler is None:
                    fail("Core execution requires a prepared compiler projection")
                executable = output_path / "program"
                output_path.mkdir()
                build_argv = [str(compiler), "native-exe", "--out", str(executable),
                              "--entry", entry, argv[3]]
                build_env = os.environ.copy()
                build_env["BEAGLE_CORE_COMPILED_OVERRIDE"] = str(core_compiler)
                run_argv = [str(executable)]
            elif target in ("clj", "js"):
                runtime = shutil.which("bb" if target == "clj" else "node")
                if runtime is None:
                    fail("runtime unavailable for target " + target)
                emitted = output_path.with_suffix(".clj" if target == "clj" else ".mjs")
                build_argv = [str(compiler), "build", argv[3], str(emitted)]
                if target == "clj":
                    expression = "(do (load-file {}) ({}) nil)".format(
                        json.dumps(str(emitted)), entry)
                    run_argv = [runtime, "-e", expression]
                else:
                    build_env = os.environ.copy()
                    build_env["BEAGLE_JS_RUNTIME_PREFIX"] = (
                        (repo_root / "beagle-lib" / "lib" / "beagle").resolve().as_uri()
                        + "/"
                    )
                    js_name = (entry.rsplit("/", 1)[-1]
                               .replace("_", "__")
                               .replace("-", "_")
                               .replace("?", "_p")
                               .replace("!", "_bang")
                               .replace("=", "_eq")
                               .replace(">", "_gt")
                               .replace("<", "_lt")
                               .replace("%", "_pct"))
                    expression = "import({}).then(m => m[{}]())".format(
                        json.dumps(emitted.as_uri()), json.dumps(js_name))
                    run_argv = [runtime, "--input-type=module", "-e", expression]
            else:
                fail("execute command does not support target " + str(target))
            built = subprocess.run(
                build_argv,
                cwd=str(repo_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=build_env,
            )
            if built.returncode != 0:
                detail = canonicalize(built.stdout + built.stderr, temp_root)
                return "execution build failed: " + " ".join(detail.split())[:1200]
            if target == "js":
                with emitted.open("a", encoding="utf-8") as stream:
                    stream.write("\nexport { " + js_name + " };\n")
            result = subprocess.run(
                run_argv,
                cwd=str(temp_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        else:
            result = subprocess.run(
                [str(compiler)] + argv,
                cwd=str(repo_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        expected = case["expected"]
        combined = canonicalize(result.stdout + result.stderr, temp_root)
        expected_exit = expected.get("exitCode")
        if expected_exit is None:
            if expected["kind"] == "named-diagnostic":
                expected_exit = 1
            elif expected["kind"] == "named-diagnostic-assertion":
                expected_exit = (
                    1
                    if expected.get("diagnosticCode") or expected.get("diagnostic")
                    else 0
                )
            else:
                expected_exit = 0
        if result.returncode != expected_exit:
            detail = " ".join(combined.split())[:400]
            return "exit code {} (expected {}): {}".format(
                result.returncode, expected_exit, detail or "no diagnostic"
            )
        if expected["kind"] in ("diagnostic", "named-diagnostic"):
            fields = ("code", "message", "diagnosticCore")
            if expected["kind"] == "named-diagnostic":
                fields = ("identifier",)
            for field in fields:
                needle = expected.get(field)
                if needle and needle not in combined:
                    return "diagnostic missing {}={!r}".format(field, needle)
            return None
        if expected["kind"] == "named-diagnostic-assertion":
            needle = expected.get("diagnosticCode")
            if needle and needle not in combined:
                return "diagnostic missing diagnosticCode={!r}".format(needle)
            diagnostic = expected.get("diagnostic")
            if isinstance(diagnostic, dict):
                needle = diagnostic.get("semanticErrorId")
                if needle and needle not in combined:
                    return "diagnostic missing semanticErrorId={!r}".format(needle)
            return None
        for assertion in expected.get("assertions", []):
            if assertion.get("kind") == "named-diagnostic":
                needle = assertion.get("diagnosticId")
                if needle and needle not in combined:
                    return "diagnostic missing diagnosticId={!r}".format(needle)
        if ("stdout" in expected and
                canonicalize(result.stdout, temp_root) != normalize(expected["stdout"])):
            return "stdout differs from canonical output: {!r}".format(result.stdout[:400])
        if ("stderr" in expected and
                canonicalize(result.stderr, temp_root) != normalize(expected["stderr"])):
            return "stderr differs from canonical output: {!r}".format(result.stderr[:400])
        for artifact in expected.get("artifacts", []):
            artifact_path = temp_root / artifact["path"]
            if not artifact_path.is_file():
                return "canonical artifact is missing: {}".format(artifact["path"])
            actual_digest = digest(artifact_path)
            if actual_digest != artifact.get("sha256"):
                return "canonical artifact digest differs: {} (actual sha256={})".format(
                    artifact["path"], actual_digest
                )
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--case", action="append", dest="case_ids")
    args = parser.parse_args()
    manifest = read_json(args.manifest)
    if manifest.get("schema") != "BeagleConformanceCorpusV1":
        print("run-corpus: unsupported manifest schema", file=sys.stderr)
        return 2
    entries = manifest.get("cases")
    if not isinstance(entries, list):
        print("run-corpus: manifest cases must be a list", file=sys.stderr)
        return 2
    repo_root = args.manifest.resolve().parents[2]
    seen = set()
    entry_by_id = {}
    for entry in entries:
        if not isinstance(entry, dict) or "caseId" not in entry:
            print("run-corpus: malformed manifest entry", file=sys.stderr)
            return 2
        entry_by_id[entry["caseId"]] = entry
    for required_id in manifest.get("requiredCoverage", {}).get("alarmBell", []):
        if required_id not in entry_by_id or entry_by_id[required_id].get("status") != "DECIDED":
            print("run-corpus: required ALARM-BELL case is not DECIDED: " + required_id,
                  file=sys.stderr)
            return 2
    core_compiler = None
    if needs_core_compiler(entries, args.manifest, args.case_ids):
        core_compiler = prepare_core_compiler(repo_root)

    failures = 0
    for entry in entries:
        try:
            case_id = entry["caseId"]
            if case_id in seen:
                fail("duplicate case id in manifest")
            seen.add(case_id)
            if args.case_ids and case_id not in args.case_ids:
                continue
            case_path = args.manifest.parent / entry["path"]
            if entry.get("sha256") and digest(case_path) != entry["sha256"]:
                fail("case payload digest does not match manifest")
            case = read_json(case_path)
            validate_case(case, case_id)
            reason = run_case(
                case, args.compiler, repo_root, core_compiler=core_compiler
            )
        except (OSError, KeyError, TypeError, ValueError,
                json.JSONDecodeError) as error:
            reason = str(error)
        if reason is None:
            print("PASS " + case_id)
        else:
            failures += 1
            print("FAIL {}: {}".format(case_id, reason))
    if args.case_ids and not seen.intersection(args.case_ids):
        print("run-corpus: no requested case exists", file=sys.stderr)
        return 2
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
