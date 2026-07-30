#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-checkout-first.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

project="$scratch/project"
forbidden="$scratch/forbidden"
mkdir -p "$project/bin" "$project/share" "$forbidden"

cp "$ROOT/bin/beagle" "$ROOT/bin/_beagle-racket" \
   "$ROOT/bin/beagle-promote" "$project/bin/"
# bin/beagle sources the generated target projection for its usage banner; a
# real checkout always has it, so the fixture carries it too.
cp "$ROOT/share/targets.sh" "$project/share/"

daemon_log="$scratch/daemon.log"
forbidden_log="$scratch/forbidden.log"

cat >"$project/bin/beagle-daemon" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BEAGLE_TEST_DAEMON_LOG"
case "${1:-}" in
    stop|start) ;;
    status) printf '%s\n' '{"ok":true,"status":"running"}' ;;
    *) exit 64 ;;
esac
EOF

cat >"$forbidden/reject" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >>"$BEAGLE_TEST_FORBIDDEN_LOG"
exit 99
EOF

chmod +x "$project/bin/"* "$forbidden/reject"
for name in firn nixos-rebuild systemctl north fram; do
    ln -s reject "$forbidden/$name"
done

git -C "$project" init -q
git -C "$project" config user.name "Beagle checkout-first test"
git -C "$project" config user.email "beagle-test@example.invalid"
git -C "$project" add bin share
git -C "$project" -c commit.gpgsign=false commit -qm "clean checkout"
head_commit="$(git -C "$project" rev-parse HEAD)"

run_promote() {
    PATH="$forbidden:$PATH" \
    BEAGLE_TEST_DAEMON_LOG="$daemon_log" \
    BEAGLE_TEST_FORBIDDEN_LOG="$forbidden_log" \
    BEAGLE_PROMOTE_DAEMON="$project/bin/beagle-daemon" \
        "$project/bin/beagle" promote "$@"
}

output="$(run_promote 2>&1)"
grep -Fq "checkout=$project" <<<"$output"
grep -Fq "commit=$head_commit" <<<"$output"
grep -Fq "runtime=beagle-daemon" <<<"$output"

expected_calls="$(printf 'stop\nstart --watch %s\nstatus\n' "$project")"
[[ "$(cat "$daemon_log")" == "$expected_calls" ]]
[[ ! -s "$forbidden_log" ]]

assert_dirty_rejected() {
    local label="$1"
    local before
    before="$(cat "$daemon_log")"
    if run_promote >"$scratch/$label.out" 2>&1; then
        echo "checkout-first: dirty $label checkout was promoted" >&2
        exit 1
    fi
    grep -Fq "checkout is dirty" "$scratch/$label.out"
    [[ "$(cat "$daemon_log")" == "$before" ]]
}

printf '\ntracked dirt\n' >>"$project/bin/beagle"
assert_dirty_rejected tracked
git -C "$project" restore bin/beagle

printf '\nstaged dirt\n' >>"$project/bin/beagle"
git -C "$project" add bin/beagle
assert_dirty_rejected staged
git -C "$project" restore --staged --worktree bin/beagle

printf 'untracked dirt\n' >"$project/UNTRACKED"
assert_dirty_rejected untracked

[[ ! -s "$forbidden_log" ]]
printf 'checkout-first: clean commit %s; checkout CLI selected; only beagle-daemon restarted; dirty gates rejected\n' \
    "$head_commit"
