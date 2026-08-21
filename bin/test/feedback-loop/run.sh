#!/usr/bin/env bash
# A machine-readable adapter over existing Beagle compiler/harness stages.
set -uo pipefail

schema='beagle.feedback-loop-benchmark/v1'

usage() {
  cat <<'EOF'
usage: run.sh --class CLASS --workload NAME --input LOGICAL=PATH ...
  --semantic LABEL=PATH|stage-log:STAGE ...
  --materialization LABEL=PATH|none ... [--queue-ns N] [--output FILE]
  --stage NAME [--expect-exit N] -- COMMAND ... [--next-stage --stage ...]

CLASS is edit-diagnostic, changed-function-module, warm-large,
cold-full-closure, or no-op-identity.
EOF
}

fail_usage() {
  printf 'feedback-loop benchmark: %s\n' "$*" >&2
  usage >&2
  exit 2
}

monotonic_ns() {
  python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
}

# Content plus relative topology only: no path, mtime, owner, or inode leaks
# into an identity.
path_identity() {
  python3 - "$1" <<'PY'
import hashlib, os, pathlib, stat, sys

root = pathlib.Path(sys.argv[1])
if not root.exists() and not root.is_symlink():
    raise SystemExit(f"missing artifact: {root}")
rows = []

def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def walk(path, logical):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        rows.append(("L", logical, os.readlink(path)))
    elif stat.S_ISREG(mode):
        rows.append(("F", logical, digest_file(path)))
    elif stat.S_ISDIR(mode):
        rows.append(("D", logical, ""))
        for child in sorted(path.iterdir(), key=lambda item: item.name):
            child_logical = child.name if logical == "." else f"{logical}/{child.name}"
            walk(child, child_logical)
    else:
        raise SystemExit(f"unsupported artifact type: {path}")

walk(root, ".")
manifest = "".join("\t".join(row) + "\n" for row in rows).encode()
print(hashlib.sha256(manifest).hexdigest())
PY
}

