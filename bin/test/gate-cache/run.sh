#!/usr/bin/env bash
# Under-key regression tests for bin/_gate-cache-run.
#
# Each check plants the failure mode that would make the cache UNSOUND —
# serving a stale green proof after an input changed — and proves the cache
# re-runs instead. Everything runs in a throwaway sandbox (cache root included,
# via BEAGLE_GATE_CACHE), with a synthetic gate whose input closure exercises
# every record kind: a transitively-sourced module, a data file, an
# ENOENT-probed flag, and a directory listing.
#
# These tests run strace themselves, so they must NOT run under an outer
# gate-cache trace (ptrace allows one tracer); the runner skips cleanly there.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAP="$ROOT/bin/_gate-cache-run"

if [[ -n "${BEAGLE_GATE_CACHE_INNER:-}" ]]; then
    echo "gate-cache tests: SKIP (already under a gate-cache trace; ptrace allows one tracer)"
    exit 0
fi
if ! command -v strace >/dev/null 2>&1; then
    echo "gate-cache tests: SKIP (strace unavailable; the cache degrades to plain runs)"
    exit 0
fi

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/gate-cache-test.XXXXXX")"
trap 'rm -rf "${sandbox:?}"' EXIT
export BEAGLE_GATE_CACHE="$sandbox/cache"
unset BEAGLE_GATE_NO_CACHE

mkdir -p "$sandbox/lib" "$sandbox/data" "$sandbox/fixtures"
cat > "$sandbox/lib/module_b.sh" <<'EOF'
b_value="from-b-v1"
EOF
cat > "$sandbox/lib/module_a.sh" <<'EOF'
source "$(dirname "${BASH_SOURCE[0]}")/module_b.sh"
a_value="from-a:$b_value"
EOF
echo "input-v1" > "$sandbox/data/in.txt"
echo "fix1" > "$sandbox/fixtures/one.txt"
cat > "$sandbox/gate.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
source "$d/lib/module_a.sh"
echo "module says: $a_value"
cat "$d/data/in.txt"
[ -f "$d/feature.flag" ] && echo "flag on" || true
ls "$d/fixtures" | sort
echo "gate ok"
EOF
chmod +x "$sandbox/gate.sh"

run_gate() {  # -> combined output on stdout, exit status preserved
    "$WRAP" --domain test --id sandbox-gate --watch "$sandbox" -- \
        "$sandbox/gate.sh" 2>&1
}

failures=0
check() {  # NAME COND-EXIT DESCRIPTION
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        failures=$((failures + 1))
    fi
}

# t1: cold run executes and stores; identical rerun is served as cached-green.
out1="$(run_gate)"; rc1=$?
[[ $rc1 -eq 0 && "$out1" == *"gate ok"* && "$out1" != *cached-green* ]]
check "cold run executes (ran-green, stored)" $?
out2="$(run_gate)"; rc2=$?
[[ $rc2 -eq 0 && "$out2" == *cached-green* ]]
check "byte-identical closure replays as cached-green" $?

out2_quiet="$(BEAGLE_GATE_CACHE_QUIET_STATUS=1 run_gate)"
[[ "$out2_quiet" == *"gate ok"* && "$out2_quiet" != *cached-green* ]]
check "quiet replay preserves proof output without cache bookkeeping" $?

# t2: the replay is the same proof — stdout replayed verbatim.
body1="$(printf '%s\n' "$out1" | grep -v '^beagle-gate-cache: ')"
body2="$(printf '%s\n' "$out2" | grep -v '^beagle-gate-cache: ')"
[[ "$body1" == "$body2" ]]
check "cached replay reproduces the stored stdout" $?

# t3: touching a TRANSITIVELY loaded module (gate -> module_a -> module_b)
# invalidates the result.
echo 'b_value="from-b-v2"' > "$sandbox/lib/module_b.sh"
out3="$(run_gate)"
[[ "$out3" != *cached-green* && "$out3" == *"from-a:from-b-v2"* ]]
check "transitively-loaded module change invalidates" $?

# t4: BEAGLE_GATE_NO_CACHE=1 bypasses — runs for real, no marker, stores nothing.
run_gate > /dev/null   # re-warm after t3
out4="$(BEAGLE_GATE_NO_CACHE=1 run_gate)"
[[ "$out4" == *"gate ok"* && "$out4" != *"beagle-gate-cache:"* ]]
check "BEAGLE_GATE_NO_CACHE=1 forces a full run" $?
out4b="$(run_gate)"
[[ "$out4b" == *cached-green* ]]
check "bypass run left the stored proof intact" $?

