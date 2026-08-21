#!/usr/bin/env bash
# SEMANTIC-READ-CLASSPATH-WRITABLE: snapshot a read-only source without making
# the build-owned copy read-only, because the build cleanup owns that copy.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="SEMANTIC-READ-CLASSPATH-WRITABLE"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-semantic-read-classpath.XXXXXX")"
source_root=""
cleanup() {
    local rc=$?
    if [[ -n "$source_root" && -d "$source_root" ]]; then
        chmod -R u+w -- "$source_root"
    fi
    rm -rf -- "${scratch:?}"
    return "$rc"
}
trap cleanup EXIT

snapshot="$scratch/snapshot.sh"
awk '
    /^semantic_read_classpath_root="\$work\/semantic-read-classpath"$/ {
        copying = 1
    }
    copying { print }
    /^semantic_read_classpath="\$semantic_read_classpath_root\/store\/out:\$semantic_read_classpath_root\/native-core\/bin"$/ {
        exit
    }
' "$root/bin/beagle-build-core" >"$snapshot"
[[ -s "$snapshot" ]] || {
    printf '%s: snapshot copy fragment was not found\n' "$gate" >&2
    exit 1
}

source_root="$scratch/read-only-source"
mkdir -p "$source_root/native-core/bin" "$source_root/store/out/store"
printf 'semantic read store\n' >"$source_root/native-core/bin/semantic_read_store.clj"
printf 'semantic read blob store\n' >"$source_root/native-core/bin/source_fact_store.clj"
printf 'semantic read database\n' >"$source_root/store/database.clj"
printf 'semantic read writer authority\n' >"$source_root/store/writer_authority.clj"
printf 'read-only classpath entry\n' >"$source_root/store/out/store/entry.clj"
chmod -R a-w -- "$source_root"

source_mode_before="$(stat -c '%a' "$source_root/store/out")"
[[ "$source_mode_before" == 555 ]] || {
    printf '%s: source fixture mode is %s, expected 555\n' \
        "$gate" "$source_mode_before" >&2
    exit 1
}

(
    work="$scratch/work"
    BEAGLE_DIR="$source_root"
    SEMANTIC_READ_STORE="$BEAGLE_DIR/native-core/bin/semantic_read_store.clj"
    SEMANTIC_READ_BLOB_STORE="$BEAGLE_DIR/native-core/bin/source_fact_store.clj"
    SEMANTIC_READ_DATABASE="$BEAGLE_DIR/store/database.clj"
    SEMANTIC_READ_WRITER_AUTHORITY="$BEAGLE_DIR/store/writer_authority.clj"
    source "$snapshot"

    [[ -w "$semantic_read_classpath_root/store/out" ]] || {
        printf '%s: destination store/out is not owner-writable\n' "$gate" >&2
        exit 1
    }
    printf 'build-owned write\n' >"$semantic_read_classpath_root/store/out/cleanup-proof"
    rm -rf -- "$semantic_read_classpath_root"
    [[ ! -e "$semantic_read_classpath_root" ]] || {
        printf '%s: destination cleanup left the classpath behind\n' "$gate" >&2
        exit 1
    }
)

source_mode_after="$(stat -c '%a' "$source_root/store/out")"
[[ "$source_mode_after" == "$source_mode_before" ]] || {
    printf '%s: source mode changed from %s to %s\n' \
        "$gate" "$source_mode_before" "$source_mode_after" >&2
    exit 1
}
printf '%s: read-only source retained mode=%s; destination write and cleanup PASS\n' \
    "$gate" "$source_mode_after"