class=''
workload=''
queue_ns=0
output=''
declare -a input_logicals=() input_paths=() input_before=()
declare -a semantic_specs=() materialization_specs=()
declare -a stage_names=() stage_expected=() stage_argv_files=()

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-feedback-loop.XXXXXX")"
cleanup() {
  local status=$?
  rm -rf -- "${scratch:?}"
  return "$status"
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --class|--workload|--queue-ns|--output|--input|--semantic|--materialization)
      (($# >= 2)) || fail_usage "$1 needs a value"
      option="$1"
      value="$2"
      shift 2
      case "$option" in
        --class) class="$value" ;;
        --workload) workload="$value" ;;
        --queue-ns) queue_ns="$value" ;;
        --output) output="$value" ;;
        --input)
          logical="${value%%=*}"
          physical="${value#*=}"
          [[ "$logical" != "$value" && -n "$logical" && -n "$physical" ]] ||
            fail_usage '--input needs LOGICAL=PATH'
          input_logicals+=("$logical")
          input_paths+=("$physical")
          ;;
        --semantic) semantic_specs+=("$value") ;;
        --materialization) materialization_specs+=("$value") ;;
      esac
      ;;
    --stage)
      (($# >= 2)) || fail_usage '--stage needs a name'
      name="$2"
      [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || fail_usage "invalid stage name: $name"
      expected=0
      shift 2
      if [[ "${1:-}" == '--expect-exit' ]]; then
        (($# >= 2)) || fail_usage '--expect-exit needs a status'
        expected="$2"
        shift 2
      fi
      [[ "$expected" =~ ^[0-9]+$ ]] || fail_usage "invalid expected exit: $expected"
      [[ "${1:-}" == '--' ]] || fail_usage "--stage $name needs -- COMMAND"
      shift
      argv_file="$scratch/stage-${#stage_names[@]}.argv"
      : >"$argv_file"
      count=0
      while (($#)) && [[ "$1" != '--next-stage' ]]; do
        printf '%s\0' "$1" >>"$argv_file"
        count=$((count + 1))
        shift
      done
      ((count > 0)) || fail_usage "--stage $name has no command"
      [[ "${1:-}" != '--next-stage' ]] || shift
      stage_names+=("$name")
      stage_expected+=("$expected")
      stage_argv_files+=("$argv_file")
      ;;
    *) fail_usage "unknown option: $1" ;;
  esac
done

case "$class" in
  edit-diagnostic|changed-function-module|warm-large|cold-full-closure|no-op-identity) ;;
  *) fail_usage 'class must name one of the five feedback-loop classes' ;;
esac
[[ -n "$workload" ]] || fail_usage '--workload is required'
[[ "$queue_ns" =~ ^[0-9]+$ ]] || fail_usage '--queue-ns must be a non-negative integer'
((${#input_logicals[@]} > 0)) || fail_usage 'at least one --input is required'
((${#semantic_specs[@]} > 0)) || fail_usage 'at least one --semantic is required'
((${#materialization_specs[@]} > 0)) || fail_usage 'at least one --materialization is required'
((${#stage_names[@]} > 0)) || fail_usage 'at least one --stage is required'

declare -A logical_seen=() stage_seen=()
for index in "${!input_logicals[@]}"; do
  logical="${input_logicals[$index]}"
  [[ -z "${logical_seen[$logical]+x}" ]] || fail_usage "repeated input name: $logical"
  logical_seen[$logical]=1
  input_before+=("$(path_identity "${input_paths[$index]}")")
done
for name in "${stage_names[@]}"; do
  [[ -z "${stage_seen[$name]+x}" ]] || fail_usage "repeated stage name: $name"
  stage_seen[$name]=1
done

workload_manifest="$scratch/workload.tsv"
{
  printf 'schema\t%s\nclass\t%s\nworkload\t%s\n' "$schema" "$class" "$workload"
  for index in "${!input_logicals[@]}"; do
    printf 'input\t%s\tsha256:%s\n' "${input_logicals[$index]}" "${input_before[$index]}"
  done | LC_ALL=C sort
  for name in "${stage_names[@]}"; do
    printf 'stage\t%s\n' "$name"
  done
} >"$workload_manifest"
workload_identity="$(sha256sum "$workload_manifest" | awk '{print $1}')"

stage_rows="$scratch/stages.tsv"
: >"$stage_rows"
active_ns=0
all_expected=1
for index in "${!stage_names[@]}"; do
  name="${stage_names[$index]}"
  expected="${stage_expected[$index]}"
  log="$scratch/$name.log"
  mapfile -d '' -t command <"${stage_argv_files[$index]}"
  started="$(monotonic_ns)"
  set +e
  "${command[@]}" >"$log" 2>&1
  actual=$?
  set -e
  ended="$(monotonic_ns)"
  elapsed=$((ended - started))
  active_ns=$((active_ns + elapsed))
  [[ "$actual" == "$expected" ]] || all_expected=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$expected" "$actual" "$started" "$ended" "$elapsed" \
    "$(sha256sum "$log" | awk '{print $1}')" >>"$stage_rows"
done

inputs_stable=1
for index in "${!input_paths[@]}"; do
  after="$(path_identity "${input_paths[$index]}")"
  [[ "$after" == "${input_before[$index]}" ]] || inputs_stable=0
done

semantic_rows="$scratch/semantic.tsv"
: >"$semantic_rows"
for spec in "${semantic_specs[@]}"; do
  if [[ "$spec" == stage-log:* ]]; then
    name="${spec#stage-log:}"
    [[ -n "${stage_seen[$name]+x}" ]] || fail_usage "unknown semantic stage: $name"
    printf 'stage-log:%s\tsha256:%s\n' "$name" \
      "$(sha256sum "$scratch/$name.log" | awk '{print $1}')" >>"$semantic_rows"
  else
    label="${spec%%=*}"
    physical="${spec#*=}"
    [[ "$label" != "$spec" && -n "$label" && -n "$physical" ]] ||
      fail_usage '--semantic needs LABEL=PATH or stage-log:STAGE'
    printf '%s\tsha256:%s\n' "$label" "$(path_identity "$physical")" >>"$semantic_rows"
  fi
done
semantic_identity="$({
  printf 'workload\tsha256:%s\n' "$workload_identity"
  cat "$semantic_rows"
} | LC_ALL=C sort | sha256sum | awk '{print $1}')"

materialization_rows="$scratch/materialization.tsv"
: >"$materialization_rows"
for spec in "${materialization_specs[@]}"; do
  if [[ "$spec" == none ]]; then
    printf 'none\tnone\n' >>"$materialization_rows"
  else
    label="${spec%%=*}"
    physical="${spec#*=}"
    [[ "$label" != "$spec" && -n "$label" && -n "$physical" ]] ||
      fail_usage '--materialization needs LABEL=PATH or none'
    printf '%s\tsha256:%s\n' "$label" "$(path_identity "$physical")" >>"$materialization_rows"
  fi
done
materialization_identity="$(LC_ALL=C sort "$materialization_rows" | sha256sum | awk '{print $1}')"

result_status=pass
[[ "$all_expected" == 1 && "$inputs_stable" == 1 ]] || result_status=fail
record="$scratch/record.json"
python3 - "$record" "$schema" "$class" "$workload" "$workload_identity" \
  "$queue_ns" "$active_ns" "$result_status" "$inputs_stable" \
  "$workload_manifest" "$stage_rows" "$semantic_rows" "$semantic_identity" \
  "$materialization_rows" "$materialization_identity" <<'PY'
import json, pathlib, sys
(
    record_path, schema, benchmark_class, workload, workload_identity, queue_ns,
    active_ns, result_status, inputs_stable, workload_manifest, stage_rows,
    semantic_rows, semantic_identity, materialization_rows, materialization_identity,
) = sys.argv[1:]

def rows(path):
    return [line.split("\t") for line in pathlib.Path(path).read_text().splitlines()]

inputs = [
    {"logicalName": row[1], "identity": row[2]}
    for row in rows(workload_manifest) if row[0] == "input"
]
stages = []
for row in rows(stage_rows):
    name, expected, actual, started, ended, elapsed, log_identity = row
    stages.append({
        "name": name, "expectedExit": int(expected), "actualExit": int(actual),
        "startedMonotonicNs": int(started), "endedMonotonicNs": int(ended),
        "activeNs": int(elapsed), "logIdentity": f"sha256:{log_identity}",
    })
def artifacts(path):
    return [{"label": label, "identity": identity} for label, identity in rows(path)]

payload = {
    "schema": schema,
    "benchmarkClass": benchmark_class,
    "workload": {
        "name": workload, "identity": f"sha256:{workload_identity}",
        "inputs": inputs, "inputStable": inputs_stable == "1",
    },
    "timing": {
        "queueNs": int(queue_ns), "activeNs": int(active_ns),
        "measurement": {
            "queue": "caller-supplied-ns",
            "active": "monotonic-command-interval",
        },
        "stages": stages,
    },
    "semantic": {
        "identity": f"sha256:{semantic_identity}",
        "artifacts": artifacts(semantic_rows),
    },
    "materialization": {
        "identity": f"sha256:{materialization_identity}",
        "artifacts": artifacts(materialization_rows),
    },
    "result": {"status": result_status},
}
pathlib.Path(record_path).write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
)
PY

if [[ -n "$output" ]]; then
  parent="$(dirname -- "$output")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.feedback-loop-record.XXXXXX")"
  cp "$record" "$temporary"
  mv "$temporary" "$output"
else
  cat "$record"
fi

[[ "$result_status" == pass ]]