# t5: changing the GATE SCRIPT ITSELF invalidates its own results.
printf '\n# comment that must invalidate\n' >> "$sandbox/gate.sh"
out5="$(run_gate)"
[[ "$out5" != *cached-green* && "$out5" == *"gate ok"* ]]
check "gate script change invalidates its own result" $?

# t6: a file appearing where the run probed ENOENT invalidates.
run_gate > /dev/null
touch "$sandbox/feature.flag"
out6="$(run_gate)"
[[ "$out6" != *cached-green* && "$out6" == *"flag on"* ]]
check "appearance of an ENOENT-probed file invalidates" $?

# t7: a new entry in a listed directory invalidates.
run_gate > /dev/null
echo "fix2" > "$sandbox/fixtures/two.txt"
out7="$(run_gate)"
[[ "$out7" != *cached-green* && "$out7" == *two.txt* ]]
check "listed-directory content change invalidates" $?

# t8: a red result is never cached — both runs execute.
cat > "$sandbox/red.sh" <<'EOF'
#!/usr/bin/env bash
echo "about to fail"
exit 3
EOF
chmod +x "$sandbox/red.sh"
"$WRAP" --domain test --id red --watch "$sandbox" -- "$sandbox/red.sh" > /dev/null 2>&1
rc_red1=$?
red2="$("$WRAP" --domain test --id red --watch "$sandbox" -- "$sandbox/red.sh" 2>&1)"
rc_red2=$?
[[ $rc_red1 -eq 3 && $rc_red2 -eq 3 && "$red2" != *cached-green* ]]
check "red results are never cached (exit code preserved)" $?

# t9: nested invocation (already under a trace) runs direct — no marker,
# nothing stored, exit code preserved.
cache_shape() { find "$sandbox/cache" 2>/dev/null | LC_ALL=C sort | sha256sum; }
shape_before="$(cache_shape)"
out9="$(BEAGLE_GATE_CACHE_INNER=1 "$WRAP" --domain test --id nested --watch "$sandbox" -- "$sandbox/gate.sh" 2>&1)"
rc9=$?
[[ $rc9 -eq 0 && "$out9" != *"beagle-gate-cache:"* ]]
check "nested invocation runs direct without tracing" $?
[[ "$(cache_shape)" == "$shape_before" ]]
check "nested invocation stored nothing new" $?

# t10: a different --id never sees another id's entries (identity separation).
out10="$("$WRAP" --domain test --id other-id --watch "$sandbox" -- "$sandbox/gate.sh" 2>&1)"
[[ "$out10" != *cached-green* && "$out10" == *"gate ok"* ]]
check "distinct --id gets a distinct identity (cold)" $?

# t11: a sanitizer-bearing gate (LeakSanitizer refuses ptrace) is detected,
# flagged untraceable, rerun direct — green result, never cached.
cat > "$sandbox/lsan.sh" <<'EOF'
#!/usr/bin/env bash
tracer="$(sed -n 's/^TracerPid:\t//p' /proc/self/status)"
if [[ "$tracer" != "0" ]]; then
    echo "==1==HINT: LeakSanitizer does not work under ptrace (strace, gdb, etc)" >&2
    exit 1
fi
echo "sanitized ok"
EOF
chmod +x "$sandbox/lsan.sh"
out11="$("$WRAP" --domain test --id lsan --watch "$sandbox" -- "$sandbox/lsan.sh" 2>&1)"
rc11=$?
[[ $rc11 -eq 0 && "$out11" == *"sanitized ok"* && "$out11" == *untraceable* ]]
check "sanitizer refusal flags identity and reruns direct (green)" $?
out11b="$("$WRAP" --domain test --id lsan --watch "$sandbox" -- "$sandbox/lsan.sh" 2>&1)"
rc11b=$?
[[ $rc11b -eq 0 && "$out11b" == *"sanitized ok"* && "$out11b" != *cached-green* && "$out11b" != *untraceable* ]]
check "flagged identity runs direct thereafter (uncached, single run)" $?

