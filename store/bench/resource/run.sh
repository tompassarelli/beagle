#!/usr/bin/env bash
# Scratch-only JVM Store resource/capacity measurement. It never reads a live
# Store path or port and never changes a system service or system closure.
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
triple_count=30000
duration_seconds=60
idle_seconds=60
output=""
store_home="${STORE_RESOURCE_HOME:-$repo/store}"
java_path="${STORE_RESOURCE_JAVA:-}"
classpath="${STORE_RESOURCE_CLASSPATH:-}"
classpath_file="${STORE_RESOURCE_CLASSPATH_FILE:-}"
port="${STORE_RESOURCE_PORT:-}"

usage() {
  cat <<'EOF'
usage: store/bench/resource/run.sh [OPTIONS]

  --size 30000|500000|5000000  acceptance corpus (default: 30000)
  --smoke                       3000 triples; 2-second idle/agent phases
  --store-home PATH             checkout/artifact store root
  --java PATH                   exact JVM executable
  --classpath-file PATH         exact server classpath file
  --classpath VALUE             exact server/client classpath
  --output PATH                 JSONL receipt (default: /tmp/...jsonl)
  --port PORT                   scratch listener port (default: free port)

The environment equivalents are STORE_RESOURCE_HOME, STORE_RESOURCE_JAVA,
STORE_RESOURCE_CLASSPATH_FILE, STORE_RESOURCE_CLASSPATH, and
STORE_RESOURCE_PORT.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --size) triple_count="${2:?--size needs a value}"; shift 2 ;;
    --smoke) triple_count=3000; duration_seconds=2; idle_seconds=2; shift ;;
    --store-home) store_home="${2:?--store-home needs a path}"; shift 2 ;;
    --java) java_path="${2:?--java needs a path}"; shift 2 ;;
    --classpath-file) classpath_file="${2:?--classpath-file needs a path}"; shift 2 ;;
    --classpath) classpath="${2:?--classpath needs a value}"; shift 2 ;;
    --output) output="${2:?--output needs a path}"; shift 2 ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "store-resource: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$triple_count" in
  3000|30000|500000|5000000) ;;
  *) echo "store-resource: size must be 3000, 30000, 500000, or 5000000" >&2; exit 2 ;;
esac
[[ -d "$store_home/out" && -r "$store_home/server.clj" ]] || {
  echo "store-resource: --store-home must contain server.clj and out/: $store_home" >&2
  exit 2
}
store_home="$(realpath "$store_home")"
if [[ -z "$java_path" ]]; then java_path="$(command -v java 2>/dev/null || true)"; fi
[[ -n "$java_path" && -x "$java_path" ]] || {
  echo "store-resource: supply an executable --java / STORE_RESOURCE_JAVA" >&2
  exit 2
}
java_path="$(realpath "$java_path")"
jcmd="$(dirname "$(readlink -f "$java_path")")/jcmd"
[[ -x "$jcmd" ]] || {
  echo "store-resource: matching jcmd is unavailable beside $java_path" >&2
  exit 2
}
if [[ -z "$classpath" ]]; then
  if [[ -z "$classpath_file" && -r "$store_home/server.classpath" ]]; then
    classpath_file="$store_home/server.classpath"
  fi
  [[ -n "$classpath_file" && -r "$classpath_file" ]] || {
    echo "store-resource: supply --classpath or a readable --classpath-file" >&2
    exit 2
  }
  classpath="$(<"$classpath_file")"
fi
[[ -n "$classpath" ]] || { echo "store-resource: classpath is empty" >&2; exit 2; }
command -v bun >/dev/null 2>&1 || {
  echo "store-resource: Bun is required to assemble the JSONL receipt" >&2
  exit 2
}
command -v bb >/dev/null 2>&1 || {
  echo "store-resource: bb is required to reserve a scratch port" >&2
  exit 2
}
[[ -f /sys/fs/cgroup/cgroup.controllers ]] || {
  echo "store-resource: Linux cgroup v2 is required" >&2
  exit 2
}