# t12: an ENOENT probe whose path contains `..` must be recorded as spelled.
# gcc probes /lib/../lib64: absent because /lib is missing, yet it collapses
# lexically onto /lib64, which exists. Storing the collapsed path asserts an
# absence that never held, and the entry can never be replayed.
mkdir -p "$sandbox/real"
cat > "$sandbox/dotdot.sh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
[ -e "$d/gone/../real" ] && echo "probe resolved" || echo "probe absent"
echo "dotdot ok"
EOF
chmod +x "$sandbox/dotdot.sh"
dotdot() { "$WRAP" --domain test --id dotdot --watch "$sandbox" -- "$sandbox/dotdot.sh" 2>&1; }
out12="$(dotdot)"
[[ "$out12" == *"probe absent"* && "$out12" != *cached-green* ]]
check "\`..\` probe: cold run records the absent path" $?
out12b="$(dotdot)"
[[ "$out12b" == *cached-green* ]]
check "\`..\` probe does not poison the entry (replays cached-green)" $?

# t13: and it is still a live assertion — making the probe resolve invalidates.
mkdir -p "$sandbox/gone"
out13="$(dotdot)"
[[ "$out13" != *cached-green* && "$out13" == *"probe resolved"* ]]
check "\`..\` probe becoming resolvable invalidates" $?

# t14: an access with no kernel-truth cwd must be refused, never guessed.
# execve carries no dirfd, and a forked child has no cwd of its own until it
# chdirs, so `( cd sub; ./tool.sh; echo … )` — not the last command, so bash
# forks — leaves ./tool.sh unplaceable. A same-named DECOY sits at the launch
# cwd, so the guess lands on a real file: the entry then carries the decoy as a
# dependency the run never had, and calls that the proof of the exec. Where the
# guess lands on nothing instead, the same records make the run permanently
# unreplayable. Both are the cache keying on a path it invented.
mkdir -p "$sandbox/sub"
printf '#!/usr/bin/env bash\necho "DECOY TOOL"\n' > "$sandbox/tool.sh"
printf '#!/usr/bin/env bash\necho "REAL TOOL v1"\n' > "$sandbox/sub/tool.sh"
chmod +x "$sandbox/tool.sh" "$sandbox/sub/tool.sh"
cat > "$sandbox/misresolve.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
(
  cd "$d/sub"
  ./tool.sh
  echo "subshell done"
)
echo "misresolve ok"
EOF
chmod +x "$sandbox/misresolve.sh"
misresolve() {
    ( cd "$sandbox" && "$WRAP" --domain test --id misresolve --watch "$sandbox" -- \
        "$sandbox/misresolve.sh" 2>&1 )
}
out14="$(misresolve)"
[[ "$out14" == *"REAL TOOL v1"* && "$out14" == *"not cached: unplaceable"* ]]
check "unplaceable relative exec is refused, not resolved against launch cwd" $?
out14b="$(misresolve)"
[[ "$out14b" != *cached-green* && "$out14b" == *"REAL TOOL v1"* ]]
check "an unplaceable access leaves no proof to replay" $?
printf '#!/usr/bin/env bash\necho "REAL TOOL v2"\n' > "$sandbox/sub/tool.sh"
out14c="$(misresolve)"
[[ "$out14c" == *"REAL TOOL v2"* && "$out14c" != *cached-green* ]]
check "an edit to the real tool is always reflected, never replayed stale" $?

# t15: a proof earned in one checkout replays in another. Two throwaway
# checkouts hold byte-identical content at different absolute paths, each with
# its own copy of the wrapper (a copy, not a symlink: the wrapper resolves its
# own realpath to find its repo root). Everything that pins a checkout — the
# launch cwd, the --watch root, argv, and every stored record — is stored as
# %R% and re-anchored onto whichever checkout looks the entry up.
make_checkout() {  # DIR VALUE
    local co="$1" value="$2"
    mkdir -p "$co/bin" "$co/lib" "$co/data" "$co/fixtures"
    cp "$WRAP" "$co/bin/_gate-cache-run"
    chmod +x "$co/bin/_gate-cache-run"
    echo 'mod_value="shared-v1"' > "$co/lib/mod.sh"
    echo "$value" > "$co/data/in.txt"
    echo "fx" > "$co/fixtures/one.txt"
    cat > "$co/xgate.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
cat data/in.txt                              # relative: resolves against cwd
source "$d/lib/mod.sh"; echo "mod: $mod_value"
[ -f "$d/feature.flag" ] && echo "flag on" || true
ls "$d" > /dev/null                          # the checkout ROOT, listed
ls "$d/fixtures" | sort
echo "xgate ok"
EOF
    chmod +x "$co/xgate.sh"
}
mkdir -p "$sandbox/coA" "$sandbox/coB"
coA="$(cd "$sandbox/coA" && pwd -P)"; coB="$(cd "$sandbox/coB" && pwd -P)"
make_checkout "$coA" "shared-input"
make_checkout "$coB" "shared-input"
cross() {  # CHECKOUT ID
    ( cd "$1" && "$1/bin/_gate-cache-run" --domain test --id "$2" --watch "$1" -- \
        "$1/xgate.sh" 2>&1 )
}

out15="$(cross "$coA" cross)"
[[ "$out15" == *"xgate ok"* && "$out15" != *cached-green* ]]
check "cross-checkout: checkout A runs cold and stores" $?

entry_dir_for() {  # ID -> the single stored entry directory
    grep -lx "id=$1" "$BEAGLE_GATE_CACHE"/test/*/*/meta 2>/dev/null | head -1 |
        xargs -r dirname
}
eA="$(entry_dir_for cross)"
leaked="$(cat "$eA"/files.sha256 "$eA"/dirs.list "$eA"/absent.list \
              "$eA"/links.list 2>/dev/null | grep -cF "$coA")"
[[ -n "$eA" && "$leaked" == 0 ]] && grep -qx 'LIST %R%' "$eA/dirs.list"
check "cross-checkout: no record kind stores a bare checkout root" $?

out15b="$(cross "$coB" cross)"
[[ "$out15b" == *cached-green* && "$out15b" == *"xgate ok"* ]]
check "cross-checkout: checkout B replays A's proof (cached-green)" $?

# t16: the negative the sharing must never break — a RELATIVE input resolved
# against B's launch cwd differs from A's, so A's proof must not be served.
echo "diverged-input" > "$coB/data/in.txt"
out16="$(cross "$coB" cross)"
[[ "$out16" != *cached-green* && "$out16" == *"diverged-input"* ]]
check "cross-checkout: a differing relative input in B never replays A" $?
out16b="$(cross "$coA" cross)"
[[ "$out16b" == *cached-green* && "$out16b" == *"shared-input"* ]]
check "cross-checkout: B's divergence left A's own proof intact" $?
echo "shared-input" > "$coB/data/in.txt"
out16c="$(cross "$coB" cross)"
[[ "$out16c" == *cached-green* && "$out16c" == *"shared-input"* ]]
check "cross-checkout: B replays again once the input matches" $?

# t17: an entry written under an older storage vocabulary must never be read
# with today's dictionary. Two shapes, each planted as the ONLY entry for its
# identity: an otherwise perfect entry that does not declare the vocabulary,
# and the full pre-%R% shape (checkout A's absolute root, no declaration) —
# which, believed, would validate B's run against A's files.
cross "$coA" crossv > /dev/null
eV="$(entry_dir_for crossv)"
[[ -n "$eV" && -d "$eV" ]] &&
    { cp -a "$eV" "$sandbox/entry.bak"; [[ "$(cross "$coB" crossv)" == *cached-green* ]]; }
check "old-vocabulary: control — the current-vocabulary entry does replay" $?

idV="$(dirname "$eV")"; nameV="$(basename "$eV")"
replant() {  # restore the pristine entry as the identity's only one
    rm -rf -- "${idV:?}"; mkdir -p "$idV"; cp -a "$sandbox/entry.bak" "$idV/$nameV"
}
replant
grep -v '^vocab=' "$eV/meta" > "$eV/meta.tmp" && mv "$eV/meta.tmp" "$eV/meta"
out17="$(cross "$coB" crossv)"
[[ "$out17" != *cached-green* && "$out17" == *"xgate ok"* ]]
check "old-vocabulary: an entry that declares no vocabulary never validates" $?

replant
for f in files.sha256 dirs.list absent.list links.list meta; do
    [[ -f "$eV/$f" ]] || continue
    sed -e "s|%R%|$coA|g" -e '/^vocab=/d' "$eV/$f" > "$eV/$f.tmp"
    mv "$eV/$f.tmp" "$eV/$f"
done
out17b="$(cross "$coB" crossv)"
[[ "$out17b" != *cached-green* && "$out17b" == *"xgate ok"* ]]
check "old-vocabulary: a pre-%R% entry is never re-anchored into checkout B" $?