started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/store-resource.XXXXXXXX")"
if [[ -z "$output" ]]; then output="/tmp/store-resource-${triple_count}-$$.jsonl"; fi
output="$(realpath -m "$output")"
evidence_directory="${output%.jsonl}.evidence"
mkdir -p "$(dirname "$output")"
[[ ! -e "$evidence_directory" ]] || {
  echo "store-resource: evidence destination already exists: $evidence_directory" >&2
  exit 2
}

uid="$(id -u)"
cgroup_parent="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/app.slice"
cgroup_path="$cgroup_parent/store-resource-$$"
case "$cgroup_path" in
  "$cgroup_parent"/store-resource-[0-9]*) ;;
  *) echo "store-resource: internal cgroup path escaped its parent" >&2; exit 2 ;;
esac
[[ -w "$cgroup_parent/cgroup.procs" ]] || {
  echo "store-resource: cgroup creation is not delegated below $cgroup_parent" >&2
  exit 2
}
mkdir "$cgroup_path"
if [[ "$triple_count" == 5000000 ]]; then
  memory_max_bytes=8589934592
else
  memory_max_bytes=3221225472
fi
printf '%s\n' "$memory_max_bytes" >"$cgroup_path/memory.max"
printf '0\n' >"$cgroup_path/memory.swap.max"
if [[ -f "$cgroup_path/memory.zswap.max" ]]; then
  printf '0\n' >"$cgroup_path/memory.zswap.max"
fi

server_pid=""
server_expected_stop=0
unexpected_server_exits=0
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.05
    done
  fi
  if [[ -d "$cgroup_path" ]]; then
    if [[ -s "$cgroup_path/cgroup.procs" ]]; then
      if [[ -f "$cgroup_path/cgroup.kill" ]]; then
        printf '1\n' >"$cgroup_path/cgroup.kill" 2>/dev/null || true
      fi
    fi
    for _ in $(seq 1 100); do
      [[ ! -s "$cgroup_path/cgroup.procs" ]] && break
      sleep 0.05
    done
    rmdir "$cgroup_path" 2>/dev/null || true
  fi
  rm -rf -- "${scratch:?}"
}
trap cleanup EXIT

if [[ -z "$port" ]]; then
  port="$(bb -e '(with-open [socket (java.net.ServerSocket. 0)] (print (.getLocalPort socket)))')"