# t18: a file whose BYTES name the checkout. A Racket `compiled/*.dep` records
# the absolute path of every dependency that is not collection-relative, so two
# checkouts with identical sources hold differing .dep bytes and a closure that
# read one could never replay in the other. The wrapper hashes such a file over
# its NORMALIZED content: the checkout spelling goes, every other bit stays.
# Two throwaway checkouts again, each with its own copy of the wrapper.
make_dep_checkout() {  # DIR DEP-BODY
    local co="$1" body="$2"
    mkdir -p "$co/bin" "$co/compiled"
    cp "$WRAP" "$co/bin/_gate-cache-run"
    chmod +x "$co/bin/_gate-cache-run"
    printf '%s\n' "$body" > "$co/compiled/mod_rkt.dep"
    cat > "$co/dgate.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(cd "$(dirname "$0")" && pwd)"
cat "$d/compiled/mod_rkt.dep" > /dev/null
echo "dgate ok"
EOF
    chmod +x "$co/dgate.sh"
}
dep_body() {  # ROOT-SPELLING [DEPENDENCY-LEAF] [COLLECTION-LEAF]
    printf '("9.1" ta6le ("srcsha" . "depsha") #"%s/lib/%s" (collects #"racket" #"%s"))' \
        "$1" "${2:-one.rkt}" "${3:-base.rkt}"
}
mkdir -p "$sandbox/coC" "$sandbox/coD"
coC="$(cd "$sandbox/coC" && pwd -P)"; coD="$(cd "$sandbox/coD" && pwd -P)"
make_dep_checkout "$coC" "$(dep_body "$coC")"
make_dep_checkout "$coD" "$(dep_body "$coD")"
dcross() {  # CHECKOUT ID
    ( cd "$1" && "$1/bin/_gate-cache-run" --domain test --id "$2" --watch "$1" -- \
        "$1/dgate.sh" 2>&1 )
}

out18="$(dcross "$coC" dep)"
[[ "$out18" == *"dgate ok"* && "$out18" != *cached-green* ]]
check ".dep: checkout C runs cold and stores" $?

eD="$(entry_dir_for dep)"
stored_dep="$(grep -F '/compiled/mod_rkt.dep' "$eD/files.sha256" | cut -c1-64)"
own_dep="$(sha256sum "$coC/compiled/mod_rkt.dep" | cut -c1-64)"
[[ -n "$stored_dep" && "$stored_dep" != "$own_dep" ]]
check ".dep: the stored hash is over normalized content, not the file's own" $?

out18b="$(dcross "$coD" dep)"
[[ "$out18b" == *cached-green* && "$out18b" == *"dgate ok"* ]]
check ".dep: one differing only by checkout root replays cross-checkout" $?

# The negatives: everything the .dep says apart from where the checkout lives
# is still keying material, so a genuinely different dependency must re-run.
printf '%s\n' "$(dep_body "$coD" TWO.rkt)" > "$coD/compiled/mod_rkt.dep"
out18c="$(dcross "$coD" dep)"
[[ "$out18c" != *cached-green* && "$out18c" == *"dgate ok"* ]]
check ".dep: one naming a different dependency never replays" $?

printf '%s\n' "$(dep_body "$coD" one.rkt list.rkt)" > "$coD/compiled/mod_rkt.dep"
out18d="$(dcross "$coD" dep)"
[[ "$out18d" != *cached-green* ]]
check ".dep: a changed collection dependency never replays" $?

# The rewrite is escaped, so it is injective: a .dep that literally spells the
# token cannot hash equal to one spelling the checkout root. Without the
# escape these two files collide and D is served C's proof — a false green,
# since the run genuinely read different bytes.
printf '%s\n' "$(dep_body '%R%')" > "$coD/compiled/mod_rkt.dep"
out18e="$(dcross "$coD" dep)"
[[ "$out18e" != *cached-green* ]]
check ".dep: a literal %R% never collides with the checkout root" $?

printf '%s\n' "$(dep_body "$coD")" > "$coD/compiled/mod_rkt.dep"
out18f="$(dcross "$coD" dep)"
[[ "$out18f" == *cached-green* ]]
check ".dep: D replays again once the .dep matches; no negative poisoned it" $?