fi
[[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] || {
  echo "store-resource: port must be from 1 through 65535" >&2
  exit 2
}
space="resource-$triple_count-$$"
log_path="$scratch/history.storelog"
snapshot_path="$log_path.snapshot"
saved_snapshot="$scratch/checkpoint.saved"
heap_max_bytes=2147483648
facts="$scratch/facts.tsv"
: >"$facts"

fact() { printf '%s\t%s\n' "$1" "$2" >>"$facts"; }
now_ns() { date +%s%N; }
cpu_usage_usec() { awk '$1 == "usage_usec" { print $2 }' "$cgroup_path/cpu.stat"; }
memory_event() {
  local name="$1"
  awk -v wanted="$name" '$1 == wanted { print $2 }' "$cgroup_path/memory.events.local"
}

run_client() {
  local result_path="$1"; shift
  "$java_path" -Xmx1g -XX:+UseG1GC -cp "$classpath" clojure.main \
    "$here/workload.clj" "$@" >"$result_path"
  [[ "$(wc -l <"$result_path")" -eq 1 ]] || {
    echo "store-resource: workload emitted other than one JSON row: $result_path" >&2
    return 1
  }
}

launch_server() {
  local label="$1"
  local gc_log="$scratch/$label.gc.log"
  local server_output="$scratch/$label.server.log"
  local request_log="$scratch/$label.requests.log"
  local start_ns start_cpu deadline
  [[ -z "$server_pid" ]] || {
    echo "store-resource: internal lifecycle overlap" >&2
    return 2
  }
  start_ns="$(now_ns)"
  start_cpu="$(cpu_usage_usec)"
  bash -c '
    cgroup="$1"; store="$2"; shift 2
    printf "%s\n" "$$" >"$cgroup/cgroup.procs"
    cd "$store"
    exec "$@"
  ' _ "$cgroup_path" "$store_home" \
    env BEAGLE_STORE_SERVER_LOG="$request_log" \
        BEAGLE_STORE_SERVER_QUIET=1 \
        BEAGLE_STORE_SERVER_ROLE=active \
    "$java_path" -Xmx2g -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError \
      "-Xlog:gc*:file=$gc_log:uptimemillis,level,tags" \
      -cp "$classpath" clojure.main server.clj serve \
      "$port" "$log_path" "$space" >"$server_output" 2>&1 &
  server_pid=$!
  deadline=$((SECONDS + 300))
  while ! rg -q '^Beagle Store server listening on ' "$server_output" 2>/dev/null; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      unexpected_server_exits=$((unexpected_server_exits + 1))
      echo "store-resource: $label server exited before readiness" >&2
      sed -n '1,160p' "$server_output" >&2
      return 1
    fi
    if (( SECONDS >= deadline )); then
      echo "store-resource: $label server exceeded the 300-second readiness deadline" >&2
      return 1
    fi
    sleep 0.05
  done
  local end_ns end_cpu
  end_ns="$(now_ns)"
  end_cpu="$(cpu_usage_usec)"
  printf -v "${label}_ready_wall_ms" '%s' "$(( (end_ns - start_ns) / 1000000 ))"
  printf -v "${label}_ready_cpu_usec" '%s' "$(( end_cpu - start_cpu ))"
  printf -v "${label}_gc_log" '%s' "$gc_log"
}

sample_process() {
  local prefix="$1"
  local rss_kb=0 pss_kb=0 file_pss_kb=0 anon_kb=0 swap_kb=0 hwm_kb=0 pid value
  while read -r pid; do
    [[ -r "/proc/$pid/smaps_rollup" ]] || continue
    value="$(awk '$1 == "Rss:" { print $2 }' "/proc/$pid/smaps_rollup")"; rss_kb=$((rss_kb + value))
    value="$(awk '$1 == "Pss:" { print $2 }' "/proc/$pid/smaps_rollup")"; pss_kb=$((pss_kb + value))
    value="$(awk '$1 == "Pss_File:" { print $2 }' "/proc/$pid/smaps_rollup")"; file_pss_kb=$((file_pss_kb + value))
    value="$(awk '$1 == "Anonymous:" { print $2 }' "/proc/$pid/smaps_rollup")"; anon_kb=$((anon_kb + value))
    value="$(awk '$1 == "Swap:" { print $2 }' "/proc/$pid/smaps_rollup")"; swap_kb=$((swap_kb + value))
    value="$(awk '$1 == "VmHWM:" { print $2 }' "/proc/$pid/status")"; hwm_kb=$((hwm_kb + value))
  done <"$cgroup_path/cgroup.procs"
  printf -v "${prefix}_rss_bytes" '%s' "$((rss_kb * 1024))"
  printf -v "${prefix}_pss_bytes" '%s' "$((pss_kb * 1024))"
  printf -v "${prefix}_file_pss_bytes" '%s' "$((file_pss_kb * 1024))"
  printf -v "${prefix}_anon_bytes" '%s' "$((anon_kb * 1024))"
  printf -v "${prefix}_swap_bytes" '%s' "$((swap_kb * 1024))"
  printf -v "${prefix}_peak_rss_bytes" '%s' "$((hwm_kb * 1024))"
  value="$(awk '$1 == "file_mapped" { print $2 }' "$cgroup_path/memory.stat")"
  printf -v "${prefix}_file_mapped_bytes" '%s' "${value:-0}"
}

stop_server() {
  local label="$1" status
  sample_process "$label"
  server_expected_stop=1
  kill -TERM "$server_pid"
  set +e
  wait "$server_pid"
  status=$?
  set -e
  server_expected_stop=0
  if [[ "$status" != 0 && "$status" != 143 ]]; then
    unexpected_server_exits=$((unexpected_server_exits + 1))
    echo "store-resource: $label server stopped with unexpected status $status" >&2
    return 1
  fi
  server_pid=""
  [[ ! -s "$cgroup_path/cgroup.procs" ]] || {
    echo "store-resource: $label left a process in its cgroup" >&2
    return 1
  }
}

# Exact source/artifact identity. Immutable classpath entries are identified by
# path; mutable directories are content-hashed.
artifact_manifest="$scratch/artifact.manifest"
(
  cd "$store_home"
  find out -type f -print0
  for path in server.clj database.clj writer_authority.clj runtime.manifest; do
    if [[ -f "$path" ]]; then printf '%s\0' "$path"; fi
  done
) | sort -z | while IFS= read -r -d '' path; do
  printf '%s  %s\n' "$(sha256sum "$store_home/$path" | cut -d' ' -f1)" "$path"
done >"$artifact_manifest"
artifact_manifest_sha256="$(sha256sum "$artifact_manifest" | cut -d' ' -f1)"
artifact_sha256="$artifact_manifest_sha256"
classpath_identity="$scratch/classpath.identity"
: >"$classpath_identity"
IFS=: read -r -a classpath_entries <<<"$classpath"
for entry in "${classpath_entries[@]}"; do
  if [[ -f "$entry" ]]; then
    printf 'file\t%s\t%s\n' "$entry" "$(sha256sum "$entry" | cut -d' ' -f1)" >>"$classpath_identity"
  elif [[ -d "$entry" && "$entry" == "$store_home/out" ]]; then
    printf 'directory\t%s\t%s\n' "$entry" "$artifact_sha256" >>"$classpath_identity"
  else
    printf 'path\t%s\n' "$entry" >>"$classpath_identity"
  fi
done
classpath_sha256="$(printf '%s' "$classpath" | sha256sum | cut -d' ' -f1)"
classpath_identity_sha256="$(sha256sum "$classpath_identity" | cut -d' ' -f1)"
source_revision="unknown"
source_dirty="unknown"
source_status_sha256=""
: >"$scratch/source.status"
source_root="$(git -C "$store_home" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$source_root" && "$(git -C "$store_home" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]]; then
  source_revision="$(git -C "$source_root" rev-parse HEAD)"
  git -C "$source_root" status --porcelain=v1 --untracked-files=all >"$scratch/source.status"
  source_status_sha256="$(sha256sum "$scratch/source.status" | cut -d' ' -f1)"
  source_dirty=0; [[ ! -s "$scratch/source.status" ]] || source_dirty=1
else
  printf 'source Git checkout unknown for store home: %s\n' "$store_home" \
    >"$scratch/source.status"
fi
"$java_path" -XshowSettings:properties -version >"$scratch/java.settings" 2>&1
java_version="$(sed -n '1p' "$scratch/java.settings")"

echo "store-resource: load $triple_count real triples" >&2
launch_server load
total_server_started_ns="$(now_ns)"
load_cpu_before="$(cpu_usage_usec)"; load_started_ns="$(now_ns)"
run_client "$scratch/seed.json" seed "$port" "$space" "$triple_count" 8
run_client "$scratch/initial-verify.json" verify "$port" "$space" "$triple_count"
load_wall_ms=$(( ($(now_ns) - load_started_ns) / 1000000 ))
load_cpu_usec=$(( $(cpu_usage_usec) - load_cpu_before ))

checkpoint_cpu_before="$(cpu_usage_usec)"; checkpoint_started_ns="$(now_ns)"
run_client "$scratch/checkpoint.json" checkpoint "$port" "$space"
checkpoint_wall_ms=$(( ($(now_ns) - checkpoint_started_ns) / 1000000 ))
checkpoint_cpu_usec=$(( $(cpu_usage_usec) - checkpoint_cpu_before ))
[[ -s "$snapshot_path" ]] || { echo "store-resource: checkpoint file was not created" >&2; exit 1; }
stop_server load
peak_rss_bytes="$load_peak_rss_bytes"

mv "$snapshot_path" "$saved_snapshot"
echo "store-resource: cold restart without checkpoint" >&2
launch_server cold
run_client "$scratch/cold-verify.json" verify "$port" "$space" "$triple_count"
stop_server cold
(( cold_peak_rss_bytes > peak_rss_bytes )) && peak_rss_bytes="$cold_peak_rss_bytes"
[[ ! -e "$snapshot_path" ]] || { echo "store-resource: cold restart unexpectedly wrote a checkpoint" >&2; exit 1; }
mv "$saved_snapshot" "$snapshot_path"

echo "store-resource: warm restart with checkpoint" >&2
launch_server warm
run_client "$scratch/warm-verify.json" verify "$port" "$space" "$triple_count"

"$jcmd" "$server_pid" GC.run >"$scratch/jcmd-gc-run.txt"
"$jcmd" "$server_pid" GC.heap_info >"$scratch/jcmd-heap-info.txt"
post_gc_heap_used_kb="$(sed -n 's/.*heap[[:space:]]*total[[:space:]]*[0-9][0-9]*K,[[:space:]]*used[[:space:]]*\([0-9][0-9]*\)K.*/\1/p' "$scratch/jcmd-heap-info.txt" | head -n 1)"
[[ -n "$post_gc_heap_used_kb" ]] || {
  echo "store-resource: could not parse post-GC heap use" >&2
  sed -n '1,80p' "$scratch/jcmd-heap-info.txt" >&2
  exit 1
}
post_gc_heap_used_bytes=$((post_gc_heap_used_kb * 1024))
sample_process post_gc
steady_gc_offset="$(stat -c%s "$warm_gc_log")"

echo "store-resource: idle ${idle_seconds}s" >&2
idle_cpu_before="$(cpu_usage_usec)"; idle_started_ns="$(now_ns)"
sleep "$idle_seconds"
idle_wall_ms=$(( ($(now_ns) - idle_started_ns) / 1000000 ))
idle_cpu_usec=$(( $(cpu_usage_usec) - idle_cpu_before ))

echo "store-resource: 32 connections / <=8 active for ${duration_seconds}s" >&2
agent_cpu_before="$(cpu_usage_usec)"; agent_started_ns="$(now_ns)"
run_client "$scratch/agent.json" agent "$port" "$space" "$triple_count" "$duration_seconds"
agent_wall_ms=$(( ($(now_ns) - agent_started_ns) / 1000000 ))
agent_cpu_usec=$(( $(cpu_usage_usec) - agent_cpu_before ))
run_client "$scratch/final-verify.json" verify "$port" "$space" "$triple_count"
stop_server warm
(( warm_peak_rss_bytes > peak_rss_bytes )) && peak_rss_bytes="$warm_peak_rss_bytes"
total_server_wall_ms=$(( ($(now_ns) - total_server_started_ns) / 1000000 ))
tail -c "+$((steady_gc_offset + 1))" "$warm_gc_log" >"$scratch/steady.gc.log"

log_logical_bytes="$(stat -c%s "$log_path")"
log_allocated_bytes="$(du -B1 "$log_path" | awk '{ print $1 }')"
snapshot_logical_bytes="$(stat -c%s "$snapshot_path")"
snapshot_allocated_bytes="$(du -B1 "$snapshot_path" | awk '{ print $1 }')"
cgroup_memory_peak_bytes="$(<"$cgroup_path/memory.peak")"
cgroup_swap_peak_bytes=0
[[ ! -f "$cgroup_path/memory.swap.peak" ]] || cgroup_swap_peak_bytes="$(<"$cgroup_path/memory.swap.peak")"
cgroup_oom_kills="$(memory_event oom_kill)"
total_cpu_usec="$(cpu_usage_usec)"

fact started_utc "$started_utc"
fact ended_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fact source_revision "$source_revision"
fact source_dirty "$source_dirty"
fact source_status_sha256 "$source_status_sha256"
fact artifact_sha256 "$artifact_sha256"
fact artifact_manifest_sha256 "$artifact_manifest_sha256"
fact store_home "$store_home"
fact classpath_sha256 "$classpath_sha256"
fact classpath_identity_sha256 "$classpath_identity_sha256"
fact java_path "$java_path"
fact java_real_path "$(readlink -f "$java_path")"
fact java_sha256 "$(sha256sum "$(readlink -f "$java_path")" | cut -d' ' -f1)"
fact java_settings_sha256 "$(sha256sum "$scratch/java.settings" | cut -d' ' -f1)"
fact java_version "$java_version"
fact heap_max_bytes "$heap_max_bytes"
fact kernel "$(uname -srvo)"
fact architecture "$(uname -m)"
fact logical_cpus "$(nproc)"
fact memory_total_bytes "$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024 ))"
fact cgroup_parent "$cgroup_parent"
fact cgroup_path "$cgroup_path"
fact cgroup_memory_max_bytes "$memory_max_bytes"
fact cgroup_swap_max_bytes 0
fact cgroup_parent_memory_max "$(<"$cgroup_parent/memory.max")"
fact cgroup_cpu_max "$(<"$cgroup_parent/cpu.max")"
if [[ -r "$cgroup_parent/cpuset.cpus.effective" ]]; then
  cpuset_cpus_effective="$(<"$cgroup_parent/cpuset.cpus.effective")"
else
  cpuset_cpus_effective="$(</sys/fs/cgroup/cpuset.cpus.effective)"
fi
fact cgroup_cpus_effective "$cpuset_cpus_effective"
fact triple_count "$triple_count"
fact seed_result "$scratch/seed.json"
fact initial_verify_result "$scratch/initial-verify.json"
fact checkpoint_result "$scratch/checkpoint.json"
fact cold_verify_result "$scratch/cold-verify.json"
fact warm_verify_result "$scratch/warm-verify.json"
fact agent_result "$scratch/agent.json"
fact final_verify_result "$scratch/final-verify.json"
fact load_gc_log "$load_gc_log"
fact cold_gc_log "$cold_gc_log"
fact warm_gc_log "$warm_gc_log"
fact steady_gc_log "$scratch/steady.gc.log"
fact load_wall_ms "$load_wall_ms"
fact load_cpu_usec "$load_cpu_usec"
fact checkpoint_wall_ms "$checkpoint_wall_ms"
fact checkpoint_cpu_usec "$checkpoint_cpu_usec"
fact cold_ready_wall_ms "$cold_ready_wall_ms"
fact cold_ready_cpu_usec "$cold_ready_cpu_usec"
fact warm_ready_wall_ms "$warm_ready_wall_ms"
fact warm_ready_cpu_usec "$warm_ready_cpu_usec"
fact idle_wall_ms "$idle_wall_ms"
fact idle_cpu_usec "$idle_cpu_usec"
fact agent_wall_ms "$agent_wall_ms"
fact agent_cpu_usec "$agent_cpu_usec"
fact total_server_wall_ms "$total_server_wall_ms"
fact total_cpu_usec "$total_cpu_usec"
fact post_gc_heap_used_bytes "$post_gc_heap_used_bytes"
fact post_gc_rss_bytes "$post_gc_rss_bytes"
fact post_gc_pss_bytes "$post_gc_pss_bytes"
fact post_gc_file_pss_bytes "$post_gc_file_pss_bytes"
fact post_gc_anon_bytes "$post_gc_anon_bytes"
fact post_gc_swap_bytes "$post_gc_swap_bytes"
fact post_gc_file_mapped_bytes "$post_gc_file_mapped_bytes"
fact peak_rss_bytes "$peak_rss_bytes"
fact cgroup_memory_peak_bytes "$cgroup_memory_peak_bytes"
fact cgroup_swap_peak_bytes "$cgroup_swap_peak_bytes"
fact cgroup_oom_kills "$cgroup_oom_kills"
fact log_logical_bytes "$log_logical_bytes"
fact log_allocated_bytes "$log_allocated_bytes"
fact snapshot_logical_bytes "$snapshot_logical_bytes"
fact snapshot_allocated_bytes "$snapshot_allocated_bytes"
fact unexpected_server_exits "$unexpected_server_exits"
fact evidence_directory "$evidence_directory"

mkdir "$evidence_directory"
cp "$artifact_manifest" "$evidence_directory/artifact.manifest"
cp "$classpath_identity" "$evidence_directory/classpath.identity"
cp "$scratch/source.status" "$evidence_directory/source.status"
cp "$scratch/java.settings" "$evidence_directory/java.settings"
cp "$scratch"/*.json "$evidence_directory/"
cp "$scratch"/*.log "$evidence_directory/"
cp "$scratch"/jcmd-*.txt "$evidence_directory/"
cp "$facts" "$evidence_directory/facts.tsv"

bun "$here/report.bjs" "$facts" "$output"
echo "store-resource: receipt=$output" >&2