# t19: a supervisor receipt path is a LOCATION, and a location is not an input.
# run-bounded.rkt takes BEAGLE_BOUNDED_COMPLETION_RECEIPT as the file to write
# its own `subtree-reaped-v0` outcome to, and beagle-test mints that path under
# a per-run `mktemp -d`. Keyed by VALUE, every gate invocation therefore handed
# every unit a path that had never existed before, so every identity was
# single-use and no stored result was ever reachable again.
#
# PRESENCE still keys, because presence is read: wasm-materializer.rkt's
# `run-owned/bounded` branches on whether the variable is set, forwarding an
# inherited receipt to the command under test and taking a fresh one for its own
# supervisor. Set and unset are genuinely different runs and must stay different
# identities.
#
# Each negative below asserts the NEW OUTPUT as well as the absence of the
# cached-green marker. A miss on its own proves nothing — a run that failed for
# an unrelated reason also fails to say cached-green — so every "must miss"
# check also requires the freshly changed input to appear in the output, which
# only a real re-execution can produce.
receipt_gate() {  # RECEIPT-PATH, or empty for unset
    if [[ -n "$1" ]]; then
        BEAGLE_BOUNDED_COMPLETION_RECEIPT="$1" \
            "$WRAP" --domain test --id receipt --watch "$sandbox" -- \
            "$sandbox/gate.sh" 2>&1
    else
        env -u BEAGLE_BOUNDED_COMPLETION_RECEIPT \
            "$WRAP" --domain test --id receipt --watch "$sandbox" -- \
            "$sandbox/gate.sh" 2>&1
    fi
}
receipt_path() { printf '/tmp/beagle-test-phase.%s/tier-workers/worker-%s.receipt' "$1" "$2"; }

out19="$(receipt_gate "$(receipt_path aaaaaa 0)")"
[[ "$out19" == *"gate ok"* && "$out19" != *cached-green* ]]
check "receipt: cold run under a receipt path stores" $?

out19b="$(receipt_gate "$(receipt_path bbbbbb 9)")"
[[ "$out19b" == *cached-green* && "$out19b" == *"gate ok"* ]]
check "receipt: a never-before-seen receipt path replays the stored proof" $?

out19c="$(receipt_gate "")"
[[ "$out19c" != *cached-green* && "$out19c" == *"gate ok"* ]]
check "receipt: UNSET is a different identity than set (presence still keys)" $?
out19d="$(receipt_gate "")"
[[ "$out19d" == *cached-green* ]]
check "receipt: the unset identity earns its own proof" $?
out19e="$(receipt_gate "$(receipt_path cccccc 2)")"
[[ "$out19e" == *cached-green* ]]
check "receipt: the unset run did not disturb the set identity" $?

# Exactly two identities for this id, however many receipt paths were used: one
# for set, one for unset. This is the direct anti-regression assertion — putting
# the value back into the key material makes this count grow with the paths.
receipt_identities="$(grep -lx 'id=receipt' "$BEAGLE_GATE_CACHE"/test/*/*/meta 2>/dev/null |
                      xargs -r -n1 dirname | xargs -r -n1 dirname |
                      LC_ALL=C sort -u | wc -l)"
[[ "$receipt_identities" == 2 ]]
check "receipt: many receipt paths collapse to two identities (set, unset)" $?

# The teeth. Neutralizing the value must not have cost the closure any of its
# record kinds, so change a real input of each kind and require a miss.
echo "input-v2-receipt" > "$sandbox/data/in.txt"
out19f="$(receipt_gate "$(receipt_path dddddd 1)")"
[[ "$out19f" != *cached-green* && "$out19f" == *"input-v2-receipt"* ]]
check "receipt: a changed file input still MISSES" $?

receipt_gate "$(receipt_path eeeeee 3)" > /dev/null
echo "fix3" > "$sandbox/fixtures/three.txt"
out19g="$(receipt_gate "$(receipt_path ffffff 4)")"
[[ "$out19g" != *cached-green* && "$out19g" == *three.txt* ]]
check "receipt: a changed directory listing still MISSES" $?

receipt_gate "$(receipt_path aaabbb 5)" > /dev/null
rm -f "$sandbox/feature.flag"
out19h="$(receipt_gate "$(receipt_path cccddd 6)")"
[[ "$out19h" != *cached-green* && "$out19h" != *"flag on"* ]]
check "receipt: a probed file that vanished still MISSES" $?

# And the closure is still live in both directions: restore nothing, re-run, and
# the newly proven state replays under yet another unseen receipt path.
out19i="$(receipt_gate "$(receipt_path eeefff 7)")"
[[ "$out19i" == *cached-green* ]]
check "receipt: the newly earned proof replays under a fresh receipt path" $?

echo
if [[ $failures -gt 0 ]]; then
    echo "gate-cache tests: $failures FAILED"
    exit 1
fi
echo "gate-cache tests: all green"
